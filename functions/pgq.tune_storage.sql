create or replace function pgq.tune_storage(i_queue_name text)
returns integer as $$
-- ----------------------------------------------------------------------
-- Function: pgq.tune_storage(1)
--
--      Tunes storage settings for queue data tables
-- ----------------------------------------------------------------------
declare
    tbl  text;
    tbloid oid;
    q record;
    i int4;
    sql text;
    pgver int4;
begin
    pgver := current_setting('server_version_num');

    select * into q
      from pgq.queue where queue_name = i_queue_name;
    if not found then
        return 0;
    end if;

    for i in 0 .. (q.queue_ntables - 1) loop
        tbl := q.queue_data_pfx || '_' || i::text;

        -- set fillfactor
        sql := 'alter table ' || tbl || ' set (fillfactor = 100';

        -- autovacuum for 8.4+
        if pgver >= 80400 then
            sql := sql || ', autovacuum_enabled=off, toast.autovacuum_enabled =off';
        end if;
        sql := sql || ')';
        execute sql;

        -- autovacuum for 8.3
        if pgver < 80400 then
            tbloid := tbl::regclass::oid;
            delete from pg_catalog.pg_autovacuum where vacrelid = tbloid;
            insert into pg_catalog.pg_autovacuum values (tbloid, false, -1,-1,-1,-1,-1,-1,-1,-1);
        end if;
    end loop;

    return 1;
end;
$$ language plpgsql strict;

