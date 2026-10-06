-- =====================================================================
-- iAkauntan :: 0747 the three ways of being paid the listings never saw
--
-- `0096` wrote the aged listings as at a date, counting an allocation
-- once both its ends were in the ledger -- and the ends it knew were a
-- receipt or payment, a credit note and (payables) a withholding
-- certificate. Then three more ways of settling a document arrived, each
-- crediting the control account and each writing a `payment_allocations`
-- row so the document's own balance would move:
--
--   0272  a contra      Dr Payable           Cr Receivable
--   0273  a deposit     Dr 2125 Deposits     Cr Receivable   (applied)
--   0275  a cheque      Dr 1140 Cheques      Cr Receivable   (taken in)
--
-- and the listings were never told. `0739` re-created both without
-- them. One invoice settled each way, measured on 6 October:
--
--   listing 7,000.00, 1210 2,200.00      (payables 700.00, 2110 400.00)
--
-- A listing that does not foot to its control account is the one
-- failure `aged_balances.sql` exists to catch, and it did not: every
-- test of the three features asserted the document's `balance_amount`,
-- and `post_dated_cheques.sql` says "the aged listing stops chasing him"
-- above an assertion on the invoice, not on the listing.
--
-- `report_statement_of_account` (0624) had the same blind spot from the
-- other side -- it lists invoices, notes and receipts and nothing else
-- -- and `statement_of_account.sql` asserts that it and the listing
-- agree to the sen. So it is told too, in the same words.
--
-- ---------------------------------------------------------------------
-- The day each one counts from
--
-- The journal's day, as for a receipt. A contra has `contra_date`; a
-- cheque has `received_on`. An applied deposit had nothing: the
-- allocation row carries `allocated_at`, which is the moment somebody
-- pressed the button, and `apply_deposit` takes a `p_date` that can be
-- earlier. So the allocation gets `applied_on`, `apply_deposit` writes
-- it, and the rows already there are given the date of their own
-- journal where exactly one journal answers to them, and the Malaysian
-- day they were written where none or several do.
--
-- Undoing: a void contra and a bounced or cancelled cheque DELETE their
-- allocations (`void_contra`, `bounce_pdc`, `cancel_pdc`), and a deposit
-- that has been applied cannot be voided. The status tests below are
-- belt and braces for a row nothing writes today -- the same position
-- a void receipt is in.
-- =====================================================================

alter table public.payment_allocations
  add column if not exists applied_on date;

comment on column public.payment_allocations.applied_on is
  'The day an applied deposit reached the ledger: the date of the '
  'journal `apply_deposit` wrote with it. Null for every other kind of '
  'allocation, whose source document carries its own date.';

-- The rows already there.
update public.payment_allocations a
   set applied_on = coalesce(
         (select min(e.entry_date)
            from public.gl_entries e
           where e.org_id = a.org_id
             and e.source_table = 'deposit_notes'
             and e.source_id = a.deposit_id
             and e.description like '% applied to %'
             and e.total_debit = a.amount
          having count(distinct e.entry_date) = 1),
         app.malaysian_day(a.allocated_at))
 where a.deposit_id is not null
   and a.applied_on is null;

