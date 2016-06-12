
/* multi-char tokens */
enum SqlToken {
	T_SPACE = 257,
	T_STRING,
	T_NUMBER,
	T_WORD,
	T_FQIDENT,
};

int sql_tokenizer(const char *sql, int *len_p, bool stdstr);

