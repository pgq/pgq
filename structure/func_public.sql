-- ----------------------------------------------------------------------
-- Section: Public Functions
-- 
-- The queue is used by a client in the following steps
-- 
-- 1. Register the client (a queue consumer)
-- 
--    pgq.register_consumer(queue_name, consumer_id)
-- 
-- 2. run a loop createing, consuming and closing batches
-- 
--    2a. pgq.get_batch_events(batch_id int8) - returns an int8 batch handle
-- 
--    2b. pgq.get_batch_events(batch_id int8) - returns a set of events for current batch
--    
--         the event structure is :(ev_id int8, ev_time timestamptz, ev_txid int8, ev_retry
--         int4, ev_type text, ev_data text, ev_extra1, ev_extra2, ev_extra3, ev_extra4)
--    
--    2c. if any of the events need to be tagged as failed, use a the function
--    
--         pgq.event_failed(batch_id int8, event_id int8, reason text)
--    
--    2d.  if you want the event to be re-inserted in the main queue afrer N seconds, use
--    
--         pgq.event_retry(batch_id int8, event_id int8, retry_seconds int4)
--    
--    2e. To finish processing and release the batch, use
--    
--         pgq.finish_batch(batch_id int8)
-- 
--         Until this is not done, the consumer will get same batch again.
-- 
--         After calling finish_batch consumer cannot do any operations with events
--         of that batch.  All operations must be done before.
-- 
-- -- ----------------------------------------------------------------------


-- Group: Queue creation

\i functions/pgq.create_queue.sql
\i functions/pgq.drop_queue.sql
\i functions/pgq.set_queue_config.sql

-- Group: Event publishing

\i functions/pgq.insert_event.sql
\i functions/pgq.current_event_table.sql

-- Group: Subscribing to queue

\i functions/pgq.register_consumer.sql
\i functions/pgq.unregister_consumer.sql

-- Group: Batch processing

\i functions/pgq.next_batch.sql
\i functions/pgq.get_batch_events.sql
\i functions/pgq.get_batch_cursor.sql
\i functions/pgq.event_retry.sql
\i functions/pgq.batch_retry.sql
\i functions/pgq.finish_batch.sql

-- Group: General info functions

\i functions/pgq.get_queue_info.sql
\i functions/pgq.get_consumer_info.sql
\i functions/pgq.version.sql
\i functions/pgq.get_batch_info.sql

