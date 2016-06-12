

create or replace function pgq.force_tick(i_queue_name text)
returns bigint as $$
-- ----------------------------------------------------------------------
-- Function: pgq.force_tick(2)
--
--      Simulate lots of events happening to force ticker to tick.
--
--      Should be called in loop, with some delay until last tick
--      changes or too much time is passed.
--
--      Such function is needed because paraller calls of pgq.ticker() are
--      dangerous, and cannot be protected with locks as snapshot
--      is taken before locking.
--
-- Parameters:
--      i_queue_name     - Name of the queue
--
-- Returns:
--      Currently last tick id.
-- ----------------------------------------------------------------------
declare
    q  record;
    t  record;
begin
    -- bump seq and get queue id
    select queue_id,
           setval(queue_event_seq, nextval(queue_event_seq)
                                   + queue_ticker_max_count * 2 + 1000) as tmp
      into q from pgq.queue
     where queue_name = i_queue_name
       and not queue_external_ticker
       and not queue_ticker_paused;

    --if not found then
    --    raise notice 'queue not found or ticks not allowed';
    --end if;

    -- return last tick id
    select tick_id into t
      from pgq.tick, pgq.queue
     where tick_queue = queue_id and queue_name = i_queue_name
     order by tick_queue desc, tick_id desc limit 1;

    return t.tick_id;
end;
$$ language plpgsql security definer;

