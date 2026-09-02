-- ---------------------------------------------------------------------
-- 0462  One payment, several companies
-- ---------------------------------------------------------------------
-- Measured before writing. `record_settlement` in the app creates one
-- `receipts` row for `orgId` and allocates against invoices fetched with
-- `.eq('org_id', orgId)`. Every settlement path in the database is the
-- same shape: `post_receipt` reads `receipts.org_id` and checks
-- `app.can_post` on it. So a person who owns three companies and is paid
-- once -- one transfer covering an invoice from each -- has to open
-- three companies, split the figure by hand three ways, and hope the
-- three receipts add back up to the money that arrived. Nothing ties
-- them together afterwards, so nothing notices when they do not.
--
-- ### One receipt per company, still
--
-- The tempting shortcut is a receipt that spans companies. It is
-- refused here, and not on a technicality: a receipt is a document in a
-- set of books. It carries that company's receipt number, hits that
-- company's bank account, posts to that company's ledger, and is
-- visible to that company's staff. A row with two `org_id`s would be a
-- hole straight through `no_tenant_sees_another`.
--
-- So a group payment is **n receipts and one link**:
--
--   * `payment_batches` -- the fact that one payment happened: the day,
--     the reference off the bank statement, a note. Not org-scoped,
--     because it belongs to none of them.
--   * `receipts.batch_id` / `purchase_payments.batch_id` -- each
--     company's own document, pointing at the shared fact.
--
-- **The batch carries no money.** It was drafted with a `total_amount`
-- and that column is deliberately absent: a member of company A reading
-- the batch would learn what the same payer settled at company B, which
-- is exactly the disclosure the tenant boundary exists to prevent. The
-- total is derivable only by summing the receipts you are allowed to
-- see, which for an accountant holding all three companies is the whole
-- payment, and for a clerk at one of them is their own line.
--
-- ### The document names the company, not the caller
--
-- The input names invoices, never organizations. A line that carried
-- its own `org_id` would let a caller state one company and settle
-- another's invoice; deriving the company from the document makes that
-- unsayable rather than merely refused.
--
-- ### All of it or none of it, and being told which company said no
--
-- It is one function call, so it is one transaction: a failure anywhere
-- takes the whole payment back out, and that is true whether the rights
-- are checked up front or discovered on the way through. The up-front
-- loop is not what makes it atomic and is not claimed to be. It is what
-- makes the refusal answerable. Without it the caller reaches
-- `post_receipt` in the company they have no rights in and is told
-- "Insufficient privileges to post" -- about a payment covering three
-- companies, with nothing saying which of the three refused, and
-- nothing to do next but try them one at a time. The assertions read
-- the message for that reason.
--
-- Mixing invoices and bills in one batch is refused too, and pointed at
-- `create_contra`, which is what setting one against the other is and
-- already exists with the party checks that operation needs.
--
-- ### Mutants
--
-- Eight, restated into a built database and run against
-- `supabase/tests/group_payment.sql`. All eight die; three of them are
-- worth the words.
--
--   * the up-front rights loop taken out -- killed by "the refusal
--     names the company that has no rights in it". The call is still
--     refused, further down, by `post_receipt`; what dies is the
--     operator's ability to act on the answer. This is the assertion
--     the loop exists for, and the only one that could have caught it;
--   * the bank-account ownership check dropped -- killed by "the bank
--     account has to be the paid company's";
--   * the over-allocation check dropped -- killed by "an invoice can be
--     over-allocated", and killed by the *success* path: with the check
--     gone the allocation goes straight through. Worth stating plainly,
--     because it is a fact about the rest of the system: nothing
--     underneath refuses it. `allocate_with_discount` compares the cash
--     against the balance only when a discount is present, and
--     `app.apply_allocation` recomputes `balance_amount` without ever
--     objecting to a negative one. A group payment is the easiest place
--     in the product to fat-finger a figure -- several companies, one
--     box of numbers -- so it checks;
--   * the posted-document check dropped -- killed the same way, by a
--     draft invoice being paid. Nothing else refuses that either: the
--     allocation clears a balance whose receivable was never posted;
--   * the one-company-one-bank check dropped -- killed by "one
--     company's share lands in one bank account";
--   * the invoices-and-bills check dropped -- killed by "setting one
--     against the other is a contra, and says so", but **not by the
--     guard the assertion names**. With the direction check gone the
--     function loads only the sales side, the bill is not in the set,
--     and the caller is told "A document on this payment does not
--     exist" -- about a bill that exists. The test goes red, which is
--     what a mutant run is for; the message an operator would get is
--     wrong, and only the direction check makes it right;
--   * `payment_batch_lines` with the membership filter removed --
--     killed by "a member of one company sees one line", 2 where 1 was
--     expected. That is the cross-tenant disclosure, and it is one
--     `and` away at all times;
--   * the picker filtered by `is_org_member` rather than `can_post` --
--     killed by "the list is what you may settle, not what you may
--     see". A viewer would have been offered invoices they cannot pay,
--     and found out at the end of the form.
-- ---------------------------------------------------------------------

