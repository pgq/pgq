\set VERBOSITY 'terse'
set client_min_messages = 'warning';
set DateStyle = 'ISO, YMD';
set timezone = 'UTC';
set bytea_output = 'hex';

\set ECHO none

create or replace function pgq.insert_event(queue_name text, ev_type text, ev_data text, ev_extra1 text, ev_extra2 text, ev_extra3 text, ev_extra4 text)
returns bigint as $$
begin
    raise warning 'insert_event(q=[%], t=[%], d=[%])', queue_name, ev_type, ev_data;
    return 1;
end;
$$ language plpgsql;

create function typetest(typ text, val text) returns void as $$
declare
    rec text;
begin
    execute 'create table ttest (nr int4, val '||typ||' default '||quote_nullable(val)
        ||', arr '||typ||'[] default array['||quote_nullable(val)||','||quote_nullable(val)
        ||']::'||typ||'[])';

    execute 'create trigger types_trig_0 after insert or update or delete on ttest'
        || ' for each row execute procedure pgq.jsontriga(''jsontriga'');';

    execute 'create trigger types_trig_1 after insert or update or delete on ttest'
        || ' for each row execute procedure pgq.logutriga(''logutriga'')';

    execute 'create trigger types_trig_2 after insert or update or delete on ttest'
        || ' for each row execute procedure pgq.sqltriga(''sqltriga'');';

    execute 'insert into ttest (nr) values (1)';

    /*
    perform 1 from pg_catalog.pg_proc p, pg_catalog.pg_namespace n
        where n.nspname = 'pg_catalog' and p.proname = 'to_json'
            and p.pronamespace = n.oid;
    if found then
        for rec in
            execute 'select row_to_json(t.*) from ttest t where nr=1'
        loop
            raise warning 'type: %  row_to_json: %', typ, rec;
        end loop;
    end if;
    */

    execute 'drop table ttest';
end;
$$ language plpgsql;

\set ECHO all

select typetest('text', null);
select typetest('text', $$'"quoted\string$%,@"'$$);
select typetest('bytea', $$\x00FF01$$);
select typetest('bool', 'true');
select typetest('bool', 'false');
select typetest('timestamptz', '2009-09-19 11:59:48.599');
select typetest('timestamp', '2009-09-19 11:59:48.599');
select typetest('date', '2009-09-19');
select typetest('time', '11:59:48.599');
select typetest('interval', '2 minutes');
select typetest('int2', '10010');
select typetest('int4', '100100100');
select typetest('int8', '100200300400500600');

select typetest('int8', '9223372036854775807');
select typetest('int8', '-9223372036854775808');

select typetest('oid', '100200300');
select typetest('xid', '100200300');
select typetest('tid', '100200300');
select typetest('real', '100100.666');
select typetest('float', '100100.6005005665');
select typetest('numeric(40,15)', '100100.600500566501811');
select typetest('box', '((1.1, 2.1), (5.6, 5.7))');
select typetest('uuid', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11');
select typetest('json', '{"a": [false, null, true]}');
select typetest('json', '[1,2,3]');

-- restore
drop function typetest(text,text);
\set ECHO none
\i functions/pgq.insert_event.sql

