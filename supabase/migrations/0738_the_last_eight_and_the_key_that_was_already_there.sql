-- ---------------------------------------------------------------------
-- 0738  The last eight, and the key that was already there
--
-- **The census's 26 down to ZERO.** Eight wrappers and eighteen
-- verdicts, every one of the twenty-six MEASURED by calling the function
-- twice against a built database and counting what was left.
--
-- Of 340 client-reachable writes, every single one now either holds an
-- idempotency key, inserts nothing, guards or replaces every row it
-- writes, refuses a repeat by name, or carries a verdict that says in
-- writing why repeating it is safe -- and `check_write_idempotency.py`
-- has `BACKLOG = 0`, so the next unprotected write fails CI by name.
--
-- ## The eight that doubled
--
-- | | |
-- | --- | --- |
-- | `create_recurring_document` | **two monthly schedules, both live.** The customer is invoiced twice a month, for ever, from one press |
-- | `run_item_conversion` | the stock is converted TWICE: measured, two output movements from one press, so one box becomes twenty bottles instead of ten |
-- | `create_payroll_run` | two payroll runs for one pay period, and two run numbers burnt |
-- | `upsert_bank_account` | two bank accounts of the same name and number, each with its own GL account |
-- | `join_pos_queue` | **two ticket numbers for one party at the door.** The second gets called and nobody is there |
-- | `upsert_pos_menu_link` | two live links to the same table, two tokens, neither revoked |
-- | `chat_create_group` | two groups of the same name with the same people in them |
-- | `upsert_landed_cost_run` | two landed-cost runs |
--
-- `create_recurring_document` is the worst of the thirty wrapped across
-- the seven tranches, and it is worse than `settle_deposit` in `0737`.
-- Every other duplicate is one wrong thing. A duplicated schedule is a
-- machine that goes on producing wrong things on a timer, and the second
-- one looks exactly as legitimate as the first.
--
-- `run_item_conversion` is the first in this programme to double a
-- PHYSICAL quantity. The others double rows, balances or papers; this
-- one says a box was broken into bottles twice, so the shelf and the
-- ledger both disagree with the room.
--
-- ## The key that was already there
--
-- `open_pos_sale` doubled too -- two parked bills from one press -- and
-- it is NOT wrapped, because it already has an idempotency key under
-- another name. `app.open_pos_sale_internal` takes `p_client_uuid` and
-- its first act is
--
--     if p_client_uuid is not null then
--       select s.id into v_sale from public.pos_sales s
--        where s.org_id = v_org and s.client_uuid = p_client_uuid;
--       if v_sale is not null then return v_sale; end if;
--
-- The till screen called it with no client_uuid at all. One caller,
-- `till_screen.dart`, `sale ??= await repo.openPosSale(reg)`, and the
-- mechanism had never been given anything to work with -- the same shape
-- as `0307`'s four wrappers, which went unused from the day they were
-- written until the gate that found them.
--
-- So the fix is in the client, not here: `openPosSale` now mints a
-- per-attempt uuid the way `callRpcOnce` mints a key, and
-- `check_idempotent_calls.py` refuses a call site that drops it. A second
-- idempotency layer over a working one would have been a worse answer
-- than using the one that is there.
--
-- ## Eighteen verdicts, every one measured
--
-- Six are refused by a unique index -- `open_matter`
-- (`matters_org_id_matter_no_key`), `upsert_item_conversion`
-- (`item_conversions_org_id_code_key`), `start_membership`
-- (`pos_membership_subscriptions_one_live`) and
-- `cover_line_with_membership` (`pos_membership_sessions_line_id_key`).
-- The last two were READ as doubling and are not: a session is unique on
-- the line it covers, and a live subscription is unique per member. That
-- is the sixth and seventh time in this programme that reading a body
-- found a defect the database was already refusing.
--
-- Five return what is already there, which is `existing:` --
-- `chat_start_direct` (exactly those two people and no third),
-- `ensure_default_warehouse`, `create_item_variants` (find-or-create per
-- variant code, and it reports `created = false`),
-- `create_supplier_from_received_einvoice`, and `ingest_offline_sales`,
-- which dedupes on the till's own `client_uuid` because an offline sync
-- that did not would be useless.
--
-- Three are state guards: `void_pos_sale` ("That bill is voided"),
-- `open_appraisal_cycle` (`not exists` per employee, so a retry appraises
-- nobody) and `run_recurring_journals_for` (it advances `next_run_date`).
--
-- Two are natural: `calculate_payroll_run` deletes and rebuilds the
-- payslips, so recalculating IS the button; `void_pos_sale_line` deletes
-- the line it voids, so a retry finds no line.
--
-- `create_po_from_suggestions` is the one worth naming on its own.
-- `app.forecast_wanted` subtracts `app.quantity_on_draft_order(...)` from
-- what the forecast asks for, so the first call's draft order makes the
-- second call want nothing. Measured: one order, then still one. That is
-- a deliberate mechanism, not an accident, and it is the only one of the
-- 340 that defends itself by netting off its own output.
--
-- Two repeat on purpose. `next_document_number` hands out the next
-- number, and asking twice is asking twice -- a key would hide a gap that
-- opening a form and closing it makes anyway. `run_inventory_forecast`
-- re-run is a new forecast, which is the button's whole purpose.
--
-- ## Where the organization comes from
--
-- Three of the eight take one. `join_pos_queue` and `upsert_pos_menu_link`
-- are given an outlet; `run_item_conversion` a conversion;
-- `create_recurring_document` a document that may be a sale or a
-- purchase, so both tables are tried in the order the function itself
-- tries them; and `upsert_bank_account`'s organization is `p_org_id` on a
-- create and the EXISTING ROW's on an amend, which is the one case where
-- reading the argument would claim the key against the wrong company.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- create_recurring_document
-- ---------------------------------------------------------------------
create or replace function public.create_recurring_document(
  p_document_id uuid, p_name text, p_frequency text, p_start_date date,
  p_interval_count integer, p_end_date date, p_max_occurrences integer,
  p_auto_post boolean, p_auto_email boolean, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_id uuid;
begin
  -- Sales first, then purchases, in the order the inner function tries
  -- them, so the key is claimed against the same organization it will
  -- write for.
  select d.org_id into v_org from public.sales_documents d
   where d.id = p_document_id;
  if v_org is null then
    select d.org_id into v_org from public.purchase_documents d
     where d.id = p_document_id;
  end if;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'create_recurring_document',
      jsonb_build_object('document', p_document_id, 'name', p_name,
                         'frequency', p_frequency,
                         'start_date', p_start_date,
                         'interval_count', p_interval_count,
                         'end_date', p_end_date,
                         'max_occurrences', p_max_occurrences,
                         'auto_post', p_auto_post,
                         'auto_email', p_auto_email));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  v_id := public.create_recurring_document(p_document_id, p_name,
    p_frequency, p_start_date, coalesce(p_interval_count, 1), p_end_date,
    p_max_occurrences, coalesce(p_auto_post, false),
    coalesce(p_auto_email, false));
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- run_item_conversion
-- ---------------------------------------------------------------------
create or replace function public.run_item_conversion(
  p_conversion uuid, p_times numeric, p_warehouse uuid,
  p_idempotency_key text)
