/*
 * common.c - functions used by all trigger variants.
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

#include <postgres.h>

#include <access/hash.h>
#include <commands/trigger.h>
#include <catalog/pg_type.h>
#include <catalog/pg_namespace.h>
#include <catalog/pg_operator.h>
#include <executor/spi.h>
#include <lib/stringinfo.h>
#include <utils/memutils.h>
#include <utils/inval.h>
#include <utils/hsearch.h>
#include <utils/syscache.h>
#include <utils/typcache.h>
#include <utils/builtins.h>
#include <utils/rel.h>

#if PG_VERSION_NUM >= 90300
#include <access/htup_details.h>
#endif

#include "common.h"
#include "stringutil.h"
#include "qbuilder.h"

/*
 * Module tag
 */
#ifdef PG_MODULE_MAGIC
PG_MODULE_MAGIC;
#endif

/* memcmp is ok on NameData fields */
#define is_magic_field(s) (memcmp(s, "_pgq_ev_", 8) == 0)

static void make_query(struct PgqTriggerEvent *ev, int fld, const char *arg);
static void override_fields(struct PgqTriggerEvent *ev);

/*
 * primary key info
 */

static bool tbl_cache_invalid;
static MemoryContext tbl_cache_ctx;
static HTAB *tbl_cache_map;

static const char pkey_sql[] =
    "SELECT k.attnum, k.attname FROM pg_catalog.pg_index i, pg_catalog.pg_attribute k"
    " WHERE i.indrelid = $1 AND k.attrelid = i.indexrelid"
    "   AND i.indisprimary AND k.attnum > 0 AND NOT k.attisdropped"
    " ORDER BY k.attnum";
static void *pkey_plan;

static void relcache_reset_cb(Datum arg, Oid relid);

/*
 * helper for queue insertion.
 *
 * does not support NULL arguments.
 */
void pgq_simple_insert(const char *queue_name, Datum ev_type, Datum ev_data,
		       Datum ev_extra1, Datum ev_extra2, Datum ev_extra3, Datum ev_extra4)
{
	Datum values[7];
	char nulls[7];
	static void *plan = NULL;
	int res;

	if (!plan) {
		const char *sql;
		Oid   types[7] = { TEXTOID, TEXTOID, TEXTOID, TEXTOID, TEXTOID, TEXTOID, TEXTOID };

		sql = "select pgq.insert_event($1, $2, $3, $4, $5, $6, $7)";
		plan = SPI_saveplan(SPI_prepare(sql, 7, types));
		if (plan == NULL)
			elog(ERROR, "logtriga: SPI_prepare() failed");
	}
	values[0] = DirectFunctionCall1(textin, (Datum)queue_name);
	values[1] = ev_type;
	values[2] = ev_data;
	values[3] = ev_extra1;
	values[4] = ev_extra2;
	values[5] = ev_extra3;
	values[6] = ev_extra4;
	nulls[0] = ' ';
	nulls[1] = ev_type ? ' ' : 'n';
	nulls[2] = ev_data ? ' ' : 'n';
	nulls[3] = ev_extra1 ? ' ' : 'n';
	nulls[4] = ev_extra2 ? ' ' : 'n';
	nulls[5] = ev_extra3 ? ' ' : 'n';
	nulls[6] = ev_extra4 ? ' ' : 'n';
	res = SPI_execute_plan(plan, values, nulls, false, 0);
	if (res != SPI_OK_SELECT)
		elog(ERROR, "call of pgq.insert_event failed");
}

