-- =====================================================================
-- iAkauntan :: 0150 bringing open invoices and bills across
--
-- 0103 imported the customer and item lists and said, in its own header,
-- what it was not doing:
--
--   Not included: importing invoices and bills. Bringing open items
--   across mid-year is the other half of a migration and it posts to the
--   ledger, which is a different problem from writing a master file: it
--   needs numbering, tax codes, an opening balance to sit against and a
--   decision about what the other side of the entry is.
--
-- This is that piece. Nobody moves onto an accounting system on the
-- first day of a financial year; they move in August with two hundred
-- unpaid invoices, and until those are here the aged receivables report
-- is a list of what has been raised since Tuesday.
--
-- ---------------------------------------------------------------------
-- The four decisions 0103 listed
--
-- **Numbering.** The old system's number, kept exactly. It is what the
-- customer quotes when they pay and what the supplier prints on the
-- statement, and a migration that renumbers everything makes the first
-- month's reconciliation impossible. Nothing is drawn from this system's
-- sequence, so the next invoice raised here is unaffected.
--
-- **Tax.** None. The SST on these documents was charged, declared and
-- very likely paid under the old system; putting it in the tax account
-- again would put it in this system's SST return again. So an opening
-- item carries one line at no tax, and the amount is what is owed.
--
-- **What the other side of the entry is.** `3900 Opening Balance
-- Equity`, created on demand rather than seeded — an organization that
-- never migrates has no use for it. Its balance is the migration's own
-- error check: bring across the receivables, the payables, the bank
-- balances and the opening trial balance, and it nets to zero. Anything
-- left in it is a piece of the old books that has not been carried over,
-- which is the one thing worth knowing and the one thing a suspense
-- posting to retained earnings would hide.
--
-- **An opening balance to sit against.** Two dates, and this is the part
-- that is easy to get wrong. The *document* keeps its original date, so
-- the aged analysis ages it properly — an invoice from November is
-- ninety days overdue and has to say so, or bringing it across achieved
-- nothing. The *ledger entry* is dated at the changeover, because the
-- trial balance moves once, on the day the books change hands, and not
-- across whatever prior periods happen to be open. One `p_as_at` for the
-- whole run.
--
-- ---------------------------------------------------------------------
-- What is imported is the outstanding amount
--
-- Not the original total. An invoice raised at 5,000 with 2,000 already
-- received is brought across as 3,000, because 3,000 is what is owed and
-- the receipt history belongs to the old system, which is where anybody
-- asking about it will look.
--
-- The column is called `outstanding_amount` for that reason: `total`
-- would be read as the invoice total by every person who ever prepares
-- one of these files, and the resulting ledger would overstate
-- receivables by everything already collected. A credit balance is
-- refused rather than negated — an amount owed *to* the customer is a
-- credit note, which is a different document with different consequences
-- and should be raised as one.
--
-- ---------------------------------------------------------------------
-- 0103's two rules, unchanged
--
-- Nothing is written unless every row is good, and the same call
-- previews and imports. Both matter more here than they did for a
-- contact list: this posts to the ledger, and a half-finished import
-- leaves a trial balance that does not agree with anything.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Reading a date out of a spreadsheet
--
-- Null means it did not parse, which the caller reports against the row.
-- Blank means the column was left empty, which is a different thing and
-- is often allowed.
-- ---------------------------------------------------------------------
create or replace function app.import_date(p_text text)
returns date
language plpgsql immutable as $$
begin
  if p_text is null or btrim(p_text) = '' then return null; end if;
  return btrim(p_text)::date;
exception when others then
  return null;
end $$;

revoke all on function app.import_date(text) from public, anon;

