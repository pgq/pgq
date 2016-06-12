/*
 * insert_event.c - C implementation of pgq.insert_event_raw().
 *
 * Copyright (c) 2007 Marko Kreen, Skype Technologies OÜ
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include "postgres.h"
#include "funcapi.h"

#include "catalog/pg_type.h"
#include "commands/trigger.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"
#include "utils/builtins.h"
#include "utils/datetime.h"
#include "utils/hsearch.h"
#include "access/xact.h"

/*
 * Module tag
 */
#ifdef PG_MODULE_MAGIC
PG_MODULE_MAGIC;
#endif

#ifndef TextDatumGetCString
#define TextDatumGetCString(d) DatumGetCString(DirectFunctionCall1(textout, d))
#endif


/*
 * Function tag
 */
Datum pgq_insert_event_raw(PG_FUNCTION_ARGS);
PG_FUNCTION_INFO_V1(pgq_insert_event_raw);

/*
 * Queue info fetching.
 *
 * Always touch ev_id sequence, even if ev_id is given as arg,
 * to notify ticker about new event.
 */
#define QUEUE_SQL \
	"select queue_id::int4, queue_data_pfx::text," \
	" queue_cur_table::int4, nextval(queue_event_seq)::int8," \
	" queue_disable_insert::bool," \
	" queue_per_tx_limit::int4" \
	" from pgq.queue where queue_name = $1"
#define COL_QUEUE_ID	1
#define COL_PREFIX	2
#define COL_TBLNO	3
#define COL_EVENT_ID	4
#define COL_DISABLED	5
#define COL_LIMIT	6

/*
 * Support inserting into pgq 2 queues.
 */
#define QUEUE_SQL_OLD \
	"select queue_id::int4, queue_data_pfx::text," \
	" queue_cur_table::int4, nextval(queue_event_seq)::int8," \
	" false::bool as queue_disable_insert," \
	" null::int4 as queue_per_tx_limit" \
	" from pgq.queue where queue_name = $1"

#define QUEUE_CHECK_NEW \
	"select 1 from pg_catalog.pg_attribute" \
	" where attname = 'queue_per_tx_limit'" \
	" and attrelid = 'pgq.queue'::regclass"

/*
 * Plan cache entry in HTAB.
 */
struct InsertCacheEntry {
	Oid queue_id;		/* actually int32, but we want to use oid_hash */
	int cur_table;

	TransactionId last_xid;
	int last_count;

	void *plan;
};

/*
 * helper structure to pass values.
 */
struct QueueState {
	int queue_id;
	int cur_table;
	char *table_prefix;
	Datum next_event_id;
	bool disabled;
	int per_tx_limit;
};

/*
 * Cached plans.
 */
static void *queue_plan;
static HTAB *insert_cache;

/*
 * Prepare utility plans and plan cache.
 */
static void init_cache(void)
{
	static int init_done = 0;
	Oid types[1] = { TEXTOID };
	HASHCTL ctl;
	int flags;
	int res;
	int max_queues = 128;
	const char *sql;

	if (init_done)
		return;

	/*
	 * Check if old (v2.x) or new (v3.x) queue table.
	 *
	 * Needed for upgrades.
	 */
	res = SPI_execute(QUEUE_CHECK_NEW, 1, 0);
	if (res < 0)
		elog(ERROR, "pgq.insert_event: QUEUE_CHECK_NEW failed");

	if (SPI_processed > 0) {
		sql = QUEUE_SQL;
	} else {
		sql = QUEUE_SQL_OLD;
	}

	/*
	 * Init plans.
	 */
	queue_plan = SPI_saveplan(SPI_prepare(sql, 1, types));
	if (queue_plan == NULL)
		elog(ERROR, "pgq_insert: SPI_prepare() failed");

	/*
	 * init insert plan cache.
	 */
	MemSet(&ctl, 0, sizeof(ctl));
	ctl.keysize = sizeof(Oid);
	ctl.entrysize = sizeof(struct InsertCacheEntry);
	ctl.hash = oid_hash;
	flags = HASH_ELEM | HASH_FUNCTION;
	insert_cache = hash_create("pgq_insert_raw plans cache", max_queues, &ctl, flags);

	init_done = 1;
}

/*
 * Create new plan for insertion into current queue table.
 */
static void *make_plan(struct QueueState *state)
{
	void *plan;
	StringInfo sql;
	static Oid types[10] = {
		INT8OID, TIMESTAMPTZOID, INT4OID, INT4OID, TEXTOID,
		TEXTOID, TEXTOID, TEXTOID, TEXTOID, TEXTOID
	};

	/*
	 * create sql
	 */
	sql = makeStringInfo();
	appendStringInfo(sql, "insert into %s_%d (ev_id, ev_time, ev_owner, ev_retry,"
			 " ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4)"
			 " values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
			 state->table_prefix, state->cur_table);
	/*
	 * create plan
	 */
	plan = SPI_prepare(sql->data, 10, types);
	return SPI_saveplan(plan);
}

/*
 * fetch insert plan from cache.
 */
