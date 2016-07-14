/*
 * stringutil.c - some tools for string handling
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
#include <lib/stringinfo.h>
#include <utils/memutils.h>
#include <utils/builtins.h>
#if PG_VERSION_NUM >= 90200
#include <utils/json.h>
#endif

#include "stringutil.h"

#ifndef SET_VARSIZE
#define SET_VARSIZE(x, len) VARATT_SIZEP(x) = len
#endif

#if PG_VERSION_NUM < 90100
static char *quote_literal_cstr(const char *str)
{
	StringInfoData buf;

	initStringInfo(&buf);

	if (strchr(str, '\\'))
		appendStringInfoCharMacro(&buf, 'E');

	appendStringInfoCharMacro(&buf, '\'');
	for (; *str; str++) {
		if (*str == '\'' || *str == '\\')
			appendStringInfoCharMacro(&buf, *str);
		appendStringInfoCharMacro(&buf, *str);
	}
	appendStringInfoCharMacro(&buf, '\'');
	return buf.data;
}
#endif

StringInfo pgq_init_varbuf(void)
{
	StringInfo buf;
	buf = makeStringInfo();
	appendStringInfoString(buf, "XXXX");
	return buf;
}

Datum pgq_finish_varbuf(StringInfo buf)
{
	if (!buf) return (Datum)0;
	SET_VARSIZE(buf->data, buf->len);
	return PointerGetDatum(buf->data);
}


/*
 * Find a string in comma-separated list.
 *
 * It does not support space inside tokens.
 */
bool pgq_strlist_contains(const char *liststr, const char *str)
{
	int c, len = strlen(str);
	const char *p, *listpos = liststr;

loop:
	/* find string fragment, later check if actual token */
	p = strstr(listpos, str);
	if (p == NULL)
		return false;

	/* move listpos further */
	listpos = p + len;
	/* survive len=0 and avoid unnecessary compare */
	if (*listpos)
		listpos++;

	/* check previous symbol */
	if (p > liststr) {
		c = *(p - 1);
		if (!isspace(c) && c != ',')
			goto loop;
	}

	/* check following symbol */
	c = p[len];
	if (c != 0 && !isspace(c) && c != ',')
		goto loop;

	return true;
}

/*
 * quoting
 */

static void pgq_urlencode(StringInfo buf, const char *src)
{
	static const char hextbl[] = "0123456789abcdef";
	while (*src) {
		unsigned c = (unsigned char)*src++;
		if (c == ' ') {
			appendStringInfoCharMacro(buf, '+');
		} else if ((c >= '0' && c <= '9')
			   || (c >= 'A' && c <= 'Z')
			   || (c >= 'a' && c <= 'z')
			   || c == '_' || c == '.' || c == '-') {
			appendStringInfoCharMacro(buf, c);
		} else {
			appendStringInfoCharMacro(buf, '%');
			appendStringInfoCharMacro(buf, hextbl[c >> 4]);
			appendStringInfoCharMacro(buf, hextbl[c & 15]);
		}
	}
}

static void pgq_quote_literal(StringInfo buf, const char *src)
{
	const char *quoted = quote_literal_cstr(src);
	appendStringInfoString(buf, quoted);
	pfree((char*)quoted);
}

/*
 * pgq_quote_ident - Quote an identifier only if needed
 */
static void pgq_quote_ident(StringInfo buf, const char *src)
{
	const char *quoted = quote_identifier(src);
	appendStringInfoString(buf, quoted);
	if (quoted != src)
		pfree((char *)quoted);
}

#if PG_VERSION_NUM < 90200

static void escape_json(StringInfo buf, const char *p)
{
	appendStringInfoCharMacro(buf, '\"');
	for (; *p; p++) {
		switch (*p) {
		case '\b': appendStringInfoString(buf, "\\b"); break;
		case '\f': appendStringInfoString(buf, "\\f"); break;
		case '\n': appendStringInfoString(buf, "\\n"); break;
		case '\r': appendStringInfoString(buf, "\\r"); break;
		case '\t': appendStringInfoString(buf, "\\t"); break;
		case '"': appendStringInfoString(buf, "\\\""); break;
		case '\\': appendStringInfoString(buf, "\\\\"); break;
		default:
			   if ((unsigned char) *p < ' ')
				   appendStringInfo(buf, "\\u%04x", (int) *p);
			   else
				   appendStringInfoCharMacro(buf, *p);
			   break;
		}
	}
	appendStringInfoCharMacro(buf, '\"');
}

#endif

void pgq_encode_cstring(StringInfo tbuf, const char *str, enum PgqEncode encoding)
{
	if (str == NULL)
		elog(ERROR, "tbuf_encode_cstring: NULL");

	switch (encoding) {
	case TBUF_QUOTE_LITERAL:
		pgq_quote_literal(tbuf, str);
		break;

	case TBUF_QUOTE_IDENT:
		pgq_quote_ident(tbuf, str);
		break;

	case TBUF_QUOTE_URLENC:
		pgq_urlencode(tbuf, str);
		break;

	case TBUF_QUOTE_JSON:
		escape_json(tbuf, str);
		break;

	default:
		elog(ERROR, "bad encoding");
	}
}

