create or replace function pgq.insert_event(queue_name text, ev_type text, ev_data text)
returns bigint as $$
-- ----------------------------------------------------------------------
-- Function: pgq.insert_event(3)
--
--      Insert a event into queue.
--
-- Parameters:
--      queue_name      - Name of the queue
--      ev_type         - User-specified type for the event
--      ev_data         - User data for the event
--
-- Returns:
--      Event ID
-- Calls:
--      pgq.insert_event(7)
-- ----------------------------------------------------------------------
begin
    return pgq.insert_event(queue_name, ev_type, ev_data, null, null, null, null);
end;
$$ language plpgsql;



create or replace function pgq.insert_event(
    queue_name text, ev_type text, ev_data text,
    ev_extra1 text, ev_extra2 text, ev_extra3 text, ev_extra4 text)
returns bigint as $$
-- ----------------------------------------------------------------------
-- Function: pgq.insert_event(7)
--
--      Insert a event into queue with all the extra fields.
--
-- Parameters:
--      queue_name      - Name of the queue
--      ev_type         - User-specified type for the event
--      ev_data         - User data for the event
--      ev_extra1       - Extra data field for the event
--      ev_extra2       - Extra data field for the event
--      ev_extra3       - Extra data field for the event
--      ev_extra4       - Extra data field for the event
--
-- Returns:
--      Event ID
-- Calls:
--      pgq.insert_event_raw(11)
-- Tables directly manipulated:
--      insert - pgq.insert_event_raw(11), a C function, inserts into current event_N_M table
-- ----------------------------------------------------------------------
begin
    return pgq.insert_event_raw(queue_name, null, now(), null, null,
            ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4);
end;
$$ language plpgsql security definer;

