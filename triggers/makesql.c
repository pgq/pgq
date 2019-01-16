/*
 * makesql.c - generate partial SQL statement for row change.
 *
 * Copyright (c) 2007 Marko Kreen, Skype Technologies OÜ
 *
 * Based on Slony-I log trigger:
 *
 *   Copyright (c) 2003-2006, PostgreSQL Global Development Group
 *	 Author: Jan Wieck, Afilias USA INC.
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


static void append_key_eq(StringInfo buf, const char *col_ident, const char *col_value)
{
	if (col_value == NULL)
		elog(ERROR, "logtriga: Unexpected NULL key value");

	pgq_encode_cstring(buf, col_ident, TBUF_QUOTE_IDENT);
	appendStringInfoChar(buf, '=');
	pgq_encode_cstring(buf, col_value, TBUF_QUOTE_LITERAL);
}

static void append_normal_eq(StringInfo buf, const char *col_ident, const char *col_value)
{
	pgq_encode_cstring(buf, col_ident, TBUF_QUOTE_IDENT);
	appendStringInfoChar(buf, '=');
	if (col_value != NULL)
		pgq_encode_cstring(buf, col_value, TBUF_QUOTE_LITERAL);
	else
		appendStringInfoString(buf, "NULL");
}

static void process_insert(PgqTriggerEvent *ev, StringInfo sql)
{
	TriggerData *tg = ev->tgdata;
	HeapTuple new_row = tg->tg_trigtuple;
	TupleDesc tupdesc = tg->tg_relation->rd_att;
	int i;
	int need_comma = false;
	int attkind_idx;

	/*
	 * Specify all the columns
	 */
	appendStringInfoChar(sql, '(');
	attkind_idx = -1;
	for (i = 0; i < tupdesc->natts; i++) {
		char *col_ident;

		/* Skip dropped columns */
		if (TupleDescAttr(tupdesc, i)->attisdropped)
			continue;

		/* Check if allowed by colstring */
		attkind_idx++;
		if (pgqtriga_skip_col(ev, i, attkind_idx))
			continue;

		if (need_comma)
			appendStringInfoChar(sql, ',');
		else
			need_comma = true;

		/* quote column name */
		col_ident = SPI_fname(tupdesc, i + 1);
		pgq_encode_cstring(sql, col_ident, TBUF_QUOTE_IDENT);
	}

	/*
	 * Append the string ") values ("
	 */
	appendStringInfoString(sql, ") values (");

	/*
	 * Append the values
	 */
	need_comma = false;
	attkind_idx = -1;
	for (i = 0; i < tupdesc->natts; i++) {
		char *col_value;

		/* Skip dropped columns */
		if (TupleDescAttr(tupdesc, i)->attisdropped)
			continue;

		/* Check if allowed by colstring */
		attkind_idx++;
		if (pgqtriga_skip_col(ev, i, attkind_idx))
			continue;

		if (need_comma)
			appendStringInfoChar(sql, ',');
		else
			need_comma = true;

		/* quote column value */
		col_value = SPI_getvalue(new_row, tupdesc, i + 1);
		if (col_value == NULL)
			appendStringInfoString(sql, "null");
		else
			pgq_encode_cstring(sql, col_value, TBUF_QUOTE_LITERAL);
	}

	/*
	 * Terminate and done
	 */
	appendStringInfoChar(sql, ')');
}

