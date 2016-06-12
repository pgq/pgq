create or replace function pgq.get_batch_events(
    in x_batch_id   bigint,
    out ev_id       bigint,
    out ev_time     timestamptz,
    out ev_txid     bigint,
    out ev_retry    int4,
    out ev_type     text,
    out ev_data     text,
    out ev_extra1   text,
    out ev_extra2   text,
    out ev_extra3   text,
    out ev_extra4   text)
returns setof record as $$
-- ----------------------------------------------------------------------
-- Function: pgq.get_batch_events(1)
--
--      Get all events in batch.
--
-- Parameters:
--      x_batch_id      - ID of active batch.
--
-- Returns:
--      List of events.
-- ----------------------------------------------------------------------
declare
    sql text;
begin
    sql := pgq.batch_event_sql(x_batch_id);
    for ev_id, ev_time, ev_txid, ev_retry, ev_type, ev_data,
        ev_extra1, ev_extra2, ev_extra3, ev_extra4
        in execute sql
    loop
        return next;
    end loop;
    return;
end;
$$ language plpgsql; -- no perms needed


