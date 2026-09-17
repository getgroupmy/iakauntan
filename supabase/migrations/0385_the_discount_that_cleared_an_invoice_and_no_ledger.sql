-- =====================================================================
-- iAkauntan :: 0385 the discount that cleared an invoice and no ledger
--
-- `payment_allocations.discount_amount` has been a column since `0005`.
-- `payment_terms.discount_percent` and `discount_days` have been
-- columns since `0003`. Nothing writes any of them, and the seeded
-- terms in `0012` — NET7 through NET90 — are eight rows of a settlement
-- discount scheme that has never existed.
--
-- That is the absence. Underneath it is something worse.
--
-- ---------------------------------------------------------------------
-- The two halves that do not agree
--
-- `app.apply_allocation` in `0009` clears the invoice by the cash **and
-- the discount**:
--
--     select coalesce(sum(amount + discount_amount), 0) into v_paid
--       from public.payment_allocations where invoice_id = v_invoice_id;
--
-- `app.post_receipt_internal` credits the receivable by the cash alone.
--
-- So an allocation carrying a discount marks the invoice `completed`
-- with a balance of nothing, takes it off the aged receivables, and
-- leaves the receivable **control account in the general ledger**
-- overstated by exactly the discount — for ever. The subsidiary ledger
-- says the customer owes nothing; the trial balance says they owe two
-- hundred ringgit; and the difference is a number nobody can place,
-- because there is no document anywhere that mentions it.
--
-- This is the shape `0371` named. Not a feature missing: a control that
-- looks applied. Every screen agrees the invoice is settled. Only the
-- ledger disagrees, and it disagrees quietly.
--
-- The rule is enforced where it cannot be got round: an allocation may
-- not carry a discount unless it names the journal that posted it.
--
-- ---------------------------------------------------------------------
-- Where a settlement discount goes
--
-- Dr Sales Returns and Discounts (4300), Cr Receivable — a reduction of
-- revenue rather than an expense, which is what a discount for early
-- settlement is. On the purchase side, Dr Payable, Cr Other Income
-- (4900): money the company did not have to pay.
--
-- The tax is deliberately left alone, and this is the part worth being
-- explicit about. Under the Sales Tax Act 2018 and the Service Tax Act
-- 2018 the tax charged is the tax on the invoice; a discount taken
-- afterwards changes the taxable value only if a credit note is issued
-- for it, which is a separate document with its own e-Invoice
-- consequences. Silently reducing the output tax here would understate
-- what the company has already told LHDN it charged. So the discount is
-- posted against revenue at its gross amount and the tax account is not
-- touched. A firm that wants the tax back raises a credit note, which
-- `0160` already does.
--
-- ---------------------------------------------------------------------
-- And the terms themselves
--
-- `payment_terms.days` and `term_type` were a picker with no
-- consequence: a document's `due_date` was typed, and choosing NET30
-- changed nothing about when the invoice fell due or when it appeared
-- on the ageing. `app.due_date_from_terms` derives it, and a document
-- saved without one now gets the one its terms imply.
--
-- Derived only when absent. A due date somebody typed is a date they
-- negotiated, and overwriting it with the standard terms would be the
-- software correcting a customer agreement it knows nothing about.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What is already there
-- ---------------------------------------------------------------------
do $$
declare v_n integer; v_total numeric;
begin
  select count(*), coalesce(sum(discount_amount), 0)
    into v_n, v_total
    from public.payment_allocations where discount_amount > 0;
  if v_n > 0 then
    raise notice
      '0385: % allocation(s) carry a discount totalling %, and none of '
      'it was ever posted. The receivable and payable control accounts '
      'are out by that much against the documents. A journal is needed '
      'to bring them back; this migration stops it happening again but '
      'cannot know which account the old ones belonged to.',
      v_n, to_char(v_total, 'FM999G999G990D00');
  end if;
end $$;

-- The journal that posted a discount, so the two halves cannot come
-- apart again. Nullable because every allocation without a discount has
-- nothing to post.
alter table public.payment_allocations
  add column if not exists discount_entry_id uuid
  references public.gl_entries (id);

