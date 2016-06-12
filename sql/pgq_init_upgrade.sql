\set ECHO none
\set VERBOSITY 'terse'
set client_min_messages = 'warning';
\i ../../upgrade/final/pgq_core_2.1.13.sql
\i ../../upgrade/final/pgq.upgrade_2.1_to_3.0.sql
\i pgq.upgrade.sql
\set ECHO all

