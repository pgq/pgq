create or replace function pgq.logutriga() returns trigger as $$
-- ----------------------------------------------------------------------
-- Function: pgq.logutriga()
--
--      Trigger function that puts row data in urlencoded form into queue.
--
-- Purpose:
--	Used as producer for several PgQ standard consumers (cube_dispatcher, 
--      queue_mover, table_dispatcher).  Basically for cases where the
--      consumer wants to parse the event and look at the actual column values.
--
-- Trigger parameters:
--      arg1 - queue name
--      argX - any number of optional arg, in any order
--
-- Optional arguments:
--      SKIP                - The actual operation should be skipped (BEFORE trigger)
--      ignore=col1[,col2]  - don't look at the specified arguments
--      pkey=col1[,col2]    - Set pkey fields for the table, autodetection will be skipped
--      backup              - Put urlencoded contents of old row to ev_extra2
--      colname=EXPR        - Override field value with SQL expression.  Can reference table
--                            columns.  colname can be: ev_type, ev_data, ev_extra1 .. ev_extra4
--      when=EXPR           - If EXPR returns false, don't insert event.
--
-- Queue event fields:
--      ev_type      - I/U/D ':' pkey_column_list
--      ev_data      - column values urlencoded
--      ev_extra1    - table name
--      ev_extra2    - optional urlencoded backup
--
-- Regular listen trigger example:
-- >   CREATE TRIGGER triga_nimi AFTER INSERT OR UPDATE ON customer
-- >   FOR EACH ROW EXECUTE PROCEDURE pgq.logutriga('qname');
--
-- Redirect trigger example:
-- >   CREATE TRIGGER triga_nimi BEFORE INSERT OR UPDATE ON customer
-- >   FOR EACH ROW EXECUTE PROCEDURE pgq.logutriga('qname', 'SKIP');
-- ----------------------------------------------------------------------
declare
    qname text;
    ev_type text;
    ev_data text;
    ev_extra1 text;
    ev_extra2 text;
    ev_extra3 text;
    ev_extra4 text;
    do_skip boolean := false;
    do_backup boolean := false;
    do_insert boolean := true;
    do_deny boolean := false;
    extra_ignore_list text[];
    full_ignore_list text[];
    ignore_list text[] := '{}';
    pkey_list text[];
    pkey_str text;
    field_sql_sfx text;
    field_sql text[] := '{}';
    data_sql text;
    ignore_col_changes int4 := 0;