-- ---------------------------------------------------------------------
-- A discount that is not posted is not a discount
-- ---------------------------------------------------------------------
create or replace function app.allocation_discount_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  if coalesce(new.discount_amount, 0) = 0 then return new; end if;

  -- Judging the change: rows that already carry an unposted discount
  -- stay editable, because they are the damage this migration reports
  -- and somebody has to be able to correct them.
  if tg_op = 'UPDATE'
     and coalesce(old.discount_amount, 0) = coalesce(new.discount_amount, 0)
  then
    return new;
  end if;

  if new.discount_entry_id is null then
    raise exception
      'A settlement discount clears the invoice, so it has to clear the '
      'receivable too. `app.apply_allocation` takes it off the document '
      'and nothing takes it off the ledger, which leaves the control '
      'account overstated by this amount for ever. Use '
      'allocate_with_discount.' using errcode = '23514';
  end if;
  if new.discount_amount < 0 then
    raise exception 'A discount is not a negative discount.'
      using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists payment_allocations_discount_ck
  on public.payment_allocations;
create trigger payment_allocations_discount_ck
  before insert or update on public.payment_allocations
  for each row execute function app.allocation_discount_guard();

-- ---------------------------------------------------------------------
-- When the invoice falls due, given its terms
-- ---------------------------------------------------------------------
create or replace function app.due_date_from_terms(
  p_term_id uuid,
  p_doc_date date)
returns date
language plpgsql
stable
set search_path = public, app, pg_temp
as $$
declare v_t public.payment_terms;
begin
  if p_doc_date is null then return null; end if;
  if p_term_id is null then return null; end if;
  select * into v_t from public.payment_terms where id = p_term_id;
  if v_t.id is null then return null; end if;

  return case v_t.term_type
    -- Cash on delivery and prepaid fall due on the day. The days
    -- column is nought on both in `0012`'s seed, but a company that
    -- edits it to thirty has not made cash on delivery mean credit.
    when 'cod'     then p_doc_date
    when 'prepaid' then p_doc_date
    -- End of month plus the days: the whole point of EOM terms is that
    -- everything invoiced in a month falls due together.
    when 'eom'     then (date_trunc('month', p_doc_date)
                          + interval '1 month - 1 day')::date + v_t.days
    else p_doc_date + v_t.days
  end;
end $$;

-- The last day the discount can be taken, and what it is worth.
create or replace function app.settlement_discount_of(
  p_term_id uuid,
  p_doc_date date,
  p_amount numeric,
  out deadline date,
  out amount numeric)
language plpgsql
stable
set search_path = public, app, pg_temp
as $$
declare v_t public.payment_terms;
begin
  deadline := null; amount := 0;
  if p_term_id is null or p_doc_date is null then return; end if;
  select * into v_t from public.payment_terms where id = p_term_id;
  if v_t.id is null then return; end if;
  -- Both halves, or neither. "2% if you pay early" with no day named is
  -- not a term anybody could act on, and a day with no percentage is
  -- not a discount.
  if coalesce(v_t.discount_percent, 0) <= 0
     or coalesce(v_t.discount_days, 0) <= 0 then
    return;
  end if;
  deadline := p_doc_date + v_t.discount_days;
  amount   := round(coalesce(p_amount, 0) * v_t.discount_percent / 100, 2);
end $$;

-- ---------------------------------------------------------------------
-- Filling in the date the terms imply
-- ---------------------------------------------------------------------
create or replace function app.document_due_date_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- Only when it is absent. A due date somebody typed is a date they
  -- negotiated, and overwriting it with the standard terms would be
  -- the software correcting an agreement it knows nothing about.
  if new.due_date is null then
    new.due_date := app.due_date_from_terms(new.payment_term_id,
                                            new.doc_date);
  end if;
  if new.due_date is not null and new.doc_date is not null
     and new.due_date < new.doc_date then
    raise exception
      'A document cannot fall due before it was raised. % is earlier '
      'than %.', to_char(new.due_date, 'DD Mon YYYY'),
      to_char(new.doc_date, 'DD Mon YYYY') using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists sales_documents_due_date_ck on public.sales_documents;
