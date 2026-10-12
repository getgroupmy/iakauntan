-- =====================================================================
-- iAkauntan :: a points card is enrolled (0842)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/loyalty_account_by_enrolment.sql
--
-- A balance is the sum of an account's ledger entries, and only an
-- owner or admin may adjust one. Before `0842` a cashier who could not
-- adjust could move a customer's whole balance to somebody else by
-- repointing the card, or erase it by deleting the account. Asked as
-- that cashier, with the role `authenticated`, as the till asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_lc (org uuid, cashier uuid, aminah uuid, friend uuid,
  newcomer uuid, acct uuid, prog uuid);
grant select on t_lc to authenticated;

do $$
declare r t_lc;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Kedai Mata Sdn Bhd', array['pos', 'loyalty']);
  insert into public.loyalty_programs (org_id, code, name)
  values (r.org, 'MATA', 'Mata Ganjaran') returning id into r.prog;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-A', 'Aminah', 'customer') returning id into r.aminah;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-B', 'A friend of the till', 'customer') returning id into r.friend;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-C', 'Pelanggan baru', 'customer') returning id into r.newcomer;
  r.acct := public.enrol_loyalty_member(r.aminah, 'CARD-A');
  perform public.adjust_loyalty_points(r.acct, 5000, 'Opening balance');
  r.cashier := pg_temp.another_user('juruwang@kedaimata.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (r.org, r.cashier, 'sales', 'active', now());
  insert into t_lc select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select cashier from t_lc), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_lc; v_new uuid;
begin
  select * into d from t_lc;
  perform pg_temp.check_true('a cashier who sells and may not adjust points',
    app.can_write_module(d.org, 'loyalty') and not app.can_admin(d.org));
  perform pg_temp.check_refused('-- as adjust_loyalty_points already says',
    format('select public.adjust_loyalty_points(%L, 5000, ''a gift'')', d.acct),
    'Only an owner or admin can adjust points.', '42501');

  -- What was measured.
  perform pg_temp.check_refused('a card is not moved to another customer',
    format('update public.loyalty_accounts set contact_id = %L where id = %L', d.friend, d.acct),
    'permission denied for table loyalty_accounts', '42501');
  perform pg_temp.check_refused('nor its account deleted',
    format('delete from public.loyalty_accounts where id = %L', d.acct),
    'permission denied for table loyalty_accounts', '42501');
  perform pg_temp.check_refused('nor one made by hand',
    format($q$insert into public.loyalty_accounts (org_id, program_id, contact_id)
              values (%L, %L, %L)$q$, d.org, d.prog, d.newcomer),
    'permission denied for table loyalty_accounts', '42501');
  perform pg_temp.check_eq('so Aminah keeps her points, and the friend has none',
    (select points::text from public.loyalty_account_balance(d.aminah)) || ' / '
      || coalesce((select points::text from public.loyalty_account_balance(d.friend)), 'no card'),
    '5000 / no card');

  -- What the till does is as before.
  v_new := public.enrol_loyalty_member(d.newcomer, 'CARD-C');
  perform pg_temp.check_true('a customer is still enrolled at the counter',
    exists (select 1 from public.loyalty_accounts
             where id = v_new and contact_id = d.newcomer and card_no = 'CARD-C'));
  perform public.enrol_loyalty_member(d.aminah, 'CARD-A2');
  perform pg_temp.check_eq('and a new card is still given to a member',
    (select card_no from public.loyalty_accounts where id = d.acct), 'CARD-A2');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('no client may write a loyalty account',
    not has_table_privilege('authenticated', 'public.loyalty_accounts', 'INSERT')
    and not has_table_privilege('authenticated', 'public.loyalty_accounts', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.loyalty_accounts', 'DELETE')
    and not has_table_privilege('anon', 'public.loyalty_accounts', 'INSERT')
    and not has_table_privilege('anon', 'public.loyalty_accounts', 'UPDATE')
    and not has_table_privilege('anon', 'public.loyalty_accounts', 'DELETE'));
  perform pg_temp.check_true('and no policy lets one',
    not exists (select 1 from pg_policies where schemaname = 'public'
                 and tablename = 'loyalty_accounts'
                 and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')));
end $$;

rollback;
