-- Section: Internal Functions

-- install & launch schema upgrade
\i functions/pgq.upgrade_schema.sql
select pgq.upgrade_schema();

-- Group: Low-level event handling

\i functions/pgq.batch_event_sql.sql
\i functions/pgq.batch_event_tables.sql
\i functions/pgq.event_retry_raw.sql
\i functions/pgq.find_tick_helper.sql

-- \i functions/pgq.insert_event_raw.sql
\i lowlevel/pgq_lowlevel.sql

-- Group: Ticker

\i functions/pgq.ticker.sql

-- Group: Periodic maintenence

\i functions/pgq.maint_retry_events.sql
\i functions/pgq.maint_rotate_tables.sql
\i functions/pgq.maint_tables_to_vacuum.sql
\i functions/pgq.maint_operations.sql

-- Group: Random utility functions

\i functions/pgq.grant_perms.sql
\i functions/pgq.tune_storage.sql
\i functions/pgq.force_tick.sql
\i functions/pgq.seq_funcs.sql
\i functions/pgq.quote_fqname.sql

