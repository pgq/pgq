
create or replace function pgq.upgrade_schema()
returns int4 as $$
-- updates table structure if necessary
declare
    cnt int4 = 0;
begin

    -- pgq.subscription.sub_last_tick: NOT NULL -> NULL
    perform 1 from information_schema.columns
      where table_schema = 'pgq'
        and table_name = 'subscription'
        and column_name ='sub_last_tick'
        and is_nullable = 'NO';
    if found then
        alter table pgq.subscription
            alter column sub_last_tick
            drop not null;
        cnt := cnt + 1;
    end if;

    -- create roles
    perform 1 from pg_catalog.pg_roles where rolname = 'pgq_reader';
    if not found then
        create role pgq_reader;
        cnt := cnt + 1;
    end if;
    perform 1 from pg_catalog.pg_roles where rolname = 'pgq_writer';
    if not found then
        create role pgq_writer;
        cnt := cnt + 1;
    end if;
    perform 1 from pg_catalog.pg_roles where rolname = 'pgq_admin';
    if not found then
        create role pgq_admin in role pgq_reader, pgq_writer;
        cnt := cnt + 1;
    end if;

    return cnt;
end;
$$ language plpgsql;


