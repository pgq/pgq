\set VERBOSITY 'terse'
set client_min_messages = 'warning';

drop schema pgq cascade;

drop sequence tmptest_seq;

drop table custom_expr;
drop table custom_expr2;
drop table custom_fields;
drop table custom_fields2;
drop table custom_pkey;
drop table deny_test;
drop table nopkey;
drop table nopkey2;
drop table rtest;
drop table if exists trunctrg1;
drop table if exists trunctrg2;
drop table ucustom_pkey;
drop table udata;
drop table when_test;

