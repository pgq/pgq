\set ECHO off
\set VERBOSITY 'terse'
set client_min_messages = 'warning';

-- drop public perms
\i structure/newgrants_pgq.sql

-- select proname, proacl from pg_proc p, pg_namespace n where n.nspname = 'pgq' and p.pronamespace = n.oid;

\set ECHO all

drop role if exists pgq_test_producer;
drop role if exists pgq_test_consumer;
drop role if exists pgq_test_admin;

create role pgq_test_consumer with login in role pgq_reader;
create role pgq_test_producer with login in role pgq_writer;
create role pgq_test_admin with login in role pgq_admin;


\c - pgq_test_admin

select * from pgq.create_queue('pqueue'); -- ok

\c - pgq_test_producer

select * from pgq.create_queue('pqueue'); -- fail

select * from pgq.insert_event('pqueue', 'test', 'data'); -- ok

select * from pgq.register_consumer('pqueue', 'prod'); -- fail

\c - pgq_test_consumer

select * from pgq.create_queue('pqueue'); -- fail
select * from pgq.insert_event('pqueue', 'test', 'data'); -- fail
select * from pgq.register_consumer('pqueue', 'cons'); -- ok
select * from pgq.next_batch('pqueue', 'cons'); -- ok

