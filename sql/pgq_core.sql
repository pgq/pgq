\set VERBOSITY 'terse'
set client_min_messages = 'warning';

select * from pgq.maint_tables_to_vacuum();
select * from pgq.maint_retry_events();

select pgq.create_queue('tmpqueue');
select pgq.register_consumer('tmpqueue', 'consumer');
select pgq.unregister_consumer('tmpqueue', 'consumer');
select pgq.drop_queue('tmpqueue');

select pgq.create_queue('myqueue');
select pgq.register_consumer('myqueue', 'consumer');
update pgq.queue set queue_ticker_max_lag = '0', queue_ticker_idle_period = '0';
select pgq.next_batch('myqueue', 'consumer');
select pgq.next_batch('myqueue', 'consumer');
select pgq.ticker();
select pgq.next_batch('myqueue', 'consumer');
select pgq.next_batch('myqueue', 'consumer');

select queue_name, consumer_name, prev_tick_id, tick_id, lag < '30 seconds' as lag_exists from pgq.get_batch_info(1);

select queue_name, queue_ntables, queue_cur_table, queue_rotation_period,
       queue_switch_time <= now() as switch_time_exists,
       queue_external_ticker, queue_ticker_max_count, queue_ticker_max_lag,
       queue_ticker_idle_period, ticker_lag < '2 hours' as ticker_lag_exists,
       last_tick_id
  from pgq.get_queue_info() order by 1;
select queue_name, consumer_name, lag < '30 seconds' as lag_exists,
       last_seen < '30 seconds' as last_seen_exists,
       last_tick, current_batch, next_tick
  from pgq.get_consumer_info() order by 1, 2;

select pgq.finish_batch(1);
select pgq.finish_batch(1);

select pgq.ticker();
select pgq.next_batch('myqueue', 'consumer');
select * from pgq.batch_event_tables(2);
select * from pgq.get_batch_events(2);
select pgq.finish_batch(2);

select pgq.insert_event('myqueue', 'r1', 'data');
select pgq.insert_event('myqueue', 'r2', 'data', 'extra1', 'extra2', 'extra3', 'extra4');
select pgq.insert_event('myqueue', 'r3', 'data');
select pgq.current_event_table('myqueue');
select pgq.ticker();

select * from pgq.next_batch_custom('myqueue', 'consumer', '1 hour', null, null);
select * from pgq.next_batch_custom('myqueue', 'consumer', null, 10000, null);
select * from pgq.next_batch_custom('myqueue', 'consumer', null, null, '10 minutes');
select pgq.next_batch('myqueue', 'consumer');
select ev_id,ev_retry,ev_type,ev_data,ev_extra1,ev_extra2,ev_extra3,ev_extra4 from pgq.get_batch_events(3);

begin;
select ev_id,ev_retry,ev_type,ev_data,ev_extra1,ev_extra2,ev_extra3,ev_extra4
    from pgq.get_batch_cursor(3, 'acurs', 10);
close acurs;
select ev_id,ev_retry,ev_type,ev_data,ev_extra1,ev_extra2,ev_extra3,ev_extra4
    from pgq.get_batch_cursor(3, 'acurs', 2);
close acurs;
select ev_id,ev_retry,ev_type,ev_data,ev_extra1,ev_extra2,ev_extra3,ev_extra4
    from pgq.get_batch_cursor(3, 'acurs', 2, 'ev_id = 1');
close acurs;
end;

select pgq.event_retry(3, 2, 0);
select pgq.batch_retry(3, 0);
select pgq.finish_batch(3);

select pgq.event_retry_raw('myqueue', 'consumer', now(), 666, now(), 0,
        'rawtest', 'data', null, null, null, null);

select pgq.ticker();

-- test maint
update pgq.queue set queue_rotation_period = '0 seconds';
select queue_name, pgq.maint_rotate_tables_step1(queue_name) from pgq.queue;
select pgq.maint_rotate_tables_step2();

-- test extra
select nextval(queue_event_seq) from pgq.queue where queue_name = 'myqueue';
select pgq.force_tick('myqueue');
select nextval(queue_event_seq) from pgq.queue where queue_name = 'myqueue';

create sequence tmptest_seq;

select pgq.seq_getval('tmptest_seq');
select pgq.seq_setval('tmptest_seq', 10);
select pgq.seq_setval('tmptest_seq', 5);
select pgq.seq_setval('tmptest_seq', 15);
select pgq.seq_getval('tmptest_seq');

-- test disabled
select pgq.insert_event('myqueue', 'test', 'event');
update pgq.queue set queue_disable_insert = true where queue_name = 'myqueue';
select pgq.insert_event('myqueue', 'test', 'event');
update pgq.queue set queue_disable_insert = false where queue_name = 'myqueue';
select pgq.insert_event('myqueue', 'test', 'event');

-- test limit
update pgq.queue set queue_per_tx_limit = 2 where queue_name = 'myqueue';
begin;
select pgq.insert_event('myqueue', 'test', 'event1');
select pgq.insert_event('myqueue', 'test', 'event2');
select pgq.insert_event('myqueue', 'test', 'event3');
end;

update pgq.queue set queue_per_tx_limit = 0 where queue_name = 'myqueue';
begin;
select pgq.insert_event('myqueue', 'test', 'event1');
select pgq.insert_event('myqueue', 'test', 'event2');
select pgq.insert_event('myqueue', 'test', 'event3');
end;

update pgq.queue set queue_per_tx_limit = null where queue_name = 'myqueue';
begin;
select pgq.insert_event('myqueue', 'test', 'event1');
select pgq.insert_event('myqueue', 'test', 'event2');
select pgq.insert_event('myqueue', 'test', 'event3');
end;

select * from pgq.maint_operations();
alter table pgq.queue add column queue_extra_maint text[];
select * from pgq.maint_operations();
update pgq.queue set queue_extra_maint = array['baz', 'foo.bar'];
select * from pgq.maint_operations();

