\set VERBOSITY 'terse'
set client_min_messages = 'warning';

-- start testing
create table rtest (
	id integer primary key,
	dat text
);

create trigger rtest_triga after insert or update or delete on rtest
for each row execute procedure pgq.sqltriga('que');

-- simple test
insert into rtest values (1, 'value1');
update rtest set dat = 'value2';
delete from rtest;

-- test new fields
alter table rtest add column dat2 text;
insert into rtest values (1, 'value1');
update rtest set dat = 'value2';
delete from rtest;

-- test field ignore
drop trigger rtest_triga on rtest;
create trigger rtest_triga after insert or update or delete on rtest
for each row execute procedure pgq.sqltriga('que2', 'ignore=dat2');

insert into rtest values (1, '666', 'newdat');
update rtest set dat = 5, dat2 = 'newdat2';
update rtest set dat = 6;
delete from rtest;

-- test hashed pkey
-- drop trigger rtest_triga on rtest;
-- create trigger rtest_triga after insert or update or delete on rtest
-- for each row execute procedure pgq.sqltriga('que2', 'ignore=dat2','pkey=dat,hashtext(dat)');

-- insert into rtest values (1, '666', 'newdat');
-- update rtest set dat = 5, dat2 = 'newdat2';
-- update rtest set dat = 6;
-- delete from rtest;


-- test wrong key
drop trigger rtest_triga on rtest;
create trigger rtest_triga after insert or update or delete on rtest
for each row execute procedure pgq.sqltriga('que3');

insert into rtest values (1, 0, 'non-null');
insert into rtest values (2, 0, NULL);
update rtest set dat2 = 'non-null2' where id=1;
update rtest set dat2 = NULL where id=1;
update rtest set dat2 = 'new-nonnull' where id=2;

delete from rtest where id=1;
delete from rtest where id=2;


-- test missing pkey
create table nopkey (dat text);
create trigger nopkey_triga after insert or update or delete on nopkey
for each row execute procedure pgq.sqltriga('que3');

insert into nopkey values ('foo');
update nopkey set dat = 'bat';
delete from nopkey;


-- test custom pkey
create table custom_pkey (dat1 text not null, dat2 int2 not null, dat3 text);
create trigger custom_triga after insert or update or delete on custom_pkey
for each row execute procedure pgq.sqltriga('que3', 'pkey=dat1,dat2');

insert into custom_pkey values ('foo', '2');
update custom_pkey set dat3 = 'bat';
delete from custom_pkey;

-- test custom fields
create table custom_fields (
    dat1 text not null primary key,
    dat2 int2 not null,
    dat3 text,
    _pgq_ev_type text default 'my_type',
    _pgq_ev_extra1 text default 'e1',
    _pgq_ev_extra2 text default 'e2',
    _pgq_ev_extra3 text default 'e3',
    _pgq_ev_extra4 text default 'e4'
);
create trigger customf_triga after insert or update or delete on custom_fields
for each row execute procedure pgq.sqltriga('que3');

insert into custom_fields values ('foo', '2');
update custom_fields set dat3 = 'bat';
delete from custom_fields;

-- test custom expression
create table custom_expr (
    dat1 text not null primary key,
    dat2 int2 not null,
    dat3 text
);
create trigger customex_triga after insert or update or delete on custom_expr
for each row execute procedure pgq.sqltriga('que3', 'ev_extra1=''test='' || dat1', 'ev_type=dat3');

insert into custom_expr values ('foo', '2');
update custom_expr set dat3 = 'bat';
delete from custom_expr;

-- test pk update
insert into rtest values (1, 'value1');
update rtest set id = 2;