-- ---------------------------------------------------------------------
-- apply_deposit: writes the day as well
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_deposit(p_deposit uuid, p_document uuid, p_amount numeric, p_date date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_note   public.deposit_notes;
  v_amount numeric(18, 2) := round(coalesce(p_amount, 0), 2);
  v_held   uuid;
  v_ctrl   uuid;
  v_no     text;
  v_bal    numeric(18, 2);
  v_cur    character(3);
  v_status text;
  v_contact uuid;
  v_lines  jsonb;
  v_entry  uuid;
  v_on     date;
begin
  select * into v_note from public.deposit_notes where id = p_deposit;
  if v_note.id is null then
    raise exception 'No such deposit.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_note.org_id,
        case when v_note.kind = 'customer' then 'sales' else 'purchases' end) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_note.status = 'void' then
    raise exception 'That deposit was voided.' using errcode = '23514';
  end if;
  if v_amount <= 0 then
    raise exception 'An application has to be for something.'
      using errcode = '23514';
  end if;
  if v_amount > v_note.balance_amount then
    raise exception
      'Deposit % has % left and this would take %.',
      v_note.deposit_no, v_note.balance_amount, v_amount using errcode = '23514';
  end if;

  if v_note.kind = 'customer' then
    select d.doc_no, d.balance_amount, d.currency, d.status::text, d.contact_id
      into v_no, v_bal, v_cur, v_status, v_contact
      from public.sales_documents d
     where d.id = p_document and d.org_id = v_note.org_id
       and d.doc_type = 'invoice' and d.deleted_at is null;
  else
    select d.doc_no, d.balance_amount, d.currency, d.status::text, d.contact_id
      into v_no, v_bal, v_cur, v_status, v_contact
      from public.purchase_documents d
     where d.id = p_document and d.org_id = v_note.org_id
       and d.doc_type = 'bill' and d.deleted_at is null;
  end if;

  if v_no is null then
    raise exception
      'No such %.', case when v_note.kind = 'customer' then 'invoice' else 'bill' end
      using errcode = 'P0002';
  end if;
  if v_status not in ('posted', 'partial') then
    raise exception '% is %, and a deposit settles an outstanding document.',
      v_no, v_status using errcode = '23514';
  end if;
  if v_cur <> v_note.currency then
    raise exception
      '% is in % and the deposit is in %. Settle it with a receipt so the '
      'exchange difference is struck where the rest of them are.',
      v_no, v_cur, v_note.currency using errcode = '23514';
  end if;
  if v_contact <> v_note.contact_id then
    raise exception 'That deposit is not %''s.', v_no using errcode = '23514';
  end if;
  if v_amount > v_bal then
    raise exception '% has % outstanding and this would apply %.',
      v_no, v_bal, v_amount using errcode = '23514';
  end if;

  v_on   := coalesce(p_date, app.today());
  v_held := app.deposit_account(v_note.org_id, v_note.kind::text);

  if v_note.kind = 'customer' then
    select coalesce(c.receivable_account_id,
                    (select a.id from public.accounts a
                      where a.org_id = v_note.org_id and a.code = '1210'))
      into v_ctrl from public.contacts c where c.id = v_note.contact_id;
    -- The liability is discharged by the invoice it was held against.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_held, 'contact_id', v_note.contact_id,
        'description', 'Deposit ' || v_note.deposit_no || ' to ' || v_no,
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_ctrl, 'contact_id', v_note.contact_id,
        'description', 'Deposit ' || v_note.deposit_no || ' to ' || v_no,
        'debit', 0, 'credit', v_amount));
    insert into public.payment_allocations
      (org_id, deposit_id, invoice_id, amount, allocated_by, applied_on)
    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid(), v_on);
  else
    select coalesce(c.payable_account_id,
                    (select a.id from public.accounts a
                      where a.org_id = v_note.org_id and a.code = '2110'))
      into v_ctrl from public.contacts c where c.id = v_note.contact_id;
    -- The asset is used up by the bill it was paid against.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_ctrl, 'contact_id', v_note.contact_id,
        'description', 'Deposit ' || v_note.deposit_no || ' to ' || v_no,
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_held, 'contact_id', v_note.contact_id,
        'description', 'Deposit ' || v_note.deposit_no || ' to ' || v_no,
        'debit', 0, 'credit', v_amount));
    insert into public.payment_allocations
      (org_id, deposit_id, bill_id, amount, allocated_by, applied_on)
    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid(), v_on);
  end if;

  v_entry := app.create_gl_entry_internal(
    v_note.org_id, v_on, 'deposit', v_lines,
    'Deposit ' || v_note.deposit_no || ' applied to ' || v_no,
    'deposit_notes', p_deposit);

  perform app.refresh_deposit(p_deposit);
  return v_entry;
end;
$function$;

