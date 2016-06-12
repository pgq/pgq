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

create table trigger_extra_args (nr int4 primary key, col1 text, col2 text);

create trigger extra_trig_1 after insert or update or delete on trigger_extra_args
for each row execute procedure pgq.logutriga('logutriga',
    'ev_extra1=(nr+3)::text', 'ev_extra2=col1||col2',
    'ev_extra3=$$333$$', 'ev_extra4=$$444$$', 'ev_type=$$badidea$$');
create trigger extra_trig_2 after insert or update or delete on trigger_extra_args
for each row execute procedure pgq.sqltriga('sqltriga',
    'ev_extra1=(nr+3)::text', 'ev_extra2=col1||col2',
    'ev_extra3=$$333$$', 'ev_extra4=$$444$$', 'ev_type=$$badidea$$');

-- test insert
insert into trigger_extra_args values (1, 'col1', 'col2');

-- test update
update trigger_extra_args set col1 = 'col1x', col2='col2x' where nr=1;

-- test delete
delete from trigger_extra_args where nr=1;

-- restore
drop table trigger_extra_args;
\set ECHO none
\i functions/pgq.insert_event.sql