-- ---------------------------------------------------------------------
-- The account the other side of an opening balance goes to
--
-- Created on demand. `is_system` so it cannot be renamed into something
-- else halfway through a migration, and `retained_earnings` because that
-- is what it becomes once the migration is finished and its balance is
-- zero.
-- ---------------------------------------------------------------------
create or replace function app.opening_balance_account(p_org_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '3900' and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts (
    org_id, code, name, description, account_type, account_subtype,
    parent_id, is_group, is_system, is_active, sort_order)
  values (
    p_org_id, '3900', 'Opening Balance Equity',
    'The other side of balances brought in from a previous system. '
    'Once everything has been carried across this account is zero; '
    'whatever is left in it has not been brought over yet.',
    'equity', 'retained_earnings',
    (select id from public.accounts
      where org_id = p_org_id and code = '3000' and deleted_at is null),
    false, true, true, 3900)
  returning id into v_id;

  return v_id;
end $$;

revoke all on function app.opening_balance_account(uuid) from public, anon;

-- ---------------------------------------------------------------------
-- Validating a file of open items
--
-- One implementation for invoices and bills, because every rule below is
-- the same rule with the word customer replaced: the two differ in which
-- table already holds a document of that number and which side of a
-- contact has to exist, and in nothing else. `p_kind` is 'invoice' or
-- 'bill'.
--
-- Returns the per-row verdict as jsonb rather than a set, so the caller
-- can count what failed before deciding whether to write anything.
-- ---------------------------------------------------------------------
create or replace function app.validate_open_items(
  p_org_id uuid, p_rows jsonb, p_as_at date, p_kind text)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  r jsonb;
  i integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_seen text[] := '{}';
  v_base text;
  v_no text; v_contact text; v_date date; v_due date;
  v_amount numeric; v_currency text; v_rate numeric;
  v_contact_id uuid; v_problem text;
begin
  select base_currency into v_base
    from public.organizations where id = p_org_id;

  for r in select * from jsonb_array_elements(p_rows)
  loop
    i := i + 1;
    v_problem := null;
    v_contact_id := null;

    v_no       := app.import_text(r, 'doc_no');
    v_contact  := app.import_text(r, 'contact_code');
    v_date     := app.import_date(app.import_text(r, 'doc_date'));
    v_due      := app.import_date(app.import_text(r, 'due_date'));
    v_amount   := app.import_number(app.import_text(r, 'outstanding_amount'), null);
    v_currency := upper(coalesce(app.import_text(r, 'currency'), v_base));
    v_rate     := app.import_number(app.import_text(r, 'exchange_rate'), null);

    if v_contact is not null then
      select c.id into v_contact_id
        from public.contacts c
       where c.org_id = p_org_id and lower(c.code) = lower(v_contact)
         and c.deleted_at is null;
    end if;

    if v_no is null then
      v_problem := 'No document number. Use the number the old system '
                || 'gave it — that is what will be quoted when it is paid.';
    elsif lower(v_no) = any (v_seen) then
      v_problem := format('%s is in this file more than once.', v_no);
    elsif p_kind = 'invoice' and exists (
      select 1 from public.sales_documents d
       where d.org_id = p_org_id and d.doc_type = 'invoice'
         and lower(d.doc_no) = lower(v_no) and d.deleted_at is null)
    then
      v_problem := format('There is already an invoice %s here.', v_no);
    elsif p_kind = 'bill' and exists (
      select 1 from public.purchase_documents d
       where d.org_id = p_org_id and d.doc_type = 'bill'
         and lower(d.doc_no) = lower(v_no) and d.deleted_at is null)
    then
      v_problem := format('There is already a bill %s here.', v_no);
    elsif v_contact is null then
      v_problem := 'No contact code.';
    elsif v_contact_id is null then
      -- Named rather than created. A contact invented from an invoice
      -- has no terms, no limit and no address, and the file that has
      -- them is the one imported before this.
      v_problem := format(
        '%s is not a contact here. Import the %s list first.',
        v_contact,
        case when p_kind = 'invoice' then 'customer' else 'supplier' end);
    elsif app.import_text(r, 'doc_date') is null then
      v_problem := 'No date. It is what the ageing is measured from.';
    elsif v_date is null then
      v_problem := format('"%s" is not a date. Use YYYY-MM-DD.',
                          app.import_text(r, 'doc_date'));
    elsif v_date > p_as_at then
      -- Not an opening item at all. Letting it through would date the
      -- ledger entry before the document, which reads as a document
      -- posted before it existed.
      v_problem := format(
        'Dated %s, which is after the changeover on %s. Enter it as an '
        'ordinary document instead.', v_date, p_as_at);
    elsif app.import_text(r, 'due_date') is not null and v_due is null then
      v_problem := format('"%s" is not a date. Use YYYY-MM-DD.',
                          app.import_text(r, 'due_date'));
    elsif v_due is not null and v_due < v_date then
      v_problem := format('Due %s, before it was dated (%s).', v_due, v_date);
    elsif app.import_text(r, 'outstanding_amount') is null then
      v_problem := 'No outstanding amount. It is what is still owed, not '
                || 'the original total.';
    elsif v_amount is null then
      v_problem := format('"%s" is not an amount.',
                          app.import_text(r, 'outstanding_amount'));
    elsif v_amount <= 0 then
      -- Refused rather than flipped. A negative is either a credit note,
      -- which is its own document, or a typo, and guessing which one
      -- puts a wrong sign in somebody's receivables.
      v_problem := format(
        '%s is not an amount owed. A balance the other way is a credit '
        'note, which has to be raised as one.', v_amount);
    elsif not exists (select 1 from public.ref_currencies rc
                       where rc.code = v_currency) then
      v_problem := format('"%s" is not a currency this system knows.', v_currency);
    elsif v_currency <> v_base and app.import_text(r, 'exchange_rate') is null then
      v_problem := format(
        'No exchange rate. %s is not this company''s currency, so the '
        'rate on the day is needed to put it in the ledger.', v_currency);
    elsif app.import_text(r, 'exchange_rate') is not null
          and (v_rate is null or v_rate <= 0) then
      v_problem := format('"%s" is not an exchange rate.',
                          app.import_text(r, 'exchange_rate'));
    end if;

    if v_problem is null then
      v_seen := v_seen || lower(v_no);
    end if;

    v_results := v_results || jsonb_build_object(
      'row_no', i,
      'doc_no', coalesce(v_no, ''),
      'status', case when v_problem is null then 'ok' else 'error' end,
      'message', coalesce(v_problem, ''));
  end loop;

  return v_results;
end $$;

revoke all on function app.validate_open_items(uuid, jsonb, date, text)
  from public, anon;

-- ---------------------------------------------------------------------
-- Everything both importers do before looking at a single row
-- ---------------------------------------------------------------------
create or replace function app.check_open_item_run(p_org_id uuid, p_rows jsonb,
                                                   p_as_at date)
returns void
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_period uuid; v_status text;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'Rows must be a list' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) = 0 then
    raise exception 'There is nothing in the file' using errcode = '22023';
  end if;
  if p_as_at is null then
    raise exception
      'No changeover date. It is the day the ledger takes these balances '
      'on, and every entry in this run carries it.' using errcode = '22023';
  end if;

  -- Checked here rather than left to the posting path, which would fail
  -- on the first row after the file had already been declared good.
  v_period := app.period_for_date(p_org_id, p_as_at);
  if v_period is null then
    raise exception
      'No fiscal period covers %. Create the financial year before '
      'bringing balances into it.', p_as_at using errcode = '23514';
  end if;
  select status into v_status from public.fiscal_periods where id = v_period;
  if v_status <> 'open' then
    raise exception
      'The period containing % is %. Opening balances have to go into an '
      'open period.', p_as_at, v_status using errcode = '23514';
  end if;
