create or replace function pgq.batch_retry(
    i_batch_id bigint,
    i_retry_seconds integer)
returns integer as $$
-- ----------------------------------------------------------------------
-- Function: pgq.batch_retry(2)
--
--     Put whole batch into retry queue, to be processed again later.
--
-- Parameters:
--      i_batch_id      - ID of active batch.
--      i_retry_time    - Time when the event should be put back into queue
--
-- Returns:
--     number of events inserted
-- Calls:
--      None
-- Tables directly manipulated:
--      pgq.retry_queue
-- ----------------------------------------------------------------------
declare
    _retry timestamptz;
    _cnt   integer;
    _s     record;
begin
    _retry := current_timestamp + ((i_retry_seconds::text || ' seconds')::interval);

    select * into _s from pgq.subscription where sub_batch = i_batch_id;
    if not found then
        raise exception 'batch_retry: batch % not found', i_batch_id;
    end if;

    insert into pgq.retry_queue (ev_retry_after, ev_queue,
        ev_id, ev_time, ev_txid, ev_owner, ev_retry,
        ev_type, ev_data, ev_extra1, ev_extra2,
        ev_extra3, ev_extra4)
    select distinct _retry, _s.sub_queue,
           b.ev_id, b.ev_time, NULL::int8, _s.sub_id, coalesce(b.ev_retry, 0) + 1,
           b.ev_type, b.ev_data, b.ev_extra1, b.ev_extra2,
           b.ev_extra3, b.ev_extra4
      from pgq.get_batch_events(i_batch_id) b
           left join pgq.retry_queue rq
                  on (rq.ev_id = b.ev_id
                      and rq.ev_owner = _s.sub_id
                      and rq.ev_queue = _s.sub_queue)
      where rq.ev_id is null;

    GET DIAGNOSTICS _cnt = ROW_COUNT;
    return _cnt;
end;
$$ language plpgsql security definer;


