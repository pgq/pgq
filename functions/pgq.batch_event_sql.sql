create or replace function pgq.batch_event_sql(x_batch_id bigint)
returns text as $$
-- ----------------------------------------------------------------------
-- Function: pgq.batch_event_sql(1)
--      Creates SELECT statement that fetches events for this batch.
--
-- Parameters:
--      x_batch_id    - ID of a active batch.
--
-- Returns:
--      SQL statement.
-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------
-- Algorithm description:
--      Given 2 snapshots, sn1 and sn2 with sn1 having xmin1, xmax1
--      and sn2 having xmin2, xmax2 create expression that filters
--      right txid's from event table.
--
--      Simplest solution would be
--      > WHERE ev_txid >= xmin1 AND ev_txid <= xmax2
--      >   AND NOT txid_visible_in_snapshot(ev_txid, sn1)
--      >   AND txid_visible_in_snapshot(ev_txid, sn2)
--
--      The simple solution has a problem with long transactions (xmin1 very low).
--      All the batches that happen when the long tx is active will need
--      to scan all events in that range.  Here is 2 optimizations used:
--
--      1)  Use [xmax1..xmax2] for range scan.  That limits the range to
--      txids that actually happened between two snapshots.  For txids
--      in the range [xmin1..xmax1] look which ones were actually
--      committed between snapshots and search for them using exact
--      values using IN (..) list.
--
--      2) As most TX are short, there could be lot of them that were
--      just below xmax1, but were committed before xmax2.  So look
--      if there are ID's near xmax1 and lower the range to include
--      them, thus decresing size of IN (..) list.
-- ----------------------------------------------------------------------
declare
    rec             record;
    sql             text;
    tbl             text;
    arr             text;
    part            text;
    select_fields   text;
    retry_expr      text;
    batch           record;
begin
    select s.sub_last_tick, s.sub_next_tick, s.sub_id, s.sub_queue,
           txid_snapshot_xmax(last.tick_snapshot) as tx_start,
           txid_snapshot_xmax(cur.tick_snapshot) as tx_end,
           last.tick_snapshot as last_snapshot,
           cur.tick_snapshot as cur_snapshot
        into batch
        from pgq.subscription s, pgq.tick last, pgq.tick cur
        where s.sub_batch = x_batch_id
          and last.tick_queue = s.sub_queue
          and last.tick_id = s.sub_last_tick
          and cur.tick_queue = s.sub_queue
          and cur.tick_id = s.sub_next_tick;
    if not found then
        raise exception 'batch not found';
    end if;

    -- load older transactions
    arr := '';
    for rec in
        -- active tx-es in prev_snapshot that were committed in cur_snapshot
        select id1 from
            txid_snapshot_xip(batch.last_snapshot) id1 left join
            txid_snapshot_xip(batch.cur_snapshot) id2 on (id1 = id2)
        where id2 is null
        order by 1 desc
    loop
        -- try to avoid big IN expression, so try to include nearby
        -- tx'es into range
        if batch.tx_start - 100 <= rec.id1 then
            batch.tx_start := rec.id1;
        else
            if arr = '' then
                arr := rec.id1::text;
            else
                arr := arr || ',' || rec.id1::text;
            end if;
        end if;
    end loop;

    -- must match pgq.event_template
    select_fields := 'select ev_id, ev_time, ev_txid, ev_retry, ev_type,'
        || ' ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4';
    retry_expr :=  ' and (ev_owner is null or ev_owner = '
        || batch.sub_id::text || ')';

    -- now generate query that goes over all potential tables
    sql := '';
    for rec in
        select xtbl from pgq.batch_event_tables(x_batch_id) xtbl
    loop
        tbl := pgq.quote_fqname(rec.xtbl);
        -- this gets newer queries that definitely are not in prev_snapshot
        part := select_fields
            || ' from pgq.tick cur, pgq.tick last, ' || tbl || ' ev '
            || ' where cur.tick_id = ' || batch.sub_next_tick::text
            || ' and cur.tick_queue = ' || batch.sub_queue::text
            || ' and last.tick_id = ' || batch.sub_last_tick::text
            || ' and last.tick_queue = ' || batch.sub_queue::text
            || ' and ev.ev_txid >= ' || batch.tx_start::text
            || ' and ev.ev_txid <= ' || batch.tx_end::text
            || ' and txid_visible_in_snapshot(ev.ev_txid, cur.tick_snapshot)'
            || ' and not txid_visible_in_snapshot(ev.ev_txid, last.tick_snapshot)'
            || retry_expr;
        -- now include older tx-es, that were ongoing
        -- at the time of prev_snapshot
        if arr <> '' then
            part := part || ' union all '
                || select_fields || ' from ' || tbl || ' ev '
                || ' where ev.ev_txid in (' || arr || ')'
                || retry_expr;
        end if;
        if sql = '' then
            sql := part;
        else
            sql := sql || ' union all ' || part;
        end if;
    end loop;
    if sql = '' then
        raise exception 'could not construct sql for batch %', x_batch_id;
    end if;
    return sql || ' order by 1';
end;
$$ language plpgsql;  -- no perms needed

