
-- listen trigger:
-- create trigger triga_nimi after insert or update on customer
-- for each row execute procedure pgq.sqltriga('qname');

-- redirect trigger:
-- create trigger triga_nimi after insert or update on customer
-- for each row execute procedure pgq.sqltriga('qname', 'ret=SKIP');

create or replace function pgq.sqltriga()
returns trigger as $$
# -- ----------------------------------------------------------------------
# -- Function: pgq.sqltriga()
# --
# --      Trigger function that puts row data in partial SQL form into queue.
# --
# -- Parameters:
# --    arg1 - queue name
# --    arg2 - optional urlencoded options
# --
# -- Extra options:
# --
# --    ret     - return value for function OK/SKIP
# --    pkey    - override pkey fields, can be functions
# --    ignore  - comma separated field names to ignore
# --
# -- Queue event fields:
# --    ev_type     - I/U/D
# --    ev_data     - partial SQL statement
# --    ev_extra1   - table name
# --
# -- ----------------------------------------------------------------------
# this triger takes 1 or 2 args:
#   queue_name - destination queue
#   args - urlencoded dict of options:
#       ret - return value: OK/SKIP
#       pkey - comma-separated col names or funcs on cols
#              simple:  pkey=user,orderno
#              hashed:  pkey=user,hashtext(user)
#       ignore - comma-separated col names to ignore

# on first call init stuff
if not 'init_done' in SD:
    # find table name plan
    q = "SELECT n.nspname || '.' || c.relname AS table_name"\
        " FROM pg_namespace n, pg_class c"\
        " WHERE n.oid = c.relnamespace AND c.oid = $1"
    SD['name_plan'] = plpy.prepare(q, ['oid'])

    # find key columns plan
    q = "SELECT k.attname FROM pg_index i, pg_attribute k"\
        " WHERE i.indrelid = $1 AND k.attrelid = i.indexrelid"\
        "   AND i.indisprimary AND k.attnum > 0 AND NOT k.attisdropped"\
        " ORDER BY k.attnum"
    SD['key_plan'] = plpy.prepare(q, ['oid'])

    # data insertion
    q = "SELECT pgq.insert_event($1, $2, $3, $4, null, null, null)"
    SD['ins_plan'] = plpy.prepare(q, ['text', 'text', 'text', 'text'])

    # shorter tags
    SD['op_map'] = {'INSERT': 'I', 'UPDATE': 'U', 'DELETE': 'D'}

    # quoting
    from psycopg import QuotedString
    def quote(s):
        if s is None:
            return "null"
        s = str(s)
        return str(QuotedString(s))
        s = s.replace('\\', '\\\\')
        s = s.replace("'", "''")
        return "'%s'" % s

    # TableInfo class
    import re, urllib
    class TableInfo:
        func_rc = re.compile("([^(]+) [(] ([^)]+) [)]", re.I | re.X)
        def __init__(self, table_oid, options_txt):
            res = plpy.execute(SD['name_plan'], [table_oid])
            self.name = res[0]['table_name']

            self.parse_options(options_txt)
            self.load_pkey()

        def recheck(self, options_txt):
            if self.options_txt == options_txt:
                return
            self.parse_options(options_txt)
            self.load_pkey()

        def parse_options(self, options_txt):
            self.options = {'ret': 'OK'}
            if options_txt:
                for s in options_txt.split('&'):
                    k, v = s.split('=', 1)
                    self.options[k] = urllib.unquote_plus(v)
            self.options_txt = options_txt

        def load_pkey(self):
            self.pkey_list = []
            if not 'pkey' in self.options:
                res = plpy.execute(SD['key_plan'], [table_oid])
                for krow in res:
                    col = krow['attname']
                    expr = col + "=%s"
                    self.pkey_list.append( (col, expr) )
            else:
                for a_pk in self.options['pkey'].split(','):
                    m = self.func_rc.match(a_pk)
                    if m:
                        col = m.group(2)
                        fn = m.group(1)
                        expr = "%s(%s) = %s(%%s)" % (fn, col, fn)
                    else:
                        # normal case
                        col = a_pk
                        expr = col + "=%s"
                    self.pkey_list.append( (col, expr) )
            if len(self.pkey_list) == 0:
                plpy.error('sqltriga needs primary key on table')
        
        def get_insert_stmt(self, new):
            col_list = []
            val_list = []
            for k, v in new.items():
                col_list.append(k)
                val_list.append(quote(v))
            return "(%s) values (%s)" % (",".join(col_list), ",".join(val_list))

        def get_update_stmt(self, old, new):
            chg_list = []
            for k, v in new.items():
                ov = old[k]
                if v == ov:
                    continue
                chg_list.append("%s=%s" % (k, quote(v)))
            if len(chg_list) == 0:
                pk = self.pkey_list[0][0]
                chg_list.append("%s=%s" % (pk, quote(new[pk])))
            return "%s where %s" % (",".join(chg_list), self.get_pkey_expr(new))

        def get_pkey_expr(self, data):
            exp_list = []
            for col, exp in self.pkey_list:
                exp_list.append(exp % quote(data[col]))
            return " and ".join(exp_list)

    SD['TableInfo'] = TableInfo

    # cache some functions
    def proc_insert(tbl):
        return tbl.get_insert_stmt(TD['new'])
    def proc_update(tbl):
        return tbl.get_update_stmt(TD['old'], TD['new'])
    def proc_delete(tbl):
        return tbl.get_pkey_expr(TD['old'])
    SD['event_func'] = {
        'I': proc_insert,
        'U': proc_update,
        'D': proc_delete,
    }

    # remember init
    SD['init_done'] = 1


# load args
table_oid = TD['relid']
queue_name = TD['args'][0]
if len(TD['args']) > 1:
    options_str = TD['args'][1]
else:
    options_str = ''

# load & cache table data
if table_oid in SD:
    tbl = SD[table_oid]
    tbl.recheck(options_str)
else:
    tbl = SD['TableInfo'](table_oid, options_str)
    SD[table_oid] = tbl

# generate payload
op = SD['op_map'][TD['event']]
data = SD['event_func'][op](tbl)

# insert event
plpy.execute(SD['ins_plan'], [queue_name, op, data, tbl.name])

# done
return tbl.options['ret']

$$ language plpythonu;