static void fill_magic_columns(PgqTriggerEvent *ev)
{
	TriggerData *tg = ev->tgdata;
	int i;
	char *col_name, *col_value;
	StringInfo *dst = NULL;
	TupleDesc tupdesc = tg->tg_relation->rd_att;
	HeapTuple row;

	if (TRIGGER_FIRED_BY_UPDATE(tg->tg_event))
		row = tg->tg_newtuple;
	else
		row = tg->tg_trigtuple;

	for (i = 0; i < tupdesc->natts; i++) {
		/* Skip dropped columns */
		if (TupleDescAttr(tupdesc, i)->attisdropped)
			continue;
		col_name = NameStr(TupleDescAttr(tupdesc, i)->attname);
		if (!is_magic_field(col_name))
			continue;
		if (strcmp(col_name, "_pgq_ev_type") == 0)
			dst = &ev->field[EV_TYPE];
		else if (strcmp(col_name, "_pgq_ev_data") == 0)
			dst = &ev->field[EV_DATA];
		else if (strcmp(col_name, "_pgq_ev_extra1") == 0)
			dst = &ev->field[EV_EXTRA1];
		else if (strcmp(col_name, "_pgq_ev_extra2") == 0)
			dst = &ev->field[EV_EXTRA2];
		else if (strcmp(col_name, "_pgq_ev_extra3") == 0)
			dst = &ev->field[EV_EXTRA3];
		else if (strcmp(col_name, "_pgq_ev_extra4") == 0)
			dst = &ev->field[EV_EXTRA4];
		else
			elog(ERROR, "Unknown magic column: %s", col_name);

		col_value = SPI_getvalue(row, tupdesc, i + 1);
		if (col_value != NULL) {
			*dst = pgq_init_varbuf();
			appendStringInfoString(*dst, col_value);
		} else {
			*dst = NULL;
		}
	}
}

void pgq_insert_tg_event(PgqTriggerEvent *ev)
{
	if (ev->tgargs->custom_fields)
		fill_magic_columns(ev);

	override_fields(ev);

	if (ev->skip_event)
		return;

	pgq_simple_insert(ev->queue_name,
			  pgq_finish_varbuf(ev->field[EV_TYPE]),
			  pgq_finish_varbuf(ev->field[EV_DATA]),
			  pgq_finish_varbuf(ev->field[EV_EXTRA1]),
			  pgq_finish_varbuf(ev->field[EV_EXTRA2]),
			  pgq_finish_varbuf(ev->field[EV_EXTRA3]),
			  pgq_finish_varbuf(ev->field[EV_EXTRA4]));
}

static char *find_table_name(Relation rel, StringInfo jsbuf)
{
	Oid nsoid = rel->rd_rel->relnamespace;
	char namebuf[NAMEDATALEN * 2 + 3];
	HeapTuple ns_tup;
	Form_pg_namespace ns_struct;
	const char *tname = NameStr(rel->rd_rel->relname);
	const char *nspname;

	/* find namespace info */
	ns_tup = SearchSysCache(NAMESPACEOID, ObjectIdGetDatum(nsoid), 0, 0, 0);
	if (!HeapTupleIsValid(ns_tup))
		elog(ERROR, "Cannot find namespace %u", nsoid);
	ns_struct = (Form_pg_namespace) GETSTRUCT(ns_tup);
	nspname = NameStr(ns_struct->nspname);

	/* fill name */
	snprintf(namebuf, sizeof(namebuf), "%s.%s", nspname, tname);

	appendStringInfoString(jsbuf, ",\"table\":[");
	pgq_encode_cstring(jsbuf, nspname, TBUF_QUOTE_JSON);
	appendStringInfoChar(jsbuf, ',');
	pgq_encode_cstring(jsbuf, tname, TBUF_QUOTE_JSON);
	appendStringInfoChar(jsbuf, ']');

	ReleaseSysCache(ns_tup);
	return pstrdup(namebuf);
}

static void init_pkey_plan(void)
{
	Oid types[1] = { OIDOID };
	pkey_plan = SPI_saveplan(SPI_prepare(pkey_sql, 1, types));
	if (pkey_plan == NULL)
		elog(ERROR, "pgq_triggers: SPI_prepare() failed");
}

