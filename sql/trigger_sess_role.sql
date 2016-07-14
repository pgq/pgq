\set VERBOSITY 'terse'
set client_min_messages = 'warning';

create or replace function pgq.insert_event(queue_name text, ev_type text, ev_data text, ev_extra1 text, ev_extra2 text, ev_extra3 text, ev_extra4 text)
returns bigint as $$
declare
    ev_id int8;
begin
    raise warning 'calling insert_event_raw';
    ev_id := pgq.insert_event_raw(queue_name, null, now(), null, null,
        ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4);
    raise warning 'insert_event(q=[%], t=[%], d=[%], 1=[%], 2=[%], 3=[%], 4=[%]) = %',
        queue_name, ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4, ev_id;
    return ev_id;
end;
$$ language plpgsql;

select pgq.create_queue('jsontriga_role');
select pgq.create_queue('logutriga_role');
select pgq.create_queue('sqltriga_role');
update pgq.queue set queue_disable_insert = true where queue_name = 'jsontriga_role';
update pgq.queue set queue_disable_insert = true where queue_name = 'logutriga_role';
update pgq.queue set queue_disable_insert = true where queue_name = 'sqltriga_role';


-- create tables
create table jsontriga_role (dat1 text primary key);
create table logutriga_role (dat1 text primary key);
create table sqltriga_role (dat1 text primary key);
create trigger trig after insert or update or delete on jsontriga_role
for each row execute procedure pgq.jsontriga('jsontriga_role');
create trigger trig after insert or update or delete on logutriga_role
for each row execute procedure pgq.logutriga('logutriga_role');
create trigger trig after insert or update or delete on sqltriga_role
for each row execute procedure pgq.sqltriga('sqltriga_role');

-- origin: expect insert_event error
show session_replication_role;
insert into jsontriga_role values ('a');
insert into logutriga_role values ('a');
insert into sqltriga_role values ('a');

-- local: silence, trigger does not call insert_event
set session_replication_role = 'local';
show session_replication_role;
insert into jsontriga_role values ('b');
insert into logutriga_role values ('b');
insert into sqltriga_role values ('b');

-- replica: silence, trigger does not call insert_event
set session_replication_role = 'replica';
show session_replication_role;
insert into jsontriga_role values ('c');
insert into logutriga_role values ('c');
insert into sqltriga_role values ('c');

select * from jsontriga_role;
select * from logutriga_role;
select * from sqltriga_role;

-- restore
set session_replication_role = 'origin';
drop table jsontriga_role;
drop table logutriga_role;
drop table sqltriga_role;
select pgq.drop_queue('jsontriga_role');
select pgq.drop_queue('logutriga_role');
select pgq.drop_queue('sqltriga_role');
\set ECHO none
\i functions/pgq.insert_event.sql

