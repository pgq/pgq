
create or replace function pgq.get_consumer_info(
    out queue_name      text,
    out consumer_name   text,
    out lag             interval,
    out last_seen       interval,
    out last_tick       bigint,
    out current_batch   bigint,
    out next_tick       bigint,
    out pending_events  bigint)
returns setof record as $$
-- ----------------------------------------------------------------------
-- Function: pgq.get_consumer_info(0)
--
--      Returns info about all consumers on all queues.
--
-- Returns:
--      See pgq.get_consumer_info(2)
-- ----------------------------------------------------------------------
begin
    for queue_name, consumer_name, lag, last_seen,
        last_tick, current_batch, next_tick, pending_events
    in
        select f.queue_name, f.consumer_name, f.lag, f.last_seen,
               f.last_tick, f.current_batch, f.next_tick, f.pending_events
            from pgq.get_consumer_info(null, null) f
    loop
        return next;
    end loop;
    return;
end;
$$ language plpgsql security definer;



create or replace function pgq.get_consumer_info(
    in i_queue_name     text,
    out queue_name      text,
    out consumer_name   text,
    out lag             interval,
    out last_seen       interval,
    out last_tick       bigint,
    out current_batch   bigint,
    out next_tick       bigint,
    out pending_events  bigint)
returns setof record as $$
-- ----------------------------------------------------------------------
-- Function: pgq.get_consumer_info(1)
--
--      Returns info about all consumers on single queue.
--
-- Returns:
--      See pgq.get_consumer_info(2)
-- ----------------------------------------------------------------------
begin
    for queue_name, consumer_name, lag, last_seen,
        last_tick, current_batch, next_tick, pending_events
    in
        select f.queue_name, f.consumer_name, f.lag, f.last_seen,
               f.last_tick, f.current_batch, f.next_tick, f.pending_events
            from pgq.get_consumer_info(i_queue_name, null) f
    loop
        return next;
    end loop;
    return;
end;
$$ language plpgsql security definer;



create or replace function pgq.get_consumer_info(
    in i_queue_name     text,
    in i_consumer_name  text,
    out queue_name      text,
    out consumer_name   text,
    out lag             interval,
    out last_seen       interval,
    out last_tick       bigint,
    out current_batch   bigint,
    out next_tick       bigint,
    out pending_events  bigint)
returns setof record as $$
-- ----------------------------------------------------------------------
-- Function: pgq.get_consumer_info(2)
--
--      Get info about particular consumer on particular queue.
--
-- Parameters:
--      i_queue_name        - name of a queue. (null = all)
--      i_consumer_name     - name of a consumer (null = all)
--
-- Returns:
--      queue_name          - Queue name
--      consumer_name       - Consumer name
--      lag                 - How old are events the consumer is processing
--      last_seen           - When the consumer seen by pgq
--      last_tick           - Tick ID of last processed tick
--      current_batch       - Current batch ID, if one is active or NULL
--      next_tick           - If batch is active, then its final tick.
-- ----------------------------------------------------------------------
declare
    _pending_events bigint;
    _queue_id bigint;
begin
    for queue_name, consumer_name, lag, last_seen,
        last_tick, current_batch, next_tick, _pending_events, _queue_id
    in
        select q.queue_name, c.co_name,
               current_timestamp - t.tick_time,
               current_timestamp - s.sub_active,
               s.sub_last_tick, s.sub_batch, s.sub_next_tick,
               t.tick_event_seq, q.queue_id
          from pgq.queue q,
               pgq.consumer c,
               pgq.subscription s
               left join pgq.tick t
                 on (t.tick_queue = s.sub_queue and t.tick_id = s.sub_last_tick)
         where q.queue_id = s.sub_queue
           and c.co_id = s.sub_consumer
           and (i_queue_name is null or q.queue_name = i_queue_name)
           and (i_consumer_name is null or c.co_name = i_consumer_name)
         order by 1,2
    loop
        select t.tick_event_seq - _pending_events
            into pending_events
            from pgq.tick t
            where t.tick_queue = _queue_id
            order by t.tick_queue desc, t.tick_id desc
            limit 1;
        return next;
    end loop;
    return;
end;
$$ language plpgsql security definer;

