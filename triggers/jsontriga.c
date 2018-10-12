/*
 * jsontriga.c - Smart trigger that logs JSON-encoded changes.
 *
 * Copyright (c) 2016 Marko Kreen
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
#include <catalog/pg_type.h>
#include <catalog/pg_operator.h>
#include <lib/stringinfo.h>
#include <utils/typcache.h>
#include <utils/rel.h>
#include <utils/date.h>
#include <utils/datetime.h>
#include <utils/timestamp.h>
#include <miscadmin.h>

#include "common.h"
#include "stringutil.h"

PG_FUNCTION_INFO_V1(pgq_jsontriga);
Datum pgq_jsontriga(PG_FUNCTION_ARGS);

/*
 * Force DateStyle like to_json() does.  Unfortunately
 * there is no sane way to call to_json() or it's underlying
 * helpers from C.  Need to reimplement, with some compat goo.
 *
 * But from plus side, timestamps work same way in 9.[012] now too.
 */

#if PG_VERSION_NUM < 90200

static void CompatEncodeDateTime(struct pg_tm * tm, fsec_t fsec, bool print_tz, int tz, const char *tzn, int style, char *str)
{
	if (print_tz) {
		EncodeDateTime(tm, fsec, &tz, NULL, style, str);
	} else {
		EncodeDateTime(tm, fsec, NULL, NULL, style, str);
	}
}
#define EncodeDateTime CompatEncodeDateTime

static int compat_timestamp2tm(Timestamp dt, int *tzp, struct pg_tm * tm, fsec_t *fsec, const char **tzn, pg_tz *attimezone)
{
	return timestamp2tm(dt, tzp, tm, fsec, (char **)tzn, attimezone);
}
#define timestamp2tm compat_timestamp2tm

#endif

#if PG_VERSION_NUM < 90400

static void EncodeSpecialTimestamp(Timestamp dt, char *str)
{
	if (TIMESTAMP_IS_NOBEGIN(dt))
		strcpy(str, EARLY);
	else if (TIMESTAMP_IS_NOEND(dt))
		strcpy(str, LATE);
	else    /* shouldn't happen */
		elog(ERROR, "invalid argument for EncodeSpecialTimestamp");
}

static void EncodeSpecialDate(DateADT dt, char *str)
{
	if (DATE_IS_NOBEGIN(dt))
		strcpy(str, EARLY);
	else if (DATE_IS_NOEND(dt))
		strcpy(str, LATE);
	else    /* shouldn't happen */
		elog(ERROR, "invalid argument for EncodeSpecialDate");
}

#endif

static void timestamp_to_json(Datum val, StringInfo dst)
{
	char buf[MAXDATELEN + 1];
	struct pg_tm tm;
	fsec_t fsec;
	Timestamp timestamp = DatumGetTimestamp(val);

	if (TIMESTAMP_NOT_FINITE(timestamp))
		EncodeSpecialTimestamp(timestamp, buf);
	else if (timestamp2tm(timestamp, NULL, &tm, &fsec, NULL, NULL) == 0)
		EncodeDateTime(&tm, fsec, false, 0, NULL, USE_XSD_DATES, buf);
	else
		ereport(ERROR,
			(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
			 errmsg("timestamp out of range")));
	appendStringInfo(dst, "\"%s\"", buf);
}

static void timestamptz_to_json(Datum val, StringInfo dst)
{
	char buf[MAXDATELEN + 1];
	int tz;
	struct pg_tm tm;
	fsec_t fsec;
	const char *tzn = NULL;
	TimestampTz timestamp = DatumGetTimestampTz(val);

	if (TIMESTAMP_NOT_FINITE(timestamp))
		EncodeSpecialTimestamp(timestamp, buf);
	else if (timestamp2tm(timestamp, &tz, &tm, &fsec, &tzn, NULL) == 0)
		EncodeDateTime(&tm, fsec, true, tz, tzn, USE_XSD_DATES, buf);
	else
		ereport(ERROR,
			(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
			 errmsg("timestamp out of range")));
	appendStringInfo(dst, "\"%s\"", buf);
}

static void date_to_json(Datum val, StringInfo dst)
{
	struct pg_tm tm;
	char buf[MAXDATELEN + 1];
	DateADT date = DatumGetDateADT(val);

	if (DATE_NOT_FINITE(date)) {
		EncodeSpecialDate(date, buf);
	} else {
		j2date(date + POSTGRES_EPOCH_JDATE, &(tm.tm_year), &(tm.tm_mon), &(tm.tm_mday));
		EncodeDateOnly(&tm, USE_XSD_DATES, buf);
	}
	appendStringInfo(dst, "\"%s\"", buf);
}

