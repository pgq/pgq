

MODULE_big = pgq_triggers
SRCS = logtriga.c logutriga.c sqltriga.c \
       common.c makesql.c stringutil.c \
       parsesql.c qbuilder.c
OBJS = $(SRCS:.c=.o)
DATA = pgq_triggers.sql

PG_CONFIG = pg_config
PGXS = $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

cs:
	cscope -b -f .cscope.out *.c

