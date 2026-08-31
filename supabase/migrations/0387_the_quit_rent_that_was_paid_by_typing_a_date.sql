-- =====================================================================
-- iAkauntan :: the quit rent that was paid by typing a date
--
-- `property_statutory_charges` has held two columns since `0162` that
-- nothing ever wrote or read: `bill_document_id`, whose own comment
-- says "the supplier bill it was paid through, if it went through the
-- books", and — worse — `paid_on`, which the sheet offers as a plain
-- date picker.
--
-- So this is what happens today. A managing agent records the quit rent
-- for a site under the National Land Code, or the half-yearly
-- assessment the local authority levies under the Local Government Act
-- 1976. It shows in `property_statutory_due` until somebody types a
-- date into "paid on". The moment they do, it leaves the report. No
-- bill was raised, no supplier was recorded, no money left a bank
-- account, and the ledger has never heard of the charge at all.
--
-- That is the shape this project keeps finding: not an absence, where
-- nothing happens and somebody notices, but a falsehood — a control
-- that appears to have been applied. The due report is the one place
-- anyone looks to see what the company still owes the land office, and
-- a typed date takes a charge out of it as convincingly as paying it
-- would.
--
-- Three things, then.
--
-- `bill_statutory_charge` makes the bill *out of* the charge, the way
-- `0382` makes an asset out of the bill line: same amount, same due
-- date, the site and the period and the account number written into the
-- description, so the two cannot afterwards disagree about what was
-- owed. It posts, and it links.
--
-- `paid_on` stops being typed when there is a bill. It is derived from
-- the bill's own settlement — the date the last thing that cleared it
-- is dated — and it moves when the bill moves, in both directions: a
-- bill reopened by a reversal takes the charge's paid date back with
-- it.
--
-- And a charge with no bill may still be marked paid, because it
-- honestly happens: the owner pays the assessment at the counter and
-- sends in the receipt. But it has to name the receipt. A date on its
-- own is a claim with nothing behind it, and that is the thing being
-- fixed.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Where a statutory property charge is charged
--
-- Not `6295 Licence and Permit`, which is where a business licence
-- goes. Quit rent is rent reserved to the State on alienated land and
-- assessment is a rate levied on the holding; both attach to the
-- property rather than to the right to trade, and a managing agent
-- reporting to a JMB or an MC is asked for them by name.
--
-- Created on demand, in the same shape as `app.property_income_account`
-- from `0163`, so a company that never manages property never grows the
-- two accounts.
-- ---------------------------------------------------------------------
create or replace function app.property_expense_account(
  p_org_id uuid, p_kind app.statutory_property_charge)
returns uuid language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id   uuid;
  v_code text := case p_kind
    when 'quit_rent'  then '6296'
    when 'assessment' then '6297'
    end;
  v_name text := case p_kind
    when 'quit_rent'  then 'Quit Rent'
    when 'assessment' then 'Assessment'
    end;
  v_note text := case p_kind
    when 'quit_rent' then
      'Rent reserved to the State on alienated land under the National '
      'Land Code, payable to the land office for the year.'
    when 'assessment' then
      'Rates levied on the holding by the local authority under the '
      'Local Government Act 1976, usually in two half-yearly bills.'
    end;
begin
  if v_code is null then
    raise exception 'Unknown statutory property charge "%"', p_kind
      using errcode = '22023';
  end if;

  select id into v_id from public.accounts
   where org_id = p_org_id and code = v_code and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts (
    org_id, code, name, description, account_type, account_subtype,
    parent_id, is_group, is_system, is_active, sort_order)
  values (
    p_org_id, v_code, v_name, v_note,
    'expense'::app.account_type, 'operating_expense'::app.account_subtype,
    (select id from public.accounts
      where org_id = p_org_id and code = '6000' and deleted_at is null),
    false, true, true, v_code::integer)
  returning id into v_id;

  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- When a purchase document was settled
--
-- The date the last thing that cleared it is dated, not the date
-- somebody keyed the allocation in. A bill paid on 30 June and
-- allocated in July was paid in June, and a charge whose payment date
-- decides which period it belongs to cannot take the keying date
-- instead.
--
-- Null while anything is still outstanding. A bill can be cleared by a
-- payment, by a debit note against it, or by a contra, so the date is
-- taken from whichever of those each allocation is.
-- ---------------------------------------------------------------------
create or replace function app.purchase_document_settled_on(p_bill uuid)
returns date language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_doc  public.purchase_documents;
  v_when date;
begin
  select * into v_doc from public.purchase_documents where id = p_bill;
  if v_doc.id is null then return null; end if;
  -- `completed` is what `app.apply_allocation` sets when the balance
  -- reaches nil; `void` and the pre-posting statuses are not settlement
  -- and a voided bill has a nil balance for a different reason.
  if v_doc.status not in ('posted', 'partial', 'completed') then
    return null;
  end if;
  if round(coalesce(v_doc.balance_amount, 0), 2) > 0 then return null; end if;

  select max(coalesce(pp.payment_date, dn.doc_date, a.allocated_at::date))
    into v_when
    from public.payment_allocations a
    left join public.purchase_payments pp on pp.id = a.payment_id
    left join public.purchase_documents dn on dn.id = a.credit_note_id
   where a.bill_id = p_bill;

  -- A bill with a zero balance and no allocation at all is a nil bill,
  -- and the day it was posted is the day it stopped being owed.
  return coalesce(v_when, v_doc.doc_date);
