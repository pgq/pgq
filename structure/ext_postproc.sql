
-- tag data objects as dumpable

SELECT pg_catalog.pg_extension_config_dump('pgq.queue', '');
SELECT pg_catalog.pg_extension_config_dump('pgq.consumer', '');
SELECT pg_catalog.pg_extension_config_dump('pgq.tick', '');
SELECT pg_catalog.pg_extension_config_dump('pgq.subscription', '');
SELECT pg_catalog.pg_extension_config_dump('pgq.event_template', '');
SELECT pg_catalog.pg_extension_config_dump('pgq.retry_queue', '');

-- This needs pg_dump 9.1.7+
SELECT pg_catalog.pg_extension_config_dump('pgq.batch_id_seq', '');