returns numeric
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_value numeric;
begin
  select c.org_id into v_org from public.item_conversions c
   where c.id = p_conversion;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'run_item_conversion',
      jsonb_build_object('conversion', p_conversion, 'times', p_times,
                         'warehouse', p_warehouse));
    if v_seen is not null then
      return (v_seen ->> 'value')::numeric;
    end if;
  end if;

  v_value := public.run_item_conversion(p_conversion, p_times, p_warehouse);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('value', v_value));
  end if;
  return v_value;
end;
$$;

-- ---------------------------------------------------------------------
-- create_payroll_run
-- ---------------------------------------------------------------------
create or replace function public.create_payroll_run(
  p_org_id uuid, p_period_id uuid, p_description text,
  p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org_id, p_idempotency_key,
    'create_payroll_run',
    jsonb_build_object('period', p_period_id,
                       'description', p_description));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.create_payroll_run(p_org_id, p_period_id, p_description);
  perform app.idempotency_end(p_org_id, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- upsert_bank_account
--
-- The organization is the EXISTING ROW's on an amend. `p_org_id` is
-- nullable and the inner function ignores it when `p_id` names a row, so
-- claiming the key against the argument would put it in whichever
-- company the caller happened to name.
-- ---------------------------------------------------------------------
create or replace function public.upsert_bank_account(
  p_name text, p_bank_name text, p_bank_code text, p_account_number text,
  p_account_type text, p_currency text, p_account_id uuid, p_id uuid,
  p_org_id uuid, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_id uuid;
begin
  if p_id is not null then
    select b.org_id into v_org from public.bank_accounts b where b.id = p_id;
  else
    v_org := p_org_id;
  end if;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'upsert_bank_account',
      jsonb_build_object('id', p_id, 'name', p_name,
                         'bank_name', p_bank_name, 'bank_code', p_bank_code,
                         'account_number', p_account_number,
                         'account_type', p_account_type,
                         'currency', p_currency,
                         'account_id', p_account_id));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  v_id := public.upsert_bank_account(p_name, p_bank_name, p_bank_code,
    p_account_number, p_account_type, p_currency, p_account_id, p_id,
    p_org_id);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- join_pos_queue
--
-- Returns a TABLE, so the replay rebuilds every column from the stored
-- result rather than returning an empty set -- the shape `0733`'s
-- `bulk_email_documents` established and `0734`'s `knock_off` repeated.
-- A queue entry's ticket number is the one thing on the customer's slip
-- of paper, so a replay has to hand back the SAME number.
-- ---------------------------------------------------------------------
create or replace function public.join_pos_queue(
  p_outlet uuid, p_party integer, p_name text, p_phone text, p_note text,
  p_idempotency_key text)
returns table (
  entry_id       uuid,
  ticket_no      integer,
  quoted_minutes integer,
  ahead          integer)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_row record;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'join_pos_queue',
      jsonb_build_object('outlet', p_outlet, 'party', p_party,
                         'name', p_name, 'phone', p_phone,
                         'note', p_note));
    if v_seen is not null then
      entry_id       := nullif(v_seen ->> 'entry_id', '')::uuid;
      ticket_no      := (v_seen ->> 'ticket_no')::integer;
      quoted_minutes := (v_seen ->> 'quoted_minutes')::integer;
      -- Not stored: how many are ahead of them is true at the moment it
      -- is asked, and a number from five minutes ago is worse than a
      -- fresh one. Counted again, against the entry the first call made.
      select count(*)::integer into ahead
        from public.pos_queue_entries q
       where q.outlet_id = p_outlet
         and q.queue_date = (select e.queue_date
                               from public.pos_queue_entries e
                              where e.id = entry_id)
         and q.status in ('waiting', 'called')
         and q.id <> entry_id;
      return next;
      return;
    end if;
  end if;

  select * into v_row from public.join_pos_queue(p_outlet, p_party, p_name,
                                                p_phone, p_note);
  entry_id       := v_row.entry_id;
  ticket_no      := v_row.ticket_no;
  quoted_minutes := v_row.quoted_minutes;
  ahead          := v_row.ahead;
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
      jsonb_build_object('entry_id', entry_id, 'ticket_no', ticket_no,
                         'quoted_minutes', quoted_minutes));
  end if;
  return next;