end $$;

-- ---------------------------------------------------------------------
-- One bill is the bill for one charge
--
-- `0382`'s partial index, the same reasoning: without it two charges
-- can point at the same bill and each report itself paid, and the pair
-- of them would clear one payment twice over.
-- ---------------------------------------------------------------------
create unique index if not exists property_statutory_one_charge_per_bill
  on public.property_statutory_charges (bill_document_id)
  where bill_document_id is not null;

-- ---------------------------------------------------------------------
-- The date is derived, or it names its receipt
--
-- Judging the change, not the row, in three cases:
--
--   * a bill is attached — `paid_on` is whatever the bill says, and
--     what was typed is overwritten rather than refused, because the
--     bill is the record and there is nothing to argue about;
--   * a bill is being detached — the paid date goes with it, which is
--     what makes `on delete set null` on the foreign key survivable:
--     deleting the bill must not leave a charge claiming to be paid
--     through a document that no longer exists;
--   * no bill — a paid date has to name the receipt behind it.
-- ---------------------------------------------------------------------
create or replace function app.statutory_charge_paid_guard()
returns trigger language plpgsql
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if tg_op = 'UPDATE'
     and old.bill_document_id is not null
     and new.bill_document_id is null then
    new.paid_on := null;
    return new;
  end if;

  if new.bill_document_id is not null then
    new.paid_on := app.purchase_document_settled_on(new.bill_document_id);
    return new;
  end if;

  if new.paid_on is not null
     and btrim(coalesce(new.reference, '')) = '' then
    raise exception
      'Mark % paid through a bill, or give the receipt number it was '
      'paid against. A date on its own takes the charge off the due '
      'list with nothing behind it.',
      case when new.period_half is null then new.period_year::text
           else new.period_year::text || ' H' || new.period_half::text end
      using errcode = '23514';
  end if;

  return new;
end $$;

drop trigger if exists property_statutory_paid_ck
  on public.property_statutory_charges;
create trigger property_statutory_paid_ck
  before insert or update on public.property_statutory_charges
  for each row execute function app.statutory_charge_paid_guard();

-- ---------------------------------------------------------------------
-- And the bill pushes
--
-- The trigger above only fires when the charge is written. The bill is
-- settled somewhere else entirely — a payment allocation, a debit note,
-- a reversal — so the movement has to come from the bill's side.
--
-- AFTER, because `balance_amount` is written by whatever posted or
-- allocated, and this reads the row as it will be stored.
-- ---------------------------------------------------------------------
create or replace function app.statutory_charge_follow_bill()
returns trigger language plpgsql
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  -- Judging the change: bills are updated for a dozen reasons that have
  -- nothing to do with whether they are paid, and every one of them
  -- would otherwise take a row lock on the charge to write back the
  -- date it already holds.
  if old.balance_amount is not distinct from new.balance_amount
     and old.status is not distinct from new.status then
    return null;
  end if;

  -- Touching the row, not setting the date. `paid_on` is derived in
  -- one place — the guard above, which runs before every write to a
  -- charge — and computing it here as well would be a second copy of
  -- the rule to keep in step. This only nudges the rows whose derived
  -- date has moved, which is why the `where` still evaluates it.
  --
  -- `bill_document_id = new.id` narrows it to this bill's charges. The
  -- mutation run could not kill widening that to every charge, and the
  -- reason is worth stating: the guard re-derives each row from its own
  -- bill, so the answer would still be right. What widening costs is a
  -- row lock on every statutory charge in reach, every time any bill in
  -- the company is paid. Kept for the same reason `0380` keeps its own
  -- unkillable predicate — correct and slow is still a defect.
  update public.property_statutory_charges
     set updated_at = now()
   where bill_document_id = new.id
     and paid_on is distinct from app.purchase_document_settled_on(new.id);

  return null;
end $$;

drop trigger if exists purchase_documents_statutory_charge
  on public.purchase_documents;
create trigger purchase_documents_statutory_charge
  after update on public.purchase_documents
  for each row execute function app.statutory_charge_follow_bill();

-- ---------------------------------------------------------------------
-- The bill, made out of the charge
--
-- Everything on it comes from the charge, so there is nothing for a
-- typist to get wrong and nothing for the two records to disagree
-- about later. The description carries the site, the kind, the period
-- and the account number, because a land office bill is identified by
-- its account number and an auditor tracing one starts there.
-- ---------------------------------------------------------------------
create or replace function public.bill_statutory_charge(
  p_charge uuid,
  p_supplier uuid,
  p_doc_date date default null,
  p_supplier_doc_no text default null,
  p_account uuid default null)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_ch     public.property_statutory_charges;
  v_site   text;
  v_sup    public.contacts;
  v_acct   uuid;
  v_bill   uuid;
  v_period text;
  v_date   date;