static void init_cache(void)
{
	HASHCTL ctl;
	int flags;
	int max_tables = 128;

	/*
	 * create own context
	 */
	tbl_cache_ctx = AllocSetContextCreate(TopMemoryContext,
					      "pgq_triggers table info",
#if (PG_VERSION_NUM >= 110000)
					      ALLOCSET_SMALL_SIZES
#else
					      ALLOCSET_SMALL_MINSIZE,
					      ALLOCSET_SMALL_INITSIZE,
					      ALLOCSET_SMALL_MAXSIZE
#endif
					      );

	/*
	 * init pkey cache.
	 */
	MemSet(&ctl, 0, sizeof(ctl));
	ctl.keysize = sizeof(Oid);
	ctl.entrysize = sizeof(struct PgqTableInfo);
	ctl.hash = oid_hash;
	flags = HASH_ELEM | HASH_FUNCTION;
	tbl_cache_map = hash_create("pgq_triggers pkey cache", max_tables, &ctl, flags);
}

/*
 * Prepare utility plans and plan cache.
 */
static void init_module(void)
{
	static int callback_init = 0;

	/* do full reset if requested */
	if (tbl_cache_invalid) {
		if (tbl_cache_map)
			hash_destroy(tbl_cache_map);
		if (tbl_cache_ctx)
			MemoryContextDelete(tbl_cache_ctx);
		tbl_cache_map = NULL;
		tbl_cache_ctx = NULL;
		tbl_cache_invalid = false;
	}

	/* re-initialize cache */
	if (tbl_cache_ctx)
		return;
	init_cache();

	/*
	 * Rest is done only once.
	 */

	if (!pkey_plan)
		init_pkey_plan();

	if (!callback_init) {
		CacheRegisterRelcacheCallback(relcache_reset_cb, (Datum)0);
		callback_init = 1;
	}
}

/*
 * Fill table information in hash table.
 */
static void fill_tbl_info(Relation rel, struct PgqTableInfo *info)
{
	StringInfo pkeys;
	Datum values[1];
	const char *name;
	TupleDesc desc;
	HeapTuple row;
	bool isnull;
	int res, i, attno;
	StringInfo jsbuf;

	jsbuf = makeStringInfo();
	name = find_table_name(rel, jsbuf);
	appendStringInfoString(jsbuf, ",\"pkey\":[");

	/* load pkeys */
	values[0] = ObjectIdGetDatum(rel->rd_id);
	res = SPI_execute_plan(pkey_plan, values, NULL, false, 0);
	if (res != SPI_OK_SELECT)
		elog(ERROR, "pkey_plan exec failed: %d", res);

	/*
	 * Fill info
	 */

	desc = SPI_tuptable->tupdesc;
	pkeys = makeStringInfo();
	info->n_pkeys = SPI_processed;
	info->table_name = MemoryContextStrdup(tbl_cache_ctx, name);
	info->pkey_attno = MemoryContextAlloc(tbl_cache_ctx, info->n_pkeys * sizeof(int));

	for (i = 0; i < SPI_processed; i++) {
		row = SPI_tuptable->vals[i];

		attno = DatumGetInt16(SPI_getbinval(row, desc, 1, &isnull));
		name = SPI_getvalue(row, desc, 2);
		info->pkey_attno[i] = attno;
		if (i > 0) {
			appendStringInfoChar(pkeys, ',');
			appendStringInfoChar(jsbuf, ',');
		}
		appendStringInfoString(pkeys, name);
		pgq_encode_cstring(jsbuf, name, TBUF_QUOTE_JSON);
	}
	appendStringInfoChar(jsbuf, ']');
	info->pkey_list = MemoryContextStrdup(tbl_cache_ctx, pkeys->data);
	info->json_info = MemoryContextStrdup(tbl_cache_ctx, jsbuf->data);
	info->tg_cache = NULL;
}

