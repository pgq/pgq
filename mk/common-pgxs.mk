
# PGXS does not support modules that are supposed
# to run on different Postgres versions very well.
# Here are some workarounds for them.

# Variables that are used when extensions are available
Extension_data ?=
Extension_data_built ?= $(EXTENSION)--$(EXT_VERSION).sql $(EXTENSION)--unpackaged--$(EXT_VERSION).sql
Extension_regress ?=

# Variables that are used when extensions are not available
Contrib_data ?=
Contrib_data_built += $(EXTENSION).sql $(EXTENSION).upgrade.sql \
		structure/newgrants_$(EXTENSION).sql \
		structure/oldgrants_$(EXTENSION).sql

Contrib_regress ?=

EXT_VERSION ?=
EXT_OLD_VERSIONS ?= 

Extension_upgrade_files = $(if $(EXT_OLD_VERSIONS),$(foreach v,$(EXT_OLD_VERSIONS),$(EXTENSION)--$(v)--$(EXT_VERSION).sql))
Extension_data_built += $(Extension_upgrade_files)

# Should the Contrib* files installed (under ../contrib/)
# even when extensions are available?
Contrib_install_always ?= yes

#
# switch variables
#

IfExt = $(if $(filter 8.% 9.0%,$(MAJORVERSION)8.3),$(2),$(1))

DATA = $(call IfExt,$(Extension_data),$(Contrib_data))
DATA_built = $(call IfExt,$(Extension_data_built),$(Contrib_data_built))
REGRESS = $(call IfExt,$(Extension_regress),$(Contrib_regress))

EXTRA_CLEAN += $(call IfExt,$(Contrib_data_built),$(Extension_data_built)) test.dump

# have deterministic dbname for regtest database
override CONTRIB_TESTDB = regression
REGRESS_OPTS = --dbname=$(CONTRIB_TESTDB)

#
# Calculate actual sql files
#

GRANT_SQL = structure/newgrants_$(EXTENSION).sql

SQLS  = $(shell $(AWK) -f mk/show-inc.awk structure/install.sql)
FUNCS = $(shell $(AWK) -f mk/show-inc.awk $(SQLS))
SRCS = $(SQLS) $(FUNCS) $(GRANT_SQL)

#
# load PGXS
#

PG_CONFIG ?= pg_config
PGXS = $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# when compiling locally and with postgres without python,
# the variable may be empty
PYTHON3 := $(if $(PYTHON3),$(PYTHON3),python3)

#
# common tools
#

NDOC = NaturalDocs
NDOCARGS = -r -o html docs/html -p docs -i docs/sql
CATSQL = $(PYTHON3) mk/catsql.py
GRANTFU = $(PYTHON3) mk/grantfu.py

#
# build rules, in case Contrib data must be always installed
#

ifeq ($(call IfExt,$(Contrib_install_always),no),yes)

all: $(Contrib_data) $(Contrib_data_built)
installdirs: installdirs-old-contrib
install: install-old-contrib

installdirs-old-contrib:
	$(MKDIR_P) '$(DESTDIR)$(datadir)/contrib'

install-old-contrib: $(Contrib_data) $(Contrib_data_built) installdirs-old-contrib
	$(INSTALL_DATA) $(addprefix $(srcdir)/, $(Contrib_data)) $(Contrib_data_built) '$(DESTDIR)$(datadir)/contrib/'

endif

#
# regtest shortcuts
#

test: install
	$(MAKE) installcheck || { filterdiff --format=unified regression.diffs | less; exit 1; }
	pg_dump regression > test.dump || true

citest: checkver
	$(MAKE) installcheck || { filterdiff --format=unified regression.diffs; exit 1; }

ack:
	cp results/*.out expected/

cleandox:
	rm -rf docs/html docs/Data docs/sql

clean: cleandox

.PHONY: test ack installdirs-old-contrib install-old-contrib cleandox dox

#
# common files
#

$(EXTENSION)--$(EXT_VERSION).sql: $(EXTENSION).sql structure/ext_postproc.sql
	$(CATSQL) $^ > $@

$(EXTENSION)--unpackaged--$(EXT_VERSION).sql: $(EXTENSION).upgrade.sql structure/ext_unpackaged.sql structure/ext_postproc.sql
	$(CATSQL) $^ > $@

$(EXTENSION).sql: $(SRCS)
	$(CATSQL) structure/install.sql $(GRANT_SQL) > $@

$(EXTENSION).upgrade.sql: $(SRCS)
	$(CATSQL) structure/upgrade.sql $(GRANT_SQL) > $@

ifneq ($(Extension_upgrade_files),)
$(Extension_upgrade_files): $(EXTENSION).upgrade.sql
	cp $< $@
endif

structure/newgrants_$(EXTENSION).sql: structure/grants.ini
	$(GRANTFU) -r -d $< > $@

structure/oldgrants_$(EXTENSION).sql: structure/grants.ini structure/grants.sql
	echo "begin;" > $@
	$(GRANTFU) -R -o $< >> $@
	cat structure/grants.sql >> $@
	echo "commit;" >> $@

checkver:
	@echo "Checking version numbers"
	@grep -q "^default_version *= *'$(EXT_VERSION)'" $(EXTENSION).control \
		|| { echo "ERROR: $(EXTENSION).control has wrong version"; exit 1; }
	@test -f "docs/notes/v$(EXT_VERSION).md" \
		|| { echo "ERROR: notes missing: docs/notes/v$(EXT_VERSION).md"; exit 1; }

all: checkver

TARNAME = $(EXTENSION)-$(EXT_VERSION)
dist: checkver
	git archive --format=tar.gz --prefix=$(TARNAME)/ -o $(TARNAME).tar.gz HEAD

release: checkver
	git tag v$(EXT_VERSION)
	git push github
	git push github v$(EXT_VERSION):v$(EXT_VERSION)