end $$;

revoke all on function app.check_open_item_run(uuid, jsonb, date)
  from public, anon;

-- ---------------------------------------------------------------------
-- Open invoices
-- ---------------------------------------------------------------------
create or replace function public.import_open_invoices(
  p_org_id uuid,
  p_rows jsonb,
  p_as_at date,
  p_commit boolean default false)
returns table (row_no integer, doc_no text, status text, message text)
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r jsonb;
  v_results jsonb;
  v_bad integer;
  v_total integer;
  v_equity uuid;
  v_ar uuid;
  v_doc_id uuid; v_entry_id uuid;
  v_contact_id uuid; v_amount numeric; v_rate numeric; v_currency text;
  v_date date; v_due date; v_base text;
begin
  perform app.check_open_item_run(p_org_id, p_rows, p_as_at);

  v_results := app.validate_open_items(p_org_id, p_rows, p_as_at, 'invoice');
  select count(*) filter (where x ->> 'status' = 'error'), count(*)
    into v_bad, v_total
    from jsonb_array_elements(v_results) x;

  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file and '
      'run it again.', v_bad, v_total using errcode = '22023';
  end if;

  if p_commit then
    select base_currency into v_base
      from public.organizations where id = p_org_id;
    v_equity := app.opening_balance_account(p_org_id);

    for r in select * from jsonb_array_elements(p_rows)
    loop
      v_currency := upper(coalesce(app.import_text(r, 'currency'), v_base));
      v_rate     := coalesce(app.import_number(
                      app.import_text(r, 'exchange_rate'), null), 1);
      v_amount   := app.import_number(
                      app.import_text(r, 'outstanding_amount'), null);
      v_date     := app.import_date(app.import_text(r, 'doc_date'));
      v_due      := coalesce(app.import_date(app.import_text(r, 'due_date')),
                             v_date);

      select c.id, coalesce(c.receivable_account_id,
               (select a.id from public.accounts a
                 where a.org_id = p_org_id and a.code = '1210'))
        into v_contact_id, v_ar
        from public.contacts c
       where c.org_id = p_org_id
         and lower(c.code) = lower(app.import_text(r, 'contact_code'))
         and c.deleted_at is null;

      -- The document keeps its own date. The ledger entry below does
      -- not: see the header.
      insert into public.sales_documents (
        org_id, doc_type, doc_no, doc_date, due_date, contact_id,
        reference, currency, exchange_rate,
        subtotal, tax_amount, total_amount, base_total_amount,
        paid_amount, balance_amount, status,
        einvoice_status, notes, created_by)
      values (
        p_org_id, 'invoice', app.import_text(r, 'doc_no'), v_date, v_due,
        v_contact_id, app.import_text(r, 'reference'), v_currency, v_rate,
        v_amount, 0, v_amount, round(v_amount * v_rate, 2),
        0, v_amount, 'posted',
        -- Never sent to LHDN and never to be: it was reported, if at
        -- all, by whoever raised it.
        'not_applicable',
        'Opening balance brought forward on ' || p_as_at, auth.uid())
      returning id into v_doc_id;

      insert into public.sales_document_lines (
        org_id, document_id, line_no, line_type, description,
        quantity, unit_price, tax_rate, tax_amount,
        line_subtotal, line_total, account_id)
      values (
        p_org_id, v_doc_id, 1, 'item',
        coalesce(app.import_text(r, 'description'),
                 'Balance brought forward'),
        1, v_amount, 0, 0, v_amount, v_amount, v_equity);

      -- Two lines, no revenue and no tax. `opening_balance` rather than
      -- `sales_invoice` as the source, because a report that groups the
      -- year's sales by journal source must not find last year's here.
      v_entry_id := app.create_gl_entry_internal(
        p_org_id, p_as_at, 'opening_balance'::app.journal_source,
        jsonb_build_array(
          jsonb_build_object(
            'account_id', v_ar,
            'description', 'Opening balance ' || app.import_text(r, 'doc_no'),
            'debit', round(v_amount * v_rate, 2), 'credit', 0,
            'contact_id', v_contact_id),
          jsonb_build_object(
            'account_id', v_equity,
            'description', 'Opening balance ' || app.import_text(r, 'doc_no'),
            'debit', 0, 'credit', round(v_amount * v_rate, 2))),
        'Opening balance ' || app.import_text(r, 'doc_no'),
        'sales_documents', v_doc_id, app.import_text(r, 'reference'),
        v_currency, v_rate);

      -- Written straight in rather than posted through an update, which
      -- is also what keeps the credit-limit trigger out of this: it
      -- fires on a document being posted, and refusing to record debt
      -- somebody already owes because it exceeds the limit for new
      -- sales would be backwards.
      update public.sales_documents
         set gl_entry_id = v_entry_id, posted_at = now(), posted_by = auth.uid()
       where id = v_doc_id;
    end loop;

    v_results := (
      select jsonb_agg(jsonb_set(x, '{status}', '"imported"'))
        from jsonb_array_elements(v_results) x);
  end if;

  return query
    select (x ->> 'row_no')::integer, x ->> 'doc_no', x ->> 'status',
           x ->> 'message'
      from jsonb_array_elements(v_results) x
     order by 1;