-- ---------------------------------------------------------------------
-- The two listings
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_ar_aging(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(contact_id uuid, contact_code text, contact_name text, doc_kind text, document_id uuid, doc_no text, doc_date date, due_date date, currency character, outstanding numeric, base_outstanding numeric, days_overdue integer, aging_bucket text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with allocations as (
    -- Only allocations whose two ends were both in the ledger by the
    -- as-at date. `discount_amount` is carried because the settlement
    -- trigger treats it as settling the invoice; nothing in the app
    -- writes it today, and if something ever does it will need a
    -- journal of its own before it can be trusted here.
    select a.invoice_id, a.receipt_id, a.credit_note_id,
           a.amount, a.discount_amount
      from public.payment_allocations a
      join public.sales_documents inv on inv.id = a.invoice_id
       and inv.gl_entry_id is not null and inv.deleted_at is null
       and inv.status <> 'void' and inv.doc_date <= p_as_at
      left join public.receipts r on r.id = a.receipt_id
       and r.gl_entry_id is not null and r.deleted_at is null
       and r.status <> 'void'
      left join public.sales_documents cn on cn.id = a.credit_note_id
       and cn.gl_entry_id is not null and cn.deleted_at is null
       and cn.status <> 'void'
      -- 0747. Three more ways a receivable is settled, each of which
      -- credits the control account and writes an allocation: a contra
      -- against the same party's bill (0272), a deposit applied (0273)
      -- and a post-dated cheque taken in (0275). Each counts from the
      -- day its journal is dated, and not once it is undone -- a void
      -- contra and a bounced or cancelled cheque delete their
      -- allocations anyway, and an applied deposit cannot be voided.
      left join public.contra_notes k on k.id = a.contra_id
       and k.gl_entry_id is not null and k.status <> 'void'
      left join public.deposit_notes n on n.id = a.deposit_id
       and n.gl_entry_id is not null and n.status <> 'void'
      left join public.post_dated_cheques q on q.id = a.pdc_id
       and q.gl_entry_id is not null
       and q.status in ('held', 'deposited', 'cleared')
     where a.org_id = p_org_id
       and coalesce(r.receipt_date, cn.doc_date, k.contra_date,
                    case when n.id is not null then a.applied_on end,
                    q.received_on) <= p_as_at
  ),
  -- Documents that moved the receivable: invoices and debit notes add
  -- to it, credit notes and refund notes take away.
  documents as (
    select d.contact_id, d.doc_type::text as doc_kind, d.id as document_id,
           d.doc_no, d.doc_date, d.due_date, d.currency,
           coalesce(d.exchange_rate, 1) as rate,
           case when d.doc_type in ('credit_note', 'refund_note')
                then -1 else 1 end
           * (d.total_amount - case
               when d.doc_type = 'credit_note' then
                 -- A credit note keeps its own full total in
                 -- `balance_amount` however much of it has been used,
                 -- so what is left has to be worked out here.
                 coalesce((select sum(al.amount) from allocations al
                            where al.credit_note_id = d.id), 0)
               when d.doc_type in ('invoice', 'debit_note') then
                 coalesce((select sum(al.amount + al.discount_amount)
                             from allocations al
                            where al.invoice_id = d.id), 0)
               -- A refund note has no way to be allocated against
               -- anything, so it stands until it is reversed.
               else 0 end) as outstanding
      from public.sales_documents d
     where d.org_id = p_org_id
       and d.doc_type in ('invoice', 'debit_note', 'credit_note', 'refund_note')
       and d.gl_entry_id is not null
       and d.status <> 'void'
       and d.deleted_at is null
       and d.doc_date <= p_as_at
    union all
    -- Cash received and not yet applied to anything. The receipt
    -- credited the receivable on the day it was banked whether or not
    -- anybody has matched it since, so it belongs on the listing.
    select r.contact_id, 'receipt', r.id, r.receipt_no,
           r.receipt_date, null::date, r.currency,
           coalesce(r.exchange_rate, 1),
           -(r.amount - coalesce((select sum(al.amount) from allocations al
                                   where al.receipt_id = r.id), 0))
      from public.receipts r
     where r.org_id = p_org_id
       and r.gl_entry_id is not null
       and r.status <> 'void'
       and r.deleted_at is null
       and r.receipt_date <= p_as_at
  )
  select d.contact_id, c.code, c.name,
         d.doc_kind, d.document_id, d.doc_no, d.doc_date, d.due_date,
         d.currency,
         round(d.outstanding, 2),
         round(d.outstanding * d.rate, 2),
         greatest(0, p_as_at - coalesce(d.due_date, d.doc_date))::integer,
         case
           when p_as_at <= coalesce(d.due_date, d.doc_date) then 'current'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 30 then '1_30'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 60 then '31_60'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 90 then '61_90'
           else 'over_90'
         end
    from documents d
    join public.contacts c on c.id = d.contact_id
   where round(d.outstanding, 2) <> 0
     and app.is_org_member(p_org_id)
   order by c.name, d.doc_date, d.doc_no;
$function$;

CREATE OR REPLACE FUNCTION public.report_ap_aging(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(contact_id uuid, contact_code text, contact_name text, doc_kind text, document_id uuid, doc_no text, doc_date date, due_date date, currency character, outstanding numeric, base_outstanding numeric, days_overdue integer, aging_bucket text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with allocations as (
    select a.bill_id, a.payment_id, a.amount, a.discount_amount
      from public.payment_allocations a
      join public.purchase_documents b on b.id = a.bill_id
       and b.gl_entry_id is not null and b.deleted_at is null
       and b.status <> 'void' and b.doc_date <= p_as_at
      left join public.purchase_payments p on p.id = a.payment_id
       and p.gl_entry_id is not null and p.deleted_at is null
       and p.status <> 'void'
      left join public.sales_documents cn on cn.id = a.credit_note_id
       and cn.gl_entry_id is not null and cn.deleted_at is null
       and cn.status <> 'void'
      left join public.withholding_certificates w on w.id = a.withholding_id
       and w.gl_entry_id is not null and w.deleted_at is null
       and w.status <> 'void'
      -- 0747. The same three as the receivables side: a contra, a
      -- deposit paid to the supplier and applied, and a post-dated
      -- cheque written out.
      left join public.contra_notes k on k.id = a.contra_id
       and k.gl_entry_id is not null and k.status <> 'void'
      left join public.deposit_notes n on n.id = a.deposit_id
       and n.gl_entry_id is not null and n.status <> 'void'
      left join public.post_dated_cheques q on q.id = a.pdc_id
       and q.gl_entry_id is not null
       and q.status in ('held', 'deposited', 'cleared')
     where a.org_id = p_org_id
       and coalesce(p.payment_date, cn.doc_date, w.cert_date, k.contra_date,
                    case when n.id is not null then a.applied_on end,
                    q.received_on) <= p_as_at
  ),
  documents as (
    select d.contact_id, d.doc_type::text as doc_kind, d.id as document_id,
           d.doc_no, d.doc_date, d.due_date, d.currency,
           coalesce(d.exchange_rate, 1) as rate,
           case when d.doc_type = 'purchase_credit_note' then -1 else 1 end
           * (d.total_amount - case
               when d.doc_type in ('bill', 'purchase_debit_note') then
                 coalesce((select sum(al.amount + al.discount_amount)
                             from allocations al where al.bill_id = d.id), 0)
               else 0 end) as outstanding
      from public.purchase_documents d
     where d.org_id = p_org_id
       and d.doc_type in ('bill', 'purchase_debit_note', 'purchase_credit_note')
       and d.gl_entry_id is not null
       and d.status <> 'void'
       and d.deleted_at is null
       and d.doc_date <= p_as_at
    union all
    select p.contact_id, 'payment', p.id, p.payment_no,
           p.payment_date, null::date, p.currency,
           coalesce(p.exchange_rate, 1),
           -(p.amount - coalesce((select sum(al.amount) from allocations al
                                   where al.payment_id = p.id), 0))
      from public.purchase_payments p
     where p.org_id = p_org_id
       and p.gl_entry_id is not null
       and p.status <> 'void'
       and p.deleted_at is null
       and p.payment_date <= p_as_at
  )
  select d.contact_id, c.code, c.name,
         d.doc_kind, d.document_id, d.doc_no, d.doc_date, d.due_date,
         d.currency,
         round(d.outstanding, 2),
         round(d.outstanding * d.rate, 2),
         greatest(0, p_as_at - coalesce(d.due_date, d.doc_date))::integer,
         case
           when p_as_at <= coalesce(d.due_date, d.doc_date) then 'current'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 30 then '1_30'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 60 then '31_60'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 90 then '61_90'
           else 'over_90'
         end
    from documents d
    join public.contacts c on c.id = d.contact_id
   where round(d.outstanding, 2) <> 0
     and app.is_org_member(p_org_id)
   order by c.name, d.doc_date, d.doc_no;
$function$;

-- ---------------------------------------------------------------------
-- And the statement a customer is sent
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_statement_of_account(p_contact_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS TABLE(line_no integer, entry_date date, kind text, doc_no text, due_date date, currency character, debit numeric, credit numeric, base_debit numeric, base_credit numeric, balance numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org  uuid;
  v_from date := coalesce(p_from, date_trunc('month', app.today())::date);
  v_to   date := coalesce(p_to, app.today());
begin
  select c.org_id into v_org from public.contacts c where c.id = p_contact_id;
  if v_org is null then
    raise exception 'No such contact.' using errcode = '22023';
  end if;
  -- Asked here rather than left to a policy: this function is SECURITY
  -- DEFINER and reads two tables directly, so without this it would
  -- hand anybody holding a uuid a customer's whole ledger.
  if not app.is_org_member(v_org) then
    raise exception 'Not your company' using errcode = '42501';
  end if;
  if v_to < v_from then
    raise exception 'The statement ends before it begins.'
      using errcode = '22023';
  end if;

  return query
  with movements as (
    select d.doc_date as entry_date,
           d.doc_type::text as kind,
           d.doc_no,
           d.due_date,
           d.currency,
           case when d.doc_type in ('invoice', 'debit_note')
                then d.total_amount else 0 end as debit,
           case when d.doc_type in ('credit_note', 'refund_note')
                then d.total_amount else 0 end as credit,
           coalesce(d.exchange_rate, 1) as rate
      from public.sales_documents d
     where d.contact_id = p_contact_id
       and d.org_id = v_org
       and d.doc_type in ('invoice', 'debit_note', 'credit_note',
                          'refund_note')
       and d.gl_entry_id is not null
       and d.status <> 'void'
       and d.deleted_at is null
    union all
    select r.receipt_date, 'receipt', r.receipt_no, null::date, r.currency,
           0, r.amount, coalesce(r.exchange_rate, 1)
      from public.receipts r
     where r.contact_id = p_contact_id
       and r.org_id = v_org
       and r.gl_entry_id is not null
       and r.status <> 'void'
       and r.deleted_at is null
    union all
    -- 0747. The other three ways the customer's account was credited:
    -- set off against what we owed him, his deposit applied, and his
    -- post-dated cheque taken in. One line for each, at what it settled
    -- of this customer's invoices, on the day its journal is dated.
    select coalesce(k.contra_date, a.applied_on, q.received_on),
           case when k.id is not null then 'contra'
                when n.id is not null then 'deposit'
                else 'cheque' end,
           coalesce(k.contra_no, n.deposit_no, q.pdc_no),
           null::date, d.currency,
           0, sum(a.amount), coalesce(d.exchange_rate, 1)
      from public.payment_allocations a
      join public.sales_documents d on d.id = a.invoice_id
       and d.contact_id = p_contact_id and d.org_id = v_org
       and d.gl_entry_id is not null and d.status <> 'void'
       and d.deleted_at is null
      left join public.contra_notes k on k.id = a.contra_id
       and k.gl_entry_id is not null and k.status <> 'void'
      left join public.deposit_notes n on n.id = a.deposit_id
       and n.gl_entry_id is not null and n.status <> 'void'
      left join public.post_dated_cheques q on q.id = a.pdc_id
       and q.gl_entry_id is not null
       and q.status in ('held', 'deposited', 'cleared')
     where a.org_id = v_org
       and (k.id is not null or n.id is not null or q.id is not null)
     group by k.id, k.contra_date, k.contra_no, n.id, n.deposit_no,
              a.applied_on, q.id, q.received_on, q.pdc_no, d.currency,
              d.exchange_rate
  ),
  -- Everything before the period, as one number. Not listed: a
  -- statement whose opening balance is itself a list is a statement
  -- for a different period.
  opening as (
    select coalesce(sum(round(m.debit * m.rate, 2)
                      - round(m.credit * m.rate, 2)), 0) as amount
      from movements m
     where m.entry_date < v_from
  ),
  inside as (
    select m.*,
           round(m.debit * m.rate, 2) as base_debit,
           round(m.credit * m.rate, 2) as base_credit
      from movements m
     where m.entry_date between v_from and v_to
  ),
  ordered as (
    select i.*,
           row_number() over (order by i.entry_date, i.kind, i.doc_no)
             as seq
      from inside i
  )
  select 0, v_from - 1, 'opening', null::text, null::date, null::char(3),
         0::numeric, 0::numeric, 0::numeric, 0::numeric, o.amount
    from opening o
  union all
  select r.seq::integer, r.entry_date, r.kind, r.doc_no, r.due_date,
         r.currency, r.debit, r.credit, r.base_debit, r.base_credit,
         (select o.amount from opening o)
           + sum(r.base_debit - r.base_credit) over (
               order by r.seq rows between unbounded preceding
                                       and current row)
    from ordered r
   order by 1;
end $function$;
