
\set VERBOSITY 'terse'
set client_min_messages = 'warning';
set datestyle = 'iso, ymd';

create or replace function pgq.insert_event(queue_name text, ev_type text, ev_data text, ev_extra1 text, ev_extra2 text, ev_extra3 text, ev_extra4 text)
returns bigint as $$
begin
    raise warning 'insert_event(q=[%], t=[%], d=[%], 1=[%], 2=[%], 3=[%], 4=[%])',
        queue_name, ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4;
    return 1;
end;
$$ language plpgsql;

create table trigger_backup (nr int4 primary key, col1 text, stamp date);

create trigger backup_trig_0 after insert or update or delete on trigger_backup
for each row execute procedure pgq.jsontriga('jsontriga', 'backup');

create trigger backup_trig_1 after insert or update or delete on trigger_backup
for each row execute procedure pgq.logutriga('logutriga', 'backup');

-- sqltriga/pl cannot do urlenc
--create trigger backup_trig_2 after insert or update or delete on trigger_backup
--for each row execute procedure pgq.sqltriga('sqltriga', 'backup');

-- test insert
insert into trigger_backup (nr, col1, stamp) values (1, 'text', '1999-02-03');
update trigger_backup set col1 = 'col1x' where nr=1;
delete from trigger_backup where nr=1;

-- restore
drop table trigger_backup;
\set ECHO none
\i functions/pgq.insert_event.sql

