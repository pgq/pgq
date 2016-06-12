
create or replace function pgq.set_queue_config(
    x_queue_name    text,
    x_param_name    text,
    x_param_value   text)
returns integer as $$
-- ----------------------------------------------------------------------
-- Function: pgq.set_queue_config(3)
--
--
--     Set configuration for specified queue.
--
-- Parameters:
--      x_queue_name    - Name of the queue to configure.
--      x_param_name    - Configuration parameter name.
--      x_param_value   - Configuration parameter value.
--  
-- Returns:
--     0 if event was already in queue, 1 otherwise.
-- Calls:
--      None
-- Tables directly manipulated:
--      update - pgq.queue
-- ----------------------------------------------------------------------
declare
    v_param_name    text;
begin
    -- discard NULL input
    if x_queue_name is null or x_param_name is null then
        raise exception 'Invalid NULL value';
    end if;

    -- check if queue exists
    perform 1 from pgq.queue where queue_name = x_queue_name;
    if not found then
        raise exception 'No such event queue';
    end if;

    -- check if valid parameter name
    v_param_name := 'queue_' || x_param_name;
    if v_param_name not in (
        'queue_ticker_max_count',
        'queue_ticker_max_lag',
        'queue_ticker_idle_period',
        'queue_ticker_paused',
        'queue_rotation_period',
        'queue_external_ticker')
    then
        raise exception 'cannot change parameter "%s"', x_param_name;
    end if;

    execute 'update pgq.queue set ' 
        || v_param_name || ' = ' || quote_literal(x_param_value)
        || ' where queue_name = ' || quote_literal(x_queue_name);

    return 1;
end;
$$ language plpgsql security definer;