end $$;

-- ---------------------------------------------------------------------
-- Open bills
--
-- The mirror image, with one addition: `supplier_doc_no`. Our own
-- reference and the supplier's are different numbers on a purchase, and
-- the one that matters when they chase payment is theirs.
-- ---------------------------------------------------------------------
create or replace function public.import_open_bills(
  p_org_id uuid,
  p_rows jsonb,
  p_as_at date,
  p_commit boolean default false)
returns table (row_no integer, doc_no text, status text, message text)
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r jsonb;
  v_results jsonb;
  v_bad integer;
  v_total integer;
  v_equity uuid;
  v_ap uuid;
  v_doc_id uuid; v_entry_id uuid;
  v_contact_id uuid; v_amount numeric; v_rate numeric; v_currency text;
  v_date date; v_due date; v_base text;
begin
  perform app.check_open_item_run(p_org_id, p_rows, p_as_at);

  v_results := app.validate_open_items(p_org_id, p_rows, p_as_at, 'bill');
  select count(*) filter (where x ->> 'status' = 'error'), count(*)
    into v_bad, v_total
    from jsonb_array_elements(v_results) x;

  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file and '
      'run it again.', v_bad, v_total using errcode = '22023';
  end if;

  if p_commit then
    select base_currency into v_base
      from public.organizations where id = p_org_id;
    v_equity := app.opening_balance_account(p_org_id);

    for r in select * from jsonb_array_elements(p_rows)
    loop
      v_currency := upper(coalesce(app.import_text(r, 'currency'), v_base));
      v_rate     := coalesce(app.import_number(
                      app.import_text(r, 'exchange_rate'), null), 1);
      v_amount   := app.import_number(
                      app.import_text(r, 'outstanding_amount'), null);
      v_date     := app.import_date(app.import_text(r, 'doc_date'));
      v_due      := coalesce(app.import_date(app.import_text(r, 'due_date')),
                             v_date);

      select c.id, coalesce(c.payable_account_id,
               (select a.id from public.accounts a
                 where a.org_id = p_org_id and a.code = '2110'))
        into v_contact_id, v_ap
        from public.contacts c
       where c.org_id = p_org_id
         and lower(c.code) = lower(app.import_text(r, 'contact_code'))
         and c.deleted_at is null;

      insert into public.purchase_documents (
        org_id, doc_type, doc_no, doc_date, due_date, contact_id,
        supplier_doc_no, supplier_doc_date, reference,
        currency, exchange_rate,
        subtotal, tax_amount, total_amount, base_total_amount,
        paid_amount, balance_amount, status, notes, created_by)
      values (
        p_org_id, 'bill', app.import_text(r, 'doc_no'), v_date, v_due,
        v_contact_id,
        coalesce(app.import_text(r, 'supplier_doc_no'),
                 app.import_text(r, 'doc_no')),
        v_date, app.import_text(r, 'reference'),
        v_currency, v_rate,
        v_amount, 0, v_amount, round(v_amount * v_rate, 2),
        0, v_amount, 'posted',
        'Opening balance brought forward on ' || p_as_at, auth.uid())
      returning id into v_doc_id;

      insert into public.purchase_document_lines (
        org_id, document_id, line_no, line_type, description,
        quantity, unit_price, tax_rate, tax_amount,
        line_subtotal, line_total, account_id)
      values (
        p_org_id, v_doc_id, 1, 'item',
        coalesce(app.import_text(r, 'description'),
                 'Balance brought forward'),
        1, v_amount, 0, 0, v_amount, v_amount, v_equity);

      v_entry_id := app.create_gl_entry_internal(
        p_org_id, p_as_at, 'opening_balance'::app.journal_source,
        jsonb_build_array(
          jsonb_build_object(
            'account_id', v_equity,
            'description', 'Opening balance ' || app.import_text(r, 'doc_no'),
            'debit', round(v_amount * v_rate, 2), 'credit', 0),
          jsonb_build_object(
            'account_id', v_ap,
            'description', 'Opening balance ' || app.import_text(r, 'doc_no'),
            'debit', 0, 'credit', round(v_amount * v_rate, 2),
            'contact_id', v_contact_id)),
        'Opening balance ' || app.import_text(r, 'doc_no'),
        'purchase_documents', v_doc_id, app.import_text(r, 'reference'),
        v_currency, v_rate);

      update public.purchase_documents
         set gl_entry_id = v_entry_id, posted_at = now(), posted_by = auth.uid()
       where id = v_doc_id;
    end loop;

    v_results := (
      select jsonb_agg(jsonb_set(x, '{status}', '"imported"'))
        from jsonb_array_elements(v_results) x);
  end if;

  return query
    select (x ->> 'row_no')::integer, x ->> 'doc_no', x ->> 'status',
           x ->> 'message'
      from jsonb_array_elements(v_results) x
     order by 1;