create trigger sales_documents_due_date_ck
  before insert or update on public.sales_documents
  for each row execute function app.document_due_date_guard();

drop trigger if exists purchase_documents_due_date_ck
  on public.purchase_documents;
create trigger purchase_documents_due_date_ck
  before insert or update on public.purchase_documents
  for each row execute function app.document_due_date_guard();

-- ---------------------------------------------------------------------
-- What the customer could still save
-- ---------------------------------------------------------------------
create or replace function public.settlement_discount_available(
  p_document uuid,
  p_as_at    date default null)
returns table (
  deadline    date,
  discount    numeric,
  pay_now     numeric,
  still_open  boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org     uuid;
  v_terms   uuid;
  v_date    date;
  v_total   numeric;
  v_balance numeric;
  v_as_at   date := coalesce(p_as_at,
                       (now() at time zone 'Asia/Kuala_Lumpur')::date);
  v_d       record;
begin
  select org_id, payment_term_id, doc_date, total_amount, balance_amount
    into v_org, v_terms, v_date, v_total, v_balance
    from public.sales_documents where id = p_document;
  if v_org is null then
    select org_id, payment_term_id, doc_date, total_amount, balance_amount
      into v_org, v_terms, v_date, v_total, v_balance
      from public.purchase_documents where id = p_document;
  end if;
  if v_org is null then
    raise exception 'No such document.' using errcode = 'P0002';
  end if;
  if not app.can_read_ledger(v_org) then
    raise exception 'not permitted to read this document'
      using errcode = '42501';
  end if;

  -- On what is still outstanding, not on the invoice total. A part-paid
  -- invoice offers a discount on the part that is left, or the customer
  -- is being offered a discount twice on the same money.
  select * into v_d from app.settlement_discount_of(v_terms, v_date,
    greatest(coalesce(v_balance, 0), 0));

  deadline   := v_d.deadline;
  discount   := v_d.amount;
  still_open := v_d.deadline is not null and v_d.deadline >= v_as_at
                and coalesce(v_balance, 0) > 0;
  pay_now    := case when still_open
                     then round(coalesce(v_balance, 0) - v_d.amount, 2)
                     else coalesce(v_balance, 0) end;
  return next;
end $$;

-- ---------------------------------------------------------------------
-- Taking it, and putting it in the ledger
-- ---------------------------------------------------------------------
create or replace function public.allocate_with_discount(
  p_receipt   uuid,
  p_invoice   uuid,
  p_amount    numeric,
  p_discount  numeric default null,
  p_as_at     date default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rcp      public.receipts;
  v_inv      public.sales_documents;
  v_offer    record;
  v_discount numeric(18, 2);
  v_ar       uuid;
  v_disc_ac  uuid;
  v_entry    uuid;
  v_alloc    uuid;
  v_as_at    date := coalesce(p_as_at,
                       (now() at time zone 'Asia/Kuala_Lumpur')::date);
begin
  select * into v_rcp from public.receipts where id = p_receipt;
  if v_rcp.id is null then
    raise exception 'No such receipt.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_rcp.org_id) then
    raise exception 'not permitted to allocate a receipt'
      using errcode = '42501';
  end if;

  select * into v_inv from public.sales_documents where id = p_invoice;
  if v_inv.id is null or v_inv.org_id <> v_rcp.org_id then
    raise exception 'No such invoice.' using errcode = 'P0002';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'An allocation is of something.' using errcode = '23514';
  end if;

  select * into v_offer from app.settlement_discount_of(
    v_inv.payment_term_id, v_inv.doc_date,
    greatest(coalesce(v_inv.balance_amount, 0), 0));

  v_discount := round(coalesce(p_discount, 0), 2);
  if v_discount > 0 then
    if v_offer.deadline is null then
      raise exception
        '% is on terms that offer no settlement discount. Set one on the '
        'payment term, or raise a credit note if the reduction is '
        'something else.', v_inv.doc_no using errcode = '23514';
    end if;
    if v_offer.deadline < v_as_at then
      raise exception
        'The discount on % ran out on %. It is not a discount any more, '
        'and taking it now would clear an invoice the customer has not '
        'paid.', v_inv.doc_no, to_char(v_offer.deadline, 'DD Mon YYYY')
        using errcode = '23514';
    end if;
    if v_discount > v_offer.amount then
      raise exception
        'The terms on % allow % as a settlement discount, not %.',
        v_inv.doc_no,
        to_char(v_offer.amount, 'FM999G999G990D00'),
        to_char(v_discount, 'FM999G999G990D00') using errcode = '23514';
    end if;
    if round(p_amount + v_discount, 2)
       > round(coalesce(v_inv.balance_amount, 0), 2) then
      raise exception
        'The cash and the discount come to more than % still owes.',
        v_inv.doc_no using errcode = '23514';
    end if;
  end if;

  if v_discount > 0 then
    select coalesce(c.receivable_account_id,
                    (select id from public.accounts
                      where org_id = v_rcp.org_id and code = '1210'))
      into v_ar from public.contacts c where c.id = v_inv.contact_id;
    select id into v_disc_ac from public.accounts
     where org_id = v_rcp.org_id and code = '4300';
    if v_ar is null or v_disc_ac is null then
      raise exception
        'No receivable (1210) or sales discount (4300) account in the '
        'chart.' using errcode = 'P0002';
    end if;

    -- Dr Sales Returns and Discounts, Cr Receivable. A reduction of
    -- revenue, which is what a discount for early settlement is.
    --
    -- The tax is not touched. What was charged is what the invoice
    -- said and what LHDN was told; changing the taxable value takes a
    -- credit note, and quietly reducing the output tax here would
    -- understate what the company has already declared.
    v_entry := public.create_gl_entry(
      v_rcp.org_id, v_as_at, 'receipt'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_disc_ac,
          'description', 'Settlement discount on ' || v_inv.doc_no,
          'debit', v_discount, 'credit', 0),
        jsonb_build_object('account_id', v_ar,
          'description', 'Settlement discount on ' || v_inv.doc_no,
          'debit', 0, 'credit', v_discount,
          'contact_id', v_inv.contact_id)),
      'Settlement discount on ' || v_inv.doc_no,
      'sales_documents', v_inv.id, v_rcp.receipt_no,
      app.base_currency(v_rcp.org_id), 1);
  end if;

  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount, discount_amount,
     discount_entry_id, allocated_by)
  values (v_rcp.org_id, p_receipt, p_invoice, round(p_amount, 2),
          v_discount, v_entry, auth.uid())
  returning id into v_alloc;

  return v_alloc;
end $$;

-- ---------------------------------------------------------------------
revoke all on function
  public.settlement_discount_available(uuid, date) from public, anon;
revoke all on function public.allocate_with_discount(
  uuid, uuid, numeric, numeric, date) from public, anon;

grant execute on function
  public.settlement_discount_available(uuid, date) to authenticated;
grant execute on function public.allocate_with_discount(
  uuid, uuid, numeric, numeric, date) to authenticated;

comment on function app.allocation_discount_guard() is
  'A settlement discount clears the invoice through '
  '`app.apply_allocation` and nothing ever cleared the receivable, so '
  'the control account was left overstated by it permanently. An '
  'allocation now cannot carry a discount without naming the journal '
  'that posted it.';
comment on function app.due_date_from_terms(uuid, date) is
  '`payment_terms.days` and `term_type` were a picker with no '
  'consequence: the due date was typed, so choosing NET30 changed '
  'nothing about the ageing.';
comment on function public.allocate_with_discount(
  uuid, uuid, numeric, numeric, date) is
  'Takes a settlement discount and posts it: Dr 4300, Cr receivable. '
  'The tax is untouched — reducing the taxable value takes a credit '
  'note, and doing it here would understate what LHDN was told.';