end;
$$;

-- ---------------------------------------------------------------------
-- upsert_pos_menu_link
--
-- Also a TABLE, and the token is the half that matters: a retry minted a
-- second live link to the same table and revoked nothing, so the number
-- of ways into a table's menu doubled. Same shape as `0735`'s
-- `share_document`, and the replay returns the SAME token.
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_menu_link(
  p_outlet uuid, p_kind app.pos_menu_link_kind, p_table uuid,
  p_register uuid, p_label text, p_expires timestamptz, p_single boolean,
  p_id uuid, p_active boolean, p_idempotency_key text)
returns table (id uuid, token text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_row record;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'upsert_pos_menu_link',
      jsonb_build_object('outlet', p_outlet, 'kind', p_kind::text,
                         'table', p_table, 'register', p_register,
                         'label', p_label, 'expires', p_expires,
                         'single', p_single, 'id', p_id,
                         'active', p_active));
    if v_seen is not null then
      id    := nullif(v_seen ->> 'id', '')::uuid;
      token := v_seen ->> 'token';
      return next;
      return;
    end if;
  end if;

  select * into v_row from public.upsert_pos_menu_link(p_outlet, p_kind,
    p_table, p_register, p_label, p_expires, coalesce(p_single, false), p_id,
    coalesce(p_active, true));
  id    := v_row.id;
  token := v_row.token;
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
      jsonb_build_object('id', id, 'token', token));
  end if;
  return next;
end;
$$;

