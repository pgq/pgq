
#include <postgres.h>
#include <executor/spi.h>

#include "qbuilder.h"
#include "parsesql.h"

/* import standard_conforming_strings */
#if PG_VERSION_NUM >= 80500
#include <parser/parser.h>
#else
#ifndef PGDLLIMPORT
#define PGDLLIMPORT DLLIMPORT
#endif
extern PGDLLIMPORT bool standard_conforming_strings;
#endif

/* create QB in right context */
struct QueryBuilder *qb_create(const struct QueryBuilderOps *ops, MemoryContext ctx)
{
	struct QueryBuilder *q;

	q = MemoryContextAllocZero(ctx, sizeof(*q));
	q->op = ops;
	q->stdstr = standard_conforming_strings;

	q->maxargs = 8;
	q->arg_map = MemoryContextAlloc(ctx, q->maxargs * sizeof(int));

	/* default size too large? */
	q->sql.maxlen = 64;
	q->sql.data = MemoryContextAlloc(ctx,  q->sql.maxlen);
	q->sql.data[0] = 0;
	return q;
}

/* add fragment without parsing */
void qb_add_raw(struct QueryBuilder *q, const char *str, int len)
{
	if (len < 0)
		len = strlen(str);
	appendBinaryStringInfo(&q->sql, str, len);
}

/* the ident may or may not be argument reference */
static void qb_handle_ident(struct QueryBuilder *q, const char *ident, int len, void *arg)
{
	int real_idx;
	int local_idx = -1, i;
	char abuf[32];

	/* is argument reference? */
	real_idx = q->op->name_lookup(arg, ident, len);
	if (real_idx < 0) {
		qb_add_raw(q, ident, len);
		return;
	}

	/* already referenced? */
	for (i = 0; i < q->nargs; i++) {
		if (q->arg_map[i] == real_idx) {
			local_idx = i;
			break;
		}
	}

	/* new reference? */
	if (local_idx < 0) {
		if (q->nargs >= FUNC_MAX_ARGS)
			elog(ERROR, "Too many args");
		if (q->nargs >= q->maxargs) {
			q->arg_map = repalloc(q->arg_map, q->maxargs * 2 * sizeof(int));
			q->maxargs *= 2;
		}
		local_idx = q->nargs++;
		q->arg_map[local_idx] = real_idx;
	}

	/* add $n to query */
	snprintf(abuf, sizeof(abuf), "$%d", local_idx + 1);
	return qb_add_raw(q, abuf, strlen(abuf));
}

/* add fragment with parsing - argument references are replaced with $n */
void qb_add_parse(struct QueryBuilder *q, const char *sql, void *arg)
{
	int tlen, tok;

	/* tokenize sql, pick out argument references */
	while (1) {
		tok = sql_tokenizer(sql, &tlen, q->stdstr);
		if (!tok)
			break;
		if (tok < 0)
			elog(ERROR, "QB: syntax error");
		if (tok == T_WORD) {
			qb_handle_ident(q, sql, tlen, arg);
		} else {
			qb_add_raw(q, sql, tlen);
		}
		sql += tlen;
	}
}

/* prepare */
void qb_prepare(struct QueryBuilder *q, void *arg)
{
	Oid types[FUNC_MAX_ARGS];
	void *plan;
	int i;

	for (i = 0; i < q->nargs; i++)
		types[i] = q->op->type_lookup(arg, q->arg_map[i]);

	plan = SPI_prepare(q->sql.data, q->nargs, types);
	q->plan = SPI_saveplan(plan);
}

/* lookup values and run plan.  returns result from SPI_execute_plan()  */
int qb_execute(struct QueryBuilder *q, void *arg)
{
	Datum values[FUNC_MAX_ARGS];
	char nulls[FUNC_MAX_ARGS];
	int i;

	if (!q->plan)
		elog(ERROR, "QB: query not prepared yet");

	for (i = 0; i < q->nargs; i++) {
		bool isnull = false;
		values[i] = q->op->value_lookup(arg, q->arg_map[i], &isnull);
		nulls[i] = isnull ? 'n' : ' ';
	}
	return SPI_execute_plan(q->plan, values, nulls, true, 0);
}

void qb_free(struct QueryBuilder *q)
{
	if (!q)
		return;
	if (q->plan)
		SPI_freeplan(q->plan);
	if (q->sql.data)
		pfree(q->sql.data);
	pfree(q);
}

