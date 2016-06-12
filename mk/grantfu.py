#! /usr/bin/env python

# GrantFu - GRANT/REVOKE generator for Postgres
# 
# Copyright (c) 2005 Marko Kreen
# 
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
# 
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.


"""Generator for PostgreSQL permissions.

Loads config where roles, objects and their mapping is described
and generates grants based on them.

ConfigParser docs: http://docs.python.org/lib/module-ConfigParser.html

Example:
--------------------------------------------------------------------
[DEFAULT]
users = user1, user2      # users to handle
groups = group1, group2   # groups to handle
auto_seq = 0              # dont handle seqs (default)
                          # '!' after a table negates this setting for a table
seq_name = id             # the name for serial field (default: id)
seq_usage = 0             # should we grant "usage" or "select, update"
                          # for automatically handled sequences

# section names can be random, but if you want to see them
# in same order as in config file, then order them alphabetically
[1.section]
on.tables = testtbl, testtbl_id_seq,   # here we handle seq by hand
         table_with_seq!               # handle seq automatically
                                       # (table_with_seq_id_seq)
user1 = select
group1 = select, insert, update

# instead of 'tables', you may use 'functions', 'languages',
# 'schemas', 'tablespaces'
---------------------------------------------------------------------
"""

import sys, os, getopt
from ConfigParser import SafeConfigParser

__version__ = "1.0"

R_NEW = 0x01
R_DEFS = 0x02
G_DEFS = 0x04
R_ONLY = 0x80

def usage(err):
    sys.stderr.write("usage: %s [-r|-R] CONF_FILE\n" % sys.argv[0])
    sys.stderr.write("  -r   Generate also REVOKE commands\n")
    sys.stderr.write("  -R   Generate only REVOKE commands\n")
    sys.stderr.write("  -d   Also REVOKE default perms\n")
    sys.stderr.write("  -D   Only REVOKE default perms\n")
    sys.stderr.write("  -o   Generate default GRANTS\n")
    sys.stderr.write("  -v   Print program version\n")
    sys.stderr.write("  -t   Put everything in one big transaction\n")
    sys.exit(err)

class PConf(SafeConfigParser):
    "List support for ConfigParser"
    def __init__(self, defaults = None):
        SafeConfigParser.__init__(self, defaults)

    def get_list(self, sect, key):
        str = self.get(sect, key).strip()
        res = []
        if not str:
            return res
        for val in str.split(","):
            res.append(val.strip())
        return res