static void clean_info(struct PgqTableInfo *info, bool found)
{
	struct PgqTriggerInfo *tg, *tmp = info->tg_cache;
	int i;

	if (!found)
		goto uninitialized;

	for (tg = info->tg_cache; tg; ) {
		tmp = tg->next;
		if (tg->ignore_list)
			pfree((void *)tg->ignore_list);
		if (tg->pkey_list)
			pfree((void *)tg->pkey_list);
		for (i = 0; i < EV_NFIELDS; i++) {
			if (tg->query[i])
				qb_free(tg->query[i]);
		}
		pfree(tg);
		tg = tmp;
	}
	if (info->table_name)
		pfree(info->table_name);
	if (info->pkey_attno)
		pfree(info->pkey_attno);
	if (info->pkey_list)
		pfree((void *)info->pkey_list);
	if (info->json_info)
		pfree((void *)info->json_info);

uninitialized:
	info->tg_cache = NULL;
	info->table_name = NULL;
	info->pkey_attno = NULL;
	info->pkey_list = NULL;
	info->n_pkeys = 0;
	info->invalid = true;
	info->json_info = NULL;
}

/*
 * the callback can be launched any time from signal callback,
 * only minimal tagging can be done here.
 */
static void relcache_reset_cb(Datum arg, Oid relid)
{
	if (relid == InvalidOid) {
		tbl_cache_invalid = true;
	} else if (tbl_cache_map && !tbl_cache_invalid) {
		struct PgqTableInfo *entry;
		entry = hash_search(tbl_cache_map, &relid, HASH_FIND, NULL);
		if (entry)
			entry->invalid = true;
	}
}

/*
 * fetch table struct from cache.
 */
static struct PgqTableInfo *find_table_info(Relation rel)
{
	struct PgqTableInfo *entry;
	bool found = false;

	init_module();

	entry = hash_search(tbl_cache_map, &rel->rd_id, HASH_ENTER, &found);
	if (!found || entry->invalid) {
		clean_info(entry, found);

		/*
		 * During fill_tbl_info() 2 events can happen:
		 * - table info reset
		 * - exception
		 * To survive both, always clean struct and tag
		 * as invalid but differently from reset.
		 */
		entry->invalid = 2;

		/* find info */
		fill_tbl_info(rel, entry);

		/*
		 * If no reset happened, it's valid.  Actual reset
		 * is postponed to next call.
		 */
		if (entry->invalid == 2)
			entry->invalid = false;
	}

	return entry;
}

static struct PgqTriggerInfo *find_trigger_info(struct PgqTableInfo *info, Oid tgoid, bool create)
{
	struct PgqTriggerInfo *tgargs;
	for (tgargs = info->tg_cache; tgargs; tgargs = tgargs->next) {
		if (tgargs->tgoid == tgoid)
			return tgargs;
	}
	if (!create)
		return NULL;
	tgargs = MemoryContextAllocZero(tbl_cache_ctx, sizeof(*tgargs));
	tgargs->tgoid = tgoid;
	tgargs->next = info->tg_cache;
	info->tg_cache = tgargs;
	return tgargs;
}

static void parse_newstyle_args(PgqTriggerEvent *ev, TriggerData *tg)
{
	int i;

	/*
	 * parse args
	 */
	for (i = 1; i < tg->tg_trigger->tgnargs; i++) {
		const char *arg = tg->tg_trigger->tgargs[i];
		if (strcmp(arg, "SKIP") == 0)
			ev->tgargs->skip = true;
		else if (strncmp(arg, "ignore=", 7) == 0)
			ev->tgargs->ignore_list = MemoryContextStrdup(tbl_cache_ctx, arg + 7);
		else if (strncmp(arg, "pkey=", 5) == 0)
			ev->tgargs->pkey_list = MemoryContextStrdup(tbl_cache_ctx, arg + 5);
		else if (strcmp(arg, "backup") == 0)
			ev->tgargs->backup = true;
		else if (strcmp(arg, "deny") == 0)
			ev->tgargs->deny = true;
		else if (strncmp(arg, "ev_extra4=", 10) == 0)
			make_query(ev, EV_EXTRA4, arg + 10);
		else if (strncmp(arg, "ev_extra3=", 10) == 0)
			make_query(ev, EV_EXTRA3, arg + 10);
		else if (strncmp(arg, "ev_extra2=", 10) == 0)
			make_query(ev, EV_EXTRA2, arg + 10);
		else if (strncmp(arg, "ev_extra1=", 10) == 0)
			make_query(ev, EV_EXTRA1, arg + 10);
		else if (strncmp(arg, "ev_data=", 8) == 0)
			make_query(ev, EV_DATA, arg + 8);
		else if (strncmp(arg, "ev_type=", 8) == 0)
			make_query(ev, EV_TYPE, arg + 8);
		else if (strncmp(arg, "when=", 5) == 0)
			make_query(ev, EV_WHEN, arg + 5);
		else
			elog(ERROR, "bad param to pgq trigger");
	}

	if (ev->op_type == 'R') {
		if (ev->tgargs->ignore_list)
			elog(ERROR, "Column ignore does not make sense for truncate trigger");
		if (ev->tgargs->pkey_list)
			elog(ERROR, "Custom pkey_list does not make sense for truncate trigger");
		if (ev->tgargs->backup)
			elog(ERROR, "Backup does not make sense for truncate trigger");
	}
}