static int process_update(PgqTriggerEvent *ev, StringInfo sql)
{
	TriggerData *tg = ev->tgdata;
	HeapTuple old_row = tg->tg_trigtuple;
	HeapTuple new_row = tg->tg_newtuple;
	TupleDesc tupdesc = tg->tg_relation->rd_att;
	Datum old_value;
	Datum new_value;
	bool old_isnull;
	bool new_isnull;

	char *col_ident;
	char *col_value;
	int i;
	int need_comma = false;
	int need_and = false;
	int attkind_idx;
	int ignore_count = 0;

	attkind_idx = -1;
	for (i = 0; i < tupdesc->natts; i++) {
		/*
		 * Ignore dropped columns
		 */
		if (TupleDescAttr(tupdesc, i)->attisdropped)
			continue;

		attkind_idx++;

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

		if (pgqtriga_is_pkey(ev, i, attkind_idx))
			elog(ERROR, "primary key update not allowed");

		if (pgqtriga_skip_col(ev, i, attkind_idx)) {
			/* this change should be ignored */
			ignore_count++;
			continue;
		}

		if (need_comma)
			appendStringInfoChar(sql, ',');
		else
			need_comma = true;

		col_ident = SPI_fname(tupdesc, i + 1);
		col_value = SPI_getvalue(new_row, tupdesc, i + 1);

		append_normal_eq(sql, col_ident, col_value);
	}

	/*
	 * It can happen that the only UPDATE an application does is to set a
	 * column to the same value again. In that case, we'd end up here with
	 * no columns in the SET clause yet. We add the first key column here
	 * with it's old value to simulate the same for the replication
	 * engine.
	 */
	if (!need_comma) {
		/* there was change in ignored columns, skip whole event */
		if (ignore_count > 0)
			return 0;

		for (i = 0, attkind_idx = -1; i < tupdesc->natts; i++) {
			if (TupleDescAttr(tupdesc, i)->attisdropped)
				continue;

			attkind_idx++;
			if (pgqtriga_is_pkey(ev, i, attkind_idx))
				break;
		}
		col_ident = SPI_fname(tupdesc, i + 1);
		col_value = SPI_getvalue(old_row, tupdesc, i + 1);

		append_key_eq(sql, col_ident, col_value);
	}

	appendStringInfoString(sql, " where ");

	for (i = 0, attkind_idx = -1; i < tupdesc->natts; i++) {
		/*
		 * Ignore dropped columns
		 */
		if (TupleDescAttr(tupdesc, i)->attisdropped)
			continue;

		attkind_idx++;
		if (!pgqtriga_is_pkey(ev, i, attkind_idx))
			continue;

		col_ident = SPI_fname(tupdesc, i + 1);
		col_value = SPI_getvalue(old_row, tupdesc, i + 1);

		if (need_and)
			appendStringInfoString(sql, " and ");
		else
			need_and = true;

		append_key_eq(sql, col_ident, col_value);
	}
	return 1;
}

static void process_delete(PgqTriggerEvent *ev, StringInfo sql)
{
	TriggerData *tg = ev->tgdata;
	HeapTuple old_row = tg->tg_trigtuple;
	TupleDesc tupdesc = tg->tg_relation->rd_att;
	char *col_ident;
	char *col_value;
	int i;
	int need_and = false;
	int attkind_idx;

	for (i = 0, attkind_idx = -1; i < tupdesc->natts; i++) {
		if (TupleDescAttr(tupdesc, i)->attisdropped)
			continue;

		attkind_idx++;
		if (!pgqtriga_is_pkey(ev, i, attkind_idx))
			continue;
		col_ident = SPI_fname(tupdesc, i + 1);
		col_value = SPI_getvalue(old_row, tupdesc, i + 1);

		if (need_and)
			appendStringInfoString(sql, " and ");
		else
			need_and = true;

		append_key_eq(sql, col_ident, col_value);
	}
}

int pgqtriga_make_sql(PgqTriggerEvent *ev, StringInfo sql)
{
	TriggerData *tg = ev->tgdata;
	TupleDesc tupdesc;
	int i;
	int attcnt;
	int need_event = 1;

	tupdesc = tg->tg_relation->rd_att;

	/*
	 * Count number of active columns
	 */
	for (i = 0, attcnt = 0; i < tupdesc->natts; i++) {
		if (TupleDescAttr(tupdesc, i)->attisdropped)
			continue;
		attcnt++;
	}

	/*
	 * Determine cmdtype and op_data depending on the command type
	 */
	if (TRIGGER_FIRED_BY_INSERT(tg->tg_event)) {
		process_insert(ev, sql);
	} else if (TRIGGER_FIRED_BY_UPDATE(tg->tg_event)) {
		need_event = process_update(ev, sql);
	} else if (TRIGGER_FIRED_BY_DELETE(tg->tg_event)) {
		process_delete(ev, sql);
	} else if (TRIGGER_FIRED_BY_TRUNCATE(tg->tg_event)) {
		/* nothing to do for truncate */
	} else
		elog(ERROR, "logtriga fired for unhandled event");

	return need_event;
}
