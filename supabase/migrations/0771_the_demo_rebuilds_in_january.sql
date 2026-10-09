-- =====================================================================
-- 0771 :: the demo rebuilds in January
--
-- Answered on 9 October: "two-function fix".
--
-- Measured under a shifted clock (libfaketime on a copy of the local
-- database): the scheduled demo rebuild passes on 28 December 2026 and
-- fails on 5 January, 10 March and 1 May 2027, for two reasons.
--
--   1. A demo company has only the fiscal year today falls in -- what
--      `create_organization` gives a real signup -- but the builders
--      date paper up to 75 days back. From 1 January until mid-March
--      some of it is in last year, and `create_gl_entry_internal`
--      refuses: "No fiscal period covers 2026-12-16".
--   2. `demo_amanah_accounts` gives Kilang the last complete calendar
--      year, approved 130 days after it and lodged 160 days after. Until
--      early June that is a day that has not happened, and
--      `fs_filing_dates_guard` refuses it.
--
-- In production `app.rebuild_demo_on_schedule` rolls a failed rebuild
-- back and logs it, so the demo would have stood frozen at its 31
-- December state, logging a failure four times a day; and the demo's
-- own tests would have turned CI red on 1 January, which here stops
-- every deploy.
--
-- Now a demo company also opens the year before (`create_previous_
-- fiscal_year`, which anchors on the earliest year's start and so holds
-- for any year-end month), and Kilang's year is the last whose
-- lodgement has passed, from a small pure function a test can ask
-- about any day rather than only today.
--
-- Not changed, on purpose: the demo is year-to-date, so in January it
-- is thin. That is the demo's design, not a failure.
--
-- Restated from `0731` and `0426`, whose texts are the live ones:
-- replayed into a rolled-back transaction they hash to what
-- production's `pg_get_functiondef` hashes to (ae8c7aa7..., e4d4b59c...).
-- The comments are EXTENDED.
-- =====================================================================

create or replace function app.demo_last_lodged_year_end(p_on date)
returns date
language sql
immutable
set search_path = pg_catalog
as $$
  -- The latest 31 December at least 160 days before p_on. 160 is
  -- `demo_amanah_accounts`' lodgement offset, the last of its dates.
  -- Through `timestamp`, not `timestamptz`: a date given to date_trunc
  -- becomes the latter, which reads the session's time zone, and this
  -- says IMMUTABLE.
  select date_trunc('year', (p_on - 159)::timestamp)::date - 1
$$;

comment on function app.demo_last_lodged_year_end(date) is
  'The latest 31 December whose accounts, approved 130 days later and '
  'lodged 160 days later as `demo_amanah_accounts` dates them, are '
  'lodged by p_on. On 9 June 2027 that is 31 December 2026; a day '
  'earlier it is 31 December 2025. Pure, so a test can ask about '
  'January in October (`0771`).';

CREATE OR REPLACE FUNCTION app.demo_company(p_owner uuid, p_name text, p_entity_type app.entity_type, p_registration_no text, p_tin text, p_msic_code text, p_activity text, p_state_code text, p_city text, p_postcode text, p_address text, p_phone text, p_email text, p_fye_month smallint DEFAULT 12)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_org uuid;
begin
  perform app.demo_act_as(p_owner);

  -- Deliberately not registered for SST here; see 0185. Where a demo
  -- company should be registered, the caller uses
  -- set_sst_registration() afterwards.
  v_org := public.create_organization(
    p_name, null, p_entity_type::text, p_registration_no, p_tin, p_msic_code,
    p_activity, p_state_code, p_city, p_postcode, p_address,
    p_phone, p_email, false, null, p_fye_month);

  update public.organizations set is_demo = true where id = v_org;

  -- `0771`: and the year before it. The builders date paper up to 75
  -- days back from today, so from 1 January to mid-March some of it
  -- falls in last year, which a real signup does not have and the
  -- rebuild then refused to post into.
  perform public.create_previous_fiscal_year(v_org);

  -- The drawer, before anything can be sold out of it. `0731`: five POS
  -- seeders completed a counter sale in a company with no bank account,
  -- and the takings went to the 1120 heading because that was what the
  -- fallback did. It is a `cash` account on 1110, so the current
  -- account `app.demo_purchases` makes later is still made.
  perform app.demo_bank_account(v_org, 'Wang Tunai', null, null, 'cash');

  return v_org;