static void *load_insert_plan(Datum qname, struct QueueState *state)
{
	struct InsertCacheEntry *entry;
	Oid queue_id = state->queue_id;
	bool did_exist = false;

	entry = hash_search(insert_cache, &queue_id, HASH_ENTER, &did_exist);
	if (did_exist) {
		if (entry->plan && state->cur_table == entry->cur_table)
			goto valid_table;
		if (entry->plan)
			SPI_freeplan(entry->plan);
	}

	entry->cur_table = state->cur_table;
	entry->last_xid = 0;
	entry->plan = NULL;

	/* this can fail, struct must be valid before */
	entry->plan = make_plan(state);
valid_table:

	if (state->per_tx_limit >= 0) {
		TransactionId xid = GetTopTransactionId();
		if (entry->last_xid != xid) {
			entry->last_xid = xid;
			entry->last_count = 0;
		}
		entry->last_count++;
		if (entry->last_count > state->per_tx_limit)
			elog(ERROR, "Queue '%s' allows max %d events from one TX",
			     TextDatumGetCString(qname), state->per_tx_limit);
	}

	return entry->plan;
}

/*
 * load queue info from pgq.queue table.
 */
static void load_queue_info(Datum queue_name, struct QueueState *state)
{
	Datum values[1];
	int res;
	TupleDesc desc;
	HeapTuple row;
	bool isnull;

	values[0] = queue_name;
	res = SPI_execute_plan(queue_plan, values, NULL, false, 0);
	if (res != SPI_OK_SELECT)
		elog(ERROR, "Queue fetch failed");
	if (SPI_processed == 0)
		elog(ERROR, "No such queue");

	row = SPI_tuptable->vals[0];
	desc = SPI_tuptable->tupdesc;
	state->queue_id = DatumGetInt32(SPI_getbinval(row, desc, COL_QUEUE_ID, &isnull));
	if (isnull)
		elog(ERROR, "queue id NULL");
	state->cur_table = DatumGetInt32(SPI_getbinval(row, desc, COL_TBLNO, &isnull));
	if (isnull)
		elog(ERROR, "table nr NULL");
	state->table_prefix = SPI_getvalue(row, desc, COL_PREFIX);
	if (state->table_prefix == NULL)
		elog(ERROR, "table prefix NULL");
	state->next_event_id = SPI_getbinval(row, desc, COL_EVENT_ID, &isnull);
	if (isnull)
		elog(ERROR, "Seq name NULL");
	state->disabled = SPI_getbinval(row, desc, COL_DISABLED, &isnull);
	if (isnull)
		elog(ERROR, "insert_disabled NULL");
	state->per_tx_limit = SPI_getbinval(row, desc, COL_LIMIT, &isnull);
	if (isnull)
		state->per_tx_limit = -1;
}

/*
 * Arguments:
 * 0: queue_name  text		NOT NULL
 * 1: ev_id       int8		if NULL take from SEQ
 * 2: ev_time     timestamptz	if NULL use now()
 * 3: ev_owner    int4
 * 4: ev_retry    int4
 * 5: ev_type     text
 * 6: ev_data     text
 * 7: ev_extra1   text
 * 8: ev_extra2   text
 * 9: ev_extra3   text
 * 10:ev_extra4   text
 */
Datum pgq_insert_event_raw(PG_FUNCTION_ARGS)
{
	Datum values[11];
	char nulls[11];
	struct QueueState state;
	int64 ret_id;
	void *ins_plan;
	Datum ev_id, ev_time;
	int i, res;
	Datum qname;

	if (PG_NARGS() < 6)
		elog(ERROR, "Need at least 6 arguments");
	if (PG_ARGISNULL(0))
		elog(ERROR, "Queue name must not be NULL");
	qname = PG_GETARG_DATUM(0);

	if (SPI_connect() < 0)
		elog(ERROR, "SPI_connect() failed");

	init_cache();

	load_queue_info(qname, &state);

	/*
	 * Check if queue has disable_insert flag set.
	 */
#if defined(PG_VERSION_NUM) && PG_VERSION_NUM >= 80300
	/* 8.3+: allow insert_event() even if connection is in 'replica' role */
	if (state.disabled) {
		if (SessionReplicationRole != SESSION_REPLICATION_ROLE_REPLICA)
			elog(ERROR, "Insert into queue disallowed");
	}
#else
	/* pre-8.3 */
	if (state.disabled)
		elog(ERROR, "Insert into queue disallowed");
#endif

	if (PG_ARGISNULL(1))
		ev_id = state.next_event_id;
	else
		ev_id = PG_GETARG_DATUM(1);

	if (PG_ARGISNULL(2))
		ev_time = DirectFunctionCall1(now, 0);
	else
		ev_time = PG_GETARG_DATUM(2);

	/*
	 * Prepare arguments for INSERT
	 */
	values[0] = ev_id;
	nulls[0] = ' ';
	values[1] = ev_time;
	nulls[1] = ' ';
	for (i = 3; i < 11; i++) {
		int dst = i - 1;
		if (i >= PG_NARGS() || PG_ARGISNULL(i)) {
			values[dst] = (Datum)NULL;
			nulls[dst] = 'n';
		} else {
			values[dst] = PG_GETARG_DATUM(i);
			nulls[dst] = ' ';
		}
	}

	/*
	 * Perform INSERT into queue table.
	 */
	ins_plan = load_insert_plan(qname, &state);
	res = SPI_execute_plan(ins_plan, values, nulls, false, 0);
	if (res != SPI_OK_INSERT)
		elog(ERROR, "Queue insert failed");

	/*
	 * ev_id cannot pass SPI_finish()
	 */
	ret_id = DatumGetInt64(ev_id);

	if (SPI_finish() < 0)
		elog(ERROR, "SPI_finish failed");

	PG_RETURN_INT64(ret_id);
}
