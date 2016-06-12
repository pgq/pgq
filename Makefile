
EXTENSION = pgq

EXT_VERSION = 3.2.6
EXT_OLD_VERSIONS = 3.1 3.1.1 3.1.2 3.1.3 3.1.6 3.2 3.2.3

DOCS = README.pgq

PGQ_TESTS = pgq_core pgq_perms logutriga sqltriga trunctrg

# comment it out if not wanted
#UPGRADE_TESTS = pgq_init_upgrade $(PGQ_TESTS) clean

Contrib_data = structure/uninstall_pgq.sql

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

