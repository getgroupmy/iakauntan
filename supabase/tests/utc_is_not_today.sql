-- =====================================================================
-- iAkauntan :: UTC is not today
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/utc_is_not_today.sql
--
-- Postgres runs in UTC, here and on Supabase. A Malaysian business day
-- is eight hours ahead, so `app.today()` exists -- it is
-- `app.malaysian_day(now())`, and eighty-seven functions in this schema
-- call it. Between 16:00 and 24:00 UTC, which is midnight to eight in
-- the morning in Kuala Lumpur, `current_date` is THE DAY BEFORE
-- `app.today()`.
--
-- `0545` is what a parameter defaulted to `CURRENT_DATE` costs when
-- somebody actually omits it: the inventory forecast measured demand to
-- yesterday and then raised a purchase order dated today, for a third
-- of every day, in the one module whose whole job is deciding when
-- something runs out.
--
-- The rest are a TRAP AND NOT A BUG, and the difference is worth
-- writing down rather than fixing blind. The nightly cron passes
-- `(now() at time zone 'Asia/Kuala_Lumpur')::date` explicitly, and
-- every Dart caller of the others passes a date of its own -- so not
-- one of those defaults is currently taken. Rewriting forty function
-- bodies into an append-only migration to change a default nobody
-- reaches would be a large irreversible artifact bought with nothing.
--
-- What is cheap, and what this file does: hold the list where it is.
-- Another function with a UTC default cannot be added quietly, and the
-- day somebody writes a caller that omits one of these, this comment is
-- what they will find.
--
-- To fix one properly: give it `DEFAULT app.today()` in a migration, as
-- `0545` did, and this file will tell you to delete its row.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_extra text;
  v_gone  text;
begin
  create temp table _utc_known (name text primary key) on commit drop;
  insert into _utc_known (name) values
    ('app.bill_the_month'),
    ('app.chase_platform_invoices'),
    ('app.expire_carried_leave'),
    ('app.group_eliminations'),
    ('app.group_intercompany_lines'),
    ('app.membership_period'),
    ('app.queue_overdue_reminders'),
    ('app.raise_notifications'),
    ('app.run_daily_jobs'),
    ('app.run_recurring_documents'),
    ('app.run_recurring_journals'),
    ('public.create_bank_transfer'),
    ('public.depreciation_preview'),
    ('public.exchange_rate_board'),
    ('public.exchange_rate_for'),
    ('public.fs_lodge'),
    ('public.fx_revaluation_preview'),
    ('public.pos_day_sheet'),
    ('public.remit_withholding'),
    ('public.report_ap_aging'),
    ('public.report_ar_aging'),
    ('public.report_asset_movements'),
    ('public.report_balance_sheet'),
    ('public.report_collections'),
    ('public.report_group_consolidated_trial_balance'),
    ('public.report_group_elimination_check'),
    ('public.report_group_intercompany'),
    ('public.report_group_trial_balance'),
    ('public.report_profit_loss'),
    ('public.report_profit_loss_by_dimension'),
    ('public.report_sales_by_person'),
    ('public.report_stock_card'),
    ('public.report_trial_balance'),
    ('public.revalue_foreign_balances'),
    ('public.run_depreciation'),
    ('public.run_recurring_documents_for'),
    ('public.run_recurring_journals_for'),
    ('public.strata_arrears'),
    ('public.transfer_between_matters');

  -- A function that defaults a date to UTC and is not on the list.
  select string_agg(f.name, ', ' order by f.name) into v_extra
    from (
      select n.nspname || '.' || p.proname as name
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public', 'app')
         and pg_get_function_arguments(p.oid) ~* 'DEFAULT CURRENT_DATE'
    ) f
   where not exists (select 1 from _utc_known k where k.name = f.name);

  if v_extra is not null then
    raise exception
      'FAIL % defaults a date parameter to CURRENT_DATE, which is UTC. '
      'A Malaysian business day is eight hours ahead -- use app.today(). '
      'If the default is genuinely never taken, add it to the list in '
      'this file and say who calls it and with what.', v_extra
      using errcode = 'P0001';
  end if;

  -- And one that has been fixed but left on the list, so the list
  -- shrinks as the trap is dismantled rather than going stale.
  select string_agg(k.name, ', ' order by k.name) into v_gone
    from _utc_known k
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname || '.' || p.proname = k.name
        and pg_get_function_arguments(p.oid) ~* 'DEFAULT CURRENT_DATE');

  if v_gone is not null then
    raise exception
      'FAIL % no longer defaults to CURRENT_DATE -- good. Take it off '
      'the list in this file.', v_gone using errcode = 'P0001';
  end if;

  perform pg_temp.check_eq('the UTC-defaulting functions are the known ones',
    (select count(*) from _utc_known), 39);
end $$;

-- And the two facts the whole file rests on, asserted rather than
-- assumed.
do $$
begin
  perform pg_temp.check_eq('app.today() is the Malaysian day',
    app.today()::text,
    ((now() at time zone 'Asia/Kuala_Lumpur')::date)::text);
  perform pg_temp.check_true('and the forecast now reads that clock',
    (select pg_get_function_arguments(oid) ~ 'p_as_of date DEFAULT app\.today'
       from pg_proc where proname = 'run_inventory_forecast'));
end $$;

rollback;
