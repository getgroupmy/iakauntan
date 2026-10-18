-- =====================================================================
-- iAkauntan :: 0912 an account fits where it is used
--
-- Posting takes its accounts from what a document names, and checks
-- none of them. `app.post_sales_document_internal` debits the
-- receivable to the customer's `receivable_account_id`, or 1210;
-- `app.resolve_account` gives each line the account the line names,
-- or its item's, or the default. Bills do the same with the supplier's
-- `payable_account_id`.
--
-- Measured on 18 October 2026, locally, as the owner with the role
-- `authenticated`, each on an invoice of RM1,000:
--
--   * the customer's receivable account set to the bank (1120): posted
--     1120 1,000 / 4100 -1,000 -- money in the bank that never came,
--     no receivable, and the invoice still owing RM1,000;
--   * a line coded to the bank: 1120 -1,000 / 1210 1,000, the bank's
--     ledger balance down with no transaction behind it;
--   * a line coded to 1210 itself: 1210 1,000 and 1210 -1,000, the
--     control account at nothing while the invoice says it is owed.
--
-- The app keeps the first in its place -- `control_account.dart` offers
-- a contact only active, non-heading accounts of the receivable or
-- payable subtype, and its own comment says why -- but only in Dart.
-- The app sets no account on a line.
--
-- Production on 18 October: two customers with a receivable account of
-- their own, both receivables accounts; every line and item account a
-- revenue or expense account.
--
-- Answered "contacts and lines", for every writer:
--
--   * a contact's receivable account is an active receivables account
--     that is not a heading, and its payable account the same for
--     payables -- the app's rule, now the database's;
--   * a sales or purchase document line, and an item's sales, purchase,
--     stock and cost-of-sales accounts, may not be a bank, cash,
--     receivable or payable account, nor a heading. Money reaches a bank
--     or a till through a receipt or a payment, and a receivable or a
--     payable through the document it belongs to. Any other account
--     stands: a customer deposit, a fixed asset sold, a cost recharged.
--
-- `0765` already refuses a heading in the ledger, when a line on one is
-- posted. This refuses it when the line is written, where the person
-- who chose it is still looking at it, and for a contact, which posts
-- nothing of its own.
--
-- Asked when the account is set or changed, not on every write: a row
-- that already names one is still written. That has to be decided in
-- the function and not by the trigger's column list, because the app
-- saves a contact whole -- `Contact.toJson` sends both control accounts
-- back with every edit. SECURITY DEFINER because it reads the account,
-- and a writer who may not read the chart must not be waved through by
-- reading nothing.
-- =====================================================================

create or replace function app.an_account_fits_where_it_is_used()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_arg   text;
  v_col   text;
  v_rule  text;
  v_label text;
  v_id    uuid;
  v_acct  public.accounts;
  v_what  text;
  v_want  text;
  v_new   jsonb := to_jsonb(new);
  v_old   jsonb;
begin
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
  end if;

  -- Each argument is `column:rule:what it is called`.
  foreach v_arg in array tg_argv loop
    v_col   := split_part(v_arg, ':', 1);
    v_rule  := split_part(v_arg, ':', 2);
    v_label := split_part(v_arg, ':', 3);
    v_id    := (v_new ->> v_col)::uuid;
    continue when v_id is null;
    continue when tg_op = 'UPDATE'
                  and (v_new -> v_col) is not distinct from (v_old -> v_col);

    select * into v_acct from public.accounts where id = v_id;
    v_what := case
      when v_acct.is_group then 'a heading'
      when not v_acct.is_active then 'retired'
      when left(v_acct.account_subtype::text, 1) in ('a', 'e', 'i', 'o', 'u')
        then 'an ' || replace(v_acct.account_subtype::text, '_', ' ') || ' account'
      else 'a ' || replace(v_acct.account_subtype::text, '_', ' ') || ' account'
    end;

    if v_rule in ('receivable', 'payable') then
      v_want := case v_rule when 'receivable' then 'accounts_receivable'
                            else 'accounts_payable' end;
      if v_acct.is_group or not v_acct.is_active
         or v_acct.account_subtype::text is distinct from v_want then
        raise exception
          '% is an active % account that is not a heading, and % % is %. '
          'The aged listing reconciles against it, and every document '
          'for this party posts its balance there.',
          v_label, case v_rule when 'receivable' then 'receivables' else 'payables' end,
          v_acct.code, v_acct.name, v_what
          using errcode = '23514';
      end if;
    elsif v_acct.is_group then
      raise exception
        '% may not be % %, which is a heading: nothing posts to a heading, '
        'only to the accounts under it.',
        v_label, v_acct.code, v_acct.name
        using errcode = '23514';
    elsif v_acct.account_subtype in ('bank', 'cash') then
      raise exception
        '% may not be % %, %: money reaches a bank or a till through a '
        'receipt or a payment, where the reconciliation can see it.',
        v_label, v_acct.code, v_acct.name, v_what
        using errcode = '23514';
    elsif v_acct.account_subtype in ('accounts_receivable', 'accounts_payable') then
      raise exception
        '% may not be % %, %: a receivable or a payable is posted by the '
        'document it belongs to, against its customer or supplier, so the '
        'aged listing still agrees with the account.',
        v_label, v_acct.code, v_acct.name, v_what
        using errcode = '23514';
    end if;
  end loop;
  return new;
end;
$$;

revoke all on function app.an_account_fits_where_it_is_used() from public, anon, authenticated;

comment on function app.an_account_fits_where_it_is_used() is
  'Refuses, for every writer, a contact''s receivable or payable account '
  'that is not an active receivables or payables account, and a document '
  'line''s or an item''s account that is a heading or a bank, cash, '
  'receivable or payable account. Asked when the account is set or '
  'changed. 0912.';

create trigger an_account_fits_where_it_is_used
  before insert or update of receivable_account_id, payable_account_id on public.contacts
  for each row execute function app.an_account_fits_where_it_is_used(
    'receivable_account_id:receivable:A customer''s receivable account',
    'payable_account_id:payable:A supplier''s payable account');

create trigger an_account_fits_where_it_is_used
  before insert or update of account_id on public.sales_document_lines
  for each row execute function app.an_account_fits_where_it_is_used(
    'account_id:posting:A sales document line''s account');

create trigger an_account_fits_where_it_is_used
  before insert or update of account_id on public.purchase_document_lines
  for each row execute function app.an_account_fits_where_it_is_used(
    'account_id:posting:A purchase document line''s account');

create trigger an_account_fits_where_it_is_used
  before insert or update of sales_account_id, purchase_account_id,
                             inventory_account_id, cogs_account_id on public.items
  for each row execute function app.an_account_fits_where_it_is_used(
    'sales_account_id:posting:An item''s sales account',
    'purchase_account_id:posting:An item''s purchase account',
    'inventory_account_id:posting:An item''s stock account',
    'cogs_account_id:posting:An item''s cost of sales account');
