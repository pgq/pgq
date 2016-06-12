drop function if exists pgq.get_queue_info();
drop function if exists pgq.get_queue_info(text);

create or replace function pgq.get_queue_info(
    out queue_name                  text,
    out queue_ntables               integer,
    out queue_cur_table             integer,
    out queue_rotation_period       interval,
    out queue_switch_time           timestamptz,
    out queue_external_ticker       boolean,
    out queue_ticker_paused         boolean,
    out queue_ticker_max_count      integer,
    out queue_ticker_max_lag        interval,
    out queue_ticker_idle_period    interval,
    out ticker_lag                  interval,
    out ev_per_sec                  float8,
    out ev_new                      bigint,
    out last_tick_id                bigint)
returns setof record as $$
-- ----------------------------------------------------------------------
-- Function: pgq.get_queue_info(0)
--
--      Get info about all queues.
--
-- Returns:
--      List of pgq.ret_queue_info records.
--     queue_name                  - queue name
--     queue_ntables               - number of tables in this queue
--     queue_cur_table             - ???
--     queue_rotation_period       - how often the event_N_M tables in this queue are rotated
--     queue_switch_time           - ??? when was this queue last rotated
--     queue_external_ticker       - ???
--     queue_ticker_paused         - ??? is ticker paused in this queue
--     queue_ticker_max_count      - max number of events before a tick is issued
--     queue_ticker_max_lag        - maks time without a tick
--     queue_ticker_idle_period    - how often the ticker should check this queue
--     ticker_lag                  - time from last tick
--     ev_per_sec                  - how many events per second this queue serves
--     ev_new                      - ???
--     last_tick_id                - last tick id for this queue
--
-- ----------------------------------------------------------------------
begin
    for queue_name, queue_ntables, queue_cur_table, queue_rotation_period,
        queue_switch_time, queue_external_ticker, queue_ticker_paused,
        queue_ticker_max_count, queue_ticker_max_lag, queue_ticker_idle_period,
        ticker_lag, ev_per_sec, ev_new, last_tick_id
    in select
        f.queue_name, f.queue_ntables, f.queue_cur_table, f.queue_rotation_period,
        f.queue_switch_time, f.queue_external_ticker, f.queue_ticker_paused,
        f.queue_ticker_max_count, f.queue_ticker_max_lag, f.queue_ticker_idle_period,
        f.ticker_lag, f.ev_per_sec, f.ev_new, f.last_tick_id
        from pgq.get_queue_info(null) f
    loop
        return next;
    end loop;
    return;
end;
$$ language plpgsql;

create or replace function pgq.get_queue_info(
    in i_queue_name                 text,
    out queue_name                  text,
    out queue_ntables               integer,
    out queue_cur_table             integer,
    out queue_rotation_period       interval,
    out queue_switch_time           timestamptz,
    out queue_external_ticker       boolean,
    out queue_ticker_paused         boolean,
    out queue_ticker_max_count      integer,
    out queue_ticker_max_lag        interval,
    out queue_ticker_idle_period    interval,
    out ticker_lag                  interval,
    out ev_per_sec                  float8,
    out ev_new                      bigint,
    out last_tick_id                bigint)
returns setof record as $$
-- ----------------------------------------------------------------------
-- Function: pgq.get_queue_info(1)
--
--      Get info about particular queue.
--
-- Returns:
--      One pgq.ret_queue_info record.
--      contente same as forpgq.get_queue_info() 
-- ----------------------------------------------------------------------
declare
    _ticker_lag interval;
    _top_tick_id bigint;
    _ht_tick_id bigint;
    _top_tick_time timestamptz;
    _top_tick_event_seq bigint;
    _ht_tick_time timestamptz;
    _ht_tick_event_seq bigint;
    _queue_id integer;
    _queue_event_seq text;
begin
    for queue_name, queue_ntables, queue_cur_table, queue_rotation_period,
        queue_switch_time, queue_external_ticker, queue_ticker_paused,
        queue_ticker_max_count, queue_ticker_max_lag, queue_ticker_idle_period,
        _queue_id, _queue_event_seq
    in select
        q.queue_name, q.queue_ntables, q.queue_cur_table,
        q.queue_rotation_period, q.queue_switch_time,
        q.queue_external_ticker, q.queue_ticker_paused,
        q.queue_ticker_max_count, q.queue_ticker_max_lag,
        q.queue_ticker_idle_period,
        q.queue_id, q.queue_event_seq
        from pgq.queue q
        where (i_queue_name is null or q.queue_name = i_queue_name)
        order by q.queue_name
    loop
        -- most recent tick
        select (current_timestamp - t.tick_time),
               tick_id, t.tick_time, t.tick_event_seq
            into ticker_lag, _top_tick_id, _top_tick_time, _top_tick_event_seq
            from pgq.tick t
            where t.tick_queue = _queue_id
            order by t.tick_queue desc, t.tick_id desc
            limit 1;
        -- slightly older tick
        select ht.tick_id, ht.tick_time, ht.tick_event_seq
            into _ht_tick_id, _ht_tick_time, _ht_tick_event_seq
            from pgq.tick ht
            where ht.tick_queue = _queue_id
             and ht.tick_id >= _top_tick_id - 20
            order by ht.tick_queue asc, ht.tick_id asc
            limit 1;
        if _ht_tick_time < _top_tick_time then
            ev_per_sec = (_top_tick_event_seq - _ht_tick_event_seq) / extract(epoch from (_top_tick_time - _ht_tick_time));
        else
            ev_per_sec = null;
        end if;
        ev_new = pgq.seq_getval(_queue_event_seq) - _top_tick_event_seq;
        last_tick_id = _top_tick_id;
        return next;
    end loop;
    return;
end;
$$ language plpgsql;