begin
  select * into v_ch from public.property_statutory_charges
   where id = p_charge;
  if v_ch.id is null then
    raise exception 'No such charge.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_ch.org_id) then
    raise exception 'not permitted to bill a statutory charge'
      using errcode = '42501';
  end if;
  if not app.has_property_module(v_ch.org_id) then
    raise exception
      'The property module is not switched on for this company'
      using errcode = '42501';
  end if;

  if v_ch.bill_document_id is not null then
    raise exception
      'That charge is already on bill %.',
      (select doc_no from public.purchase_documents
        where id = v_ch.bill_document_id)
      using errcode = '23505';
  end if;
  -- A charge already marked paid by hand and a bill would each claim to
  -- be the record of the payment. Clearing the typed date first is the
  -- deliberate step that says which one is right.
  if v_ch.paid_on is not null then
    raise exception
      'That charge is already marked paid on %. Clear the paid date '
      'before billing it, so there is one record of the payment and '
      'not two.', to_char(v_ch.paid_on, 'DD Mon YYYY')
      using errcode = '23514';
  end if;
  if round(coalesce(v_ch.amount, 0), 2) <= 0 then
    raise exception 'A bill is for something. That charge is nil.'
      using errcode = '23514';
  end if;

  select * into v_sup from public.contacts
   where id = p_supplier and org_id = v_ch.org_id;
  if v_sup.id is null then
    raise exception 'No such supplier.' using errcode = 'P0002';
  end if;

  select name into v_site from public.property_sites where id = v_ch.site_id;
  v_period := case when v_ch.period_half is null then v_ch.period_year::text
                   else v_ch.period_year::text || ' H'
                        || v_ch.period_half::text end;
  v_acct := coalesce(p_account,
                     app.property_expense_account(v_ch.org_id, v_ch.kind));
  v_date := coalesce(p_doc_date,
                     (now() at time zone 'Asia/Kuala_Lumpur')::date);

  insert into public.purchase_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id,
    supplier_doc_no, reference, currency, exchange_rate, status)
  values (
    v_ch.org_id, 'bill',
    app.next_document_number_internal(v_ch.org_id, 'bill'),
    v_date, v_ch.due_date, p_supplier,
    p_supplier_doc_no, v_ch.account_no,
    app.base_currency(v_ch.org_id), 1, 'draft')
  returning id into v_bill;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, unit_price, account_id, tax_rate)
  values (
    v_ch.org_id, v_bill, 1, 'item',
    format('%s — %s, %s%s',
           coalesce(v_site, 'Property'),
           case v_ch.kind when 'quit_rent' then 'quit rent'
                          else 'assessment' end,
           v_period,
           case when btrim(coalesce(v_ch.account_no, '')) = '' then ''
                else format(' (account %s)', v_ch.account_no) end),
    1, v_ch.amount, v_acct, 0);

  perform app.post_purchase_document_internal(v_bill);

  -- Linking last: the trigger on the charge derives `paid_on` from the
  -- bill the moment the link exists, and a bill that is not yet posted
  -- has no balance to derive it from.
  update public.property_statutory_charges
     set bill_document_id = v_bill, updated_at = now()
   where id = p_charge;

  return v_bill;
end $$;

-- ---------------------------------------------------------------------
-- What is behind each charge
--
-- The question an auditor asks about a managing agent's statutory
-- charges is not "what is outstanding" — `property_statutory_due`
-- answers that — but "show me each one and what you paid it with". A
-- charge paid through a bill names the bill. One paid outside the books
-- names its receipt. One that is neither is still owed.
-- ---------------------------------------------------------------------
create or replace function public.report_statutory_charges(
  p_org_id uuid,
  p_year integer default null)
returns table (
  charge_id uuid,
  site_name text,
  kind app.statutory_property_charge,
  period text,
  authority text,
  account_no text,
  amount numeric,
  due_date date,
  paid_on date,
  settled_by text,
  bill_id uuid,
  bill_no text,
  reference text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id)
     or not app.has_property_module(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select ch.id, s.name, ch.kind,
           case when ch.period_half is null then ch.period_year::text
                else ch.period_year::text || ' H'
                     || ch.period_half::text end,
           ch.authority, ch.account_no, ch.amount, ch.due_date, ch.paid_on,
           case when ch.bill_document_id is not null then 'bill'
                when ch.paid_on is not null then 'outside the books'
                else 'unpaid' end,
           ch.bill_document_id, b.doc_no, ch.reference
      from public.property_statutory_charges ch
      join public.property_sites s on s.id = ch.site_id
      left join public.purchase_documents b on b.id = ch.bill_document_id
     where ch.org_id = p_org_id
       and (p_year is null or ch.period_year = p_year)
     order by ch.period_year desc, s.name, ch.kind, ch.period_half;
end $$;

grant execute on function public.bill_statutory_charge(
  uuid, uuid, date, text, uuid) to authenticated;
grant execute on function public.report_statutory_charges(uuid, integer)
  to authenticated;
