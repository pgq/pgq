
-- ----------------------------------------------------------------------
-- Function: pgq.insert_event_raw(11)
--
--      Actual event insertion.  Used also by retry queue maintenance.
--
-- Parameters:
--      queue_name      - Name of the queue
--      ev_id           - Event ID.  If NULL, will be taken from seq.
--      ev_time         - Event creation time.
--      ev_owner        - Subscription ID when retry event. If NULL, the event is for everybody.
--      ev_retry        - Retry count. NULL for first-time events.
--      ev_type         - user data
--      ev_data         - user data
--      ev_extra1       - user data
--      ev_extra2       - user data
--      ev_extra3       - user data
--      ev_extra4       - user data
--
-- Returns:
--      Event ID.
-- ----------------------------------------------------------------------
create or replace function pgq.insert_event_raw(
    queue_name text, ev_id bigint, ev_time timestamptz,
    ev_owner integer, ev_retry integer, ev_type text, ev_data text,
    ev_extra1 text, ev_extra2 text, ev_extra3 text, ev_extra4 text)
returns int8 as $$
declare
    qstate record;
    _qname text;
begin
    _qname := queue_name;
    select q.queue_id,
        pgq.quote_fqname(q.queue_data_pfx || '_' || q.queue_cur_table::text) as cur_table_name,
        nextval(q.queue_event_seq) as next_ev_id,
        q.queue_disable_insert,
        q.queue_per_tx_limit
    from pgq.queue q where q.queue_name = _qname into qstate;

    if ev_id is null then
        ev_id := qstate.next_ev_id;
    end if;

    if qstate.queue_disable_insert then
        if current_setting('session_replication_role') <> 'replica' then
            raise exception 'Insert into queue disallowed';
        end if;
    end if;

    execute 'insert into ' || qstate.cur_table_name
        || ' (ev_id, ev_time, ev_owner, ev_retry,'
        || ' ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4)'
        || 'values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)'
        using ev_id, ev_time, ev_owner, ev_retry,
              ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4;

    return ev_id;
end;
$$ language plpgsql;

