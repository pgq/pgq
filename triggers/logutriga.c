/*
 * logutriga.c - Smart trigger that logs urlencoded changes.
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
#include <executor/spi.h>
#include <commands/trigger.h>
#include <catalog/pg_operator.h>
#include <lib/stringinfo.h>
#include <utils/typcache.h>
#include <utils/rel.h>


#include "common.h"
#include "stringutil.h"

PG_FUNCTION_INFO_V1(pgq_logutriga);
Datum pgq_logutriga(PG_FUNCTION_ARGS);

/* need to ignore UPDATE where only ignored columns change */
static int is_interesting_change(PgqTriggerEvent *ev, TriggerData *tg)
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
		if (tupdesc->attrs[i]->attisdropped)
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
				if (DatumGetBool(FunctionCall2(opr_finfo_p, old_value, new_value)))
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

void pgq_urlenc_row(PgqTriggerEvent *ev, HeapTuple row, StringInfo buf)
{
	TriggerData *tg = ev->tgdata;
	TupleDesc tupdesc = tg->tg_relation->rd_att;
	bool first = true;
	int i;
	const char *col_ident, *col_value;
	int attkind_idx = -1;

	if (ev->op_type == 'R')
		return;

	for (i = 0; i < tg->tg_relation->rd_att->natts; i++) {
		/* Skip dropped columns */
		if (tupdesc->attrs[i]->attisdropped)
			continue;

		attkind_idx++;

		if (pgqtriga_skip_col(ev, i, attkind_idx))
			continue;

		if (first)
			first = false;
		else
			appendStringInfoChar(buf, '&');

		/* quote column name */
		col_ident = SPI_fname(tupdesc, i + 1);
		pgq_encode_cstring(buf, col_ident, TBUF_QUOTE_URLENC);

		/* quote column value */
		col_value = SPI_getvalue(row, tupdesc, i + 1);
		if (col_value != NULL) {
			appendStringInfoChar(buf, '=');
			pgq_encode_cstring(buf, col_value, TBUF_QUOTE_URLENC);
		}
	}
}

/*
 * PgQ log trigger, takes 2 arguments:
 * 1. queue name to be inserted to.
 *
 * Queue events will be in format:
 *    ev_type   - operation type, I/U/D
 *    ev_data   - urlencoded column values
 *    ev_extra1 - table name
 *    ev_extra2 - optional urlencoded backup
 */
Datum pgq_logutriga(PG_FUNCTION_ARGS)
{
	TriggerData *tg;
	struct PgqTriggerEvent ev;
	HeapTuple row;

	/*
	 * Get the trigger call context
	 */
	if (!CALLED_AS_TRIGGER(fcinfo))
		elog(ERROR, "pgq.logutriga not called as trigger");

	tg = (TriggerData *)(fcinfo->context);
	if (TRIGGER_FIRED_BY_UPDATE(tg->tg_event))
		row = tg->tg_newtuple;
	else
		row = tg->tg_trigtuple;

	if (pgq_is_logging_disabled())
		goto skip_it;

	/*
	 * Connect to the SPI manager
	 */
	if (SPI_connect() < 0)
		elog(ERROR, "logutriga: SPI_connect() failed");

	pgq_prepare_event(&ev, tg, true);

	appendStringInfoString(ev.field[EV_EXTRA1], ev.info->table_name);
	appendStringInfoChar(ev.field[EV_TYPE], ev.op_type);
	if (ev.op_type != 'R') {
		appendStringInfoChar(ev.field[EV_TYPE], ':');
		appendStringInfoString(ev.field[EV_TYPE], ev.pkey_list);
	}

	if (is_interesting_change(&ev, tg)) {
		/*
		 * create type, data
		 */
		pgq_urlenc_row(&ev, row, ev.field[EV_DATA]);

		/*
		 * Construct the parameter array and insert the log row.
		 */
		pgq_insert_tg_event(&ev);
	}

	if (SPI_finish() < 0)
		elog(ERROR, "SPI_finish failed");

	/*
	 * After trigger ignores result,
	 * before trigger skips event if NULL.
	 */
skip_it:
	if (TRIGGER_FIRED_AFTER(tg->tg_event) || ev.tgargs->skip)
		return PointerGetDatum(NULL);
	else
		return PointerGetDatum(row);
}
