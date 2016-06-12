\set VERBOSITY 'terse'
set client_min_messages = 'warning';

select pgq.create_queue('queue_disabled');

-- test disabled
select pgq.insert_event('queue_disabled', 'test', 'event');
update pgq.queue set queue_disable_insert = true where queue_name = 'queue_disabled';
select pgq.insert_event('queue_disabled', 'test', 'event');
update pgq.queue set queue_disable_insert = false where queue_name = 'queue_disabled';
select pgq.insert_event('queue_disabled', 'test', 'event');

select pgq.drop_queue('queue_disabled');

