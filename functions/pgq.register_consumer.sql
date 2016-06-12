create or replace function pgq.register_consumer(
    x_queue_name text,
    x_consumer_id text)
returns integer as $$
-- ----------------------------------------------------------------------
-- Function: pgq.register_consumer(2)
--
--      Subscribe consumer on a queue.
--
--      From this moment forward, consumer will see all events in the queue.
--
-- Parameters:
--      x_queue_name        - Name of queue
--      x_consumer_name     - Name of consumer
--
-- Returns:
--      0  - if already registered
--      1  - if new registration
-- Calls:
--      pgq.register_consumer_at(3)
-- Tables directly manipulated:
--      None
-- ----------------------------------------------------------------------
begin
    return pgq.register_consumer_at(x_queue_name, x_consumer_id, NULL);
end;
$$ language plpgsql security definer;


create or replace function pgq.register_consumer_at(
    x_queue_name text,
    x_consumer_name text,
    x_tick_pos bigint)
returns integer as $$
-- ----------------------------------------------------------------------
-- Function: pgq.register_consumer_at(3)
--
--      Extended registration, allows to specify tick_id.
--
-- Note:
--      For usage in special situations.
--
-- Parameters:
--      x_queue_name        - Name of a queue
--      x_consumer_name     - Name of consumer
--      x_tick_pos          - Tick ID
--
-- Returns:
--      0/1 whether consumer has already registered.
-- Calls:
--      None
-- Tables directly manipulated:
--      update/insert - pgq.subscription
-- ----------------------------------------------------------------------
declare
    tmp         text;
    last_tick   bigint;
    x_queue_id  integer;
    x_consumer_id integer;
    queue integer;
    sub record;
begin
    select queue_id into x_queue_id from pgq.queue
        where queue_name = x_queue_name;
    if not found then
        raise exception 'Event queue not created yet';
    end if;

    -- get consumer and create if new
    select co_id into x_consumer_id from pgq.consumer
        where co_name = x_consumer_name
        for update;
    if not found then
        insert into pgq.consumer (co_name) values (x_consumer_name);
        x_consumer_id := currval('pgq.consumer_co_id_seq');
    end if;

    -- if particular tick was requested, check if it exists
    if x_tick_pos is not null then
        perform 1 from pgq.tick
            where tick_queue = x_queue_id
              and tick_id = x_tick_pos;
        if not found then
            raise exception 'cannot reposition, tick not found: %', x_tick_pos;
        end if;
    end if;

    -- check if already registered
    select sub_last_tick, sub_batch into sub
        from pgq.subscription
        where sub_consumer = x_consumer_id
          and sub_queue  = x_queue_id;
    if found then
        if x_tick_pos is not null then
            -- if requested, update tick pos and drop partial batch
            update pgq.subscription
                set sub_last_tick = x_tick_pos,
                    sub_batch = null,
                    sub_next_tick = null,
                    sub_active = now()
                where sub_consumer = x_consumer_id
                  and sub_queue = x_queue_id;
        end if;
        -- already registered
        return 0;
    end if;

    --  new registration
    if x_tick_pos is null then
        -- start from current tick
        select tick_id into last_tick from pgq.tick
            where tick_queue = x_queue_id
            order by tick_queue desc, tick_id desc
            limit 1;
        if not found then
            raise exception 'No ticks for this queue.  Please run ticker on database.';
        end if;
    else
        last_tick := x_tick_pos;
    end if;

    -- register
    insert into pgq.subscription (sub_queue, sub_consumer, sub_last_tick)
        values (x_queue_id, x_consumer_id, last_tick);
    return 1;
end;
$$ language plpgsql security definer;