static void parse_oldstyle_args(PgqTriggerEvent *ev, TriggerData *tg)
{
	const char *kpos;
	int attcnt, i;
	TupleDesc tupdesc;

	if (tg->tg_trigger->tgnargs < 2 || tg->tg_trigger->tgnargs > 3)
		elog(ERROR, "pgq.logtriga must be used with 2 or 3 args");
	ev->attkind = tg->tg_trigger->tgargs[1];
	ev->attkind_len = strlen(ev->attkind);
	if (tg->tg_trigger->tgnargs > 2)
		ev->table_name = tg->tg_trigger->tgargs[2];

	/*
	 * Count number of active columns
	 */
	tupdesc = tg->tg_relation->rd_att;
	for (i = 0, attcnt = 0; i < tupdesc->natts; i++) {
		if (!TupleDescAttr(tupdesc, i)->attisdropped)
			attcnt++;
	}

	/*
	 * look if last pkey column exists
	 */
	kpos = strrchr(ev->attkind, 'k');
	if (kpos == NULL)
		elog(ERROR, "need at least one key column");
	if (kpos - ev->attkind >= attcnt)
		elog(ERROR, "key column does not exist");
}

/*
 * parse trigger arguments.
 */
void pgq_prepare_event(struct PgqTriggerEvent *ev, TriggerData *tg, bool newstyle, bool jsonbackup)
{
	memset(ev, 0, sizeof(*ev));

	/*
	 * Check trigger calling conventions
	 */
	if (TRIGGER_FIRED_BY_TRUNCATE(tg->tg_event)) {
		if (!TRIGGER_FIRED_FOR_STATEMENT(tg->tg_event))
			elog(ERROR, "pgq tRuncate trigger must be fired FOR EACH STATEMENT");
	} else if (!TRIGGER_FIRED_FOR_ROW(tg->tg_event)) {
		elog(ERROR, "pgq Ins/Upd/Del trigger must be fired FOR EACH ROW");
	}
	if (tg->tg_trigger->tgnargs < 1)
		elog(ERROR, "pgq trigger must have destination queue as argument");

	/*
	 * check operation type
	 */
	if (TRIGGER_FIRED_BY_INSERT(tg->tg_event)) {
		ev->op_type = 'I';
		ev->op_type_str = "INSERT";
	} else if (TRIGGER_FIRED_BY_UPDATE(tg->tg_event)) {
		ev->op_type = 'U';
		ev->op_type_str = "UPDATE";
	} else if (TRIGGER_FIRED_BY_DELETE(tg->tg_event)) {
		ev->op_type = 'D';
		ev->op_type_str = "DELETE";
	} else if (TRIGGER_FIRED_BY_TRUNCATE(tg->tg_event)) {
		ev->op_type = 'R';
		ev->op_type_str = "TRUNCATE";
	} else {
		elog(ERROR, "unknown event for pgq trigger");
	}

	/*
	 * load table info
	 */
	ev->tgdata = tg;
	ev->info = find_table_info(tg->tg_relation);
	ev->table_name = ev->info->table_name;
	ev->pkey_list = ev->info->pkey_list;
	ev->queue_name = tg->tg_trigger->tgargs[0];

	/*
	 * parse args, newstyle args are cached
	 */
	ev->tgargs = find_trigger_info(ev->info, tg->tg_trigger->tgoid, true);
	if (newstyle) {
		if (!ev->tgargs->finalized)
			parse_newstyle_args(ev, tg);
		if (ev->tgargs->pkey_list)
			ev->pkey_list = ev->tgargs->pkey_list;
		/* Check if we have pkey */
		if (ev->op_type == 'U' || ev->op_type == 'D') {
			if (ev->pkey_list[0] == 0)
				elog(ERROR, "Update/Delete on table without pkey");
		}
	} else {
		parse_oldstyle_args(ev, tg);
	}
	ev->tgargs->finalized = true;

	/*
	 * Check if BEFORE/AFTER makes sense.
	 */
	if (ev->tgargs->skip) {
		if (TRIGGER_FIRED_AFTER(tg->tg_event))
			elog(ERROR, "SKIP does not work in AFTER trigger.");
	} else {
		if (!TRIGGER_FIRED_AFTER(tg->tg_event))
			/* dont care ??? */ ;
	}

	if (ev->tgargs->deny) {
		elog(ERROR, "Table '%s' to queue '%s': change not allowed (%s)",
		     ev->table_name, ev->queue_name, ev->op_type_str);
	}

	/*
	 * init data
	 */
	ev->field[EV_TYPE] = pgq_init_varbuf();
	ev->field[EV_DATA] = pgq_init_varbuf();
	ev->field[EV_EXTRA1] = pgq_init_varbuf();

	/*
	 * Do the backup, if requested.
	 */
	if (ev->tgargs->backup && ev->op_type == 'U') {
		ev->field[EV_EXTRA2] = pgq_init_varbuf();
		if (jsonbackup) {
			pgq_jsonenc_row(ev, tg->tg_trigtuple, ev->field[EV_EXTRA2]);
		} else {
			pgq_urlenc_row(ev, tg->tg_trigtuple, ev->field[EV_EXTRA2]);
		}
	}
}

