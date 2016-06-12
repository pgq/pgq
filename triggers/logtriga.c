/*
 * logtriga.c - Dumb SQL logging trigger.
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
#include <lib/stringinfo.h>

#include "common.h"
#include "stringutil.h"

PG_FUNCTION_INFO_V1(pgq_logtriga);
Datum pgq_logtriga(PG_FUNCTION_ARGS);

/*
 * PGQ log trigger, takes 2 arguments:
 * 1. queue name to be inserted to.
 * 2. column type string
 *
 * Queue events will be in format:
 *    ev_type   - operation type, I/U/D
 *    ev_data   - partial SQL describing operation
 *    ev_extra1 - table name
 */

Datum pgq_logtriga(PG_FUNCTION_ARGS)
{
	TriggerData *tg;
	PgqTriggerEvent ev;

	/*
	 * Get the trigger call context
	 */
	if (!CALLED_AS_TRIGGER(fcinfo))
		elog(ERROR, "pgq.logtriga not called as trigger");

	tg = (TriggerData *)(fcinfo->context);

	if (!TRIGGER_FIRED_AFTER(tg->tg_event))
		elog(ERROR, "pgq.logtriga must be fired AFTER");

	if (pgq_is_logging_disabled())
		goto skip_it;

	/*
	 * Connect to the SPI manager
	 */
	if (SPI_connect() < 0)
		elog(ERROR, "logtriga: SPI_connect() failed");

	pgq_prepare_event(&ev, tg, false);

	appendStringInfoChar(ev.field[EV_TYPE], ev.op_type);
	appendStringInfoString(ev.field[EV_EXTRA1], ev.info->table_name);

	/*
	 * create sql and insert if interesting
	 */
	if (pgqtriga_make_sql(&ev, ev.field[EV_DATA]))
		pgq_insert_tg_event(&ev);

	if (SPI_finish() < 0)
		elog(ERROR, "SPI_finish failed");

skip_it:
	return PointerGetDatum(NULL);
}