create table public.payment_batches (
  id         uuid primary key default gen_random_uuid(),
  paid_on    date not null,
  reference  text,
  note       text,
  -- No total. See the header: a shared total is a cross-tenant
  -- disclosure dressed as a convenience.
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);

comment on table public.payment_batches is
  'One payment that settled documents in more than one company. Holds '
  'the day and the bank reference and no money at all -- each '
  'company''s share is its own receipt or payment row. See 0462.';

alter table public.receipts
  add column batch_id uuid references public.payment_batches (id)
    on delete set null;
alter table public.purchase_payments
  add column batch_id uuid references public.payment_batches (id)
    on delete set null;

create index on public.receipts (batch_id) where batch_id is not null;
create index on public.purchase_payments (batch_id) where batch_id is not null;

alter table public.payment_batches enable row level security;

-- Readable by anybody holding one of its documents, and by whoever
-- recorded it. Nothing may write it but the function below.
create policy payment_batches_read on public.payment_batches
  for select to authenticated
  using (
    created_by = auth.uid()
    or exists (select 1 from public.receipts r
                where r.batch_id = payment_batches.id
                  and app.is_org_member(r.org_id))
    or exists (select 1 from public.purchase_payments p
                where p.batch_id = payment_batches.id
                  and app.is_org_member(p.org_id)));

-- ---------------------------------------------------------------------
-- The lines, read out of the caller's json once and reused
-- ---------------------------------------------------------------------
create or replace function app.group_payment_lines(p_lines jsonb)
returns table (
  invoice_id        uuid,
  bill_id           uuid,
  amount            numeric,
  discount          numeric,
  bank_account_id   uuid,
  payment_mode_code text)
language sql immutable
set search_path = public, app, pg_temp
as $$
  select x.invoice_id, x.bill_id, round(x.amount, 2),
         round(coalesce(x.discount, 0), 2),
         x.bank_account_id, x.payment_mode_code
    from jsonb_to_recordset(coalesce(p_lines, '[]'::jsonb))
      as x(invoice_id uuid, bill_id uuid, amount numeric, discount numeric,
           bank_account_id uuid, payment_mode_code text);
$$;

