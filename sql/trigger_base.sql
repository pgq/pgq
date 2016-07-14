\set VERBOSITY 'terse'
set client_min_messages = 'warning';
set bytea_output = 'hex';

create or replace function pgq.insert_event(queue_name text, ev_type text, ev_data text, ev_extra1 text, ev_extra2 text, ev_extra3 text, ev_extra4 text)
returns bigint as $$
begin
    raise warning 'insert_event(q=[%], t=[%], d=[%], 1=[%], 2=[%], 3=[%], 4=[%])',
        queue_name, ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4;
    return 1;
end;
$$ language plpgsql;

create table trigger_base (
    id serial primary key,
    txt text,
    val float
);

create trigger base_trig_0 after insert or update or delete on trigger_base
for each row execute procedure pgq.jsontriga('jsontriga');
create trigger base_trig_1 after insert or update or delete on trigger_base
for each row execute procedure pgq.logutriga('logutriga');
create trigger base_trig_2 after insert or update or delete on trigger_base
for each row execute procedure pgq.sqltriga('sqltriga');

insert into trigger_base (txt) values ('text1');
insert into trigger_base (val) values (1.5);
update trigger_base set txt='text2' where id=1;
delete from trigger_base where id=2;

-- test missing pkey
create table trigger_nopkey_jsontriga (dat text);
create table trigger_nopkey_logutriga (dat text);
create table trigger_nopkey_sqltriga (dat text);

create trigger nopkey after insert or update or delete on trigger_nopkey_jsontriga
for each row execute procedure pgq.jsontriga('jsontriga');
create trigger nopkey after insert or update or delete on trigger_nopkey_logutriga
for each row execute procedure pgq.logutriga('logutriga');
create trigger nopkey after insert or update or delete on trigger_nopkey_sqltriga
for each row execute procedure pgq.sqltriga('sqltriga');

insert into trigger_nopkey_jsontriga values ('foo');
insert into trigger_nopkey_logutriga values ('foo');
insert into trigger_nopkey_sqltriga values ('foo');
update trigger_nopkey_jsontriga set dat = 'bat';
update trigger_nopkey_logutriga set dat = 'bat';
update trigger_nopkey_sqltriga set dat = 'bat';
delete from trigger_nopkey_jsontriga;
delete from trigger_nopkey_logutriga;
delete from trigger_nopkey_sqltriga;

-- test invalid pk update
create table trigger_pkey_jsontriga (id int4 primary key);
create table trigger_pkey_logutriga (id int4 primary key);
create table trigger_pkey_sqltriga (id int4 primary key);
insert into trigger_pkey_jsontriga values (1);
insert into trigger_pkey_logutriga values (1);
insert into trigger_pkey_sqltriga values (1);
create trigger nopkey after insert or update or delete on trigger_pkey_jsontriga
for each row execute procedure pgq.jsontriga('jsontriga');
create trigger nopkey after insert or update or delete on trigger_pkey_logutriga
for each row execute procedure pgq.logutriga('logutriga');
create trigger nopkey after insert or update or delete on trigger_pkey_sqltriga
for each row execute procedure pgq.sqltriga('sqltriga');

update trigger_pkey_jsontriga set id = 6;
update trigger_pkey_logutriga set id = 6;
update trigger_pkey_sqltriga set id = 6;

-- restore
drop table trigger_base;
drop table trigger_nopkey_jsontriga;
drop table trigger_nopkey_logutriga;
drop table trigger_nopkey_sqltriga;
drop table trigger_pkey_jsontriga;
drop table trigger_pkey_logutriga;
drop table trigger_pkey_sqltriga;

\set ECHO none
\i functions/pgq.insert_event.sql

