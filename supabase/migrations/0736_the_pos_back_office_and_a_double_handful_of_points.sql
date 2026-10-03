-- ---------------------------------------------------------------------
-- 0736  The POS back office, and a double handful of points
--
-- The census's 48 down to 38: six wrappers and four verdicts, every one
-- of the ten MEASURED by calling the function twice against a built
-- database and counting rows rather than by reading it.
--
-- The six that doubled, and what two taps leave behind:
--
-- | | |
-- | --- | --- |
-- | `upsert_cash_forecast_item` | two forecast lines, so the cash runway is wrong by one of them |
-- | `upsert_pos_driver` | two drivers of the same name on the same outlet's list |
-- | `upsert_pos_report` | two saved reports |
-- | `upsert_pos_menu_schedule` | two schedules, both live, so the menu changes twice at the same time |
-- | `upsert_pos_promotion` | two promotions, both running |
-- | `adjust_loyalty_points` | **100 points from one 50-point adjustment.** Measured: `app.loyalty_balance` came back 100 after two identical calls |
--
-- `adjust_loyalty_points` is the one that matters most. The other five
-- leave a visible duplicate somebody deletes; this one leaves a BALANCE,
-- and a balance has no row saying it was credited twice. It is the same
-- shape as `0735`'s `escalate_ticket` and the second of its kind in this
-- programme.
--
-- The five `upsert_*` are the POS and cash-flow back office, and they are
-- the create-or-amend shape `b0682f0b` measured eight of: an optional
-- `p_id`, amend with one and create without. The eight were refused by a
-- unique index on `(org, code)`. These five have no such index — a
-- forecast line, a driver, a saved report, a schedule and a promotion are
-- all things a company may legitimately have two of with the same name —
-- so nothing can tell a second create from a dropped connection except a
-- key.
--
-- ## Four verdicts, also measured
--
-- * `upsert_loyalty_tier` — refused by `loyalty_tiers_program_id_code_key`.
-- * `upsert_pos_modifier` — refused by `pos_modifiers_group_id_code_key`.
--   Both are the create-or-amend shape WITH the index, so they join the
--   eight.
-- * `enrol_loyalty_member` — ran twice and left one account, deliberately:
--   "A cashier who taps twice enrols one member, and gets back the
--   account they already had rather than an error they have to explain to
--   somebody holding a card." An `existing:` verdict.
-- * `set_module_hidden` — ran twice and left one row. It sets a flag; the
--   second call updates the row the first one inserted. A `natural:`
--   verdict, and the census only had it on the list because the insert
--   itself carries no `on conflict`.
--
-- ## Where the organization comes from
--
-- Five of the six take one. `adjust_loyalty_points` is given a loyalty
-- account, so the organization is read off that before the key is
-- claimed, which is what makes `0475`'s membership guard apply.
--
-- ## The arguments the client was not sending
--
-- `check_idempotent_calls.py` requires every parameter to be named,
-- because the wrapper can have no defaults. Three were missing and all
-- three default to null, so an explicit null is the same call:
-- `upsert_pos_driver`'s `p_user`, and `upsert_pos_menu_schedule`'s
-- `p_starts_on` and `p_ends_on`. `upsert_pos_promotion` names all
-- twenty-one already, which is the one piece of luck in this tranche.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- upsert_cash_forecast_item
-- ---------------------------------------------------------------------
create or replace function public.upsert_cash_forecast_item(
  p_id uuid, p_org uuid, p_direction text, p_description text,
  p_amount numeric, p_expected_on date, p_recurrence text,
  p_until date, p_notes text, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org, p_idempotency_key,
    'upsert_cash_forecast_item',
    jsonb_build_object('id', p_id, 'direction', p_direction,
                       'description', p_description,
                       'amount', p_amount,
                       'expected_on', p_expected_on,
                       'recurrence', p_recurrence, 'until', p_until,
                       'notes', p_notes));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.upsert_cash_forecast_item(p_id, p_org, p_direction,
    p_description, p_amount, p_expected_on, p_recurrence, p_until,
    p_notes);
  perform app.idempotency_end(p_org, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- upsert_pos_driver
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_driver(
  p_id uuid, p_org uuid, p_name text, p_phone text, p_vehicle text,
  p_plate text, p_outlet uuid, p_user uuid, p_active boolean,
  p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org, p_idempotency_key,
    'upsert_pos_driver',
    jsonb_build_object('id', p_id, 'name', p_name, 'phone', p_phone,
                       'vehicle', p_vehicle, 'plate', p_plate,
                       'outlet', p_outlet, 'user', p_user,
                       'active', p_active));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.upsert_pos_driver(p_id, p_org, p_name, p_phone,
    p_vehicle, p_plate, p_outlet, p_user, p_active);
  perform app.idempotency_end(p_org, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- upsert_pos_report
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_report(
  p_org uuid, p_name text, p_source app.pos_report_source,
  p_dimensions text[], p_measures text[], p_period text, p_from date,
  p_to date, p_outlets uuid[], p_channels text[], p_sort_by text,
  p_sort_desc boolean, p_limit integer, p_shared boolean, p_id uuid,
  p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org, p_idempotency_key,
    'upsert_pos_report',
    jsonb_build_object('name', p_name, 'source', p_source::text,
                       'dimensions', p_dimensions,
                       'measures', p_measures, 'period', p_period,
                       'from', p_from, 'to', p_to,
                       'outlets', p_outlets, 'channels', p_channels,
                       'sort_by', p_sort_by, 'sort_desc', p_sort_desc,
                       'limit', p_limit, 'shared', p_shared,
                       'id', p_id));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.upsert_pos_report(p_org, p_name, p_source, p_dimensions,
    p_measures, p_period, p_from, p_to, p_outlets, p_channels, p_sort_by,
    p_sort_desc, p_limit, p_shared, p_id);
  perform app.idempotency_end(p_org, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- upsert_pos_menu_schedule
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_menu_schedule(
  p_org uuid, p_name text, p_weekdays smallint[],
  p_starts_at time without time zone,
  p_ends_at time without time zone, p_starts_on date, p_ends_on date,
  p_items uuid[], p_id uuid, p_is_active boolean,
  p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org, p_idempotency_key,
    'upsert_pos_menu_schedule',
    jsonb_build_object('name', p_name, 'weekdays', p_weekdays,
                       'starts_at', p_starts_at, 'ends_at', p_ends_at,
                       'starts_on', p_starts_on, 'ends_on', p_ends_on,
                       'items', p_items, 'id', p_id,
                       'is_active', p_is_active));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.upsert_pos_menu_schedule(p_org, p_name, p_weekdays,
    p_starts_at, p_ends_at, p_starts_on, p_ends_on, p_items, p_id,
    p_is_active);
  perform app.idempotency_end(p_org, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- upsert_pos_promotion
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_promotion(
  p_org uuid, p_name text, p_kind app.pos_promo_kind, p_code text,
  p_percent numeric, p_amount numeric, p_buy integer, p_get integer,
  p_starts_on date, p_ends_on date, p_weekdays smallint[],
  p_starts_at time without time zone,
  p_ends_at time without time zone, p_min_subtotal numeric,
  p_max_uses integer, p_max_per_customer integer, p_items uuid[],
  p_outlets uuid[], p_channels text[], p_id uuid,
  p_is_active boolean, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org, p_idempotency_key,
    'upsert_pos_promotion',
    jsonb_build_object('name', p_name, 'kind', p_kind::text,
                       'code', p_code, 'percent', p_percent,
                       'amount', p_amount, 'buy', p_buy, 'get', p_get,
                       'starts_on', p_starts_on, 'ends_on', p_ends_on,
                       'weekdays', p_weekdays,
                       'starts_at', p_starts_at, 'ends_at', p_ends_at,
                       'min_subtotal', p_min_subtotal,
                       'max_uses', p_max_uses,
                       'max_per_customer', p_max_per_customer,
                       'items', p_items, 'outlets', p_outlets,
                       'channels', p_channels, 'id', p_id,
                       'is_active', p_is_active));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.upsert_pos_promotion(p_org, p_name, p_kind, p_code,
    p_percent, p_amount, p_buy, p_get, p_starts_on, p_ends_on,
    p_weekdays, p_starts_at, p_ends_at, p_min_subtotal, p_max_uses,
    p_max_per_customer, p_items, p_outlets, p_channels, p_id,
    p_is_active);
  perform app.idempotency_end(p_org, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- adjust_loyalty_points
-- ---------------------------------------------------------------------
create or replace function public.adjust_loyalty_points(
  p_account uuid, p_points integer, p_note text,
  p_idempotency_key text)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_n integer;
begin
  select a.org_id into v_org from public.loyalty_accounts a
    where a.id = p_account;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key, 'adjust_loyalty_points',
    jsonb_build_object('account', p_account, 'points', p_points,
                       'note', p_note));
    if v_seen is not null then
      return coalesce((v_seen ->> 'balance')::integer, 0);
    end if;
  end if;

  v_n := public.adjust_loyalty_points(p_account, p_points, p_note);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('balance', v_n));
  end if;
  return v_n;
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from every new function;
-- these are new signatures and arrive with no grant at all.
grant execute on function public.upsert_cash_forecast_item(
  uuid, uuid, text, text, numeric, date, text, date, text, text)
  to authenticated;
grant execute on function public.upsert_pos_driver(
  uuid, uuid, text, text, text, text, uuid, uuid, boolean, text)
  to authenticated;
grant execute on function public.upsert_pos_report(
  uuid, text, app.pos_report_source, text[], text[], text, date, date,
  uuid[], text[], text, boolean, integer, boolean, uuid, text)
  to authenticated;
grant execute on function public.upsert_pos_menu_schedule(
  uuid, text, smallint[], time without time zone, time without time zone,
  date, date, uuid[], uuid, boolean, text) to authenticated;
grant execute on function public.upsert_pos_promotion(
  uuid, text, app.pos_promo_kind, text, numeric, numeric, integer, integer,
  date, date, smallint[], time without time zone, time without time zone,
  numeric, integer, integer, uuid[], uuid[], text[], uuid, boolean, text)
  to authenticated;
grant execute on function public.adjust_loyalty_points(
  uuid, integer, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- What each one refuses, for `docs/api/`
-- ---------------------------------------------------------------------
comment on function public.upsert_cash_forecast_item(
  uuid, uuid, text, text, numeric, date, text, date, text, text) is
  'Saves one cash forecast line per idempotency key: amends when p_id is '
  'given, creates when it is null. Measured: without a key two identical '
  'creates leave two lines and the cash runway is wrong by one of them. '
  'The key is required and has no default, which is what makes PostgREST '
  'choose this overload rather than the unprotected one, so every '
  'parameter must be named. Refuses a key already used for different '
  'arguments (22023), a key still in flight (55006), and a caller who is '
  'not a member of the organization.';

comment on function public.upsert_pos_driver(
  uuid, uuid, text, text, text, text, uuid, uuid, boolean, text) is
  'Saves one delivery driver per idempotency key. Measured: without one, '
  'two taps put two drivers of the same name on the outlet''s list -- '
  'there is no unique index, because a company may legitimately employ '
  'two people of the same name. As upsert_cash_forecast_item for the key '
  'and the refusals.';

comment on function public.upsert_pos_report(
  uuid, text, app.pos_report_source, text[], text[], text, date, date,
  uuid[], text[], text, boolean, integer, boolean, uuid, text) is
  'Saves one POS report definition per idempotency key. Measured: '
  'without one, two identical saves leave two reports. As '
  'upsert_cash_forecast_item for the key and the refusals.';

comment on function public.upsert_pos_menu_schedule(
  uuid, text, smallint[], time without time zone, time without time zone,
  date, date, uuid[], uuid, boolean, text) is
  'Saves one menu schedule per idempotency key. Measured: without one, '
  'two identical saves leave two schedules BOTH LIVE, so the menu '
  'changes twice at the same moment. As upsert_cash_forecast_item for '
  'the key and the refusals.';

comment on function public.upsert_pos_promotion(
  uuid, text, app.pos_promo_kind, text, numeric, numeric, integer, integer,
  date, date, smallint[], time without time zone, time without time zone,
  numeric, integer, integer, uuid[], uuid[], text[], uuid, boolean, text) is
  'Saves one promotion per idempotency key. Measured: without one, two '
  'identical saves leave two promotions both running. A promotion with '
  'a code is covered by pos_promotions_code_idx; one without a code is '
  'not, which is why this needs a key rather than a verdict. As '
  'upsert_cash_forecast_item for the key and the refusals.';

comment on function public.adjust_loyalty_points(uuid, integer, text, text) is
  'Adjusts a loyalty balance once per idempotency key. What a retry '
  'duplicates here is not a row anybody can see but the BALANCE: '
  'measured, two identical 50-point adjustments left 100 points, and '
  'nothing on the account says it was credited twice. The organization '
  'comes from the loyalty account. Refuses a key already used for '
  'different arguments (22023) and a caller who is not a member of that '
  'organization.';
