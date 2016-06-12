
ALTER EXTENSION pgq ADD SCHEMA pgq;

ALTER EXTENSION pgq ADD TABLE pgq.queue;
ALTER EXTENSION pgq ADD TABLE pgq.consumer;
ALTER EXTENSION pgq ADD TABLE pgq.tick;
ALTER EXTENSION pgq ADD TABLE pgq.subscription;
ALTER EXTENSION pgq ADD TABLE pgq.event_template;
ALTER EXTENSION pgq ADD TABLE pgq.retry_queue;

ALTER EXTENSION pgq ADD SEQUENCE pgq.batch_id_seq;

