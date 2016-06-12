
#ifndef TEST
#include <postgres.h>
#else
#include <ctype.h>
#include <string.h>
#endif

#include "parsesql.h"

/*
 * Small SQL tokenizer.  For cases where flex/bison is overkill.
 *
 * To simplify further processing, it merges words separated
 * with dots together.  That also means it does not support
 * whitespace/comments before and after dot.
 *
 * Otherwise it's relatively compatible with main parser.
 *
 * Return value:
 * -1      - error
 *  0      - end of string
 *  1..255 - single char
 *  >255   - token code
 */
int sql_tokenizer(const char *sql, int *len_p, bool stdstr)
{
	const char *p = sql;
	int tok;

	*len_p = 0;
	if (!*p) {
		/* end */
		return 0;
	} else if (isspace(*p) || (p[0] == '-' && p[1] == '-') || (p[0] == '/' && p[1] == '*')) {
		/* whitespace */
		tok = T_SPACE;
		while (1) {
			if (p[0] == '-' && p[1] == '-') {
				/* line comment */
				while (*p && *p != '\n')
					p++;
			} else if (p[0] == '/' && p[1] == '*') {
				/* c-comment, potentially nested */
				int level = 1;
				p += 2;
				while (level) {
					if (p[0] == '*' && p[1] == '/') {
						level--;
						p += 2;
					} else if (p[0] == '/' && p[1] == '*') {
						level++;
						p += 2;
					} else if (!*p) {
						return -1;
					} else
						p++;
				}
			} else if (isspace(p[0])) {
				/* plain whitespace */
				while (isspace(p[0]))
					p++;
			} else
				break;
		}
	} else if ((p[0] == '\'' && !stdstr) || ((p[0] == 'E' || p[0] == 'e') && p[1] == '\'')) {
		/* extended string */
		tok = T_STRING;
		if (p[0] == '\'')
			p++;
		else
			p += 2;
		for (; *p; p++) {
			if (p[0] == '\'') {
				if (p[1] == '\'')
					p++;
				else
					break;
			} else if (p[0] == '\\') {
				if (!p[1])
					return -1;
				p++;
			}
		}
		if (*p++ != '\'')
			return -1;
	} else if (p[0] == '\'' && stdstr) {
		/* standard string */
		tok = T_STRING;
		for (p++; *p; p++) {
			if (p[0] == '\'') {
				if (p[1] == '\'')
					p++;
				else
					break;
			}
		}
		if (*p++ != '\'')
			return -1;
	} else if (isalpha(*p) || (*p == '_')) {
		/* plain/quoted words separated with '.' */
		tok = T_WORD;
		while (1) {
			/* plain ident */
			while (*p && (isalnum(*p) || *p == '_' || *p == '.'))
				p++;
			if (p[0] == '"') {
				/* quoted ident */
				for (p++; *p; p++) {
					if (p[0] == '"') {
						if (p[1] == '"')
							p++;
						else
							break;
					}
				}
				if (*p++ != '"')
					return -1;
			} else if (p[0] == '.') {
				tok = T_FQIDENT;
				p++;
			} else {
				break;
			}
		}
	} else if (isdigit(p[0]) || (p[0] == '.' && isdigit(p[1]))) {
		/* number */
		tok = T_NUMBER;
		while (*p) {
			if (isdigit(*p) || *p == '.') {
				p++;
			} else if ((*p == 'e' || *p == 'E')) {
				if (p[1] == '.' || p[1] == '+' || p[1] == '-') {
					p += 2;
				} else if (isdigit(p[1])) {
					p += 2;
				} else
					break;
			} else
				break;
		}
	} else if (p[0] == '$') {
		if (isdigit(p[1])) {
			/* dollar ident */
			tok = T_WORD;
			for (p += 2; *p; p++) {
				if (!isdigit(*p))
					break;
			}
		} else if (isalpha(p[1]) || p[1] == '_' || p[1] == '$') {
			/* dollar quote */
			const char *p2, *p3;
			tok = T_STRING;
			p2 = strchr(p+1, '$');
			if (!p2)
				return -1;
			p3 = ++p2;
			
			while (1) {
				p3 = strchr(p3, '$');
				if (!p3)
					return -1;
				if (strncmp(p3, p, p2 - p) == 0)
					break;
				p3++;
			}
			p = p3 + (p2 - p);
		} else
			return -1;
	} else if (*p == '.') {
		/* disallow standalone dot - seems ident parsing missed it */
		return -1;
	} else {
		/* return other symbols as-is */
		tok = *p++;
	}
	*len_p = p - sql;
	return tok;
}


#ifdef TEST

/*
 * test code
 */

const char test_sql[] =
"\r\n\t "
"-- foo\n"
"/*/**//* nested *//**/*/\n"
"select 1, .600, $1, $150, 1.44e+.1,"
" bzo.\"fo'\"\".o\".zoo.fa, "
"E'a\\\\ \\000 \\' baz ''',"
"'foo''baz' from \"quoted\"\"id\";"
"$$$$ $_$ $x$ $ $_ $_$"
;

int main(void)
{
	const char *sql = test_sql;
	int tlen;
	int tok;
	bool stdstr = false;
	while (1) {
		tok = sql_tokenizer(sql, &tlen, stdstr);
		if (tok == 0) {
			printf("EOF\n");
			break;
		} else if (tok < 0) {
			printf("ERR\n");
			return 1;
		}
		printf("tok=%d len=%d str=<%.*s>\n", tok, tlen, tlen, sql);
		sql += tlen;
	}
	return 0;
}

#endif

