create or replace function pgq.grant_perms(x_queue_name text)
returns integer as $$
-- ----------------------------------------------------------------------
-- Function: pgq.grant_perms(1)
--
--      Make event tables readable by public.
--
-- Parameters:
--      x_queue_name        - Name of the queue.
--
-- Returns:
--      nothing
-- ----------------------------------------------------------------------
declare
    q           record;
    i           integer;
    pos         integer;
    tbl_perms   text;
    seq_perms   text;
    dst_schema  text;
    dst_table   text;
    part_table  text;
begin
    select * from pgq.queue into q
        where queue_name = x_queue_name;
    if not found then
        raise exception 'Queue not found';
    end if;

    -- split data table name to components
    pos := position('.' in q.queue_data_pfx);
    if pos > 0 then
        dst_schema := substring(q.queue_data_pfx for pos - 1);
        dst_table := substring(q.queue_data_pfx from pos + 1);
    else
        dst_schema := 'public';
        dst_table := q.queue_data_pfx;
    end if;

    -- tick seq, normal users don't need to modify it
    execute 'grant select on ' || pgq.quote_fqname(q.queue_tick_seq) || ' to public';

    -- event seq
    execute 'grant select on ' || pgq.quote_fqname(q.queue_event_seq) || ' to public';
    execute 'grant usage on ' || pgq.quote_fqname(q.queue_event_seq) || ' to pgq_admin';

    -- set grants on parent table
    perform pgq._grant_perms_from('pgq', 'event_template', dst_schema, dst_table);

    -- set grants on real event tables
    for i in 0 .. q.queue_ntables - 1 loop
        part_table := dst_table  || '_' || i::text;
        perform pgq._grant_perms_from('pgq', 'event_template', dst_schema, part_table);
    end loop;

    return 1;
end;
$$ language plpgsql security definer;


create or replace function pgq._grant_perms_from(src_schema text, src_table text, dst_schema text, dst_table text)
returns integer as $$
-- ----------------------------------------------------------------------
-- Function: pgq.grant_perms_from(1)
--
--      Copy grants from one table to another.
--      Workaround for missing GRANTS option for CREATE TABLE LIKE.
-- ----------------------------------------------------------------------
declare
    fq_table text;
    sql text;
    g record;
    q_grantee text;
begin
    fq_table := quote_ident(dst_schema) || '.' || quote_ident(dst_table);

    for g in
        select grantor, grantee, privilege_type, is_grantable
            from information_schema.table_privileges
            where table_schema = src_schema
                and table_name = src_table
    loop
        if g.grantee = 'PUBLIC' then
            q_grantee = 'public';
        else
            q_grantee = quote_ident(g.grantee);
        end if;
        sql := 'grant ' || g.privilege_type || ' on ' || fq_table
            || ' to ' || q_grantee;
        if g.is_grantable = 'YES' then
            sql := sql || ' with grant option';
        end if;
        execute sql;
    end loop;

    return 1;
end;
$$ language plpgsql strict;

