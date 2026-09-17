-- =====================================================================
-- iAkauntan :: 0624 the statement a customer asks for
--
-- `report_ar_aging` answers "how much is this customer late by, and in
-- which bucket". It is the credit controller's question. The customer's
-- own question is a different one and this product could not answer it:
--
--   "What do I owe you, and how did it get to that?"
--
-- A statement of account is the answer. An opening balance, every
-- document and every payment that moved it in date order, a running
-- balance down the page, and a closing balance that is the same number
-- the ageing report shows.
--
-- ---------------------------------------------------------------------
-- What already exists, and why this is still worth writing
--
-- `app/lib/src/features/contacts/statement_pdf.dart` has produced a
-- statement since long before this, for customers and for suppliers,
-- and `statement.dart` ages it into five buckets. That is an OPEN-ITEM
-- statement: every document with a balance left on it, and how late
-- each one is.
--
-- This is the other kind, and the two are not substitutes. An open-item
-- statement says WHAT IS UNPAID. A brought-forward statement says WHAT
-- HAPPENED: an invoice for 10,000 appears at 10,000 on its date and a
-- receipt for 6,000 appears at 6,000 on its, rather than one line of
-- 4,000. The customer reconciles against their own ledger line by line,
-- which is the thing they actually ring up about, and an open-item
-- statement cannot be reconciled that way because it has already netted
-- the two together.
--
-- Every accounting package ships both for that reason.
--
-- ---------------------------------------------------------------------
-- And a defect this makes visible
--
-- `Repo.outstandingFor`, which feeds the existing statement, filters
-- `doc_type = 'invoice'`. So a credit note, a debit note, a refund note
-- and an unapplied receipt are missing from a document that goes to the
-- customer, and a customer holding a credit note is sent a statement
-- that overstates what they owe. It does not agree with
-- `report_ar_aging`, which signs all four correctly.
--
-- Not fixed in this migration -- it is a client-side query and belongs
-- in the commit that wires the app to these functions -- but written
-- down here because this is where it was found.
--
-- ---------------------------------------------------------------------
-- Movements, not balances, and that is the whole difference
--
-- The ageing report lists what is OUTSTANDING on each document: an
-- invoice for 10,000 with 6,000 paid appears as 4,000. A statement
-- lists what MOVED: the invoice at 10,000 on its date, the receipt at
-- 6,000 on its date, and 4,000 at the bottom. Same answer, arrived at
-- the way the customer's own ledger arrived at it, which is the point
-- -- the two are reconciled against each other line by line, and a
-- statement that only shows net figures cannot be.
--
-- So nothing here nets an allocation off a document. Allocations do not
-- appear at all; they are the *link* between two movements that are
-- both already listed, and showing them as well would double the page
-- and count nothing twice.
--
-- ---------------------------------------------------------------------
-- The running balance is in the company's own currency
--
-- A customer invoiced in USD and paid in MYR has no single column that
-- can run down the page, and the honest answer is to run it in the
-- base currency and print the document currency beside each line.
-- `base_debit` and `base_credit` carry the converted figures at each
-- document's own rate, which is the rate the ledger posted at.
--
-- For the ordinary single-currency customer the two are identical and
-- the screen shows one column.
--
-- ---------------------------------------------------------------------
-- What is on it
--
-- Posted, not void, not deleted -- the same three conditions the ageing
-- report uses, and for the same reason: a draft invoice is not a claim
-- on anybody, and a statement that showed one would be asking a
-- customer to pay for a decision nobody has made.
--
--   invoice, debit note      -> debit  (they owe more)
--   credit note, refund note -> credit
--   receipt                  -> credit
--
-- A deposit that has not been applied is a receipt like any other and
-- appears on its own line, which is right: the customer paid it and
-- their own books say so.
-- =====================================================================

create or replace function public.report_statement_of_account(
  p_contact_id uuid,
  p_from date default null,
  p_to date default null)
returns table (
  line_no      integer,
  entry_date   date,
  kind         text,
  doc_no       text,
  due_date     date,
  currency     char(3),
  debit        numeric,
  credit       numeric,
  base_debit   numeric,
  base_credit  numeric,
  balance      numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
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
end $$;

revoke all on function public.report_statement_of_account(uuid, date, date)
  from public, anon;
grant execute on function public.report_statement_of_account(uuid, date, date)
  to authenticated;

comment on function public.report_statement_of_account(uuid, date, date) is
  'One customer''s statement: an opening balance, every posted document '
  'and receipt that moved it in date order, and a running balance in '
  'the company''s own currency. Row 0 is the brought-forward figure. '
  '0624.';

-- ---------------------------------------------------------------------
-- The figure at the bottom, on its own
--
-- The closing balance is the last row's `balance`, and a caller that
-- only wants the number should not have to fetch the page to get it --
-- a list of two hundred customers with what each owes is a real screen
-- and two hundred statements is not.
--
-- Deliberately derived from the same movements rather than from
-- `report_ar_aging`. Two functions that are meant to agree and are
-- written from different sources are two functions that will disagree,
-- and `statement_of_account.sql` asserts they agree to the sen.
-- ---------------------------------------------------------------------
create or replace function public.statement_balance(
  p_contact_id uuid,
  p_as_at date default null)
returns numeric
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  -- The LAST row's balance, not the largest. A balance that went up
  -- and came down again has a maximum that is somebody else's number,
  -- and `max()` reads as right until a customer pays.
  select coalesce((
    select s.balance
      from public.report_statement_of_account(
             p_contact_id, '0001-01-01'::date,
             coalesce(p_as_at, app.today())) s
     order by s.line_no desc
     limit 1), 0);
$$;

revoke all on function public.statement_balance(uuid, date)
  from public, anon;
grant execute on function public.statement_balance(uuid, date)
  to authenticated;

comment on function public.statement_balance(uuid, date) is
  'What one customer owes at a date, from the same movements the '
  'statement lists. 0624.';

do $do$
begin
  if not has_function_privilege('authenticated',
       'public.report_statement_of_account(uuid, date, date)', 'execute') then
    raise exception 'The statement is reachable by nobody.';
  end if;
  if has_function_privilege('anon',
       'public.report_statement_of_account(uuid, date, date)', 'execute') then
    raise exception
      'The statement is reachable by a stranger holding a contact uuid.';
  end if;
end
$do$;
