create or replace function pgq.current_event_table(x_queue_name text)
returns text as $$
-- ----------------------------------------------------------------------
-- Function: pgq.current_event_table(1)
--
--      Return active event table for particular queue.
--      Event can be added to it without going via functions,
--      e.g. by COPY.
--
--      If queue is disabled and GUC session_replication_role <> 'replica'
--      then raises exception.
--
--      or expressed in a different way - an even table of a disabled queue
--      is returned only on replica
--
-- Note:
--      The result is valid only during current transaction.
--
-- Permissions:
--      Actual insertion requires superuser access.
--
-- Parameters:
--      x_queue_name    - Queue name.
-- ----------------------------------------------------------------------
declare
    res text;
    disabled boolean;
begin
    select queue_data_pfx || '_' || queue_cur_table::text,
           queue_disable_insert
        into res, disabled
        from pgq.queue where queue_name = x_queue_name;
    if not found then
        raise exception 'Event queue not found';
    end if;
    if disabled then
        if current_setting('session_replication_role') <> 'replica' then
            raise exception 'Writing to queue disabled';
        end if;
    end if;
    return res;
end;
$$ language plpgsql; -- no perms needed

