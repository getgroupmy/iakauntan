-- =====================================================================
-- iAkauntan :: 0888 a reversal never comes before what it undoes
--
-- `reverse_gl_entry` asked that the reversal's period was open and
-- nothing about its date against the journal it undoes. The Journals
-- screen's "Reverse" offers a date up to a year back. And the voids of
-- a sales document, a deposit and a contra reverse at today -- so a
-- document dated ahead, voided now, is undone before it was done.
--
-- Measured on 14 October 2026, locally, as an accountant with the role
-- `authenticated`: a journal dated 14 October reversed on 4 October;
-- and an invoice dated 3 November, voided on 14 October, its reversal
-- dated 14 October -- negative revenue in October, the sale in
-- November.
--
-- Production held one reversal on 14 October, dated on or after its
-- original.
--
-- Answered "never before what it undoes":
--
--   * `reverse_gl_entry` refuses a date before the original journal's,
--     naming it;
--   * `void_sales_document`, `void_deposit` and `void_contra` reverse on
--     the later of today and the original journal's date, so voiding a
--     document dated ahead still works, and is undone on its own day.
--
-- The other callers already pass a day no earlier than the original:
-- `cancel_pdc` today (the cheque's journal is dated when it was
-- received), `unmatch_bank_transaction` and `void_bank_transfer` the
-- original's own date.
--
-- One exception, found by the suite after the question was answered:
-- `revalue_foreign_balances` takes the standing revaluation back at the
-- new run's date, and `fx_shapes.sql` runs March and then February on
-- purpose -- "what a bookkeeper does when they reopen a prior month" --
-- so March's revaluation is taken back on 28 February. A revaluation is
-- re-measured, not undone, and its journals (`source =
-- 'fx_revaluation'`) are left out of the rule rather than that rerun
-- broken.
--
-- Each body is `pg_get_functiondef` of what was applied, with the
-- change marked 0888.
-- =====================================================================

