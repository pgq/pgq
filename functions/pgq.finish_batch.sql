
create or replace function pgq.finish_batch(
    x_batch_id bigint)
returns integer as $$
-- ----------------------------------------------------------------------
-- Function: pgq.finish_batch(1)
--
--      Closes a batch.  No more operations can be done with events
--      of this batch.
--
-- Parameters:
--      x_batch_id      - id of batch.
--
-- Returns:
--      1 if batch was found, 0 otherwise.
-- Calls:
--      None
-- Tables directly manipulated:
--      update - pgq.subscription
-- ----------------------------------------------------------------------
begin
    update pgq.subscription
        set sub_active = now(),
            sub_last_tick = sub_next_tick,
            sub_next_tick = null,
            sub_batch = null
        where sub_batch = x_batch_id;
    if not found then
        raise warning 'finish_batch: batch % not found', x_batch_id;
        return 0;
    end if;

    return 1;
end;
$$ language plpgsql security definer;