class GrantFu:
    def __init__(self, cf, revoke):
        self.cf = cf
        self.revoke = revoke

        # avoid putting grantfu vars into defaults, thus into every section
        self.group_list = []
        self.user_list = []
        self.auto_seq = 0
        self.seq_name = "id"
        self.seq_usage = 0
        if self.cf.has_option('GrantFu', 'groups'):
            self.group_list = self.cf.get_list('GrantFu', 'groups')
        if self.cf.has_option('GrantFu', 'users'):
            self.user_list += self.cf.get_list('GrantFu', 'users')
        if self.cf.has_option('GrantFu', 'roles'):
            self.user_list += self.cf.get_list('GrantFu', 'roles')
        if self.cf.has_option('GrantFu', 'auto_seq'):
            self.auto_seq = self.cf.getint('GrantFu', 'auto_seq')
        if self.cf.has_option('GrantFu', 'seq_name'):
            self.seq_name = self.cf.get('GrantFu', 'seq_name')
        if self.cf.has_option('GrantFu', 'seq_usage'):
            self.seq_usage = self.cf.getint('GrantFu', 'seq_usage')

        # make string of all subjects
        tmp = []
        for g in self.group_list:
            tmp.append("group " + g)
        for u in self.user_list:
            tmp.append(u)
        self.all_subjs = ", ".join(tmp)

        # per-section vars
        self.sect = None
        self.seq_list = []
        self.seq_allowed = []

    def process(self):
        if len(self.user_list) == 0 and len(self.group_list) == 0:
            return

        sect_list = self.cf.sections()
        sect_list.sort()
        for self.sect in sect_list:
            if self.sect == "GrantFu":
                continue
            print "\n-- %s --" % self.sect

            self.handle_tables()
            self.handle_other('on.databases', 'DATABASE')
            self.handle_other('on.functions', 'FUNCTION')
            self.handle_other('on.languages', 'LANGUAGE')
            self.handle_other('on.schemas', 'SCHEMA')
            self.handle_other('on.tablespaces', 'TABLESPACE')
            self.handle_other('on.sequences', 'SEQUENCE')
            self.handle_other('on.types', 'TYPE')
            self.handle_other('on.domains', 'DOMAIN')

    def handle_other(self, listname, obj_type):
        """Handle grants for all objects except tables."""

        if not self.sect_hasvar(listname):
            return

        # don't parse list, as in case of functions it may be complicated
        obj_str = obj_type + " " + self.sect_var(listname)
        
        if self.revoke & R_NEW:
            self.gen_revoke(obj_str)
        
        if self.revoke & R_DEFS:
            self.gen_revoke_defs(obj_str, obj_type)
        
        if not self.revoke & R_ONLY:
            self.gen_one_type(obj_str)

        if self.revoke & G_DEFS:
            self.gen_defs(obj_str, obj_type)

    def handle_tables(self):
        """Handle grants for tables and sequences.
        
        The tricky part here is the automatic handling of sequences."""

        if not self.sect_hasvar('on.tables'):
            return

        cleaned_list = []
        table_list = self.sect_list('on.tables')
        for table in table_list:
            if table[-1] == '!':
                table = table[:-1]
                if not self.auto_seq:
                    self.seq_list.append("%s_%s_seq" % (table, self.seq_name))
            else:
                if self.auto_seq:
                    self.seq_list.append("%s_%s_seq" % (table, self.seq_name))
            cleaned_list.append(table)
        obj_str = "TABLE " + ", ".join(cleaned_list)

        if self.revoke & R_NEW:
            self.gen_revoke(obj_str)
        if self.revoke & R_DEFS:
            self.gen_revoke_defs(obj_str, "TABLE")
        if not self.revoke & R_ONLY:
            self.gen_one_type(obj_str)
        if self.revoke & G_DEFS:
            self.gen_defs(obj_str, "TABLE")

        # cleanup
        self.seq_list = []
        self.seq_allowed = []

    def gen_revoke(self, obj_str):
        "Generate revoke for one section / subject type (user or group)"

        if len(self.seq_list) > 0:
            obj_str += ", " + ", ".join(self.seq_list)
        obj_str = obj_str.strip().replace('\n', '\n    ')
        print "REVOKE ALL ON %s\n  FROM %s CASCADE;" % (obj_str, self.all_subjs)

    def gen_revoke_defs(self, obj_str, obj_type):
        "Generate revoke defaults for one section"

        # process only things that have default grants to public
        if obj_type not in ('FUNCTION', 'DATABASE', 'LANGUAGE', 'TYPE', 'DOMAIN'):
            return

        defrole = 'public'

        # if the sections contains grants to 'public', dont drop
        if self.sect_hasvar(defrole):
            return

        obj_str = obj_str.strip().replace('\n', '\n    ')
        print "REVOKE ALL ON %s\n  FROM %s CASCADE;" % (obj_str, defrole)

    def gen_defs(self, obj_str, obj_type):
        "Generate defaults grants for one section"

        if obj_type == "FUNCTION":
            defgrants = "execute"
        elif obj_type == "DATABASE":
            defgrants = "connect, temp"
        elif obj_type in ("LANGUAGE", "TYPE", "DOMAIN"):
            defgrants = "usage"
        else:
            return

        defrole = 'public'

        obj_str = obj_str.strip().replace('\n', '\n    ')
        print "GRANT %s ON %s\n  TO %s;" % (defgrants, obj_str, defrole)

    def gen_one_subj(self, subj, fqsubj, obj_str):
        if not self.sect_hasvar(subj):
            return
        obj_str = obj_str.strip().replace('\n', '\n    ')
        perm = self.sect_var(subj).strip()
        if perm:
            print "GRANT %s ON %s\n  TO %s;" % (perm, obj_str, fqsubj)

        # check for seq perms
        if len(self.seq_list) > 0:
            loperm = perm.lower()
            if loperm.find("insert") >= 0 or loperm.find("all") >= 0:
                self.seq_allowed.append(fqsubj)

    def gen_one_type(self, obj_str):
        "Generate GRANT for one section / one object type in section"

        for u in self.user_list:
            self.gen_one_subj(u, u, obj_str)
        for g in self.group_list:
            self.gen_one_subj(g, "group " + g, obj_str)

        # if there was any seq perms, generate grants
        if len(self.seq_allowed) > 0:
            seq_str = ", ".join(self.seq_list)
            subj_str = ", ".join(self.seq_allowed)
            if self.seq_usage:
                cmd = "GRANT usage ON SEQUENCE %s\n  TO %s;"
            else:
                cmd = "GRANT select, update ON %s\n  TO %s;"
            print cmd % (seq_str, subj_str)

    def sect_var(self, name):
        return self.cf.get(self.sect, name).strip()

    def sect_list(self, name):
        return self.cf.get_list(self.sect, name)

    def sect_hasvar(self, name):
        return self.cf.has_option(self.sect, name)

def main():
    revoke = 0
    tx = False

    try:
        opts, args = getopt.getopt(sys.argv[1:], "vhrRdDot")
    except getopt.error, det:
        print "getopt error:", det
        usage(1)

    for o, v in opts:
        if o == "-h":
            usage(0)
        elif o == "-r":
            revoke |= R_NEW
        elif o == "-R":
            revoke |= R_NEW | R_ONLY
        elif o == "-d":
            revoke |= R_DEFS
        elif o == "-D":
            revoke |= R_DEFS | R_ONLY
        elif o == "-o":
            revoke |= G_DEFS
        elif o == "-t":
            tx = True
        elif o == "-v":
            print "GrantFu version", __version__
            sys.exit(0)

    if len(args) != 1:
        usage(1)

    # load config
    cf = PConf()
    cf.read(args[0])
    if not cf.has_section("GrantFu"):
        print "Incorrect config file, GrantFu sction missing"
        sys.exit(1)

    if tx:
        print "begin;\n"

    # revokes and default grants
    if revoke & (R_NEW | R_DEFS):
        g = GrantFu(cf, revoke | R_ONLY)
        g.process()
        revoke = revoke & R_ONLY

    # grants
    if revoke & R_ONLY == 0:
        g = GrantFu(cf, revoke & G_DEFS)
        g.process()

    if tx:
        print "\ncommit;\n"

if __name__ == '__main__':
    main()