/*
 * Check if column should be skipped
 */
bool pgqtriga_skip_col(PgqTriggerEvent *ev, int i, int attkind_idx)
{
	TriggerData *tg = ev->tgdata;
	TupleDesc tupdesc;
	const char *name;

	tupdesc = tg->tg_relation->rd_att;
	if (TupleDescAttr(tupdesc, i)->attisdropped)
		return true;
	name = NameStr(TupleDescAttr(tupdesc, i)->attname);

	if (is_magic_field(name)) {
		ev->tgargs->custom_fields = 1;
		return true;
	}

	if (ev->attkind) {
		if (attkind_idx >= ev->attkind_len)
			return true;
		return ev->attkind[attkind_idx] == 'i';
	} else if (ev->tgargs->ignore_list) {
		return pgq_strlist_contains(ev->tgargs->ignore_list, name);
	}
	return false;
}

/*
 * Check if column is pkey.
 */
bool pgqtriga_is_pkey(PgqTriggerEvent *ev, int i, int attkind_idx)
{
	TriggerData *tg = ev->tgdata;
	TupleDesc tupdesc;
	const char *name;

	if (ev->attkind) {
		if (attkind_idx >= ev->attkind_len)
			return false;
		return ev->attkind[attkind_idx] == 'k';
	} else if (ev->pkey_list) {
		tupdesc = tg->tg_relation->rd_att;
		if (TupleDescAttr(tupdesc, i)->attisdropped)
			return false;
		name = NameStr(TupleDescAttr(tupdesc, i)->attname);
		if (is_magic_field(name)) {
			ev->tgargs->custom_fields = 1;
			return false;
		}
		return pgq_strlist_contains(ev->pkey_list, name);
	}
	return false;
}


