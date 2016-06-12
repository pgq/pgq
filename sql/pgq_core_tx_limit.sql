\set VERBOSITY 'terse'
set client_min_messages = 'warning';

select pgq.create_queue('queue_tx_limit');

-- test limit
update pgq.queue set queue_per_tx_limit = 2 where queue_name = 'queue_tx_limit';
begin;
select pgq.insert_event('queue_tx_limit', 'test', 'event1');
select pgq.insert_event('queue_tx_limit', 'test', 'event2');
select pgq.insert_event('queue_tx_limit', 'test', 'event3');
end;

update pgq.queue set queue_per_tx_limit = 0 where queue_name = 'queue_tx_limit';
begin;
select pgq.insert_event('queue_tx_limit', 'test', 'event1');
end;

update pgq.queue set queue_per_tx_limit = null where queue_name = 'queue_tx_limit';
begin;
select pgq.insert_event('queue_tx_limit', 'test', 'event1');
select pgq.insert_event('queue_tx_limit', 'test', 'event2');
select pgq.insert_event('queue_tx_limit', 'test', 'event3');
end;

