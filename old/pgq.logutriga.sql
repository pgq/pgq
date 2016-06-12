
create or replace function pgq.logutriga()
returns trigger as $$
# -- ----------------------------------------------------------------------
# -- Function: pgq.logutriga()
# --
# --      Trigger function that puts row data urlencoded into queue.
# --
# -- Trigger parameters:
# --      arg1 - queue name
# --      arg2 - optionally 'SKIP'
# --
# -- Queue event fields:
# --   ev_type      - I/U/D
# --   ev_data      - column values urlencoded
# --   ev_extra1    - table name
# --   ev_extra2    - primary key columns
# --
# -- Regular listen trigger example:
# -- >  CREATE TRIGGER triga_nimi AFTER INSERT OR UPDATE ON customer
# -- >  FOR EACH ROW EXECUTE PROCEDURE pgq.logutriga('qname');
# --
# -- Redirect trigger example:
# -- >   CREATE TRIGGER triga_nimi AFTER INSERT OR UPDATE ON customer
# -- >   FOR EACH ROW EXECUTE PROCEDURE pgq.logutriga('qname', 'SKIP');
# -- ----------------------------------------------------------------------

# this triger takes 1 or 2 args:
#   queue_name - destination queue
#   option return code (OK, SKIP) SKIP means op won't happen
# copy-paste of db_urlencode from skytools.quoting
from urllib import quote_plus
def db_urlencode(dict):
    elem_list = []
    for k, v in dict.items():
        if v is None:
            elem = quote_plus(str(k))
        else:
            elem = quote_plus(str(k)) + '=' + quote_plus(str(v))
        elem_list.append(elem)
    return '&'.join(elem_list)

# load args
queue_name = TD['args'][0]
if len(TD['args']) > 1:
    ret_code = TD['args'][1]
else:
    ret_code = 'OK'
table_oid = TD['relid']

# on first call init plans
if not 'init_done' in SD:
    # find table name
    q = "SELECT n.nspname || '.' || c.relname AS table_name"\
        " FROM pg_namespace n, pg_class c"\
        " WHERE n.oid = c.relnamespace AND c.oid = $1"
    SD['name_plan'] = plpy.prepare(q, ['oid'])

    # find key columns
    q = "SELECT k.attname FROM pg_index i, pg_attribute k"\
        " WHERE i.indrelid = $1 AND k.attrelid = i.indexrelid"\
        "   AND i.indisprimary AND k.attnum > 0 AND NOT k.attisdropped"\
        " ORDER BY k.attnum"
    SD['key_plan'] = plpy.prepare(q, ['oid'])

    # insert data
    q = "SELECT pgq.insert_event($1, $2, $3, $4, $5, null, null)"
    SD['ins_plan'] = plpy.prepare(q, ['text', 'text', 'text', 'text', 'text'])

    # shorter tags
    SD['op_map'] = {'INSERT': 'I', 'UPDATE': 'U', 'DELETE': 'D'}

    # remember init
    SD['init_done'] = 1

# load & cache table data
if table_oid in SD:
    tbl_name, tbl_keys = SD[table_oid]
else:
    res = plpy.execute(SD['name_plan'], [table_oid])
    tbl_name = res[0]['table_name']
    res = plpy.execute(SD['key_plan'], [table_oid])
    tbl_keys = ",".join(map(lambda x: x['attname'], res))

    SD[table_oid] = (tbl_name, tbl_keys)

# prepare args
if TD['event'] == 'DELETE':
    data = db_urlencode(TD['old'])
else:
    data = db_urlencode(TD['new'])

# insert event
plpy.execute(SD['ins_plan'], [
    queue_name,
    SD['op_map'][TD['event']],
    data, tbl_name, tbl_keys])

# done
return ret_code

$$ language plpythonu;

