-- =====================================================================
-- iAkauntan :: 0923 a closed account takes no new name
--
-- `0921` and `0922` stop an account being closed while a setting or a
-- draft still names it. The other door is naming one that is closed
-- already. A contact (`0912`), payroll settings (`0919`) and a manual
-- journal refuse a closed account; nothing else asked.
--
-- Measured on 23 November 2026, locally, as the owner with the role
-- `authenticated`, each against an account closed beforehand with
-- `retire_account` -- every one accepted:
--
--   * an item, new or existing, as its sales or its purchase account;
--   * a new invoice line and a new bill line;
--   * a draft expense, and `set_expense_split` for a line of a split;
--   * a claim type, new or existing;
--   * `save_payment_method`, as the charge account;
--   * a fixed asset, as each of its three accounts;
--   * a draft stock adjustment;
--   * a recurring journal and a recurring document, as a line of the
--     template.
--
-- The app's own pickers list only open accounts, so each needs a
-- direct write or a function handed an account's id. Production on 23
-- November: three closed accounts, and nothing of these kinds naming
-- one.
--
-- Answered "close both doors"; this is the second. For every writer, a
-- trigger refuses a closed account -- `deleted_at` set, or `is_active`
-- off -- where one of those is set or changed, so a row that already
-- names one is still saved whole. Two things are let through on
-- purpose:
--
--   * a line carried on from the line it came from. `transfer_document`
--     copies a line's account with `source_line_id`; a goods received
--     note already posted is not asked by `0922`, and its bill must
--     still be raised. A carried line keeps its parent's account and
--     is asked only if it names a different one;
--   * another company's account, which is looked up by nobody here and
--     left to each column's tenant key, so it is described in no
--     refusal.
--
-- A recurring journal or document is asked for the accounts its
-- template newly names, and for all of them when it is switched back
-- on: one switched off is not held open by `0921`, so an account it
-- names may have closed since.
--
-- Not in this: a contact, an item or a payment method that was
-- removed and is restored is not asked again; an item's cost of sales
-- account, a tax code's two and a salary component's, which no posting
-- reads (`0921`); a landed cost run's charges, which were not
-- measured.
-- =====================================================================

create or replace function app.a_closed_account_takes_no_new_name()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_arg    text;
  v_col    text;
  v_label  text;
  v_id     uuid;
  v_acct   public.accounts;
  v_parent uuid;
  v_new    jsonb := to_jsonb(new);
  v_old    jsonb;
begin
  -- SECURITY DEFINER because it reads the account, and a writer who may
  -- not read the chart must not be waved through by reading nothing.
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
  end if;

  -- Each argument is `column:what it is called`.
  foreach v_arg in array tg_argv loop
    v_col   := split_part(v_arg, ':', 1);
    v_label := split_part(v_arg, ':', 2);
    v_id    := (v_new ->> v_col)::uuid;
    continue when v_id is null;
    continue when tg_op = 'UPDATE'
                  and (v_new -> v_col) is not distinct from (v_old -> v_col);

    select * into v_acct
      from public.accounts a
     where a.id = v_id and a.org_id = new.org_id;
    -- An account that does not exist, or is another company's, is the
    -- tenant key's to refuse -- and is not described to this writer.
    continue when v_acct.id is null;
    continue when v_acct.deleted_at is null and v_acct.is_active;

    -- A line carried on from the line it came from keeps that line's
    -- account, open or not.
    if (v_new ->> 'source_line_id') is not null then
      execute format('select l.account_id from %I.%I l where l.id = $1',
                     tg_table_schema, tg_table_name)
        into v_parent using (v_new ->> 'source_line_id')::uuid;
      continue when v_parent is not distinct from v_id;
    end if;

    raise exception
      '% may not be % %, which is closed: what is posted through it '
      'would land in an account that is out of use. Choose one that is '
      'open.',
      v_label, v_acct.code, v_acct.name
      using errcode = '23514';
  end loop;
  return new;
end;
$$;

revoke all on function app.a_closed_account_takes_no_new_name() from public, anon, authenticated;

comment on function app.a_closed_account_takes_no_new_name() is
  'Refuses, for every writer, a closed account (deleted_at set or '
  'is_active off) where a column named in its arguments is set or '
  'changed. A line carried on from its source line keeps that line''s '
  'account; another company''s account is left to the tenant key. 0923.';

