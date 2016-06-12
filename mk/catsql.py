#! /usr/bin/env python

"""Prints out SQL files with psql command execution.

Supported psql commands: \i, \cd, \q
Others are skipped.

Aditionally does some pre-processing for NDoc.
NDoc is looks nice but needs some hand-holding.

Bug:

- function def end detection searches for 'as'/'is' but does not check
  word boundaries - finds them even in function name.  That means in
  main conf, as/is must be disabled and $ ' added.  This script can
  remove the unnecessary AS from output.

Niceties:

- Ndoc includes function def in output only if def is after comment.
  But for SQL functions its better to have it after def.
  This script can swap comment and def.

- Optionally remove CREATE FUNCTION (OR REPLACE) from def to
  keep it shorter in doc.

Note:

- NDoc compares real function name and name in comment. if differ,
  it decides detection failed.

"""

import sys, os, re, getopt

def usage(x):
    print("usage: catsql [--ndoc] FILE [FILE ...]")
    sys.exit(x)

# NDoc specific changes
cf_ndoc = 0

# compile regexes
func_re = r"create\s+(or\s+replace\s+)?function\s+"
func_rc = re.compile(func_re, re.I)
comm_rc = re.compile(r"^\s*([#]\s*)?(?P<com>--.*)", re.I)
end_rc = re.compile(r"\b([;]|begin|declare|end)\b", re.I)
as_rc = re.compile(r"\s+as\s+", re.I)
cmd_rc = re.compile(r"^\\([a-z]*)(\s+.*)?", re.I)

# conversion func
def fix_func(ln):
    # if ndoc, replace AS with ' '
    if cf_ndoc:
        return as_rc.sub(' ', ln)
    else:
        return ln

# got function def
def proc_func(f, ln):
    # remove CREATE OR REPLACE
    if cf_ndoc:
        ln = func_rc.sub('', ln)

    ln = fix_func(ln)
    pre_list = [ln]
    comm_list = []
    while 1:
        ln = f.readline()
        if not ln:
            break

        com = None
        if cf_ndoc:
            com = comm_rc.search(ln)
        if cf_ndoc and com:
            pos = com.start('com')
            comm_list.append(ln[pos:])
        elif end_rc.search(ln):
            break
        elif len(comm_list) > 0:
            break
        else:
            pre_list.append(fix_func(ln))

    if len(comm_list) > 2:
        map(sys.stdout.write, comm_list)
        map(sys.stdout.write, pre_list)
    else:
        map(sys.stdout.write, pre_list)
        map(sys.stdout.write, comm_list)
    if ln:
        sys.stdout.write(fix_func(ln))

def cat_file(fn):
    sys.stdout.write("\n")
    f = open(fn)
    while 1:
        ln = f.readline()
        if not ln:
            break
        m = cmd_rc.search(ln)
        if m:
            cmd = m.group(1)
            if cmd == "i":          # include a file
                fn2 = m.group(2).strip()
                cat_file(fn2)
            elif cmd == "q":        # quit
                sys.exit(0)
            elif cmd == "cd":       # chdir
                cd_dir = m.group(2).strip()
                os.chdir(cd_dir)
            else:                   # skip all others
                pass
        else:
            if func_rc.search(ln):  # function header
                proc_func(f, ln)
            else:                   # normal sql
                sys.stdout.write(ln)
    sys.stdout.write("\n")

def main():
    global cf_ndoc

    try:
        opts, args = getopt.gnu_getopt(sys.argv[1:], 'h', ['ndoc'])
    except getopt.error, d:
        print(str(d))
        usage(1)
    for o, v in opts:
        if o == "-h":
            usage(0)
        elif o == "--ndoc":
            cf_ndoc = 1
    for fn in args:
        cat_file(fn)

if __name__ == '__main__':
    main()

