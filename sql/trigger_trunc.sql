\set VERBOSITY 'terse'
set client_min_messages = 'warning';

create or replace function pgq.insert_event(queue_name text, ev_type text, ev_data text, ev_extra1 text, ev_extra2 text, ev_extra3 text, ev_extra4 text)
returns bigint as $$
begin
    raise warning 'insert_event(q=[%], t=[%], d=[%], 1=[%], 2=[%], 3=[%], 4=[%])',
        queue_name, ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4;
    return 1;
end;
$$ language plpgsql;

create table jsontriga_trunc (dat1 text primary key);
create table logutriga_trunc (dat1 text primary key);
create table sqltriga_trunc (dat1 text primary key);

-- test successful truncate

create trigger trunc1_trig after truncate on jsontriga_trunc
for each statement execute procedure pgq.jsontriga('jsontriga');
create trigger trunc1_trig after truncate on logutriga_trunc
for each statement execute procedure pgq.logutriga('logutriga');
create trigger trunc1_trig after truncate on sqltriga_trunc
for each statement execute procedure pgq.sqltriga('sqltriga');

truncate jsontriga_trunc;
truncate logutriga_trunc;
truncate sqltriga_trunc;

-- test deny

create table jsontriga_trunc2 (dat1 text primary key);
create table logutriga_trunc2 (dat1 text primary key);
create table sqltriga_trunc2 (dat1 text primary key);

create trigger trunc_trig after truncate on jsontriga_trunc2
for each statement execute procedure pgq.jsontriga('jsontriga_trunc2', 'deny');
create trigger trunc_trig after truncate on logutriga_trunc2
for each statement execute procedure pgq.sqltriga('logutriga_trunc2', 'deny');
create trigger trunc_trig after truncate on sqltriga_trunc2
for each statement execute procedure pgq.sqltriga('sqltriga_trunc2', 'deny');

truncate jsontriga_trunc2;
truncate logutriga_trunc2;
truncate sqltriga_trunc2;

-- restore
drop table jsontriga_trunc;
drop table logutriga_trunc;
drop table sqltriga_trunc;
drop table jsontriga_trunc2;
drop table logutriga_trunc2;
drop table sqltriga_trunc2;
\set ECHO none
\i functions/pgq.insert_event.sql