-- reverse_gl_entry
CREATE OR REPLACE FUNCTION public.reverse_gl_entry(p_entry_id uuid, p_date date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_entry public.gl_entries;
  v_new_id uuid;
  v_period_id uuid;
  v_status text;
  v_on date := coalesce(p_date, app.today());
begin
  select * into v_entry from public.gl_entries where id = p_entry_id;
  if not found then raise exception 'Journal % not found', p_entry_id; end if;
  if not app.can_post(v_entry.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_entry.status <> 'posted' then
    raise exception 'Only posted journals can be reversed' using errcode = '22023';
  end if;

  -- Reversing twice would contra the contra and put the entry back,
  -- which is the shape of the bug this migration exists to fix.
  if exists (select 1 from public.gl_entries r
              where r.reversed_entry_id = p_entry_id and r.status = 'posted') then
    raise exception 'Journal % has already been reversed', v_entry.entry_no
      using errcode = '22023';
  end if;

  -- 0888: a reversal undoes a journal, and cannot come before it. Dated
  -- earlier, the period between carries the undoing without the thing
  -- undone -- negative revenue in one month, the sale in the next.
  -- A foreign-exchange revaluation is the one exception: it is not
  -- undone but re-measured, and a run for an earlier month takes the
  -- standing one back on that month's day (`fx_shapes.sql`, "a rerun
  -- out of order").
  if v_on < v_entry.entry_date and v_entry.source <> 'fx_revaluation' then
    raise exception
      'Journal % is dated %, and a reversal cannot come before what it '
      'undoes. Date it on or after that day.', v_entry.entry_no,
      to_char(v_entry.entry_date, 'DD Mon YYYY') using errcode = '23514';
  end if;

  v_period_id := app.period_for_date(v_entry.org_id, v_on);
  if v_period_id is null then
    raise exception
      'No fiscal period covers %. Create the fiscal year before posting to it.',
      v_on using errcode = '23514';
  end if;
  select status into v_status from public.fiscal_periods where id = v_period_id;
  if v_status <> 'open' then
    raise exception 'Fiscal period for % is %', v_on, v_status using errcode = '23514';
  end if;

  insert into public.gl_entries (
    org_id, entry_no, entry_date, fiscal_period_id, source, source_table, source_id,
    description, reference, currency, exchange_rate, status, is_reversal,
    reversed_entry_id, posted_at, posted_by, created_by
  ) values (
    v_entry.org_id, app.next_document_number_internal(v_entry.org_id, 'journal'),
    v_on, v_period_id, v_entry.source,
    v_entry.source_table, v_entry.source_id,
    'Reversal of ' || v_entry.entry_no, v_entry.reference,
    v_entry.currency, v_entry.exchange_rate, 'posted', true, v_entry.id,
    now(), auth.uid(), auth.uid()
  ) returning id into v_new_id;

  insert into public.gl_lines (
    org_id, entry_id, line_no, account_id, description, debit, credit,
    currency, exchange_rate, contact_id, item_id, tax_code_id)
  select org_id, v_new_id, line_no, account_id,
         'Reversal: ' || coalesce(description, ''),
         credit, debit, currency, exchange_rate, contact_id, item_id, tax_code_id
    from public.gl_lines where entry_id = p_entry_id;

  -- The original stays posted. The pair nets to zero, and both halves
  -- are on the page where an auditor can see what happened.
  return v_new_id;
end; $function$;

-- void_sales_document
CREATE OR REPLACE FUNCTION public.void_sales_document(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_doc public.sales_documents;
begin
  select * into v_doc from public.sales_documents where id = p_id;
  if not found then raise exception 'Document % not found', p_id; end if;
  if not app.can_post(v_doc.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_doc.paid_amount > 0 then
    raise exception 'Cannot void %: payments have been applied', v_doc.doc_no;
  end if;
  -- 0803. And asked of the e-Invoices themselves, as 0770 asks for one
  -- LHDN has not yet answered: the column above is a copy, and a copy
  -- is only as good as whoever last wrote it.
  if v_doc.einvoice_status = 'valid'
     or exists (select 1 from public.einvoice_documents e
                 where e.org_id = v_doc.org_id
                   and e.source_table = 'sales_documents'
                   and e.source_id = v_doc.id
                   and e.status = 'valid') then
    raise exception 'Cannot void %: cancel the e-Invoice with LHDN first', v_doc.doc_no;
  end if;
  -- 0770. Read from the e-Invoices themselves. One LHDN has and has not
  -- yet answered may come back valid, which is a cancellation of its
  -- own; voiding under it would leave LHDN holding a sale we do not.
  if exists (select 1 from public.einvoice_documents e
              where e.org_id = v_doc.org_id
                and e.source_table = 'sales_documents'
                and e.source_id = v_doc.id
                and e.status = 'submitted') then
    raise exception
      'Cannot void %: its e-Invoice is with LHDN awaiting validation. Wait '
      'for the answer, and if it is accepted, cancel it with LHDN first.',
      v_doc.doc_no
      using errcode = '55006';
  end if;

  if v_doc.gl_entry_id is not null then
    perform public.reverse_gl_entry(v_doc.gl_entry_id,
      -- 0888: today, or the day it was posted if that is still to come.
      greatest(app.today(), (select e.entry_date from public.gl_entries e
                              where e.id = v_doc.gl_entry_id)));
  end if;

  -- 0770. What LHDN never accepted is withdrawn. The submit sweep sends
  -- 'draft', 'queued', 'failed' and 'invalid' without looking at the
  -- invoice, so left as it was, an e-Invoice for this sale would still
  -- have gone -- and come back valid for a sale that is void.
  update public.einvoice_documents e
     set status = 'cancelled',
         cancelled_at = now(),
         cancellation_reason = 'Withdrawn before LHDN accepted it: '
           || v_doc.doc_no || ' was voided'
           || coalesce(' (' || nullif(btrim(p_reason), '') || ')', '')
   where e.org_id = v_doc.org_id
     and e.source_table = 'sales_documents'
     and e.source_id = v_doc.id
     and e.status in ('draft', 'queued', 'failed', 'invalid');

  update public.sales_documents
     set status = 'void',
         internal_notes = coalesce(internal_notes || E'\n', '') || 'Voided: ' || coalesce(p_reason, '')
   where id = p_id;
end;
$function$;

-- void_deposit
CREATE OR REPLACE FUNCTION public.void_deposit(p_id uuid, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_note public.deposit_notes;
  v_rev  uuid;
begin
  select * into v_note from public.deposit_notes where id = p_id;
  if v_note.id is null then
    raise exception 'No such deposit.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_note.org_id,
        case when v_note.kind = 'customer' then 'sales' else 'purchases' end) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_note.status = 'void' then
    raise exception 'That deposit is already void.' using errcode = '23514';
  end if;
  if v_note.balance_amount <> v_note.amount then
    raise exception
      'Deposit % has already been used: % applied, % given back, % kept. '
      'Undo those first.',
      v_note.deposit_no, v_note.applied_amount, v_note.refunded_amount,
      v_note.forfeited_amount using errcode = '23514';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'Say why.' using errcode = '23514';
  end if;

  if v_note.gl_entry_id is not null then
    v_rev := public.reverse_gl_entry(v_note.gl_entry_id,
      -- 0888: today, or the day it was posted if that is still to come.
      greatest(app.today(), (select e.entry_date from public.gl_entries e
                              where e.id = v_note.gl_entry_id)));
  end if;

  if v_note.bank_account_id is not null then
    update public.bank_accounts
       set current_balance = current_balance
             + case when v_note.kind = 'customer' then -v_note.amount
                    else v_note.amount end
     where id = v_note.bank_account_id;
  end if;

  update public.deposit_notes
     set status = 'void', void_entry_id = v_rev, void_reason = trim(p_reason),
         voided_at = now(), voided_by = auth.uid(), balance_amount = 0
   where id = p_id;
  return v_rev;
end;
$function$;

-- void_contra
CREATE OR REPLACE FUNCTION public.void_contra(p_id uuid, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_note public.contra_notes;
  v_rev  uuid;
begin
  select * into v_note from public.contra_notes where id = p_id;
  if v_note.id is null then
    raise exception 'No such contra.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_note.org_id, 'sales')
     or not app.can_write_module(v_note.org_id, 'purchases') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_note.status = 'void' then
    raise exception 'That contra is already void.' using errcode = '23514';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'Say why. A contra reversed without a reason is a '
      'question somebody asks later and nobody can answer.'
      using errcode = '23514';
  end if;

  delete from public.payment_allocations where contra_id = p_id;

  if v_note.gl_entry_id is not null then
    v_rev := public.reverse_gl_entry(v_note.gl_entry_id,
      -- 0888: today, or the day it was posted if that is still to come.
      greatest(app.today(), (select e.entry_date from public.gl_entries e
                              where e.id = v_note.gl_entry_id)));
  end if;

  update public.contra_notes
     set status = 'void', void_entry_id = v_rev, void_reason = trim(p_reason),
         voided_at = now(), voided_by = auth.uid()
   where id = p_id;
  return v_rev;
end;
$function$;
