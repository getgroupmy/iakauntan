-- =====================================================================
-- iAkauntan :: 0099 withholding tax
--
-- Paying a non-resident for services, royalties or interest makes the
-- payer a tax collector: a slice of the payment is kept back and sent
-- to LHDN within one month of paying or crediting, and the deduction is
-- certified to the payee. Miss the month and s.109(2) adds ten per cent
-- to the tax and the expense stops being deductible until it is paid.
-- `tax_codes` carries `rate` and `is_inclusive` and stops, so none of
-- that could be recorded.
--
-- Two decisions worth stating:
--
-- **A certificate is a settlement, not a tax code.** Withholding is not
-- another rate on a line. It is a separate statutory event with its own
-- date, its own form, its own deadline and its own slip handed to the
-- payee — and it partly settles a bill without any money reaching the
-- supplier. So it is modelled the way a supplier payment is modelled:
-- a document that debits the payable, credits somewhere else, and
-- writes a `payment_allocations` row. `withholding_id` becomes the
-- fourth source a settlement can have. The bill's `balance_amount`
-- falls by the tax through the trigger that was already there, and the
-- aged payables listing keeps footing to the control account because
-- both sides moved together.
--
-- **The rate is a default, not a rule.** A double tax agreement can
-- reduce any of these, and which one applies depends on the payee's
-- residence rather than on anything in this database. `ref_withholding_types`
-- holds the rate in the Act; the certificate holds the rate actually
-- applied and the two are allowed to differ.
--
-- Scope: tax the organization withholds *from* a payment it makes.
-- Tax withheld from money coming in is a different thing — a credit
-- against the company's own assessment — and is not built here.
--
-- The rates below are the statutory ones in the Income Tax Act 1967.
-- `supabase/tests/withholding.sql` asserts each of them and the
-- one-month deadline, so moving a number breaks CI rather than a
-- return. They are still worth checking against LHDN's current
-- practice notes before a real CP37 goes out.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Numbering
-- ---------------------------------------------------------------------
create or replace function app.default_doc_prefix(p_doc_type text)
returns text
language sql
immutable
as $$
  select case p_doc_type
    when 'quotation'            then 'QT-'
    when 'sales_order'          then 'SO-'
    when 'delivery_order'       then 'DO-'
    when 'invoice'              then 'INV-'
    when 'credit_note'          then 'CN-'
    when 'debit_note'           then 'DN-'
    when 'refund_note'          then 'RN-'
    when 'proforma'             then 'PF-'
    when 'purchase_request'     then 'PR-'
    when 'purchase_order'       then 'PO-'
    when 'goods_received'       then 'GRN-'
    when 'bill'                 then 'BILL-'
    when 'purchase_credit_note' then 'PCN-'
    when 'purchase_debit_note'  then 'PDN-'
    when 'purchase_return'      then 'PRT-'
    when 'receipt'              then 'RCP-'
    when 'payment'              then 'PAY-'
    when 'expense'              then 'EXP-'
    when 'journal'              then 'JV-'
    when 'stock_adjustment'     then 'ADJ-'
    when 'stock_movement'       then 'SM-'
    when 'lead'                 then 'LD-'
    when 'opportunity'          then 'OPP-'
    when 'contact'              then 'C-'
    when 'item'                 then 'I-'
    when 'withholding'          then 'WHT-'
    else upper(left(p_doc_type, 3)) || '-'
  end;
$$;

-- ---------------------------------------------------------------------
-- Where the money sits between deduction and remittance
--
-- Not 2140 Income Tax Payable: that is the company's own tax on its own
-- profit. This is somebody else's tax being held for a month, and an
-- auditor asking "what is in 2140" should not get both answers.
-- ---------------------------------------------------------------------
insert into public.accounts
  (org_id, code, name, account_type, account_subtype, is_group, parent_id, sort_order)
select o.id, '2145', 'Withholding Tax Payable', 'liability', 'tax_payable',
       false, p.id, 2145
  from public.organizations o
  left join public.accounts p on p.org_id = o.id and p.code = '2100'
 where not exists (
   select 1 from public.accounts a where a.org_id = o.id and a.code = '2145');

