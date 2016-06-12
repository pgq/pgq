create or replace function pgq.event_retry_raw(
    x_queue text,
    x_consumer text,
    x_retry_after timestamptz,
    x_ev_id bigint,
    x_ev_time timestamptz,
    x_ev_retry integer,
    x_ev_type text,
    x_ev_data text,
    x_ev_extra1 text,
    x_ev_extra2 text,
    x_ev_extra3 text,
    x_ev_extra4 text)
returns bigint as $$
-- ----------------------------------------------------------------------
-- Function: pgq.event_retry_raw(12)
--
--      Allows full control over what goes to retry queue.
--
-- Parameters:
--      x_queue         - name of the queue
--      x_consumer      - name of the consumer
--      x_retry_after   - when the event should be processed again
--      x_ev_id         - event id
--      x_ev_time       - creation time
--      x_ev_retry      - retry count
--      x_ev_type       - user data
--      x_ev_data       - user data
--      x_ev_extra1     - user data
--      x_ev_extra2     - user data
--      x_ev_extra3     - user data
--      x_ev_extra4     - user data
--
-- Returns:
--      Event ID.
-- ----------------------------------------------------------------------
declare
    q record;
    id bigint;
begin
    select sub_id, queue_event_seq, sub_queue into q
      from pgq.consumer, pgq.queue, pgq.subscription
     where queue_name = x_queue
       and co_name = x_consumer
       and sub_consumer = co_id
       and sub_queue = queue_id;
    if not found then
        raise exception 'consumer not registered';
    end if;

    id := x_ev_id;
    if id is null then
        id := nextval(q.queue_event_seq);
    end if;

    insert into pgq.retry_queue (ev_retry_after, ev_queue,
            ev_id, ev_time, ev_owner, ev_retry,
            ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4)
    values (x_retry_after, q.sub_queue,
            id, x_ev_time, q.sub_id, x_ev_retry,
            x_ev_type, x_ev_data, x_ev_extra1, x_ev_extra2,
            x_ev_extra3, x_ev_extra4);

    return id;
end;
$$ language plpgsql security definer;