/*
 * Check if trigger action should be skipped.
 */

bool pgq_is_logging_disabled(void)
{
#if defined(PG_VERSION_NUM) && PG_VERSION_NUM >= 80300
	/*
	 * Force-disable the trigger in local replication role. In other
	 * roles rely on the enabled/disabled status of the trigger.
	 */
	if (SessionReplicationRole == SESSION_REPLICATION_ROLE_LOCAL)
		return true;
#endif
	return false;
}

/*
 * Callbacks for queryfilter
 */

static int tg_name_lookup(void *arg, const char *name, int len)
{
	TriggerData *tg = arg;
	TupleDesc desc = tg->tg_relation->rd_att;
	char namebuf[NAMEDATALEN + 1];
	int nr;

	if (len >= sizeof(namebuf))
		return -1;
	memcpy(namebuf, name, len);
	namebuf[len] = 0;

	nr = SPI_fnumber(desc, namebuf);
	if (nr > 0)
		return nr;
	return -1;
}

static Oid tg_type_lookup(void *arg, int spi_nr)
{
	TriggerData *tg = arg;
	TupleDesc desc = tg->tg_relation->rd_att;

	return SPI_gettypeid(desc, spi_nr);
}

static Datum tg_value_lookup(void *arg, int spi_nr, bool *isnull)
{
	TriggerData *tg = arg;
	TupleDesc desc = tg->tg_relation->rd_att;
	HeapTuple row;

	if (TRIGGER_FIRED_BY_UPDATE(tg->tg_event))
		row = tg->tg_newtuple;
	else
		row = tg->tg_trigtuple;

	return SPI_getbinval(row, desc, spi_nr, isnull);
}

static const struct QueryBuilderOps tg_ops = {
	tg_name_lookup,
	tg_type_lookup,
	tg_value_lookup,
};

/*
 * Custom override queries for field values.
 */

static void make_query(struct PgqTriggerEvent *ev, int fld, const char *arg)
{
	struct TriggerData *tg = ev->tgdata;
	struct PgqTriggerInfo *tgargs;
	struct QueryBuilder *q;
	Oid tgoid = tg->tg_trigger->tgoid;
	const char *pfx = "select ";

	if (ev->op_type == 'R')
		elog(ERROR, "Custom expressions do not make sense for truncater trigger");

	/* make sure tgargs exists */
	if (!ev->tgargs)
		ev->tgargs = find_trigger_info(ev->info, tgoid, true);
	tgargs = ev->tgargs;

	if (tgargs->query[fld]) {
		/* seems we already have prepared query */
		if (tgargs->query[fld]->plan)
			return;
		/* query is broken, last prepare failed? */
		qb_free(tgargs->query[fld]);
		tgargs->query[fld] = NULL;
	}

	/* allocate query in right context */
	q = qb_create(&tg_ops, tbl_cache_ctx);

	/* attach immediately */
	tgargs->query[fld] = q;

	/* prepare the query */
	qb_add_raw(q, pfx, strlen(pfx));
	qb_add_parse(q, arg, tg);
	qb_prepare(q, tg);
}