create or replace function app.withholding_account(p_org_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '2145';
  if v_id is null then
    insert into public.accounts
      (org_id, code, name, account_type, account_subtype, is_group,
       parent_id, sort_order)
    values (p_org_id, '2145', 'Withholding Tax Payable', 'liability',
            'tax_payable', false,
            (select id from public.accounts
              where org_id = p_org_id and code = '2100'), 2145)
    returning id into v_id;
  end if;
  return v_id;
end; $$;

revoke all on function app.withholding_account(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- What can be withheld, and at what
-- ---------------------------------------------------------------------
create table if not exists public.ref_withholding_types (
  code        text primary key,
  section     text not null,
  name        text not null,
  -- The rate in the Act. A treaty can reduce it; the certificate
  -- records what was actually applied.
  rate        numeric(9, 4) not null check (rate >= 0 and rate <= 100),
  form_code   text,
  -- s.107D is the one that applies to a resident. Everything else here
  -- is a payment to a non-resident.
  payee       text not null default 'non_resident'
              check (payee in ('non_resident', 'resident')),
  -- Months from paying or crediting to the remittance deadline.
  remit_months integer not null default 1,
  is_active   boolean not null default true,
  sort_order  integer not null default 0
);

alter table public.ref_withholding_types enable row level security;
drop policy if exists ref_withholding_types_read on public.ref_withholding_types;
create policy ref_withholding_types_read on public.ref_withholding_types
  for select to authenticated using (true);

revoke all on public.ref_withholding_types from anon;
revoke all on public.ref_withholding_types from authenticated;
grant select on public.ref_withholding_types to authenticated;

insert into public.ref_withholding_types
  (code, section, name, rate, form_code, payee, sort_order)
values
  ('S107A_A', 'ITA s.107A(1)(a)',
   'Non-resident contractor — tax on the contractor', 10, 'CP37D',
   'non_resident', 10),
  ('S107A_B', 'ITA s.107A(1)(b)',
   'Non-resident contractor — tax on the contractor''s employees', 3,
   'CP37D', 'non_resident', 20),
  ('S109_INTEREST', 'ITA s.109', 'Interest paid to a non-resident', 15,
   'CP37', 'non_resident', 30),
  ('S109_ROYALTY', 'ITA s.109', 'Royalty paid to a non-resident', 10,
   'CP37', 'non_resident', 40),
  ('S109A_ENTERTAINER', 'ITA s.109A',
   'Remuneration of a non-resident public entertainer', 15, 'CP37E',
   'non_resident', 50),
  ('S109B_SPECIAL', 'ITA s.109B',
   'Special classes of income under s.4A — technical services, '
   'installation, rent of movable property', 10, 'CP37A',
   'non_resident', 60),
  ('S109F_OTHER', 'ITA s.109F',
   'Other gains or profits under s.4(f)', 10, 'CP37F', 'non_resident', 70),
  ('S107D_AGENT', 'ITA s.107D',
   'Payment to a resident individual agent, dealer or distributor', 2,
   'CP107D', 'resident', 80)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- The certificate
-- ---------------------------------------------------------------------
create table if not exists public.withholding_certificates (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations (id) on delete cascade,
  certificate_no text not null,
  -- The date paid or credited, which is what starts the month running.
  cert_date      date not null default current_date,
  contact_id     uuid not null references public.contacts (id) on delete restrict,
  bill_id        uuid references public.purchase_documents (id) on delete restrict,

  wht_code       text not null references public.ref_withholding_types (code),
  -- Copied rather than joined: a certificate is evidence, and the
  -- section it was issued under does not change because somebody
  -- edited a reference table two years later.
  section        text not null,
  form_code      text,

  currency       char(3) not null default 'MYR',
  exchange_rate  numeric(18, 8) not null default 1 check (exchange_rate > 0),
  gross_amount   numeric(18, 2) not null check (gross_amount > 0),
  rate           numeric(9, 4) not null check (rate >= 0 and rate <= 100),
  tax_amount     numeric(18, 2) not null check (tax_amount >= 0),

  due_date       date not null,
  remitted_on    date,
  remittance_ref text,
  remittance_gl_entry_id uuid references public.gl_entries (id) on delete set null,

  status         app.doc_status not null default 'draft',
  gl_entry_id    uuid references public.gl_entries (id) on delete set null,
  posted_at      timestamptz,
  posted_by      uuid references auth.users (id),

  notes          text,
  created_by     uuid references auth.users (id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  unique (org_id, certificate_no)
);

create index if not exists withholding_certificates_due
  on public.withholding_certificates (org_id, due_date)
  where remitted_on is null;
create index if not exists withholding_certificates_bill
  on public.withholding_certificates (bill_id) where bill_id is not null;

drop trigger if exists set_updated_at on public.withholding_certificates;
create trigger set_updated_at before update on public.withholding_certificates
  for each row execute function app.set_updated_at();

alter table public.withholding_certificates enable row level security;

drop policy if exists withholding_certificates_select on public.withholding_certificates;
create policy withholding_certificates_select on public.withholding_certificates
  for select to authenticated using (app.is_org_member(org_id));
drop policy if exists withholding_certificates_write on public.withholding_certificates;
create policy withholding_certificates_write on public.withholding_certificates
  for all to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));

revoke all on public.withholding_certificates from anon;
revoke all on public.withholding_certificates from authenticated;
grant select, insert, update, delete
  on public.withholding_certificates to authenticated;

-- ---------------------------------------------------------------------
-- A fourth kind of settlement
--
-- Withholding settles part of a bill without money reaching the
-- supplier. Routing it through `payment_allocations` rather than a bare
-- journal is what keeps `balance_amount` and the payable control
-- account moving together — `app.apply_allocation` sums every
-- allocation against the bill and does not care where it came from.
-- ---------------------------------------------------------------------
alter table public.payment_allocations
  add column if not exists withholding_id uuid
    references public.withholding_certificates (id) on delete cascade;

alter table public.payment_allocations
  drop constraint if exists payment_allocations_source_ck;
alter table public.payment_allocations
  add constraint payment_allocations_source_ck check (
    num_nonnulls(receipt_id, payment_id, credit_note_id, withholding_id) = 1
  );

create index if not exists payment_allocations_withholding
  on public.payment_allocations (withholding_id) where withholding_id is not null;

-- ---------------------------------------------------------------------
-- Raising one
-- ---------------------------------------------------------------------
create or replace function public.create_withholding(
  p_bill_id uuid,
  p_wht_code text,
  p_gross_amount numeric default null,
  p_rate numeric default null,
  p_cert_date date default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_bill public.purchase_documents;
  t public.ref_withholding_types;
  v_gross numeric(18, 2);
  v_rate numeric(9, 4);
  v_tax numeric(18, 2);
  v_date date;
  v_id uuid;
begin
  select * into v_bill from public.purchase_documents
   where id = p_bill_id and deleted_at is null;
  if not found then
    raise exception 'Bill % not found', p_bill_id using errcode = 'P0002';
  end if;
  if not app.can_post(v_bill.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  -- Nothing to withhold from until the bill is in the ledger: the
  -- certificate debits the payable this bill created.
  if v_bill.gl_entry_id is null then
    raise exception 'Post the bill before withholding tax on it'
      using errcode = '22023';
  end if;

  select * into t from public.ref_withholding_types
   where code = p_wht_code and is_active;
  if not found then
    raise exception 'Unknown withholding type %', p_wht_code
      using errcode = '22023';
  end if;

  v_date := coalesce(p_cert_date, v_bill.doc_date);
  -- The whole payment unless somebody says otherwise. A contract split
  -- between withholdable services and reimbursed expenses is a figure
  -- only the person reading the contract can give.
  v_gross := round(coalesce(p_gross_amount, v_bill.total_amount), 2);
  v_rate := coalesce(p_rate, t.rate);
  v_tax := round(v_gross * v_rate / 100.0, 2);

  if v_gross <= 0 then
    raise exception 'There is nothing to withhold from' using errcode = '22023';
  end if;
  -- Over-withholding would settle more of the bill than is left on it
  -- and push the payable the wrong way.
  if v_tax > v_bill.balance_amount then
    raise exception
      'Withholding % is more than the % still outstanding on %',
      v_tax, v_bill.balance_amount, v_bill.doc_no using errcode = '22023';
  end if;

  insert into public.withholding_certificates
    (org_id, certificate_no, cert_date, contact_id, bill_id,
     wht_code, section, form_code, currency, exchange_rate,
     gross_amount, rate, tax_amount, due_date, created_by)
  values (
    v_bill.org_id,
    public.next_document_number(v_bill.org_id, 'withholding'),
    v_date, v_bill.contact_id, v_bill.id,
    t.code, t.section, t.form_code,
    v_bill.currency, coalesce(v_bill.exchange_rate, 1),
    v_gross, v_rate, v_tax,
    -- "Within one month after paying or crediting", so the deadline
    -- moves with the length of the month rather than sitting 30 days
    -- out.
    (v_date + make_interval(months => t.remit_months))::date,
    auth.uid())
  returning id into v_id;

  return v_id;
end; $$;

-- ---------------------------------------------------------------------
-- Posting it
--
--   Dr  Accounts payable        the supplier is owed this much less
--   Cr  Withholding tax payable and LHDN is owed it instead
--
-- No money moves. That happens at remittance.
-- ---------------------------------------------------------------------
create or replace function public.post_withholding(p_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  c public.withholding_certificates;
  v_ap uuid;
  v_wht uuid;
  v_base numeric(18, 2);
  v_entry uuid;
begin
  select * into c from public.withholding_certificates where id = p_id;
  if not found then
    raise exception 'Certificate % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_post(c.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if c.gl_entry_id is not null then
    raise exception 'Certificate % is already posted', c.certificate_no;
  end if;
  if c.tax_amount = 0 then
    raise exception 'A certificate for nothing is not worth posting'
      using errcode = '22023';
  end if;

  select coalesce(ct.payable_account_id,
                  (select id from public.accounts
                    where org_id = c.org_id and code = '2110'))
    into v_ap
    from public.contacts ct where ct.id = c.contact_id;
  v_wht := app.withholding_account(c.org_id);

  v_base := round(c.tax_amount * coalesce(c.exchange_rate, 1), 2);

  v_entry := public.create_gl_entry(
    c.org_id, c.cert_date, 'withholding'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object(
        'account_id', v_ap,
        'description', 'Withholding ' || c.section || ' ' || c.certificate_no,
        'debit', v_base, 'credit', 0, 'contact_id', c.contact_id),
      jsonb_build_object(
        'account_id', v_wht,
        'description', 'Withholding tax payable ' || c.certificate_no,
        'debit', 0, 'credit', v_base, 'contact_id', c.contact_id)),
    'Withholding tax ' || c.certificate_no,
    'withholding_certificates', c.id, c.form_code,
    c.currency, coalesce(c.exchange_rate, 1));

  -- The subledger half. Without it the bill still shows the gross
  -- outstanding while the control account has already come down.
  if c.bill_id is not null then
    insert into public.payment_allocations
      (org_id, withholding_id, bill_id, amount, allocated_by)
    values (c.org_id, c.id, c.bill_id, c.tax_amount, auth.uid());
  end if;

  update public.withholding_certificates
     set gl_entry_id = v_entry, status = 'posted',
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  return v_entry;
end; $$;

-- ---------------------------------------------------------------------
-- Paying LHDN
--
--   Dr  Withholding tax payable
--   Cr  Bank
-- ---------------------------------------------------------------------
create or replace function public.remit_withholding(
  p_id uuid,
  p_paid_on date default current_date,
  p_bank_account_id uuid default null,
  p_reference text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  c public.withholding_certificates;
  v_bank uuid;
  v_wht uuid;
  v_base numeric(18, 2);
  v_entry uuid;
begin
  select * into c from public.withholding_certificates where id = p_id;
  if not found then
    raise exception 'Certificate % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_post(c.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if c.gl_entry_id is null then
    raise exception 'Post the certificate before remitting it'
      using errcode = '22023';
  end if;
  if c.remitted_on is not null then
    raise exception 'Certificate % was already remitted on %',
      c.certificate_no, c.remitted_on using errcode = '22023';
  end if;

  select a.id into v_bank from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = p_bank_account_id;
  if v_bank is null then
    select id into v_bank from public.accounts
     where org_id = c.org_id and code = '1120';
  end if;

  v_wht := app.withholding_account(c.org_id);
  v_base := round(c.tax_amount * coalesce(c.exchange_rate, 1), 2);

  v_entry := public.create_gl_entry(
    c.org_id, p_paid_on, 'withholding'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object(
        'account_id', v_wht,
        'description', 'Remitted ' || c.section || ' ' || c.certificate_no,
        'debit', v_base, 'credit', 0),
      jsonb_build_object(
        'account_id', v_bank,
        'description', 'Remitted ' || c.certificate_no,
        'debit', 0, 'credit', v_base)),
    'Withholding remittance ' || c.certificate_no,
    'withholding_certificates', c.id,
    coalesce(p_reference, c.form_code));

  if p_bank_account_id is not null then
    update public.bank_accounts
       set current_balance = current_balance - v_base
     where id = p_bank_account_id;
  end if;

  update public.withholding_certificates
     set remitted_on = p_paid_on, remittance_ref = p_reference,
         remittance_gl_entry_id = v_entry, status = 'completed'
   where id = p_id;

  return v_entry;
end; $$;

-- ---------------------------------------------------------------------
-- What is owed, to whom, and by when
--
-- One row per certificate, grouped by the form it goes on, because the
-- form is the unit of work: CP37 and CP37A are filed separately.
--
-- `penalty_if_unpaid` is the ten per cent s.109(2) adds once the month
-- has run out. It is computed, never posted: nobody has been charged it
-- until LHDN says so, and a journal for a penalty that has not been
-- raised is a liability the company does not have.
-- ---------------------------------------------------------------------
create or replace function public.report_withholding(
  p_org_id uuid,
  p_from date default null,
  p_to date default current_date)
returns table (
  certificate_id uuid, certificate_no text, cert_date date,
  contact_name text, section text, form_code text,
  currency char(3), gross_amount numeric, rate numeric,
  tax_amount numeric, base_tax_amount numeric,
  due_date date, remitted_on date, days_late integer,
  penalty_if_unpaid numeric)
language sql stable security definer set search_path = public, app, pg_temp as $$
  select c.id, c.certificate_no, c.cert_date, ct.name, c.section, c.form_code,
         c.currency, c.gross_amount, c.rate, c.tax_amount,
         round(c.tax_amount * coalesce(c.exchange_rate, 1), 2),
         c.due_date, c.remitted_on,
         greatest(0, coalesce(c.remitted_on, current_date) - c.due_date)::integer,
         case
           when c.remitted_on is null and current_date > c.due_date
           then round(c.tax_amount * coalesce(c.exchange_rate, 1) * 0.10, 2)
           else 0
         end
    from public.withholding_certificates c
    join public.contacts ct on ct.id = c.contact_id
   where c.org_id = p_org_id
     and c.deleted_at is null
     and c.status <> 'void'
     and (p_from is null or c.cert_date >= p_from)
     and c.cert_date <= p_to
     and app.is_org_member(p_org_id)
   order by c.form_code, c.cert_date, c.certificate_no;
$$;

-- ---------------------------------------------------------------------
-- The aged payables listing, now that a bill can be settled a fourth way
--
-- Unchanged except for the source date of a withholding allocation.
-- Leaving it out would make the listing show a bill as fully
-- outstanding while the control account had already come down by the
-- tax — the footing `supabase/tests/aged_balances.sql` asserts.
-- ---------------------------------------------------------------------
create or replace function public.report_ap_aging(
  p_org_id uuid, p_as_at date default current_date)
returns table (
  contact_id uuid, contact_code text, contact_name text,
  doc_kind text, document_id uuid, doc_no text,
  doc_date date, due_date date, currency char(3),
  outstanding numeric, base_outstanding numeric,
  days_overdue integer, aging_bucket text)
language sql stable security definer set search_path = public, app, pg_temp as $$
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
     where a.org_id = p_org_id
       and coalesce(p.payment_date, cn.doc_date, w.cert_date) <= p_as_at
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
$$;

-- ---------------------------------------------------------------------
-- PostgreSQL hands EXECUTE to PUBLIC on every new function.
-- ---------------------------------------------------------------------
revoke all on function public.create_withholding(uuid, text, numeric, numeric, date)
  from public, anon;
revoke all on function public.post_withholding(uuid) from public, anon;
revoke all on function public.remit_withholding(uuid, date, uuid, text)
  from public, anon;
revoke all on function public.report_withholding(uuid, date, date) from public, anon;
revoke all on function public.report_ap_aging(uuid, date) from public, anon;

grant execute on function public.create_withholding(uuid, text, numeric, numeric, date)
  to authenticated;
grant execute on function public.post_withholding(uuid) to authenticated;
grant execute on function public.remit_withholding(uuid, date, uuid, text)
  to authenticated;
grant execute on function public.report_withholding(uuid, date, date) to authenticated;
grant execute on function public.report_ap_aging(uuid, date) to authenticated;
