create or replace function pgq.version()
returns text as $$
-- ----------------------------------------------------------------------
-- Function: pgq.version(0)
--
--      Returns version string for pgq.  ATM it is based on SkyTools
--      version and only bumped when database code changes.
-- ----------------------------------------------------------------------
begin
    return '3.2.6';
end;
$$ language plpgsql;

