
create or replace function pgq.get_batch_info(
    in x_batch_id       bigint,
    out queue_name      text,
    out consumer_name   text,
    out batch_start     timestamptz,
    out batch_end       timestamptz,
    out prev_tick_id    bigint,
    out tick_id         bigint,
    out lag             interval,
    out seq_start       bigint,
    out seq_end         bigint)
as $$
-- ----------------------------------------------------------------------
-- Function: pgq.get_batch_info(1)
--
--      Returns detailed info about a batch.
--
-- Parameters:
--      x_batch_id      - id of a active batch.
--
-- Returns: ??? pls check
--      queue_name      - which queue this batch came from
--      consumer_name   - batch processed by
--      batch_start     - start time of batch
--      batch_end       - end time of batch
--      prev_tick_id    - start tick for this batch
--      tick_id         - end tick for this batch
--      lag             - now() - tick_id.time 
--      seq_start       - start event id for batch
--      seq_end         - end event id for batch
-- ----------------------------------------------------------------------
begin
    select q.queue_name, c.co_name,
           prev.tick_time, cur.tick_time,
           s.sub_last_tick, s.sub_next_tick,
           current_timestamp - cur.tick_time,
           prev.tick_event_seq, cur.tick_event_seq
        into queue_name, consumer_name, batch_start, batch_end,
             prev_tick_id, tick_id, lag, seq_start, seq_end
        from pgq.subscription s, pgq.tick cur, pgq.tick prev,
             pgq.queue q, pgq.consumer c
        where s.sub_batch = x_batch_id
          and prev.tick_id = s.sub_last_tick
          and prev.tick_queue = s.sub_queue
          and cur.tick_id = s.sub_next_tick
          and cur.tick_queue = s.sub_queue
          and q.queue_id = s.sub_queue
          and c.co_id = s.sub_consumer;
    return;
end;
$$ language plpgsql security definer;

