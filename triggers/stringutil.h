
enum PgqEncode {
	TBUF_QUOTE_IDENT,
	TBUF_QUOTE_LITERAL,
	TBUF_QUOTE_URLENC,
};

StringInfo pgq_init_varbuf(void);
Datum pgq_finish_varbuf(StringInfo buf);
bool pgq_strlist_contains(const char *liststr, const char *str);
void pgq_encode_cstring(StringInfo tbuf, const char *str, enum PgqEncode encoding);