static void override_fields(struct PgqTriggerEvent *ev)
{
	TriggerData *tg = ev->tgdata;
	int res, i;
	char *val;

	/* no overrides */
	if (!ev->tgargs)
		return;

	for (i = 0; i < EV_NFIELDS; i++) {
		if (!ev->tgargs->query[i])
			continue;
		res = qb_execute(ev->tgargs->query[i], tg);
		if (res != SPI_OK_SELECT)
			elog(ERROR, "Override query failed");
		if (SPI_processed != 1)
			elog(ERROR, "Expect 1 row from override query, got %d", (int)SPI_processed);

		/* special handling for EV_WHEN */
		if (i == EV_WHEN) {
			bool isnull;
			Oid oid = SPI_gettypeid(SPI_tuptable->tupdesc, 1);
			Datum when_res;
			if (oid != BOOLOID)
				elog(ERROR, "when= query result must be boolean, got=%u", oid);
			when_res = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
			if (isnull)
				elog(ERROR, "when= should not be NULL");
			if (DatumGetBool(when_res) == 0)
				ev->skip_event = true;
			continue;
		}

		/* normal field */
		val = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1);
		if (ev->field[i]) {
			pfree(ev->field[i]->data);
			pfree(ev->field[i]);
			ev->field[i] = NULL;
		}
		if (val) {
			ev->field[i] = pgq_init_varbuf();
			appendStringInfoString(ev->field[i], val);
		}
	}
}

/*
 * need to ignore UPDATE where only ignored columns change
 */
int pgq_is_interesting_change(PgqTriggerEvent *ev, TriggerData *tg)
{
	HeapTuple old_row = tg->tg_trigtuple;
	HeapTuple new_row = tg->tg_newtuple;
	TupleDesc tupdesc = tg->tg_relation->rd_att;
	Datum old_value;
	Datum new_value;
	bool old_isnull;
	bool new_isnull;
	bool is_pk;

	int i, attkind_idx = -1;
	int ignore_count = 0;

	/* only UPDATE may need to be ignored */
	if (!TRIGGER_FIRED_BY_UPDATE(tg->tg_event))
		return 1;

	for (i = 0; i < tupdesc->natts; i++) {
		/*
		 * Ignore dropped columns
		 */
		if (TupleDescAttr(tupdesc, i)->attisdropped)
			continue;
		attkind_idx++;

		is_pk = pgqtriga_is_pkey(ev, i, attkind_idx);
		if (!is_pk && ev->tgargs->ignore_list == NULL)
			continue;

		old_value = SPI_getbinval(old_row, tupdesc, i + 1, &old_isnull);
		new_value = SPI_getbinval(new_row, tupdesc, i + 1, &new_isnull);

		/*
		 * If old and new value are NULL, the column is unchanged
		 */
		if (old_isnull && new_isnull)
			continue;

		/*
		 * If both are NOT NULL, we need to compare the values and skip
		 * setting the column if equal
		 */
		if (!old_isnull && !new_isnull) {
			Oid opr_oid;
			FmgrInfo *opr_finfo_p;

			/*
			 * Lookup the equal operators function call info using the
			 * typecache if available
			 */
			TypeCacheEntry *type_cache;

			type_cache = lookup_type_cache(SPI_gettypeid(tupdesc, i + 1),
						       TYPECACHE_EQ_OPR | TYPECACHE_EQ_OPR_FINFO);
			opr_oid = type_cache->eq_opr;
			if (opr_oid == ARRAY_EQ_OP)
				opr_oid = InvalidOid;
			else
				opr_finfo_p = &(type_cache->eq_opr_finfo);

			/*
			 * If we have an equal operator, use that to do binary
			 * comparison. Else get the string representation of both
			 * attributes and do string comparison.
			 */
			if (OidIsValid(opr_oid)) {
				if (DatumGetBool(FunctionCall2Coll(opr_finfo_p,
								   TupleDescAttr(tupdesc, i)->attcollation,
								   old_value, new_value)))
					continue;
			} else {
				char *old_strval = SPI_getvalue(old_row, tupdesc, i + 1);
				char *new_strval = SPI_getvalue(new_row, tupdesc, i + 1);

				if (strcmp(old_strval, new_strval) == 0)
					continue;
			}
		}

		if (is_pk)
			elog(ERROR, "primary key update not allowed");

		if (pgqtriga_skip_col(ev, i, attkind_idx)) {
			/* this change should be ignored */
			ignore_count++;
			continue;
		}

		/* a non-ignored column has changed */
		return 1;
	}

	/* skip if only ignored column had changed */
	if (ignore_count)
		return 0;

	/* do show NOP updates */
	return 1;
}

