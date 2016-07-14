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

create table trigger_ignore (dat1 text primary key, col1 text, col2 text);

create trigger ignore_trig_0 after insert or update or delete on trigger_ignore
for each row execute procedure pgq.jsontriga('jsontriga', 'ignore=col2');
create trigger ignore_trig_1 after insert or update or delete on trigger_ignore
for each row execute procedure pgq.logutriga('logutriga', 'ignore=col2');
create trigger ignore_trig_2 after insert or update or delete on trigger_ignore
for each row execute procedure pgq.sqltriga('sqltriga', 'ignore=col2');

-- test insert
insert into trigger_ignore values ('a', 'col1', 'col2');

-- test update of non-ignored column
update trigger_ignore set col1 = 'col1x' where dat1 = 'a';
update trigger_ignore set col1 = 'col1y', col2='col2y' where dat1 = 'a';

-- test update of ignored column
update trigger_ignore set col2 = 'col2z' where dat1 = 'a';

-- test null update
update trigger_ignore set col2 = col2 where dat1 = 'a';

-- restore
drop table trigger_ignore;
\set ECHO none
\i functions/pgq.insert_event.sql