-- ---------------------------------------------------------------------
-- Taking it
-- ---------------------------------------------------------------------
create or replace function public.record_group_payment(
  p_paid_on   date,
  p_reference text,
  p_lines     jsonb,
  p_note      text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
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
        perform public.allocate_with_discount(
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
        perform public.allocate_payment_with_discount(
          v_id, l.doc_id, l.amount, nullif(l.discount, 0), p_paid_on);
      end loop;

      perform public.post_purchase_payment(v_id);
    end if;
  end loop;

  return v_batch;
end;
$$;

-- ---------------------------------------------------------------------
-- Reading one back, and only the part that is yours
-- ---------------------------------------------------------------------
create or replace function public.payment_batch_lines(p_batch uuid)
returns table (
  org_id        uuid,
  org_name      text,
  kind          text,
  settlement_id uuid,
  settlement_no text,
  paid_on       date,
  contact_name  text,
  currency      char(3),
  amount        numeric,
  reference     text)
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select r.org_id, o.name, 'receipt', r.id, r.receipt_no, r.receipt_date,
         c.name, r.currency, r.amount, r.reference
    from public.receipts r
    join public.organizations o on o.id = r.org_id
    left join public.contacts c on c.id = r.contact_id
   where r.batch_id = p_batch
     and app.is_org_member(r.org_id)
  union all
  select p.org_id, o.name, 'payment', p.id, p.payment_no, p.payment_date,
         c.name, p.currency, p.amount, p.reference
    from public.purchase_payments p
    join public.organizations o on o.id = p.org_id
    left join public.contacts c on c.id = p.contact_id
   where p.batch_id = p_batch
     and app.is_org_member(p.org_id)
   order by 2, 5;
$$;

-- The picker: every company the caller may post in, and what is open in
-- it. Cross-company by construction, and not a leak -- these are the
-- caller's own companies, which is the whole point of the screen.
create or replace function public.open_documents_across_companies(
  p_kind    text default 'invoice',
  p_search  text default null)
returns table (
  org_id         uuid,
  org_name       text,
  doc_id         uuid,
  doc_no         text,
  doc_date       date,
  due_date       date,
  contact_id     uuid,
  contact_name   text,
  currency       char(3),
  total_amount   numeric,
  balance_amount numeric)
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select d.org_id, o.name, d.id, d.doc_no, d.doc_date, d.due_date,
         d.contact_id, c.name, d.currency, d.total_amount, d.balance_amount
    from public.sales_documents d
    join public.organizations o on o.id = d.org_id
    left join public.contacts c on c.id = d.contact_id
   where p_kind = 'invoice'
     and d.doc_type = 'invoice'
     and d.deleted_at is null
     and d.status in ('posted', 'partial')
     and coalesce(d.balance_amount, 0) > 0
     and app.can_post(d.org_id)
     and (p_search is null or btrim(p_search) = ''
          or c.name ilike '%' || btrim(p_search) || '%'
          or d.doc_no ilike '%' || btrim(p_search) || '%'
          or o.name ilike '%' || btrim(p_search) || '%')
  union all
  select d.org_id, o.name, d.id, d.doc_no, d.doc_date, d.due_date,
         d.contact_id, c.name, d.currency, d.total_amount, d.balance_amount
    from public.purchase_documents d
    join public.organizations o on o.id = d.org_id
    left join public.contacts c on c.id = d.contact_id
   where p_kind = 'bill'
     and d.doc_type = 'bill'
     and d.deleted_at is null
     and d.status in ('posted', 'partial')
     and coalesce(d.balance_amount, 0) > 0
     and app.can_post(d.org_id)
     and (p_search is null or btrim(p_search) = ''
          or c.name ilike '%' || btrim(p_search) || '%'
          or d.doc_no ilike '%' || btrim(p_search) || '%'
          or o.name ilike '%' || btrim(p_search) || '%')
   order by 2, 5;
$$;

revoke all on function app.group_payment_lines(jsonb)
  from public, anon, authenticated;
revoke all on function public.record_group_payment(date, text, jsonb, text)
  from public, anon;
revoke all on function public.payment_batch_lines(uuid) from public, anon;
revoke all on function public.open_documents_across_companies(text, text)
  from public, anon;

grant execute on function public.record_group_payment(date, text, jsonb, text)
  to authenticated;
grant execute on function public.payment_batch_lines(uuid) to authenticated;
grant execute on function public.open_documents_across_companies(text, text)
  to authenticated;
grant select on public.payment_batches to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(to_regprocedure(
    'public.record_group_payment(date, text, jsonb, text)'));
begin
  -- The batch holds no money. Adding a total later would be the
  -- cross-tenant disclosure this was written to avoid.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public'
                and table_name = 'payment_batches'
                and column_name in ('total_amount', 'amount')) then
    raise exception
      '0462: the batch carries a total, which tells one company what '
      'another was paid';
  end if;

  -- Allocations go through the discount functions, never straight into
  -- payment_allocations: 0385's guard is the only thing that makes a
  -- discount post a journal.
  if position('insert into public.payment_allocations' in v_src) > 0 then
    raise exception '0462: a group payment writes allocations by hand';
  end if;

  if position('app.can_post' in v_src) = 0 then
    raise exception '0462: a group payment posts without asking';
  end if;

  if position('post_receipt' in v_src) = 0
     or position('post_purchase_payment' in v_src) = 0 then
    raise exception '0462: a group payment leaves documents unposted';
  end if;
end
$do$;

comment on function public.record_group_payment(date, text, jsonb, text) is
  'One payment covering documents in several companies: one receipt (or '
  'supplier payment) per company and contact, linked by a batch that '
  'holds no money. Rights are checked in every company before anything '
  'is written. See 0462.';
comment on function public.open_documents_across_companies(text, text) is
  'What is open across every company the caller may post in — the list '
  'a group payment is chosen from. See 0462.';
