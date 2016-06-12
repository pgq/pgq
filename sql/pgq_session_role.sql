\set VERBOSITY 'terse'
set client_min_messages = 'warning';

show session_replication_role;

select pgq.create_queue('role_test_enabled');
select pgq.create_queue('role_test_disabled');
update pgq.queue set queue_disable_insert=true where queue_name = 'role_test_disabled';

select pgq.insert_event('role_test_enabled', 'enabled', 'role:origin');
select pgq.insert_event('role_test_disabled', 'disabled', 'role:origin');

set session_replication_role = 'replica';
show session_replication_role;
select pgq.insert_event('role_test_enabled', 'enabled', 'role:replica');
select pgq.insert_event('role_test_disabled', 'disabled', 'role:replica');

set session_replication_role = 'local';
show session_replication_role;
select pgq.insert_event('role_test_enabled', 'enabled', 'role:local');
select pgq.insert_event('role_test_disabled', 'disabled', 'role:local');

set session_replication_role = 'origin';
show session_replication_role;
select pgq.insert_event('role_test_enabled', 'enabled', 'role:origin');
select pgq.insert_event('role_test_disabled', 'disabled', 'role:origin');

select pgq.drop_queue('role_test_enabled');
select pgq.drop_queue('role_test_disabled');

