enum PgqFields {
	EV_TYPE = 0,
	EV_DATA,
	EV_EXTRA1,
	EV_EXTRA2,
	EV_EXTRA3,
	EV_EXTRA4,
	EV_WHEN,
	EV_NFIELDS
};

/*
 * Per-event temporary data.
 */
struct PgqTriggerEvent {
	char op_type;

	/* overridable fields */
	// fixme: check proper usage
	const char *table_name;
	const char *queue_name;
	const char *pkey_list;

	/* no cache for old-style args */
	const char *attkind;
	int attkind_len;

	/* cached per-table info */
	struct PgqTableInfo *info;

	/* cached per-trigger args */
	struct PgqTriggerInfo *tgargs;

	/* current event data */
	TriggerData *tgdata;

	/* result fields */
	StringInfo field[EV_NFIELDS];

	/* if 'when=' query fails */
	bool skip_event;
};
typedef struct PgqTriggerEvent PgqTriggerEvent;

/*
 * Per trigger cached info, stored under table cache,
 * so that invalidate can drop it.
 */
struct PgqTriggerInfo {
	struct PgqTriggerInfo *next;
	Oid tgoid;
	bool finalized;

	bool skip;
	bool backup;
	bool custom_fields;
	bool deny;

	const char *ignore_list;
	const char *pkey_list;

	struct QueryBuilder *query[EV_NFIELDS];
};

/*
 * Per-table cached info.
 *
 * Per-trigger info should be cached under tg_cache.
 */
struct PgqTableInfo {
	Oid reloid;		/* must be first, used by htab */
	int n_pkeys;		/* number of pkeys */
	const char *pkey_list;	/* pk column name list */
	int *pkey_attno;	/* pk column positions */
	char *table_name;	/* schema-quelified table name */
	int invalid;		/* set if the info was invalidated */

	struct PgqTriggerInfo *tg_cache;
};

/* common.c */
void pgq_prepare_event(struct PgqTriggerEvent *ev, TriggerData *tg, bool newstyle);
void pgq_simple_insert(const char *queue_name, Datum ev_type, Datum ev_data,
		       Datum ev_extra1, Datum ev_extra2, Datum ev_extra3, Datum ev_extra4);
bool pgqtriga_skip_col(PgqTriggerEvent *ev, int i, int attkind_idx);
bool pgqtriga_is_pkey(PgqTriggerEvent *ev, int i, int attkind_idx);
void pgq_insert_tg_event(PgqTriggerEvent *ev);

bool pgq_is_logging_disabled(void);

/* makesql.c */
int pgqtriga_make_sql(PgqTriggerEvent *ev, StringInfo sql);

/* logutriga.c */
void pgq_urlenc_row(PgqTriggerEvent *ev, HeapTuple row, StringInfo buf);

#ifndef TRIGGER_FIRED_BY_TRUNCATE
#define TRIGGER_FIRED_BY_TRUNCATE(tg)	0
#endif

