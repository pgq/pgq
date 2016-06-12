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
#include <mb/pg_wchar.h>
#include <parser/keywords.h>
#include <utils/memutils.h>

#include "stringutil.h"

#ifndef SET_VARSIZE
#define SET_VARSIZE(x, len) VARATT_SIZEP(x) = len
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

static int pgq_urlencode(char *dst, const uint8 *src, int srclen)
{
	static const char hextbl[] = "0123456789abcdef";
	const uint8 *end = src + srclen;
	char *p = dst;
	while (src < end) {
		unsigned c = *src++;
		if (c == ' ') {
			*p++ = '+';
		} else if ((c >= '0' && c <= '9')
			   || (c >= 'A' && c <= 'Z')
			   || (c >= 'a' && c <= 'z')
			   || c == '_' || c == '.' || c == '-') {
			*p++ = c;
		} else {
			*p++ = '%';
			*p++ = hextbl[c >> 4];
			*p++ = hextbl[c & 15];
		}
	}
	return p - dst;
}

static int pgq_quote_literal(char *dst, const uint8 *src, int srclen)
{
	const uint8 *cp1 = src, *src_end = src + srclen;
	char *cp2 = dst;
	bool is_ext = false;

	*cp2++ = '\'';
	while (cp1 < src_end) {
		int wl = pg_mblen((const char *)cp1);
		if (wl != 1) {
			while (wl-- > 0 && cp1 < src_end)
				*cp2++ = *cp1++;
			continue;
		}

		if (*cp1 == '\'') {
			*cp2++ = '\'';
		} else if (*cp1 == '\\') {
			if (!is_ext) {
				/* make room for 'E' */
				memmove(dst + 1, dst, cp2 - dst);
				*dst = 'E';
				is_ext = true;
				cp2++;
			}
			*cp2++ = '\\';
		}
		*cp2++ = *cp1++;
	}
	*cp2++ = '\'';

	return cp2 - dst;
}

/* check if ident is keyword that needs quoting */
static bool is_keyword(const char *ident)
{
	const ScanKeyword *kw;

	/* do the lookup */
#if PG_VERSION_NUM >= 80500
	kw = ScanKeywordLookup(ident, ScanKeywords, NumScanKeywords);
#else
	kw = ScanKeywordLookup(ident);
#endif

	/* unreserved? */
#if PG_VERSION_NUM >= 80300
	if (kw && kw->category == UNRESERVED_KEYWORD)
		return false;
#endif

	/* found anything? */
	return kw != NULL;
}

/*
 * pgq_quote_ident - Quote an identifier only if needed
 */
static int pgq_quote_ident(char *dst, const uint8 *src, int srclen)
{
	/*
	 * Can avoid quoting if ident starts with a lowercase letter or
	 * underscore and contains only lowercase letters, digits, and
	 * underscores, *and* is not any SQL keyword.  Otherwise, supply
	 * quotes.
	 */
	int nquotes = 0;
	bool safe;
	const char *ptr;
	char *optr;
	char ident[NAMEDATALEN + 1];

	/* expect idents be not bigger than NAMEDATALEN */
	if (srclen > NAMEDATALEN)
		srclen = NAMEDATALEN;
	memcpy(ident, src, srclen);
	ident[srclen] = 0;

	/*
	 * would like to use <ctype.h> macros here, but they might yield
	 * unwanted locale-specific results...
	 */
	safe = ((ident[0] >= 'a' && ident[0] <= 'z') || ident[0] == '_');

	for (ptr = ident; *ptr; ptr++) {
		char ch = *ptr;

		if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || (ch == '_'))
			continue;	/* okay */

		safe = false;
		if (ch == '"')
			nquotes++;
	}

	if (safe) {
		if (is_keyword(ident))
			safe = false;
	}

	optr = dst;
	if (!safe)
		*optr++ = '"';

	for (ptr = ident; *ptr; ptr++) {
		char ch = *ptr;

		if (ch == '"')
			*optr++ = '"';
		*optr++ = ch;
	}
	if (!safe)
		*optr++ = '"';

	return optr - dst;
}

static char *start_append(StringInfo buf, int alloc_len)
{
	enlargeStringInfo(buf, alloc_len);
	return buf->data + buf->len;
}

static void finish_append(StringInfo buf, int final_len)
{
	if (buf->len + final_len > buf->maxlen)
		elog(FATAL, "buffer overflow");
	buf->len += final_len;
}


static void tbuf_encode_data(StringInfo buf, const uint8 *data, int len, enum PgqEncode encoding)
{
	int dlen = 0;
	char *dst;

	switch (encoding) {
	case TBUF_QUOTE_LITERAL:
		dst = start_append(buf, len * 2 + 3);
		dlen = pgq_quote_literal(dst, data, len);
		break;

	case TBUF_QUOTE_IDENT:
		dst = start_append(buf, len * 2 + 2);
		dlen = pgq_quote_ident(dst, data, len);
		break;

	case TBUF_QUOTE_URLENC:
		dst = start_append(buf, len * 3 + 2);
		dlen = pgq_urlencode(dst, data, len);
		break;

	default:
		elog(ERROR, "bad encoding");
	}

	finish_append(buf, dlen);
}

void pgq_encode_cstring(StringInfo tbuf, const char *str, enum PgqEncode encoding)
{
	if (str == NULL)
		elog(ERROR, "tbuf_encode_cstring: NULL");
	tbuf_encode_data(tbuf, (const uint8 *)str, strlen(str), encoding);
}