create trigger a_closed_account_takes_no_new_name
  before insert or update of sales_account_id, purchase_account_id on public.items
  for each row execute function app.a_closed_account_takes_no_new_name(
    'sales_account_id:An item''s sales account',
    'purchase_account_id:An item''s purchase account');

create trigger a_closed_account_takes_no_new_name
  before insert or update of account_id on public.sales_document_lines
  for each row execute function app.a_closed_account_takes_no_new_name(
    'account_id:A sales document line''s account');

create trigger a_closed_account_takes_no_new_name
  before insert or update of account_id on public.purchase_document_lines
  for each row execute function app.a_closed_account_takes_no_new_name(
    'account_id:A purchase document line''s account');

create trigger a_closed_account_takes_no_new_name
  before insert or update of account_id on public.expenses
  for each row execute function app.a_closed_account_takes_no_new_name(
    'account_id:An expense''s account');

create trigger a_closed_account_takes_no_new_name
  before insert or update of account_id on public.expense_lines
  for each row execute function app.a_closed_account_takes_no_new_name(
    'account_id:A line of an expense''s split');

create trigger a_closed_account_takes_no_new_name
  before insert or update of expense_account_id on public.claim_types
  for each row execute function app.a_closed_account_takes_no_new_name(
    'expense_account_id:A claim type''s expense account');

create trigger a_closed_account_takes_no_new_name
  before insert or update of charge_account_id on public.payment_methods
  for each row execute function app.a_closed_account_takes_no_new_name(
    'charge_account_id:A payment method''s charge account');

create trigger a_closed_account_takes_no_new_name
  before insert or update of asset_account_id, accumulated_account_id, expense_account_id
  on public.fixed_assets
  for each row execute function app.a_closed_account_takes_no_new_name(
    'asset_account_id:A fixed asset''s asset account',
    'accumulated_account_id:A fixed asset''s accumulated depreciation account',
    'expense_account_id:A fixed asset''s depreciation expense account');

create trigger a_closed_account_takes_no_new_name
  before insert or update of account_id on public.stock_adjustments
  for each row execute function app.a_closed_account_takes_no_new_name(
    'account_id:A stock adjustment''s account');

-- ---------------------------------------------------------------------
-- The two that keep their accounts in a template
-- ---------------------------------------------------------------------
create or replace function app.a_recurring_template_names_no_closed_account()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_acct    public.accounts;
  v_lines   jsonb;
  v_before  jsonb := '[]'::jsonb;
  v_all     boolean;
  v_what    text := tg_argv[0];
begin
  -- Asked when the template changes, for the accounts it did not name
  -- before; and when it is switched back on, for all of them.
  if tg_op = 'UPDATE' then
    v_all := new.is_active and not old.is_active;
    if not v_all and new.template is not distinct from old.template then
      return new;
    end if;
    if not v_all and jsonb_typeof(old.template -> 'lines') = 'array' then
      v_before := old.template -> 'lines';
    end if;
  end if;

  v_lines := case when jsonb_typeof(new.template -> 'lines') = 'array'
                  then new.template -> 'lines' else '[]'::jsonb end;

  select a.* into v_acct
    from jsonb_array_elements(v_lines) l
    join public.accounts a
      on a.id::text = l ->> 'account_id' and a.org_id = new.org_id
   where (a.deleted_at is not null or not a.is_active)
     and not exists (select 1 from jsonb_array_elements(v_before) b
                      where b ->> 'account_id' = l ->> 'account_id')
   order by a.code
   limit 1;

  if v_acct.id is not null then
    raise exception
      '% may not be % %, which is closed: what is posted through it '
      'would land in an account that is out of use. Choose one that is '
      'open.',
      v_what, v_acct.code, v_acct.name
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function app.a_recurring_template_names_no_closed_account() from public, anon, authenticated;

comment on function app.a_recurring_template_names_no_closed_account() is
  'Refuses, for every writer, a recurring journal or document whose '
  'template lines newly name a closed account of the same company, or '
  'that is switched back on while naming one. 0923.';

create trigger a_recurring_template_names_no_closed_account
  before insert or update of template, is_active on public.recurring_journals
  for each row execute function app.a_recurring_template_names_no_closed_account(
    'A recurring journal''s line');

create trigger a_recurring_template_names_no_closed_account
  before insert or update of template, is_active on public.recurring_documents
  for each row execute function app.a_recurring_template_names_no_closed_account(
    'A recurring document''s line');
