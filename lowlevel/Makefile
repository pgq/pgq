
MODULE_big = pgq_lowlevel
DATA = pgq_lowlevel.sql

SRCS = insert_event.c
OBJS = $(SRCS:.c=.o)

PG_CONFIG = pg_config
PGXS = $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