begin
    if TG_NARGS < 1 then
        raise exception 'Trigger needs queue name';
    end if;
    qname := TG_ARGV[0];

    -- standard output
    ev_extra1 := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;

    -- prepare to handle magic fields
    field_sql_sfx := ')::text as val from (select $1.*) r';
    extra_ignore_list := array['_pgq_ev_type', '_pgq_ev_extra1', '_pgq_ev_extra2',
                               '_pgq_ev_extra3', '_pgq_ev_extra4']::text[];

    -- parse trigger args
    declare
        got boolean;
        argpair text[];
        i integer;
    begin
        for i in 1 .. TG_NARGS-1 loop
            if TG_ARGV[i] in ('skip', 'SKIP') then
                do_skip := true;
            elsif TG_ARGV[i] = 'backup' then
                do_backup := true;
            elsif TG_ARGV[i] = 'deny' then
                do_deny := true;
            else
                got := false;
                for argpair in select regexp_matches(TG_ARGV[i], '^([^=]+)=(.*)') loop
                    got := true;
                    if argpair[1] = 'pkey' then
                        pkey_str := argpair[2];
                        pkey_list := string_to_array(pkey_str, ',');
                    elsif argpair[1] = 'ignore' then
                        ignore_list := string_to_array(argpair[2], ',');
                    elsif argpair[1] ~ '^ev_(type|extra[1-4])$' then
                        field_sql := array_append(field_sql, 'select ' || quote_literal(argpair[1])
                                                  || '::text as key, (' || argpair[2] || field_sql_sfx);
                    elsif argpair[1] = 'when' then
                        field_sql := array_append(field_sql, 'select ' || quote_literal(argpair[1])
                                                  || '::text as key, (case when (' || argpair[2]
                                                  || ')::boolean then ''proceed'' else null end' || field_sql_sfx);
                    else
                        got := false;
                    end if;
                end loop;
                if not got then
                    raise exception 'bad argument: %', TG_ARGV[i];
                end if;
            end if;
        end loop;
    end;

    full_ignore_list := ignore_list || extra_ignore_list;

    if pkey_str is null then
        select array_agg(pk.attname)
            from (select k.attname from pg_index i, pg_attribute k
                    where i.indrelid = TG_RELID
                        and k.attrelid = i.indexrelid and i.indisprimary
                        and k.attnum > 0 and not k.attisdropped
                    order by k.attnum) pk
            into pkey_list;
        if pkey_list is null then
            pkey_list := '{}';
            pkey_str := '';
        else
            pkey_str := array_to_string(pkey_list, ',');
        end if;
    end if;
    if pkey_str = '' and TG_OP in ('UPDATE', 'DELETE') then
        raise exception 'Update/Delete on table without pkey';
    end if;

    if TG_OP = 'INSERT' then
        ev_type := 'I:' || pkey_str;
    elsif TG_OP = 'UPDATE' then
        ev_type := 'U:' || pkey_str;
    elsif TG_OP = 'DELETE' then
        ev_type := 'D:' || pkey_str;
    elsif TG_OP = 'TRUNCATE' then
        ev_type := 'R';
    else
        raise exception 'TG_OP not supported: %', TG_OP;
    end if;

    if current_setting('session_replication_role') = 'local' then
        if TG_WHEN = 'AFTER' or TG_OP = 'TRUNCATE' then
            return null;
        elsif TG_OP = 'DELETE' then
            return OLD;
        else
            return NEW;
        end if;
    elsif do_deny then
        raise exception 'Table ''%.%'' to queue ''%'': change not allowed (%)',
                    TG_TABLE_SCHEMA, TG_TABLE_NAME, qname, TG_OP;
    elsif TG_OP = 'TRUNCATE' then
        perform pgq.insert_event(qname, ev_type, '', ev_extra1, ev_extra2, ev_extra3, ev_extra4);
        return null;
    end if;

    -- process table columns
    declare
        attr record;
        pkey_sql_buf text[];
        qcol text;
        data_sql_buf text[];
        ignore_sql text;
        ignore_sql_buf text[];
        pkey_change_sql text;
        pkey_col_changes int4 := 0;
        valexp text;
    begin
        for attr in
            select k.attnum, k.attname, k.atttypid
                from pg_attribute k
                where k.attrelid = TG_RELID and k.attnum > 0 and not k.attisdropped
                order by k.attnum
        loop
            qcol := quote_ident(attr.attname);
            if attr.attname = any (ignore_list) then
                ignore_sql_buf := array_append(ignore_sql_buf,
                    'select case when rold.' || qcol || ' is null and rnew.' || qcol || ' is null then false'
                        || ' when rold.' || qcol || ' is null or rnew.' || qcol || ' is null then true'
                        || ' else rold.' || qcol || ' <> rnew.' || qcol
                        || ' end as is_changed '
                        || 'from (select $1.*) rold, (select $2.*) rnew');
                continue;
            elsif attr.attname = any (extra_ignore_list) then
                field_sql := array_prepend('select ' || quote_literal(substring(attr.attname from 6))
                                           || '::text as key, (r.' || qcol || field_sql_sfx, field_sql);
                continue;
            end if;

            if attr.atttypid = 'boolean'::regtype::oid then
                valexp := 'case r.' || qcol || ' when true then ''t'' else ''f'' end';
            else
                valexp := 'r.' || qcol || '::text';
            end if;

            if attr.attname = any (pkey_list) then
                pkey_sql_buf := array_append(pkey_sql_buf,
                        'select case when rold.' || qcol || ' is null and rnew.' || qcol || ' is null then false'
                        || ' when rold.' || qcol || ' is null or rnew.' || qcol || ' is null then true'
                        || ' else rold.' || qcol || ' <> rnew.' || qcol
                        || ' end as is_changed '
                        || 'from (select $1.*) rold, (select $2.*) rnew');
            end if;

            data_sql_buf := array_append(data_sql_buf,
                    'select pgq._urlencode(' || quote_literal(attr.attname)
                    || ') || coalesce(''='' || pgq._urlencode(' || valexp
                    || '), '''') as upair from (select $1.*) r');
        end loop;

        -- SQL to see if pkey columns have changed
        if TG_OP = 'UPDATE' then
            pkey_change_sql := 'select count(1) from (' || array_to_string(pkey_sql_buf, ' union all ')
                            || ') cols where cols.is_changed';
            execute pkey_change_sql using OLD, NEW into pkey_col_changes;
            if pkey_col_changes > 0 then
                raise exception 'primary key update not allowed';
            end if;
        end if;

        -- SQL to see if ignored columns have changed
        if TG_OP = 'UPDATE' and array_length(ignore_list, 1) is not null then
            ignore_sql := 'select count(1) from (' || array_to_string(ignore_sql_buf, ' union all ')
                || ') cols where cols.is_changed';
            execute ignore_sql using OLD, NEW into ignore_col_changes;
        end if;

        -- SQL to load data
        data_sql := 'select array_to_string(array_agg(cols.upair), ''&'') from ('
                 || array_to_string(data_sql_buf, ' union all ') || ') cols';
    end;

    -- render data
    declare
        old_data text;
    begin
        if TG_OP = 'INSERT' then
            execute data_sql using NEW into ev_data;
        elsif TG_OP = 'UPDATE' then

            -- render NEW
            execute data_sql using NEW into ev_data;

            -- render OLD when needed
            if do_backup or array_length(ignore_list, 1) is not null then
                execute data_sql using OLD into old_data;
            end if;

            -- only change was to ignored columns?
            if old_data = ev_data and ignore_col_changes > 0 then
                do_insert := false;
            end if;

            -- is backup needed?
            if do_backup then
                ev_extra2 := old_data;
            end if;
        elsif TG_OP = 'DELETE' then
            execute data_sql using OLD into ev_data;
        end if;
    end;

    -- apply magic args and columns
    declare
        col text;
        val text;
        rmain record;
        sql text;
    begin
        if do_insert and array_length(field_sql, 1) is not null then
            if TG_OP = 'DELETE' then
                rmain := OLD;
            else
                rmain := NEW;
            end if;

            sql := array_to_string(field_sql, ' union all ');
            for col, val in
                execute sql using rmain
            loop
                if col = 'ev_type' then
                    ev_type := val;
                elsif col = 'ev_extra1' then
                    ev_extra1 := val;
                elsif col = 'ev_extra2' then
                    ev_extra2 := val;
                elsif col = 'ev_extra3' then
                    ev_extra3 := val;
                elsif col = 'ev_extra4' then
                    ev_extra4 := val;
                elsif col = 'when' then
                    if val is null then
                        do_insert := false;
                    end if;
                end if;
            end loop;
        end if;
    end;

    -- insert final values
    if do_insert then
        perform pgq.insert_event(qname, ev_type, ev_data, ev_extra1, ev_extra2, ev_extra3, ev_extra4);
    end if;

    if do_skip or TG_WHEN = 'AFTER' or TG_OP = 'TRUNCATE' then
        return null;
    elsif TG_OP = 'DELETE' then
        return OLD;
    else
        return NEW;
    end if;
end;
$$ language plpgsql;

create or replace function pgq._urlencode(val text)
returns text as $$
    select replace(string_agg(pair[1] || regexp_replace(encode(convert_to(pair[2], 'utf8'), 'hex'), '..', E'%\\&', 'g'), ''), '%20', '+')
        from regexp_matches($1, '([-_.a-zA-Z0-9]*)([^-_.a-zA-Z0-9]*)', 'g') pair
$$ language sql strict immutable;

