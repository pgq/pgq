\set VERBOSITY 'terse'
set client_min_messages = 'warning';

select 1 from (select set_config(name, 'escape', false) as ignore
          from pg_settings where name = 'bytea_output') x
          where x.ignore = 'foo';

create or replace function pgq.insert_event(queue_name text, ev_type text, ev_data text, ev_extra1 text, ev_extra2 text, ev_extra3 text, ev_extra4 text)
returns bigint as $$
begin
    raise warning 'insert_event(%, %, %, %)', queue_name, ev_type, ev_data, ev_extra1;
    return 1;
end;
$$ language plpgsql;

create table udata (
    id serial primary key,
    txt text,
    bin bytea
);

create trigger utest AFTER insert or update or delete ON udata
for each row execute procedure pgq.logutriga('udata_que');

insert into udata (txt) values ('text1');
insert into udata (bin) values (E'bi\tn\\000bin');

-- test ignore
drop trigger utest on udata;
truncate udata;
create trigger utest after insert or update or delete on udata
for each row execute procedure pgq.logutriga('udata_que', 'ignore=bin');

insert into udata values (1, 'txt', 'bin');
update udata set txt = 'txt';
update udata set txt = 'txt2', bin = 'bin2';
update udata set bin = 'bin3';
delete from udata;

-- test missing pkey
create table nopkey2 (dat text);
create trigger nopkey_triga2 after insert or update or delete on nopkey2
for each row execute procedure pgq.logutriga('que3');

insert into nopkey2 values ('foo');
update nopkey2 set dat = 'bat';
delete from nopkey2;

-- test custom pkey
create table ucustom_pkey (dat1 text not null, dat2 int2 not null, dat3 text);
create trigger ucustom_triga after insert or update or delete on ucustom_pkey
--for each row execute procedure pgq.logutriga('que3', 'pkey=dat1,dat2');
for each row execute procedure pgq.logutriga('que3');

insert into ucustom_pkey values ('foo', '2');
update ucustom_pkey set dat3 = 'bat';
delete from ucustom_pkey;

-- test custom fields
create table custom_fields2 (
    dat1 text not null primary key,
    dat2 int2 not null,
    dat3 text,
    _pgq_ev_type text default 'my_type',
    _pgq_ev_extra1 text default 'e1',
    _pgq_ev_extra2 text default 'e2',
    _pgq_ev_extra3 text default 'e3',
    _pgq_ev_extra4 text default 'e4'
);
create trigger customf2_triga after insert or update or delete on custom_fields2
for each row execute procedure pgq.logutriga('que3');

insert into custom_fields2 values ('foo', '2');
update custom_fields2 set dat3 = 'bat';
delete from custom_fields2;


-- test custom expression
create table custom_expr2 (
    dat1 text not null primary key,
    dat2 int2 not null,
    dat3 text
);
create trigger customex2_triga after insert or update or delete on custom_expr2
for each row execute procedure pgq.logutriga('que3', 'ev_extra1=''test='' || dat1', 'ev_type=dat3');

insert into custom_expr2 values ('foo', '2');
update custom_expr2 set dat3 = 'bat';
delete from custom_expr2;

-- test when=
create table when_test (
    dat1 text not null primary key,
    dat2 int2 not null,
    dat3 text
);
create trigger when_triga after insert or update or delete on when_test
for each row execute procedure pgq.logutriga('que3', 'when=dat1=''foo''');

insert into when_test values ('foo', '2');
insert into when_test values ('bar', '2');
select * from when_test;
update when_test set dat3 = 'bat';
delete from when_test;

drop trigger when_triga on when_test;
create trigger when_triga after insert or update or delete on when_test
for each row execute procedure pgq.logutriga('que3', 'when=current_user=''random''');

insert into when_test values ('foo', '2');
select * from when_test;

-- test deny
create table deny_test (
    dat1 text not null primary key,
    dat2 text
);
create trigger deny_triga after insert or update or delete on deny_test
for each row execute procedure pgq.logutriga('noqueue', 'deny');
insert into deny_test values ('1', '2');

-- test pk update
insert into udata (id, txt) values (1, 'txt');
update udata set id = 2;
