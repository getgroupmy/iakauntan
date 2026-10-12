-- =====================================================================
-- iAkauntan :: the register is never short (0833)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/share_register_kept.sql
--
-- The register of members is computed from the share movements, and
-- `0064` refused a movement out of a holding that was not there -- but
-- counted the holding only up to the movement's own date. A transfer
-- backdated before one already recorded left the holder at minus 100.
-- And a client could edit or delete any movement, or record one in
-- another company's class of shares. Asked as the owner, with the role
-- `authenticated`, as the movement sheet asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_sr (org uuid, saham uuid, lain uuid,
  ord uuid, pref uuid, ord_lain uuid, a uuid, b uuid, c uuid, first_allot uuid);
grant select, update on t_sr to authenticated;

-- One movement, as the sheet sends it: Saham's ordinary shares unless
-- told otherwise.
create or replace function pg_temp.move(
  p_type text, p_date date, p_from uuid, p_to uuid, p_qty numeric,
  p_entity uuid default null, p_class uuid default null)
returns text language plpgsql as $$
declare d t_sr;
begin
  select * into d from t_sr;
  return format(
    $q$insert into public.corp_share_events (org_id, entity_id, share_class_id,
         event_type, event_date, from_person_id, to_person_id, quantity)
       values (%L, %L, %L, %L, %L, %L, %L, %s)$q$,
    d.org, coalesce(p_entity, d.saham), coalesce(p_class, d.ord),
    p_type, p_date, p_from, p_to, p_qty);
end $$;
grant execute on function pg_temp.move(text, date, uuid, uuid, numeric, uuid, uuid) to authenticated;

-- One class of the register, as one line: who holds how many.
create or replace function pg_temp.register(p_entity uuid, p_class uuid)
returns text language sql as $$
  select coalesce(string_agg(r.member_name || '=' || r.shares::numeric(20, 0),
                             ', ' order by r.member_name), '')
    from public.corp_register_of_members(p_entity) r
   where r.share_class_id = p_class;
$$;
grant execute on function pg_temp.register(uuid, uuid) to authenticated;