end $$;

revoke all on function public.import_open_invoices(uuid, jsonb, date, boolean)
  from public, anon;
revoke all on function public.import_open_bills(uuid, jsonb, date, boolean)
  from public, anon;
grant execute on function public.import_open_invoices(uuid, jsonb, date, boolean)
  to authenticated;
grant execute on function public.import_open_bills(uuid, jsonb, date, boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- What is left in the suspense account
--
-- The migration's own arithmetic, and the reason `3900` exists rather
-- than the receivables going straight to retained earnings. A non-zero
-- balance here is not an error in this software — it is the part of the
-- old books that has not been carried across yet, and it is worth
-- saying so plainly rather than leaving somebody to find it in a trial
-- balance six weeks later.
-- ---------------------------------------------------------------------
create or replace function public.report_opening_balance_suspense(p_org_id uuid)
returns table (balance numeric, entries integer, settled boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_account uuid;
begin
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select id into v_account from public.accounts
   where org_id = p_org_id and code = '3900' and deleted_at is null;

  -- Nothing has ever been brought across, which is not the same as a
  -- migration that has balanced. Reported as settled with no entries so
  -- the caller can tell the two apart.
  if v_account is null then
    return query select 0::numeric, 0, true;
    return;
  end if;

  return query
    select round(coalesce(sum(l.credit - l.debit), 0), 2),
           count(*)::integer,
           round(coalesce(sum(l.credit - l.debit), 0), 2) = 0
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
     where l.org_id = p_org_id and l.account_id = v_account
       and e.status = 'posted';
end $$;

revoke all on function public.report_opening_balance_suspense(uuid)
  from public, anon;
grant execute on function public.report_opening_balance_suspense(uuid)
  to authenticated;