end $function$;


create or replace function app.demo_amanah_accounts(
  p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_today  date := app.today();
  v_kilang uuid;
  v_pinang uuid;
  v_bayu   uuid;
  -- The year end each set of accounts is for. Kilang's is the last
  -- calendar year whose accounts can have been LODGED by today (`0771`:
  -- it was the last complete calendar year, whose approval, circulation
  -- and lodgement fall 130 to 160 days after it -- in the future from
  -- 1 January to early June, which `fs_filing_dates_guard` refuses);
  -- the other two are placed by how far they are from their lodgement
  -- date rather than by the calendar, because what this demonstrates is
  -- the countdown.
  v_k_end  date := app.demo_last_lodged_year_end(v_today);
  v_p_end  date := (date_trunc('month', v_today)
                    - interval '5 months' - interval '1 day')::date;
  v_b_end  date := (date_trunc('month', v_today)
                    - interval '9 months' - interval '1 day')::date;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);

  select id into v_kilang from public.corp_entities
   where org_id = p_org and name like 'Kilang%';
  select id into v_pinang from public.corp_entities
   where org_id = p_org and name like 'Pinang%';
  select id into v_bayu from public.corp_entities
   where org_id = p_org and name like 'Bayu%';

  -- Nothing to prepare accounts for. `0188` seeds all three, so this
  -- only fires if that seed changes -- and saying so is better than
  -- writing three filings with a null company on them, which is the
  -- defect this exists to demonstrate the absence of.
  if v_kilang is null or v_pinang is null or v_bayu is null then
    perform set_config('request.jwt.claims', '', true);
    return 'Amanah accounts: skipped, the client entities are not there.';
  end if;

  insert into public.fs_filings
    (org_id, corp_entity_id, fy_start, fy_end, framework, audit_status,
     auditor_name, auditor_firm_no, auditor_signatory, audit_report_date,
     opinion, employee_count, directors_approval_date, circulated_on,
     lodged_on, mbrs_reference, status, created_by)
  values
    (p_org, v_kilang,
     (v_k_end - interval '1 year' + interval '1 day')::date, v_k_end,
     'mpers', 'audited',
     'Tan & Rekan', 'AF 1234', 'Tan Wei Ming', v_k_end + 120,
     'unmodified', 38, v_k_end + 130, v_k_end + 140, v_k_end + 160,
     'MBRS-' || to_char(v_k_end, 'YYYY') || '-004512', 'lodged', p_owner),

    (p_org, v_pinang,
     (v_p_end - interval '1 year' + interval '1 day')::date, v_p_end,
     'mfrs', 'audited',
     'Tan & Rekan', 'AF 1234', 'Tan Wei Ming', v_p_end + 110,
     'unmodified', 214, v_p_end + 120, null,
     null, null, 'frozen', p_owner),

    (p_org, v_bayu,
     (v_b_end - interval '1 year' + interval '1 day')::date, v_b_end,
     'mpers', 'audit_exempt',
     null, null, null, null,
     null, 2, null, null,
     null, null, 'draft', p_owner);

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Amanah accounts: %s sets prepared for client companies -- one '
    'lodged, one frozen and about a month from its s.258 date, one '
    'still draft and already past it.',
    (select count(*) from public.fs_filings where org_id = p_org));
end $$;


comment on function app.demo_company(uuid, text, app.entity_type, text, text,
                                     text, text, text, text, text, text,
                                     text, text, smallint) is
  'Creates a demo company through create_organization(), so it gets the '
  'same chart of accounts, tax codes, payment terms, warehouse, price '
  'levels, pipeline and fiscal calendar a real signup does -- and, '
  'since `0771`, the fiscal year before that one too, because the demo '
  'dates paper up to 75 days back and in the first weeks of a year '
  'that is last year.';

comment on function app.demo_amanah_accounts(uuid, uuid) is
  'A set of accounts for each of Amanah''s three client companies, in '
  'three states, so the MBRS module and the s.258 deadline list have '
  'something in them. Kilang''s lodged set is for the last year whose '
  'lodgement has passed (`app.demo_last_lodged_year_end`, `0771`), so '
  'no date on it is one that has not happened yet.';
