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

create table trigger_when (nr int4 primary key, col1 text, col2 text);

create trigger when_trig_0 after insert or update or delete on trigger_when
for each row execute procedure pgq.jsontriga('jsontriga', 'when=col2=''foo''');
create trigger when_trig_1 after insert or update or delete on trigger_when
for each row execute procedure pgq.logutriga('logutriga', 'when=col2=''foo''');
create trigger when_trig_2 after insert or update or delete on trigger_when
for each row execute procedure pgq.sqltriga('sqltriga', 'when=col2=''foo''');

-- test insert with when
insert into trigger_when values (1, 'col1', 'col2');
insert into trigger_when values (2, 'col1', 'foo');

-- restore
drop table trigger_when;
\set ECHO none
\i functions/pgq.insert_event.sql

