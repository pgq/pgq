create or replace function pgq.insert_event_raw(
        queue_name text, ev_id bigint, ev_time timestamptz,
        ev_owner integer, ev_retry integer, ev_type text, ev_data text,
        ev_extra1 text, ev_extra2 text, ev_extra3 text, ev_extra4 text)
returns bigint as $$
# -- ----------------------------------------------------------------------
# -- Function: pgq.insert_event_raw(11)
# --
# --    Deprecated function, replaced by C code in pgq_lowlevel.so.
# --    
# --    Actual event insertion.  Used also by retry queue maintenance.
# --
# -- Parameters:
# --      queue_name      - Name of the queue
# --      ev_id           - Event ID.  If NULL, will be taken from seq.
# --      ev_time         - Event creation time.
# --      ev_owner        - Subscription ID when retry event. If NULL, the event is for everybody.
# --      ev_retry        - Retry count. NULL for first-time events.
# --      ev_type         - user data
# --      ev_data         - user data
# --      ev_extra1       - user data
# --      ev_extra2       - user data
# --      ev_extra3       - user data
# --      ev_extra4       - user data
# --
# -- Returns:
# --      Event ID.
# -- ----------------------------------------------------------------------

    # load args
    queue_name = args[0]
    ev_id = args[1]
    ev_time = args[2]
    ev_owner = args[3]
    ev_retry = args[4]
    ev_type = args[5]
    ev_data = args[6]
    ev_extra1 = args[7]
    ev_extra2 = args[8]
    ev_extra3 = args[9]
    ev_extra4 = args[10]

    if not "cf_plan" in SD:
        # get current event table
        q = "select queue_data_pfx, queue_cur_table, queue_event_seq "\
            " from pgq.queue where queue_name = $1"
        SD["cf_plan"] = plpy.prepare(q, ["text"])

        # get next id
        q = "select nextval($1) as id"
        SD["seq_plan"] = plpy.prepare(q, ["text"])

    # get queue config
    res = plpy.execute(SD["cf_plan"], [queue_name])
    if len(res) != 1:
        plpy.error("Unknown event queue: %s" % (queue_name))
    tbl_prefix = res[0]["queue_data_pfx"]
    cur_nr = res[0]["queue_cur_table"]
    id_seq = res[0]["queue_event_seq"]

    # get id - bump seq even if id is given
    res = plpy.execute(SD['seq_plan'], [id_seq])
    if ev_id is None:
        ev_id = res[0]["id"]

    # create plan for insertion
    ins_plan = None
    ins_key = "ins.%s" % (queue_name)
    if ins_key in SD:
        nr, ins_plan = SD[ins_key]
        if nr != cur_nr:
            ins_plan = None
    if ins_plan == None:
        q = "insert into %s_%s (ev_id, ev_time, ev_owner, ev_retry,"\
            " ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4)"\
            " values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)" % (
            tbl_prefix, cur_nr)
        types = ["int8", "timestamptz", "int4", "int4", "text",
                 "text", "text", "text", "text", "text"]
        ins_plan = plpy.prepare(q, types)
        SD[ins_key] = (cur_nr, ins_plan)

    # insert the event
    plpy.execute(ins_plan, [ev_id, ev_time, ev_owner, ev_retry, ev_type, ev_data,
                            ev_extra1, ev_extra2, ev_extra3, ev_extra4])

    # done
    return ev_id

$$ language plpythonu;  -- event inserting needs no special perms