-- ---------------------------------------------------------------------
-- chat_create_group
-- ---------------------------------------------------------------------
create or replace function public.chat_create_group(
  p_my_org uuid, p_title text, p_members jsonb, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_my_org, p_idempotency_key,
    'chat_create_group',
    jsonb_build_object('title', p_title, 'members', p_members));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.chat_create_group(p_my_org, p_title, p_members);
  perform app.idempotency_end(p_my_org, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- upsert_landed_cost_run
-- ---------------------------------------------------------------------
create or replace function public.upsert_landed_cost_run(
  p_id uuid, p_org uuid, p_date date, p_bills jsonb, p_charges jsonb,
  p_notes text, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org, p_idempotency_key,
    'upsert_landed_cost_run',
    jsonb_build_object('id', p_id, 'date', p_date, 'bills', p_bills,
                       'charges', p_charges, 'notes', p_notes));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.upsert_landed_cost_run(p_id, p_org, p_date, p_bills,
                                        p_charges, p_notes);
  perform app.idempotency_end(p_org, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from every new function;
-- these are new signatures and arrive with no grant at all.
grant execute on function public.create_recurring_document(
  uuid, text, text, date, integer, date, integer, boolean, boolean, text)
  to authenticated;
grant execute on function public.run_item_conversion(
  uuid, numeric, uuid, text) to authenticated;
grant execute on function public.create_payroll_run(
  uuid, uuid, text, text) to authenticated;
grant execute on function public.upsert_bank_account(
  text, text, text, text, text, text, uuid, uuid, uuid, text)
  to authenticated;
grant execute on function public.join_pos_queue(
  uuid, integer, text, text, text, text) to authenticated;
grant execute on function public.upsert_pos_menu_link(
  uuid, app.pos_menu_link_kind, uuid, uuid, text, timestamptz, boolean,
  uuid, boolean, text) to authenticated;
grant execute on function public.chat_create_group(
  uuid, text, jsonb, text) to authenticated;
grant execute on function public.upsert_landed_cost_run(
  uuid, uuid, date, jsonb, jsonb, text, text) to authenticated;

comment on function public.create_recurring_document(
  uuid, text, text, date, integer, date, integer, boolean, boolean, text) is
  'Sets up one recurring schedule per idempotency key. MEASURED: without '
  'one, two taps left TWO live monthly schedules, so the customer is '
  'invoiced twice a month for ever from one press -- the only duplicate '
  'in this programme that goes on producing wrong documents on a timer. '
  'The organization comes from the document, sales first then purchases. '
  'Every parameter must be named. Refuses a key already used for '
  'different arguments (22023), a key still in flight (55006), and a '
  'caller who is not a member of the organization.';

comment on function public.run_item_conversion(uuid, numeric, uuid, text) is
  'Runs one stock conversion per idempotency key. MEASURED: without one, '
  'two taps produced TWO sets of output movements -- a physical quantity '
  'doubled, so the shelf and the ledger both disagree with the room. The '
  'organization comes from the conversion. As '
  'create_recurring_document for the key and the refusals.';

comment on function public.create_payroll_run(uuid, uuid, text, text) is
  'Opens one payroll run per idempotency key. MEASURED: without one, two '
  'taps left two runs against the same pay period and burnt two run '
  'numbers. As create_recurring_document for the key and the refusals.';

comment on function public.upsert_bank_account(
  text, text, text, text, text, text, uuid, uuid, uuid, text) is
  'Saves one bank account per idempotency key. MEASURED: without one, '
  'two taps left two accounts of the same name and number, each with its '
  'own GL account. The organization is the EXISTING ROW''s on an amend '
  'and p_org_id on a create, because the inner function ignores p_org_id '
  'when p_id names a row. As create_recurring_document for the key and '
  'the refusals.';

comment on function public.join_pos_queue(
  uuid, integer, text, text, text, text) is
  'Puts a party in the queue once per idempotency key, returning the '
  'SAME ticket number on a replay -- that number is on the customer''s '
  'slip of paper. MEASURED: without one, two taps gave one party two '
  'numbers, and the second gets called to an empty doorway. How many are '
  'ahead is counted fresh on a replay rather than stored, because a '
  'number from five minutes ago is worse than a new one. The '
  'organization comes from the outlet. As create_recurring_document for '
  'the key and the refusals.';

comment on function public.upsert_pos_menu_link(
  uuid, app.pos_menu_link_kind, uuid, uuid, text, timestamptz, boolean,
  uuid, boolean, text) is
  'Saves one menu link per idempotency key and returns the SAME token on '
  'a replay. MEASURED: without one, two taps minted two live links to '
  'the same table and revoked neither, doubling the ways into that '
  'table''s menu -- the shape of 0735''s share_document. The '
  'organization comes from the outlet. As create_recurring_document for '
  'the key and the refusals.';

comment on function public.chat_create_group(uuid, text, jsonb, text) is
  'Creates one group conversation per idempotency key. MEASURED: without '
  'one, two taps left two groups of the same name with the same people '
  'in them. chat_start_direct needs no key: it looks for the '
  'conversation with exactly those two and hands it back. As '
  'create_recurring_document for the key and the refusals.';

comment on function public.upsert_landed_cost_run(
  uuid, uuid, date, jsonb, jsonb, text, text) is
  'Saves one landed-cost run per idempotency key. MEASURED: without one, '
  'two identical saves left two runs. As create_recurring_document for '
  'the key and the refusals.';
