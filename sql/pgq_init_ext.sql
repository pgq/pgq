
\set ECHO none
\set VERBOSITY 'terse'
set client_min_messages = 'warning';
-- just create to extension (used to be "from unpackaged" test)
create extension pgq;
select pgq.create_queue('testqueue1');
\set ECHO all

select array_length(extconfig, 1) from pg_catalog.pg_extension where extname = 'pgq';

select pgq.create_queue('testqueue2');
--drop extension pgq; -- will fail
select pgq.drop_queue('testqueue2');
select pgq.drop_queue('testqueue1');

-- drop extension
drop extension pgq;

-- create clean schema
create extension pgq;

select array_length(extconfig, 1) from pg_catalog.pg_extension where extname = 'pgq';

