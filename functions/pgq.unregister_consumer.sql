
create or replace function pgq.unregister_consumer(
    x_queue_name text,
    x_consumer_name text)
returns integer as $$
-- ----------------------------------------------------------------------
-- Function: pgq.unregister_consumer(2)
--
--      Unsubscribe consumer from the queue.
--      Also consumer's retry events are deleted.
--
-- Parameters:
--      x_queue_name        - Name of the queue
--      x_consumer_name     - Name of the consumer
--
-- Returns:
--      number of (sub)consumers unregistered
-- Calls:
--      None
-- Tables directly manipulated:
--      delete - pgq.retry_queue
--      delete - pgq.subscription
-- ----------------------------------------------------------------------
declare
    x_sub_id integer;
    _sub_id_cnt integer;
    _consumer_id integer;
    _is_subconsumer boolean;
begin
    select s.sub_id, c.co_id,
           -- subconsumers can only have both null or both not null - main consumer for subconsumers has only one not null
           (s.sub_last_tick IS NULL AND s.sub_next_tick IS NULL) OR (s.sub_last_tick IS NOT NULL AND s.sub_next_tick IS NOT NULL)
      into x_sub_id, _consumer_id, _is_subconsumer
      from pgq.subscription s, pgq.consumer c, pgq.queue q
     where s.sub_queue = q.queue_id
       and s.sub_consumer = c.co_id
       and q.queue_name = x_queue_name
       and c.co_name = x_consumer_name
       for update of s, c;
    if not found then
        return 0;
    end if;

    -- consumer + subconsumer count
    select count(*) into _sub_id_cnt
        from pgq.subscription
       where sub_id = x_sub_id;

    -- delete only one subconsumer
    if _sub_id_cnt > 1 and _is_subconsumer then
        delete from pgq.subscription
              where sub_id = x_sub_id
                and sub_consumer = _consumer_id;
        return 1;
    else
        -- delete main consumer (including possible subconsumers)

        -- retry events
        delete from pgq.retry_queue
            where ev_owner = x_sub_id;

        -- this will drop subconsumers too
        delete from pgq.subscription
            where sub_id = x_sub_id;

        perform 1 from pgq.subscription
            where sub_consumer = _consumer_id;
        if not found then
            delete from pgq.consumer
                where co_id = _consumer_id;
        end if;

        return _sub_id_cnt;
    end if;

end;
$$ language plpgsql security definer;

