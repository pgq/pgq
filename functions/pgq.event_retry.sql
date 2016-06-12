create or replace function pgq.event_retry(
    x_batch_id bigint,
    x_event_id bigint,
    x_retry_time timestamptz)
returns integer as $$
-- ----------------------------------------------------------------------
-- Function: pgq.event_retry(3a)
--
--     Put the event into retry queue, to be processed again later.
--
-- Parameters:
--      x_batch_id      - ID of active batch.
--      x_event_id      - event id
--      x_retry_time    - Time when the event should be put back into queue
--
-- Returns:
--     1 - success
--     0 - event already in retry queue
-- Calls:
--      None
-- Tables directly manipulated:
--      insert - pgq.retry_queue
-- ----------------------------------------------------------------------
begin
    insert into pgq.retry_queue (ev_retry_after, ev_queue,
        ev_id, ev_time, ev_txid, ev_owner, ev_retry, ev_type, ev_data,
        ev_extra1, ev_extra2, ev_extra3, ev_extra4)
    select x_retry_time, sub_queue,
           ev_id, ev_time, NULL, sub_id, coalesce(ev_retry, 0) + 1,
           ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4
      from pgq.get_batch_events(x_batch_id),
           pgq.subscription
     where sub_batch = x_batch_id
       and ev_id = x_event_id;
    if not found then
        raise exception 'event not found';
    end if;
    return 1;

-- dont worry if the event is already in queue
exception
    when unique_violation then
        return 0;
end;
$$ language plpgsql security definer;


create or replace function pgq.event_retry(
    x_batch_id bigint,
    x_event_id bigint,
    x_retry_seconds integer)
returns integer as $$
-- ----------------------------------------------------------------------
-- Function: pgq.event_retry(3b)
--
--     Put the event into retry queue, to be processed later again.
--
-- Parameters:
--      x_batch_id      - ID of active batch.
--      x_event_id      - event id
--      x_retry_seconds - Time when the event should be put back into queue
--
-- Returns:
--     1 - success
--     0 - event already in retry queue
-- Calls:
--      pgq.event_retry(3a)
-- Tables directly manipulated:
--      None
-- ----------------------------------------------------------------------
declare
    new_retry  timestamptz;
begin
    new_retry := current_timestamp + ((x_retry_seconds::text || ' seconds')::interval);
    return pgq.event_retry(x_batch_id, x_event_id, new_retry);
end;
$$ language plpgsql security definer;

