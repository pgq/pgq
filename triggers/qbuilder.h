
#include <lib/stringinfo.h>

/*
 * Callbacks that to argument name/type/value lookups.
 */
struct QueryBuilderOps {
	/* returns name index or < 0 if unknown. str is not null-terminated */
	int (*name_lookup)(void *arg, const char *str, int len);

	/* returns type oid for nr that .name_lookup returned */
	Oid (*type_lookup)(void *arg, int nr);

	/* returns value for nr that .name_lookup returned */
	Datum (*value_lookup)(void *arg, int nr, bool *isnull);
};

/*
 * Parsed query
 */
struct QueryBuilder {
	StringInfoData sql;
	bool stdstr;
	const struct QueryBuilderOps *op;

	void *plan;

	int nargs;
	int maxargs;
	int *arg_map;
};

struct QueryBuilder *qb_create(const struct QueryBuilderOps *ops, MemoryContext ctx);
void qb_add_raw(struct QueryBuilder *q, const char *str, int len);
void qb_add_parse(struct QueryBuilder *q, const char *str, void *arg);
void qb_free(struct QueryBuilder *q);

void qb_prepare(struct QueryBuilder *q, void *arg);
int qb_execute(struct QueryBuilder *q, void *arg);

