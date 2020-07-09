
EXTENSION = pgq

EXT_VERSION = 3.4
EXT_OLD_VERSIONS = 3.2 3.2.3 3.2.6 3.3.1

PGQ_TESTS = pgq_core pgq_core_disabled pgq_core_tx_limit \
	    pgq_session_role pgq_perms \
	    trigger_base trigger_sess_role trigger_types trigger_trunc trigger_ignore \
	    trigger_pkey trigger_deny trigger_when trigger_extra_args trigger_extra_cols \
	    \
	    clean_ext pgq_init_ext \
	    switch_plonly \
	    \
	    pgq_core pgq_core_disabled \
	    pgq_session_role pgq_perms \
	    trigger_base trigger_sess_role trigger_types trigger_trunc trigger_ignore \
	    trigger_pkey trigger_deny trigger_when trigger_extra_args trigger_extra_cols \

# comment it out if not wanted
#UPGRADE_TESTS = pgq_init_upgrade $(PGQ_TESTS) clean

Contrib_data = structure/uninstall_pgq.sql
Contrib_data_built = pgq_pl_only.sql pgq_pl_only.upgrade.sql

Contrib_regress   = $(UPGRADE_TESTS) pgq_init_noext $(PGQ_TESTS)
Extension_regress = $(UPGRADE_TESTS) pgq_init_ext $(PGQ_TESTS)

include mk/common-pgxs.mk

SUBDIRS = lowlevel triggers

# PGXS does not have subdir support, thus hack to recurse into lowlevel/
all: sub-all
install: sub-install
clean: sub-clean
distclean: sub-distclean
sub-all sub-install sub-clean sub-distclean:
	for dir in $(SUBDIRS); do \
		$(MAKE) -C $$dir $(subst sub-,,$@) \
			DESTDIR=$(DESTDIR) \
			PG_CONFIG=$(PG_CONFIG) \
		|| exit 1; \
	done

lowlevel/pgq_lowlevel.sql: sub-all
triggers/pgq_triggers.sql: sub-all

PLONLY_SRCS = lowlevel_pl/insert_event.sql lowlevel_pl/logutriga.sql lowlevel_pl/sqltriga.sql

pgq_pl_only.sql: $(SRCS) $(PLONLY_SRCS)
	$(CATSQL) structure/install_pl.sql $(GRANT_SQL) > $@

pgq_pl_only.upgrade.sql: $(SRCS) $(PLONLY_SRCS)
	$(CATSQL) structure/upgrade_pl.sql $(GRANT_SQL) > $@

plonly: pgq_pl_only.sql pgq_pl_only.upgrade.sql

#
# docs
#
dox: cleandox $(SRCS)
	mkdir -p docs/html
	mkdir -p docs/sql
	$(CATSQL) --ndoc structure/tables.sql > docs/sql/schema.sql
	$(CATSQL) --ndoc structure/func_public.sql > docs/sql/external.sql
	$(CATSQL) --ndoc structure/func_internal.sql > docs/sql/internal.sql
	$(CATSQL) --ndoc structure/triggers.sql > docs/sql/triggers.sql
	$(NDOC) $(NDOCARGS)

doxsync:
	for m in pgq_coop pgq_node pgq_ext londiste; do \
		cp docs/Topics.txt docs/Languages.txt ../$$m/docs; \
	done

deb:
	make -f debian/rules genfiles
	debuild -us -uc -b

debclean:
	make -f debian/rules debclean

