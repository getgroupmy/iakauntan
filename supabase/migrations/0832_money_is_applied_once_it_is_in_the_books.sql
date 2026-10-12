-- =====================================================================
-- iAkauntan :: 0832 money is applied once it is in the books
--
-- `allocate_with_discount` and `allocate_payment_with_discount` set a
-- receipt against an invoice, or a supplier payment against a bill, and
-- `app.apply_allocation` moves the document's paid figure and status.
-- Neither asked whether either side had been posted. And the receipt
-- and payment screens recorded a settlement as three requests -- insert
-- a draft, apply it, post it -- with nothing to undo the second if the
-- third was refused.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`: a draft receipt, never posted, settled a posted
-- RM1,000 invoice -- `completed`, nothing owed, while the ledger still
-- carried the RM1,000 receivable. A draft supplier payment did the same
-- to a RM700 bill. A posted RM400 receipt settled a DRAFT invoice, which
-- became `completed` and, the posting function taking only a draft,
-- could never then be posted. And the screens' own three requests leave
-- the first state behind whenever the posting fails after the applying
-- succeeded -- a closed period, a dropped connection.
--
-- Answered "one transaction":
--
-- 1. `record_settlement` records a receipt or payment, applies it and
--    posts it in one call -- recorded, applied, then posted, because
--    posting reads what was applied to work out an exchange difference
--    -- all or nothing. The screens call it.
-- 2. The knock-off bodies move to `app.allocate_with_discount_internal`
--    and `app.allocate_payment_with_discount_internal`, asking nothing
--    new. `record_settlement`, `record_group_payment`,
--    `settle_from_client_account` and the demo practice -- each of
--    which records, applies and posts in one transaction -- apply
--    through them.
-- 3. `allocate_with_discount` and `allocate_payment_with_discount`,
--    the client's door, refuse money not yet posted, a document not yet
--    posted, and a voided one, then call the body. Applying money
--    already banked to an invoice raised later (`apply_on_account`)
--    and the knock-off screen are as before.
--
-- An app build from before this calls the old three requests and is
-- refused at the second; its draft receipt is left unposted and
-- unapplied, which is what a failed posting always left, minus the
-- invoice marked paid.
--
-- Every restated function is from `pg_get_functiondef` of the live one,
-- with only what is marked `0832` changed. Production held 56 receipt
-- and 20 payment allocations on 12 October, every one between posted
-- documents.
-- =====================================================================

CREATE OR REPLACE FUNCTION app.allocate_with_discount_internal(p_receipt uuid, p_invoice uuid, p_amount numeric, p_discount numeric DEFAULT NULL::numeric, p_as_at date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_rcp      public.receipts;
  v_inv      public.sales_documents;
  v_offer    record;
  v_discount numeric(18, 2);
  -- 0760. The discount in the books' currency, at the invoice's rate.
  v_disc_base numeric(18, 2);
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
    --
    -- 0760. At the INVOICE's rate. The discount is a share of the
    -- invoice's own figure, in the invoice's currency, and it settles
    -- part of a receivable recorded at the invoice's rate -- so that is
    -- the rate that clears it. This posted the document-currency figure
    -- as ringgit at a rate of 1: USD20 off a USD invoice at 4.50 took
    -- RM20 off the receivable, and left RM70 owing in the ledger on an
    -- invoice that showed nothing owed.
    v_disc_base := round(v_discount * coalesce(v_inv.exchange_rate, 1), 2);
    v_entry := public.create_gl_entry(
      v_rcp.org_id, v_as_at, 'receipt'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_disc_ac,
          'description', 'Settlement discount on ' || v_inv.doc_no,
          'debit', v_disc_base, 'credit', 0,
          'fc_debit', v_discount, 'fc_credit', 0),
        jsonb_build_object('account_id', v_ar,
          'description', 'Settlement discount on ' || v_inv.doc_no,
          'debit', 0, 'credit', v_disc_base,
          'fc_debit', 0, 'fc_credit', v_discount,
          'contact_id', v_inv.contact_id)),
      'Settlement discount on ' || v_inv.doc_no,
      'sales_documents', v_inv.id, v_rcp.receipt_no,
      v_inv.currency, coalesce(v_inv.exchange_rate, 1));
  end if;

  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount, discount_amount,
     discount_entry_id, allocated_by)
  values (v_rcp.org_id, p_receipt, p_invoice, round(p_amount, 2),
          v_discount, v_entry, auth.uid())
  returning id into v_alloc;

  return v_alloc;
end $function$;

CREATE OR REPLACE FUNCTION app.allocate_payment_with_discount_internal(p_payment uuid, p_bill uuid, p_amount numeric, p_discount numeric DEFAULT NULL::numeric, p_as_at date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_pay      public.purchase_payments;
  v_bill     public.purchase_documents;
  v_offer    record;
  v_discount numeric(18, 2);
  -- 0760. The discount in the books' currency, at the bill's rate.
  v_disc_base numeric(18, 2);
  v_ap       uuid;
  v_inc_ac   uuid;
  v_entry    uuid;
  v_alloc    uuid;
  v_as_at    date := coalesce(p_as_at,
                       (now() at time zone 'Asia/Kuala_Lumpur')::date);
begin
  select * into v_pay from public.purchase_payments where id = p_payment;
  if v_pay.id is null then
    raise exception 'No such payment.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_pay.org_id) then
    raise exception 'not permitted to allocate a payment'
      using errcode = '42501';
  end if;

  select * into v_bill from public.purchase_documents where id = p_bill;
  if v_bill.id is null or v_bill.org_id <> v_pay.org_id then
    raise exception 'No such bill.' using errcode = 'P0002';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'An allocation is of something.' using errcode = '23514';
  end if;

  select * into v_offer from app.settlement_discount_of(
    v_bill.payment_term_id, v_bill.doc_date,
    greatest(coalesce(v_bill.balance_amount, 0), 0));

  v_discount := round(coalesce(p_discount, 0), 2);
  if v_discount > 0 then
    if v_offer.deadline is null then
      raise exception
        '% is on terms that offer no settlement discount. Ask the '
        'supplier for a credit note if the reduction is something else.',
        v_bill.doc_no using errcode = '23514';
    end if;
    if v_offer.deadline < v_as_at then
      raise exception
        'The discount on % ran out on %. Taking it now would clear a '
        'bill the company has not paid.',
        v_bill.doc_no, to_char(v_offer.deadline, 'DD Mon YYYY')
        using errcode = '23514';
    end if;
    if v_discount > v_offer.amount then
      raise exception
        'The terms on % allow % as a settlement discount, not %.',
        v_bill.doc_no,
        to_char(v_offer.amount, 'FM999G999G990D00'),
        to_char(v_discount, 'FM999G999G990D00') using errcode = '23514';
    end if;
    if round(p_amount + v_discount, 2)
       > round(coalesce(v_bill.balance_amount, 0), 2) then
      raise exception
        'The cash and the discount come to more than is owed on %.',
        v_bill.doc_no using errcode = '23514';
    end if;

    select coalesce(c.payable_account_id,
                    (select id from public.accounts
                      where org_id = v_pay.org_id and code = '2110'))
      into v_ap from public.contacts c where c.id = v_bill.contact_id;
    select id into v_inc_ac from public.accounts
     where org_id = v_pay.org_id and code = '4900';
    if v_ap is null or v_inc_ac is null then
      raise exception
        'No payable (2110) or other income (4900) account in the chart.'
        using errcode = 'P0002';
    end if;

    -- Dr Payable, Cr Other Income. Income rather than a reduction of
    -- cost: it is earned by paying sooner, not by buying more cheaply,
    -- and putting it against Purchases would move it into cost of
    -- sales and restate a cost the stock valuation is built on.
    --
    -- The input tax is untouched. What the supplier charged is what the
    -- company claims, and changing it takes a credit note from them.
    --
    -- 0760. At the BILL's rate, for the reason `allocate_with_discount`
    -- gives: the discount settles part of a payable recorded at that
    -- rate. Unconverted, USD20 off a USD bill at 4.50 took RM20 off the
    -- payable and left RM70 owing on a bill that showed nothing owed.
    v_disc_base := round(v_discount * coalesce(v_bill.exchange_rate, 1), 2);
    v_entry := public.create_gl_entry(
      v_pay.org_id, v_as_at, 'payment'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_ap,
          'description', 'Settlement discount on ' || v_bill.doc_no,
          'debit', v_disc_base, 'credit', 0,
          'fc_debit', v_discount, 'fc_credit', 0,
          'contact_id', v_bill.contact_id),
        jsonb_build_object('account_id', v_inc_ac,
          'description', 'Settlement discount on ' || v_bill.doc_no,
          'debit', 0, 'credit', v_disc_base,
          'fc_debit', 0, 'fc_credit', v_discount)),
      'Settlement discount on ' || v_bill.doc_no,
      'purchase_documents', v_bill.id, v_pay.payment_no,
      v_bill.currency, coalesce(v_bill.exchange_rate, 1));
  end if;

  insert into public.payment_allocations
    (org_id, payment_id, bill_id, amount, discount_amount,
     discount_entry_id, allocated_by)
  values (v_pay.org_id, p_payment, p_bill, round(p_amount, 2),
          v_discount, v_entry, auth.uid())
  returning id into v_alloc;

  return v_alloc;
end $function$;

CREATE OR REPLACE FUNCTION public.allocate_with_discount(p_receipt uuid, p_invoice uuid, p_amount numeric, p_discount numeric DEFAULT NULL::numeric, p_as_at date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_rcp public.receipts;
  v_inv public.sales_documents;
begin
  select * into v_rcp from public.receipts where id = p_receipt;
  select * into v_inv from public.sales_documents where id = p_invoice;

  -- Both in the books (0832). Money that was never posted is no money,
  -- and a document never posted owes nothing yet: applying either
  -- marked an invoice paid that the ledger still said was owed, or a
  -- draft `completed` that could then never be posted. Asked only of a
  -- receipt and an invoice that exist and are this company's; the
  -- body below answers for the rest, as it always has.
  if v_rcp.id is not null and v_inv.id is not null
     and v_inv.org_id = v_rcp.org_id then
    if v_rcp.gl_entry_id is null then
      raise exception
        'Receipt % is not posted yet. Post it, then apply it -- or record '
        'it and apply it in one go, as the receipt screen does.',
        v_rcp.receipt_no using errcode = '23514';
    end if;
    if v_inv.gl_entry_id is null then
      raise exception '% is not posted yet. Post it, then apply money to it.',
        v_inv.doc_no using errcode = '23514';
    end if;
    if v_inv.status = 'void' then
      raise exception '% has been voided, and is owed by nobody.',
        v_inv.doc_no using errcode = '23514';
    end if;
  end if;

  return app.allocate_with_discount_internal(
    p_receipt, p_invoice, p_amount, p_discount, p_as_at);
end $function$;

CREATE OR REPLACE FUNCTION public.allocate_payment_with_discount(p_payment uuid, p_bill uuid, p_amount numeric, p_discount numeric DEFAULT NULL::numeric, p_as_at date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_pay  public.purchase_payments;
  v_bill public.purchase_documents;
begin
  select * into v_pay from public.purchase_payments where id = p_payment;
  select * into v_bill from public.purchase_documents where id = p_bill;

  -- Both in the books (0832), as for a receipt and an invoice.
  if v_pay.id is not null and v_bill.id is not null
     and v_bill.org_id = v_pay.org_id then
    if v_pay.gl_entry_id is null then
      raise exception
        'Payment % is not posted yet. Post it, then apply it -- or record '
        'it and apply it in one go, as the payment screen does.',
        v_pay.payment_no using errcode = '23514';
    end if;
    if v_bill.gl_entry_id is null then
      raise exception '% is not posted yet. Post it, then apply money to it.',
        v_bill.doc_no using errcode = '23514';
    end if;
    if v_bill.status = 'void' then
      raise exception '% has been voided, and is owed to nobody.',
        v_bill.doc_no using errcode = '23514';
    end if;
  end if;

  return app.allocate_payment_with_discount_internal(
    p_payment, p_bill, p_amount, p_discount, p_as_at);
end $function$;

CREATE OR REPLACE FUNCTION public.record_group_payment(p_paid_on date, p_reference text, p_lines jsonb, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_batch  uuid;
  v_inv    integer;
  v_bill   integer;
  v_bad    text;
  v_org    uuid;
  v_sales  boolean;
  g        record;
  l        record;
  v_id     uuid;
  v_bank   uuid;
  v_rate   numeric(18, 8);
begin
  if p_paid_on is null then
    raise exception 'A payment happened on a day.' using errcode = '23514';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'A payment settles something.' using errcode = '23514';
  end if;

  if exists (select 1 from app.group_payment_lines(p_lines) x
              where (x.invoice_id is null) = (x.bill_id is null)) then
    raise exception
      'Every line settles one invoice or one bill.' using errcode = '23514';
  end if;

  select count(*) filter (where x.invoice_id is not null),
         count(*) filter (where x.bill_id is not null)
    into v_inv, v_bill
    from app.group_payment_lines(p_lines) x;

  if v_inv > 0 and v_bill > 0 then
    raise exception
      'A payment settles invoices or bills, not both. Setting money owed '
      'against money due is a contra, and create_contra does it with the '
      'checks that operation needs.' using errcode = '23514';
  end if;
  v_sales := v_inv > 0;

  if exists (select 1 from app.group_payment_lines(p_lines) x
              where coalesce(x.amount, 0) <= 0) then
    raise exception 'An allocation is of something.' using errcode = '23514';
  end if;

  if exists (select 1 from app.group_payment_lines(p_lines) x
              group by coalesce(x.invoice_id, x.bill_id)
             having count(*) > 1) then
    raise exception
      'The same document is on this payment twice. One document, one line, '
      'one figure.' using errcode = '23514';
  end if;

  -- The documents, and through them the companies.
  create temp table if not exists pg_temp._gp (
    doc_id uuid, org_id uuid, contact_id uuid, doc_no text,
    currency char(3), balance numeric, status app.doc_status,
    amount numeric, discount numeric,
    bank_account_id uuid, payment_mode_code text) on commit drop;
  delete from pg_temp._gp;

  if v_sales then
    insert into pg_temp._gp
    select d.id, d.org_id, d.contact_id, d.doc_no, d.currency,
           coalesce(d.balance_amount, 0), d.status,
           x.amount, x.discount, x.bank_account_id, x.payment_mode_code
      from app.group_payment_lines(p_lines) x
      join public.sales_documents d on d.id = x.invoice_id
     where d.deleted_at is null;
  else
    insert into pg_temp._gp
    select d.id, d.org_id, d.contact_id, d.doc_no, d.currency,
           coalesce(d.balance_amount, 0), d.status,
           x.amount, x.discount, x.bank_account_id, x.payment_mode_code
      from app.group_payment_lines(p_lines) x
      join public.purchase_documents d on d.id = x.bill_id
     where d.deleted_at is null;
  end if;

  if (select count(*) from pg_temp._gp) <> v_inv + v_bill then
    raise exception 'A document on this payment does not exist.'
      using errcode = 'P0002';
  end if;

  select string_agg(doc_no, ', ' order by doc_no) into v_bad
    from pg_temp._gp where status not in ('posted', 'partial');
  if v_bad is not null then
    raise exception
      '% is not a posted document. Paying it would clear a balance the '
      'ledger has never been told about.', v_bad using errcode = '23514';
  end if;

  select string_agg(
           format('%s owes %s and is offered %s', doc_no,
                  to_char(balance, 'FM999G999G990D00'),
                  to_char(amount + discount, 'FM999G999G990D00')),
           '; ' order by doc_no)
    into v_bad
    from pg_temp._gp where round(amount + discount, 2) > round(balance, 2);
  if v_bad is not null then
    raise exception
      'More than is outstanding: %.', v_bad using errcode = '23514';
  end if;

  select string_agg(b.doc_no, ', ' order by b.doc_no) into v_bad
    from pg_temp._gp b
    left join public.bank_accounts a on a.id = b.bank_account_id
   where b.bank_account_id is not null
     and (a.id is null or a.org_id <> b.org_id);
  if v_bad is not null then
    raise exception
      'The bank account named against % belongs to another company.', v_bad
      using errcode = '23514';
  end if;

  -- Every company, before a single row is written, so the refusal can
  -- name the one that stopped it.
  for v_org in select distinct org_id from pg_temp._gp loop
    if not app.can_post(v_org) then
      raise exception
        'You cannot post payments in %. A payment that covers several '
        'companies needs the right to post in every one of them, and '
        'nothing has been written.',
        coalesce((select name from public.organizations where id = v_org),
                 v_org::text)
        using errcode = '42501';
    end if;
  end loop;

  select string_agg(distinct org_id::text, ', ') into v_bad
    from pg_temp._gp b
   where (select count(distinct currency) from pg_temp._gp c
           where c.org_id = b.org_id and c.contact_id = b.contact_id) > 1;
  if v_bad is not null then
    raise exception
      'One company''s share of this payment is in two currencies. A '
      'receipt is in one, and the rate belongs to it.'
      using errcode = '23514';
  end if;

  insert into public.payment_batches (paid_on, reference, note, created_by)
  values (p_paid_on, nullif(btrim(p_reference), ''),
          nullif(btrim(p_note), ''), auth.uid())
  returning id into v_batch;

  for g in
    select org_id, contact_id, currency,
           sum(amount) as cash,
           min(bank_account_id::text)::uuid as bank,
           max(bank_account_id::text)::uuid as bank_hi,
           min(payment_mode_code) as mode
      from pg_temp._gp
     group by org_id, contact_id, currency
     order by org_id, contact_id
  loop
    if g.bank is distinct from g.bank_hi then
      raise exception
        'One company''s share of a payment lands in one bank account.'
        using errcode = '23514';
    end if;

    v_rate := case when g.currency = app.base_currency(g.org_id) then 1
                   else app.exchange_rate_for(g.org_id, g.currency, p_paid_on)
              end;

    -- Where the money landed, when the caller did not say. An ordinary
    -- receipt taken through the settlement dialog always names an
    -- account; a group payment is chosen from a list of documents, and
    -- asking for a bank account per company before the figures are even
    -- agreed is a form nobody finishes. Left null the posting falls
    -- through to cash (1120) and no bank balance moves at all, which is
    -- the wrong answer for every company that banks.
    if g.bank is null then
      select id into v_bank from public.bank_accounts
       where org_id = g.org_id and is_default and is_active
       order by created_at limit 1;
    else
      v_bank := g.bank;
    end if;

    if v_sales then
      insert into public.receipts (
        org_id, receipt_no, receipt_date, contact_id, payment_mode_code,
        bank_account_id, reference, currency, exchange_rate, amount,
        unapplied_amount, batch_id, created_by)
      values (
        g.org_id, app.next_document_number_internal(g.org_id, 'receipt'),
        p_paid_on, g.contact_id, g.mode, v_bank,
        nullif(btrim(p_reference), ''), g.currency, v_rate, g.cash,
        g.cash, v_batch, auth.uid())
      returning id into v_id;

      for l in select doc_id, amount, discount from pg_temp._gp
                where org_id = g.org_id and contact_id = g.contact_id
                order by doc_no
      loop
        perform app.allocate_with_discount_internal(  -- 0832: posted below, in this transaction
          v_id, l.doc_id, l.amount, nullif(l.discount, 0), p_paid_on);
      end loop;

      perform public.post_receipt(v_id);
    else
      insert into public.purchase_payments (
        org_id, payment_no, payment_date, contact_id, payment_mode_code,
        bank_account_id, reference, currency, exchange_rate, amount,
        unapplied_amount, batch_id, created_by)
      values (
        g.org_id, app.next_document_number_internal(g.org_id, 'payment'),
        p_paid_on, g.contact_id, g.mode, v_bank,
        nullif(btrim(p_reference), ''), g.currency, v_rate, g.cash,
        g.cash, v_batch, auth.uid())
      returning id into v_id;

      for l in select doc_id, amount, discount from pg_temp._gp
                where org_id = g.org_id and contact_id = g.contact_id
                order by doc_no
      loop
        perform app.allocate_payment_with_discount_internal(  -- 0832: posted below, in this transaction
          v_id, l.doc_id, l.amount, nullif(l.discount, 0), p_paid_on);
      end loop;

      perform public.post_purchase_payment(v_id);
    end if;
  end loop;

  return v_batch;
end;
$function$;

CREATE OR REPLACE FUNCTION public.settle_from_client_account(p_matter uuid, p_invoice uuid, p_amount numeric, p_date date DEFAULT NULL::date, p_office_bank uuid DEFAULT NULL::uuid, p_reference text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org        uuid;
  v_matter_no  text;
  v_client     uuid;
  v_inv        public.sales_documents;
  v_held       numeric(18, 2);
  v_owing      numeric(18, 2);
  v_bank       uuid;
  v_is_client  boolean;
  v_txn        uuid;
  v_receipt    uuid;
begin
  select m.org_id, m.matter_no, m.client_id
    into v_org, v_matter_no, v_client
    from public.matters m where m.id = p_matter;
  if v_org is null then
    raise exception 'There is no such matter' using errcode = 'P0002';
  end if;
  if not app.has_module(v_org, 'legal') then
    raise exception 'Client accounting is part of the legal module'
      using errcode = '42501';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges to move client money'
      using errcode = '42501';
  end if;

  select * into v_inv from public.sales_documents d
   where d.id = p_invoice and d.org_id = v_org;
  if v_inv.id is null then
    raise exception 'There is no such invoice' using errcode = 'P0002';
  end if;

  -- Whose bill it is. A matter's money settles that matter's bill and
  -- nothing else: not another client's, and not the same client's other
  -- matter, because a client ledger is kept per matter. An invoice
  -- raised without a matter on it is allowed through only when it is
  -- addressed to this matter's client -- that is a bill for this
  -- client's work that nobody attributed, not somebody else's.
  if v_inv.matter_id is not null then
    if v_inv.matter_id <> p_matter then
      raise exception
        'Invoice % belongs to another matter. Money held for matter % '
        'cannot settle it.', v_inv.doc_no, v_matter_no
        using errcode = '23514';
    end if;
  elsif v_inv.contact_id is distinct from v_client then
    raise exception
      'Invoice % is not addressed to the client of matter %. One '
      'client''s money cannot settle another''s bill.',
      v_inv.doc_no, v_matter_no
      using errcode = '23514';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'A transfer to office has to be a positive amount'
      using errcode = '23514';
  end if;

  select coalesce(sum(t.amount), 0) into v_held
    from public.client_account_transactions t
   where t.matter_id = p_matter and t.status <> 'void';
  if p_amount > v_held then
    raise exception
      'Matter % holds % and cannot transfer %. Money held for one matter '
      'cannot fund another.',
      v_matter_no, to_char(v_held, 'FM999999990.00'),
      to_char(p_amount, 'FM999999990.00')
      using errcode = '23514';
  end if;

  v_owing := coalesce(v_inv.total_amount, 0) - coalesce(v_inv.paid_amount, 0);
  if p_amount > v_owing then
    raise exception
      'Invoice % owes % and cannot take %. Client money paid beyond a '
      'bill is still the client''s.',
      v_inv.doc_no, to_char(v_owing, 'FM999999990.00'),
      to_char(p_amount, 'FM999999990.00')
      using errcode = '23514';
  end if;

  -- Where it lands. Named, or the default office account -- never the
  -- client account, which would be a transfer that moved nothing while
  -- recording that it had.
  if p_office_bank is not null then
    select b.id, b.is_client_account into v_bank, v_is_client
      from public.bank_accounts b
     where b.id = p_office_bank and b.org_id = v_org;
    if v_bank is null then
      raise exception 'There is no such bank account' using errcode = 'P0002';
    end if;
    if v_is_client then
      raise exception
        'The money has to leave the client account. % is a client '
        'account.', (select name from public.bank_accounts where id = v_bank)
        using errcode = '23514';
    end if;
  else
    select b.id into v_bank from public.bank_accounts b
     where b.org_id = v_org and not b.is_client_account and b.is_active
     order by b.is_default desc, b.created_at
     limit 1;
    if v_bank is null then
      raise exception 'No office account is configured to receive it'
        using errcode = '23514';
    end if;
  end if;

  -- Leg one: the money leaves the client account. `invoice_id` is what
  -- makes this a lawful transfer rather than the one-legged kind, and
  -- the trigger below refuses one without it.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, reference, invoice_id, created_by)
  select v_org, p_matter,
         public.next_document_number(v_org, 'client_txn'),
         coalesce(p_date, app.today()), 'transfer_to_office',
         b.id, -p_amount,
         'Transfer to office, invoice ' || v_inv.doc_no,
         p_reference, p_invoice, auth.uid()
    from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account and b.is_active
   order by b.is_default desc, b.created_at
   limit 1
  returning id into v_txn;

  if v_txn is null then
    raise exception 'No client account is configured' using errcode = '23514';
  end if;
  perform public.post_client_transaction(v_txn);

  -- Leg two: it arrives in the office account and settles the bill.
  -- An ordinary receipt through the ordinary path, so the receivable,
  -- the bank balance, the allocation and the audit trail are the same
  -- ones every other receipt writes.
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id, reference, notes, created_by)
  values (v_org, public.next_document_number(v_org, 'receipt'),
          coalesce(p_date, app.today()), v_inv.contact_id,
          p_amount, p_amount,
          coalesce(v_inv.currency, 'MYR'), 1, v_bank, p_reference,
          'From client account, matter ' || v_matter_no, auth.uid())
  returning id into v_receipt;

  -- 0832: through the body, the receipt being posted just below in
  -- this same transaction.
  perform app.allocate_with_discount_internal(v_receipt, p_invoice, p_amount, null,
                                        coalesce(p_date, app.today()));

  -- And posted, which is the step that debits the office bank and
  -- credits the receivable. `allocate_with_discount` settles the
  -- invoice; it does not post the receipt, and a receipt left in draft
  -- is the same disappearance in a different place -- the client ledger
  -- down, the bill marked paid, and the office account still empty.
  -- The order is the settlement screen's own: allocate, then post.
  perform public.post_receipt(v_receipt);
  return v_receipt;
end $function$;

CREATE OR REPLACE FUNCTION app.demo_practice_books(p_org uuid, p_owner uuid, p_what text, p_fee numeric, p_customer text DEFAULT 'Kumpulan Awan Sdn Bhd'::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_rev      uuid;
  v_na       uuid;
  v_rate     numeric;
  v_cust     uuid;
  v_bank     uuid;
  v_doc      uuid;
  v_rcp      uuid;
  v_month    date;
  v_date     date;
  v_raised   integer := 0;
  v_settled  integer := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_rev from public.accounts
   where org_id = p_org and code = '4100';
  select id, rate into v_na, v_rate from public.tax_codes
   where org_id = p_org and code = 'NA';

  insert into public.contacts (org_id, code, name, contact_type, entity_type,
                               email, city, state_code, created_by)
  values (p_org, 'CUST-001', p_customer, 'customer', 'sdn_bhd',
          'accounts@kumpulanawan.demo', 'Kuala Lumpur', '14', p_owner)
  on conflict (org_id, code) do nothing;
  select id into v_cust from public.contacts
   where org_id = p_org and code = 'CUST-001';

  -- The account number is still derived from the org id, so a reseed of
  -- the same company produces the same number.
  v_bank := app.demo_bank_account(
    p_org, 'Current account', 'Malayan Banking Berhad',
    '5' || lpad((abs(hashtext(p_org::text)) % 100000000)::text, 11, '0'));

  v_month := date_trunc('year', app.today())::date;
  while v_month <= app.today() loop
    v_date := least(v_month + 6, app.today());

    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, subject, created_by)
    values (p_org, 'invoice',
            app.next_document_number_internal(p_org, 'invoice'),
            v_date, v_date + 30, v_cust, 'draft', 'MYR', 1,
            p_what || ' — ' || to_char(v_month, 'Mon YYYY'), p_owner)
    returning id into v_doc;

    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, tax_code_id, tax_rate, account_id)
    values (p_org, v_doc, 1, 'item', p_what, 1, p_fee, v_na, v_rate, v_rev);

    perform public.post_sales_document(v_doc);
    v_raised := v_raised + 1;

    -- Anything older than two months has been paid. The two that have
    -- not are what the portfolio's "who owes what" is made of, and what
    -- a single payment across four companies settles.
    if v_date < (app.today() - 60) then
      insert into public.receipts
        (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
         payment_mode_code, currency, exchange_rate, amount,
         unapplied_amount, reference, created_by)
      values (p_org, app.next_document_number_internal(p_org, 'receipt'),
              v_date + 30, v_cust, v_bank, '03', 'MYR', 1, p_fee, p_fee,
              'Bank transfer', p_owner)
      returning id into v_rcp;

      perform app.allocate_with_discount_internal(v_rcp, v_doc, p_fee, null,  -- 0832
                                            v_date + 30);
      perform public.post_receipt(v_rcp);
      v_settled := v_settled + 1;
    end if;

    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('%s: %s invoices, %s settled.',
                (select name from public.organizations where id = p_org),
                v_raised, v_settled);
end $function$;

create or replace function public.record_settlement(
  p_org_id uuid,
  p_is_receipt boolean,
  p_contact_id uuid,
  p_amount numeric,
  p_date date,
  p_allocations jsonb,
  p_bank_account_id uuid,
  p_payment_mode_code text,
  p_payment_method_id uuid,
  p_reference text,
  p_bank_charges numeric,
  p_currency text,
  p_exchange_rate numeric,
  p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_seen jsonb;
  v_id   uuid;
  a      jsonb;
begin
  if not app.can_post(p_org_id)
     or not app.can_write_module(p_org_id,
              case when p_is_receipt then 'sales' else 'purchases' end) then
    raise exception 'Not permitted to record a % here.',
      case when p_is_receipt then 'receipt' else 'payment' end
      using errcode = '42501';
  end if;

  v_seen := app.idempotency_begin(p_org_id, p_idempotency_key,
    'record_settlement',
    jsonb_build_object('is_receipt', p_is_receipt, 'contact', p_contact_id,
                       'amount', p_amount, 'date', p_date,
                       'allocations', p_allocations));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  -- Recorded, applied, then posted -- in that order, because posting
  -- reads what was applied to work out any exchange difference
  -- (`app.realised_fx_on_settlement`) -- and in one transaction, so a
  -- posting that is refused takes the allocations with it.
  if p_is_receipt then
    insert into public.receipts
      (org_id, receipt_no, receipt_date, contact_id, amount,
       unapplied_amount, currency, exchange_rate, bank_charges,
       bank_account_id, payment_mode_code, payment_method_id, reference)
    values
      (p_org_id, app.next_document_number_internal(p_org_id, 'receipt'),
       p_date, p_contact_id, p_amount, p_amount, p_currency,
       p_exchange_rate, coalesce(p_bank_charges, 0), p_bank_account_id,
       p_payment_mode_code, p_payment_method_id, p_reference)
    returning id into v_id;
    for a in select * from jsonb_array_elements(coalesce(p_allocations, '[]'::jsonb)) loop
      perform app.allocate_with_discount_internal(
        v_id, (a ->> 'document_id')::uuid, (a ->> 'amount')::numeric,
        nullif((a ->> 'discount')::numeric, 0), null);
    end loop;
    perform public.post_receipt(v_id);
  else
    insert into public.purchase_payments
      (org_id, payment_no, payment_date, contact_id, amount,
       unapplied_amount, currency, exchange_rate, bank_charges,
       bank_account_id, payment_mode_code, payment_method_id, reference)
    values
      (p_org_id, app.next_document_number_internal(p_org_id, 'payment'),
       p_date, p_contact_id, p_amount, p_amount, p_currency,
       p_exchange_rate, coalesce(p_bank_charges, 0), p_bank_account_id,
       p_payment_mode_code, p_payment_method_id, p_reference)
    returning id into v_id;
    for a in select * from jsonb_array_elements(coalesce(p_allocations, '[]'::jsonb)) loop
      perform app.allocate_payment_with_discount_internal(
        v_id, (a ->> 'document_id')::uuid, (a ->> 'amount')::numeric,
        nullif((a ->> 'discount')::numeric, 0), null);
    end loop;
    perform public.post_purchase_payment(v_id);
  end if;

  perform app.idempotency_end(p_org_id, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end $$;

revoke all on function app.allocate_with_discount_internal(uuid, uuid, numeric, numeric, date)
  from public, anon, authenticated;
revoke all on function app.allocate_payment_with_discount_internal(uuid, uuid, numeric, numeric, date)
  from public, anon, authenticated;
revoke all on function public.record_settlement(uuid, boolean, uuid, numeric, date, jsonb, uuid, text, uuid, text, numeric, text, numeric, text)
  from public, anon;
grant execute on function public.record_settlement(uuid, boolean, uuid, numeric, date, jsonb, uuid, text, uuid, text, numeric, text, numeric, text)
  to authenticated;

comment on function app.allocate_with_discount_internal(uuid, uuid, numeric, numeric, date) is
  'The knock-off of a receipt against an invoice, with any settlement '
  'discount, asking nothing of whether either is posted. Called by '
  'record_settlement and the flows that record, apply and post a '
  'receipt in one transaction; the client''s door is '
  'allocate_with_discount, which asks. 0832.';
comment on function app.allocate_payment_with_discount_internal(uuid, uuid, numeric, numeric, date) is
  'The purchase side of allocate_with_discount_internal. 0832.';
comment on function public.allocate_with_discount(uuid, uuid, numeric, numeric, date) is
  'Applies a POSTED receipt to a POSTED invoice, with any settlement '
  'discount the invoice''s terms allow (0385, 0760). Refuses money or a '
  'document not yet in the books, and a voided invoice (0832).';
comment on function public.allocate_payment_with_discount(uuid, uuid, numeric, numeric, date) is
  'Applies a POSTED supplier payment to a POSTED bill, with any '
  'settlement discount (0385, 0760). Refuses money or a bill not yet in '
  'the books, and a voided bill (0832).';
comment on function public.record_settlement(uuid, boolean, uuid, numeric, date, jsonb, uuid, text, uuid, text, numeric, text, numeric, text) is
  'Records a customer receipt or a supplier payment, applies it to the '
  'documents given and posts it, all or nothing (0832). The receipt and '
  'payment screens'' one call; a refused posting leaves nothing applied.';