/*
 * Convert row to JSON
 */

static void pgq_jsonenc_row(PgqTriggerEvent *ev, HeapTuple row, StringInfo buf)
{
	Oid col_type;
	Datum col_datum;
	bool isnull;
	TriggerData *tg = ev->tgdata;
	TupleDesc tupdesc = tg->tg_relation->rd_att;
	bool first = true;
	int i;
	const char *col_ident, *col_value;
	int attkind_idx = -1;

	if (ev->op_type == 'R') {
		appendStringInfoString(buf, "{}");
		return;
	}

	appendStringInfoChar(buf, '{');
	for (i = 0; i < tg->tg_relation->rd_att->natts; i++) {
		/* Skip dropped columns */
		if (TupleDescAttr(tupdesc, i)->attisdropped)
			continue;

		attkind_idx++;

		if (pgqtriga_skip_col(ev, i, attkind_idx))
			continue;

		if (first)
			first = false;
		else
			appendStringInfoChar(buf, ',');

		/* quote column name */
		col_ident = SPI_fname(tupdesc, i + 1);
		pgq_encode_cstring(buf, col_ident, TBUF_QUOTE_JSON);
		appendStringInfoChar(buf, ':');

		/* quote column value */
		col_type = TupleDescAttr(tupdesc, i)->atttypid;
		col_datum = SPI_getbinval(row, tupdesc, i + 1, &isnull);
		col_value = NULL;
		if (isnull) {
			appendStringInfoString(buf, "null");
			continue;
		}

		switch (col_type) {
		case BOOLOID:
			if (DatumGetBool(col_datum)) {
				appendStringInfoString(buf, "true");
			} else {
				appendStringInfoString(buf, "false");
			}
			break;

		case TIMESTAMPOID:
			timestamp_to_json(col_datum, buf);
			break;

		case TIMESTAMPTZOID:
			timestamptz_to_json(col_datum, buf);
			break;

		case DATEOID:
			date_to_json(col_datum, buf);
			break;

		case INT2OID:
			appendStringInfo(buf, "%d", (int)DatumGetInt16(col_datum));
			break;

		case INT4OID:
			appendStringInfo(buf, "%d", (int)DatumGetInt32(col_datum));
			break;

		case INT8OID:
			col_value = SPI_getvalue(row, tupdesc, i + 1);
			appendStringInfoString(buf, col_value);
			break;

		default:
			col_value = SPI_getvalue(row, tupdesc, i + 1);
			pgq_encode_cstring(buf, col_value, TBUF_QUOTE_JSON);
			break;
		}

		if (col_value)
			pfree((void*)col_value);
	}
	appendStringInfoChar(buf, '}');
}

static void fill_json_type(PgqTriggerEvent *ev, HeapTuple row, StringInfo ev_type)
{
	appendStringInfo(ev_type, "{\"op\":\"%s\"", ev->op_type_str);
	if (ev->tgargs->pkey_list) {
		static const char pkey_tag[] = "\"pkey\":";
		const char *cstart, *cpos;
		char *start, *pos, *tmp;
		char sep = '[';

		cstart = ev->info->json_info;
		cpos = strstr(cstart, "\"pkey\":");
		appendBinaryStringInfo(ev_type, cstart, cpos - cstart + strlen(pkey_tag));

		start = tmp = pstrdup(ev->tgargs->pkey_list);
		pos = strchr(start, ',');
		while (pos) {
			appendStringInfoChar(ev_type, sep);
			sep = ',';
			*pos = 0;
			pgq_encode_cstring(ev_type, start, TBUF_QUOTE_JSON);
			start = pos + 1;
			pos = strchr(start, ',');
		}
		appendStringInfoChar(ev_type, sep);
		pgq_encode_cstring(ev_type, start, TBUF_QUOTE_JSON);
		appendStringInfoChar(ev_type, ']');
		pfree(tmp);
	} else {
		appendStringInfoString(ev_type, ev->info->json_info);
	}
	appendStringInfoChar(ev_type, '}');
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
Datum pgq_jsontriga(PG_FUNCTION_ARGS)
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

	fill_json_type(&ev, row, ev.field[EV_TYPE]);

	if (pgq_is_interesting_change(&ev, tg)) {
		/*
		 * create type, data
		 */
		pgq_jsonenc_row(&ev, row, ev.field[EV_DATA]);

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
