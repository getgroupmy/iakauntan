-- =====================================================================
-- iAkauntan :: a post-dated cheque is banked on its date (0886)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/cheque_banked_on_its_date.sql
--
-- `deposit_pdc` and `clear_pdc` took any day, and the cheque list's
-- "Pay it in" and "It cleared" send none, so a cheque dated next month
-- was paid in and cleared today -- the money in the bank a month before
-- any bank would pay it. Asked as an accountant, with the role
-- `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cb (org uuid, accountant uuid, cust uuid, bank uuid,
  early uuid, paid uuid, held uuid, back uuid, returned uuid);
grant select on t_cb to authenticated;

-- What a cheque says about itself.
create or replace function pg_temp.cb_state(p_cheque uuid)
returns text language sql as $$
  select status::text || ' paid in ' || coalesce(deposited_on::text, '-')
         || ' cleared ' || coalesce(cleared_on::text, '-')
    from public.post_dated_cheques where id = p_cheque;
$$;

-- The journal its clearing posted, by date.
create or replace function pg_temp.cb_cleared_entry(p_cheque uuid)
returns text language sql as $$
  select coalesce((select e.entry_date::text from public.gl_entries e
                    where e.id = c.settle_entry_id), 'none')
    from public.post_dated_cheques c where c.id = p_cheque;
$$;

do $$
declare r t_cb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Cek Bertarikh Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 90);
  r.accountant := pg_temp.another_user('akauntan@cekbertarikh.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.accountant, 'accountant', 'active');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan', 'customer') returning id into r.cust;
  r.bank := pg_temp.test_bank_account(r.org, 'Semasa', 'current', 'MYR', 0, 0, '512345678904');

  -- Five cheques received today, each dated thirty days on.
  r.early    := public.record_pdc(r.org, 'incoming', r.cust, '900001',
                  pg_temp.today() + 30, 100, '[]'::jsonb, r.bank);
  r.paid     := public.record_pdc(r.org, 'incoming', r.cust, '900002',
                  pg_temp.today() + 30, 200, '[]'::jsonb, r.bank);
  r.held     := public.record_pdc(r.org, 'incoming', r.cust, '900003',
                  pg_temp.today() + 30, 300, '[]'::jsonb, r.bank);
  r.back     := public.record_pdc(r.org, 'incoming', r.cust, '900004',
                  pg_temp.today() + 30, 400, '[]'::jsonb, r.bank);
  r.returned := public.record_pdc(r.org, 'incoming', r.cust, '900005',
                  pg_temp.today() + 30, 500, '[]'::jsonb, r.bank);
  insert into t_cb select r.*;
end $$;

select pg_temp.sign_in_as((select accountant from t_cb));
set local role authenticated;

do $$
declare d t_cb;
begin
  select * into d from t_cb;

  -- -------------------------------------------------------------------
  -- Before its date: not paid in, not cleared
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a cheque is not paid in before its date',
    format('select public.deposit_pdc(%L)', d.early),
    'Cheque 900001 is dated %, and no bank takes it before then.%', '23514');
  perform pg_temp.check_refused('not even the day before',
    format('select public.deposit_pdc(%L, %L)', d.early, pg_temp.today() + 29),
    'Cheque 900001 is dated %, and no bank takes it before then.%', '23514');
  perform pg_temp.check_refused('nor does it clear before its date',
    format('select public.clear_pdc(%L)', d.early),
    'Cheque 900001 is dated %, and no bank pays it before then.%', '23514');
  perform pg_temp.check_refused('not even the day before',
    format('select public.clear_pdc(%L, %L)', d.early, pg_temp.today() + 29),
    'Cheque 900001 is dated %, and no bank pays it before then.%', '23514');
  perform pg_temp.check_eq('so it is still held, and nothing reached the bank',
    pg_temp.cb_state(d.early) || ' / ' || pg_temp.cb_cleared_entry(d.early),
    'held paid in - cleared - / none');
  perform public.deposit_pdc(d.early, pg_temp.today() + 30);
  perform pg_temp.check_eq('it is paid in on the day written on it',
    pg_temp.cb_state(d.early),
    'deposited paid in ' || (pg_temp.today() + 30) || ' cleared -');

  -- -------------------------------------------------------------------
  -- On its date, and after it was paid in
  -- -------------------------------------------------------------------
  perform public.deposit_pdc(d.paid, pg_temp.today() + 35);
  perform pg_temp.check_eq('paid in on or after its date',
    pg_temp.cb_state(d.paid),
    'deposited paid in ' || (pg_temp.today() + 35) || ' cleared -');
  perform pg_temp.check_refused('it does not clear before the day it was paid in',
    format('select public.clear_pdc(%L, %L)', d.paid, pg_temp.today() + 32),
    'Cheque 900002 was paid in on %, and cannot have cleared before it was.', '23514');
  perform public.clear_pdc(d.paid, pg_temp.today() + 35);
  perform pg_temp.check_eq('it clears the day it was paid in, and the bank has it then',
    pg_temp.cb_state(d.paid) || ' / ' || pg_temp.cb_cleared_entry(d.paid),
    'cleared paid in ' || (pg_temp.today() + 35) || ' cleared ' || (pg_temp.today() + 35)
      || ' / ' || (pg_temp.today() + 35));

  perform public.clear_pdc(d.held, pg_temp.today() + 30);
  perform pg_temp.check_eq('a cheque still held clears on its own date',
    pg_temp.cb_state(d.held) || ' / ' || pg_temp.cb_cleared_entry(d.held),
    'cleared paid in - cleared ' || (pg_temp.today() + 30) || ' / ' || (pg_temp.today() + 30));

  -- -------------------------------------------------------------------
  -- What may happen before its date
  -- -------------------------------------------------------------------
  perform public.cancel_pdc(d.back, 'He paid cash instead');
  perform pg_temp.check_eq('it is handed back before its date',
    pg_temp.cb_state(d.back), 'cancelled paid in - cleared -');
  perform public.bounce_pdc(d.returned, 'Post-dated: presented too early');
  perform pg_temp.check_eq('and comes back unpaid before its date',
    pg_temp.cb_state(d.returned), 'bounced paid in - cleared -');
end $$;

reset role;

rollback;