do $$
declare r t_sr;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Daftar Saham Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (r.org, 'secretarial', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (r.org, 'Saham Sdn Bhd', 'sdn_bhd', date '2024-03-12', 31, 12)
  returning id into r.saham;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (r.org, 'Lain Sdn Bhd', 'sdn_bhd', date '2024-03-12', 31, 12)
  returning id into r.lain;
  insert into public.corp_share_classes (org_id, entity_id, code, name)
  values (r.org, r.saham, 'ORD', 'Ordinary') returning id into r.ord;
  insert into public.corp_share_classes (org_id, entity_id, code, name)
  values (r.org, r.saham, 'PREF', 'Preference') returning id into r.pref;
  insert into public.corp_share_classes (org_id, entity_id, code, name)
  values (r.org, r.lain, 'ORD', 'Ordinary') returning id into r.ord_lain;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (r.org, 'individual', 'Member A', '920415085566') returning id into r.a;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (r.org, 'individual', 'Member B', '850922105533') returning id into r.b;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (r.org, 'individual', 'Member C', '880101145577') returning id into r.c;
  insert into t_sr select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_sr;
begin
  select * into d from t_sr;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- A is allotted 100 ordinary shares on 1 January -- and 1,000
  -- preference shares, which are not the ordinary ones -- and transfers
  -- all 100 ordinary to B on 1 March; 30 more are allotted to A on
  -- 1 April.
  execute pg_temp.move('allotment', date '2026-01-01', null, d.a, 100);
  update t_sr set first_allot = (select id from public.corp_share_events
                                  where entity_id = d.saham and to_person_id = d.a);
  execute pg_temp.move('allotment', date '2026-01-01', null, d.a, 1000, null, d.pref);
  execute pg_temp.move('transfer', date '2026-03-01', d.a, d.b, 100);
  execute pg_temp.move('allotment', date '2026-04-01', null, d.a, 30);
  perform pg_temp.check_eq('the register as recorded',
    pg_temp.register(d.saham, d.ord), 'Member A=30, Member B=100');

  -- What was measured: a transfer backdated before one already
  -- recorded. A held 100 on 1 February; on 1 March A would hold none
  -- to give.
  perform pg_temp.check_refused('a transfer backdated before one already recorded',
    pg_temp.move('transfer', date '2026-02-01', d.a, d.c, 100),
    'Moving 100.0000 on 2026-02-01 would leave the holder 100.0000 short on 2026-03-01, when a movement already recorded moves those shares.%',
    '23514');
  -- Short for a month is short, though 1 April makes it up.
  perform pg_temp.check_refused('short for a month, made up after, is short',
    pg_temp.move('transfer', date '2026-02-01', d.a, d.c, 30),
    'Moving 30.0000 on 2026-02-01 would leave the holder 30.0000 short on 2026-03-01,%',
    '23514');
  -- The same day counts together: on 1 March A gives B all 100.
  perform pg_temp.check_refused('a movement on the day of one already recorded counts with it',
    pg_temp.move('transfer', date '2026-03-01', d.a, d.c, 30),
    'Holder has 0.0000 shares of that class on 2026-03-01, cannot move 30.0000',
    '23514');

  -- History keyed in out of order, where it fits, is taken: with 50
  -- more from 10 January, A gives C 50 on 1 February and still has the
  -- 100 for B on 1 March -- exactly none over.
  execute pg_temp.move('allotment', date '2026-01-10', null, d.a, 50);
  execute pg_temp.move('transfer', date '2026-02-01', d.a, d.c, 50);
  perform pg_temp.check_eq('history keyed in out of order, where it fits, is taken',
    pg_temp.register(d.saham, d.ord), 'Member A=30, Member B=100, Member C=50');

  -- A cancellation is a movement out like any other.
  execute pg_temp.move('transfer', date '2026-06-01', d.c, d.b, 50);
  perform pg_temp.check_refused('a cancellation backdated before a transfer already recorded',
    pg_temp.move('cancellation', date '2026-05-15', d.c, null, 50),
    'Moving 50.0000 on 2026-05-15 would leave the holder 50.0000 short on 2026-06-01,%',
    '23514');

  -- A holder's movement to themselves moves nothing. It had counted as
  -- 30 gained, so 31 could leave a holding of 30 --
  execute pg_temp.move('conversion', date '2026-04-02', d.a, d.a, 30);
  perform pg_temp.check_refused('a movement to oneself is not shares gained',
    pg_temp.move('transfer', date '2026-05-01', d.a, d.c, 31),
    'Holder has 30.0000 shares of that class on 2026-05-01, cannot move 31.0000',
    '23514');
  -- -- and on a later date as well: A's last 30 go to B on 20 May, so
  -- 30 more out on 1 April leaves A short then.
  execute pg_temp.move('transfer', date '2026-05-20', d.a, d.b, 30);
  perform pg_temp.check_refused('nor on a later date',
    pg_temp.move('transfer', date '2026-04-01', d.a, d.c, 30),
    'Moving 30.0000 on 2026-04-01 would leave the holder 30.0000 short on 2026-05-20,%',
    '23514');

  -- Another company's class of shares.
  perform pg_temp.check_refused('an allotment in another company''s class of shares',
    pg_temp.move('allotment', date '2026-04-01', null, d.c, 500, d.lain, d.ord),
    'That class of shares is another company''s.%', '23514');
  execute pg_temp.move('allotment', date '2026-04-01', null, d.c, 500, d.lain, d.ord_lain);

  -- Added to, not edited.
  perform pg_temp.check_refused('a movement is not edited',
    format('update public.corp_share_events set quantity = 10 where id = %L', d.first_allot),
    'permission denied for table corp_share_events', '42501');
  perform pg_temp.check_refused('nor deleted',
    format('delete from public.corp_share_events where id = %L', d.first_allot),
    'permission denied for table corp_share_events', '42501');

  perform pg_temp.check_eq('so the register is what was recorded',
    pg_temp.register(d.saham, d.ord), 'Member B=180');
  perform pg_temp.check_eq('the preference shares apart',
    pg_temp.register(d.saham, d.pref), 'Member A=1000');
  perform pg_temp.check_eq('and the issued capital is the allotments',
    (select string_agg(c.share_class || '=' || c.shares::numeric(20, 0), ', '
                       order by c.share_class)
       from public.corp_issued_capital(d.saham) c),
    'Ordinary=180, Preference=1000');
  perform pg_temp.check_eq('and the other company''s are its own',
    pg_temp.register(d.lain, d.ord_lain), 'Member C=500');
end $$;

reset role;

-- The door is insert, and only with the module.
do $$
declare d t_sr;
begin
  select * into d from t_sr;
  perform pg_temp.check_true('no client may update or delete a movement',
    not has_table_privilege('authenticated', 'public.corp_share_events', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.corp_share_events', 'DELETE')
    and not has_table_privilege('anon', 'public.corp_share_events', 'UPDATE')
    and not has_table_privilege('anon', 'public.corp_share_events', 'DELETE'));
  perform pg_temp.check_eq('and no policy lets one',
    (select string_agg(policyname || ':' || cmd, ', ' order by policyname)
       from pg_policies where schemaname = 'public' and tablename = 'corp_share_events'),
    'corp_share_events_insert:INSERT, corp_share_events_select:SELECT');
  update public.org_modules set is_enabled = false
   where org_id = d.org and module_code = 'secretarial';
end $$;

set local role authenticated;
do $$
declare d t_sr;
begin
  select * into d from t_sr;
  perform pg_temp.check_refused('a company without the secretarial module records nothing',
    pg_temp.move('allotment', date '2026-07-01', null, d.a, 1),
    'new row violates row-level security policy%', '42501');
end $$;

rollback;
