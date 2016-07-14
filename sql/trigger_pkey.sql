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

create table trigger_pkey (nr int4, col1 text, col2 text);

create trigger pkey_trig_0 after insert or update or delete on trigger_pkey
for each row execute procedure pgq.jsontriga('jsontriga', 'pkey=nr,col1');
create trigger pkey_trig_1 after insert or update or delete on trigger_pkey
for each row execute procedure pgq.logutriga('logutriga', 'pkey=nr,col1');
create trigger pkey_trig_2 after insert or update or delete on trigger_pkey
for each row execute procedure pgq.sqltriga('sqltriga', 'pkey=nr,col1');

insert into trigger_pkey values (1, 'col1', 'col2');
update trigger_pkey set col2='col2x' where nr=1;
delete from trigger_pkey where nr=1;

-- restore
drop table trigger_pkey;
\set ECHO none
\i functions/pgq.insert_event.sql

