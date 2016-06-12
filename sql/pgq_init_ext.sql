
-- create noext schema
\set ECHO none
\set VERBOSITY 'terse'
set client_min_messages = 'warning';
\i structure/install.sql
select pgq.create_queue('testqueue1');
\set ECHO all
-- convert to extension
create extension pgq from 'unpackaged';
select array_length(extconfig, 1) from pg_catalog.pg_extension where extname = 'pgq';

select pgq.create_queue('testqueue2');
--drop extension pgq; -- will fail
select pgq.drop_queue('testqueue2');
select pgq.drop_queue('testqueue1');

-- drop schema failure
drop extension pgq;

-- create clean schema
create extension pgq;

select array_length(extconfig, 1) from pg_catalog.pg_extension where extname = 'pgq';

