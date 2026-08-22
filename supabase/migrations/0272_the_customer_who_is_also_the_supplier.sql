-- =====================================================================
-- The customer who is also the supplier
--
-- A hardware shop sells cement to a contractor and buys scaffolding
-- back from him. He owes RM 8,000 on an invoice; the shop owes him
-- RM 5,000 on a bill. Nobody writes two cheques. They agree the smaller
-- figure cancels, and RM 3,000 changes hands.
--
-- The books have to say that, and today they cannot. The only way to
-- record it is a manual journal moving RM 5,000 between the two control
-- accounts, which leaves both subsidiary ledgers untouched: the invoice
-- still shows RM 8,000 outstanding, the bill still shows RM 5,000, the
-- aged listings still chase him, and neither agrees with the control
-- account any more. That last part is the real damage -- the aged
-- receivable is the only thing an auditor reconciles the control
-- account to, and a journal is precisely how the two stop agreeing.
--
-- ---------------------------------------------------------------------
-- Where the offset lives
--
-- In `payment_allocations`, next to the receipts, payments, credit
-- notes and withholding certificates that already settle documents
-- there. `app.apply_allocation` recomputes an invoice's paid amount and
-- status from every row that names it, whatever wrote the row, so a
-- contra allocation makes the subsidiary ledger correct with no change
-- to that function at all. The alternative -- a fake bank account with
-- fake money moving through it -- puts a transaction in the cash book
-- that never happened, and somebody reconciling the bank has to know to
-- ignore it for ever.
--
-- ---------------------------------------------------------------------
-- Who counts as the same party
--
-- The same contact, or two contacts with the same TIN. A shop that
-- keeps "ABC Trading (customer)" and "ABC Trading (supplier)" as two
-- records is doing something ordinary, and refusing them would make the
-- feature useless to the businesses that most need it. The TIN is the
-- identity LHDN uses and this system already collects and verifies it,
-- so it is the right thing to compare -- rather than the name, which is
-- typed twice and therefore differs.
--
-- ---------------------------------------------------------------------
-- Base currency only, deliberately
--
-- Offsetting a USD invoice against a USD bill taken at different rates
-- realises an exchange difference, and which of the two rates the
-- offset is struck at is a decision with a real answer that depends on
-- the agreement between the parties. Guessing it would put a wrong
-- number in the FX gain account. So a contra in anything but the
-- company's own currency is refused, and says why.
-- =====================================================================

-- Its own kind of journal, so the ledger can be asked what a contra
-- did. Added before the function that names it: the literal is resolved
-- when that function runs, which is after this migration has committed.
alter type app.journal_source add value if not exists 'contra';

create type app.contra_status as enum ('posted', 'void');

-- ---------------------------------------------------------------------
-- Its own number series
-- ---------------------------------------------------------------------
--
-- Re-created from 0271, which is the last migration to define it, with
-- one line added. The fallback would have given 'CON-', which collides
-- with nothing but says less.
create or replace function app.default_doc_prefix(p_doc_type text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
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
    when 'bank_transfer'        then 'TRF-'
    when 'manufacturing_order'  then 'MO-'
    when 'pos_shift'            then 'SH-'
    when 'pos_sale'             then 'POS-'
    when 'stock_transfer'       then 'STN-'
    when 'landed_cost'          then 'LC-'
    when 'contra'               then 'CTR-'
    else upper(left(p_doc_type, 3)) || '-'
  end;
$$;

-- ---------------------------------------------------------------------
-- The note
-- ---------------------------------------------------------------------
create table public.contra_notes (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id)
                  on delete cascade,
  contra_no     text not null,
  contra_date   date not null default current_date,
  status        app.contra_status not null default 'posted',

  -- Both sides of the party. Usually the same contact; two records with
  -- the same TIN when a shop keeps its customer and supplier files
  -- apart.
  customer_contact_id uuid not null references public.contacts(id),
  supplier_contact_id uuid not null references public.contacts(id),

  amount        numeric(18, 2) not null check (amount > 0),
  notes         text,

  gl_entry_id   uuid references public.gl_entries(id),
  void_entry_id uuid references public.gl_entries(id),
  voided_at     timestamptz,
  voided_by     uuid references auth.users(id),
  void_reason   text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, contra_no)
);

create index contra_notes_org_idx on public.contra_notes (org_id, contra_date desc);
create index contra_notes_customer_idx on public.contra_notes (customer_contact_id);
create index contra_notes_supplier_idx on public.contra_notes (supplier_contact_id);

create trigger contra_notes_touch before update on public.contra_notes
  for each row execute function app.set_updated_at();

comment on table public.contra_notes is
  'Offsetting what a party owes against what is owed to them, without inventing a bank transaction.';

-- ---------------------------------------------------------------------
-- A contra settles documents the same way everything else does
-- ---------------------------------------------------------------------
--
-- The source check has said "exactly one of these" since 0005 and it
-- still does; there is simply one more thing a settlement can come
-- from. `app.apply_allocation` needs no change at all -- it recomputes
-- from every row naming the document, whatever wrote it.
alter table public.payment_allocations
  add column if not exists contra_id uuid references public.contra_notes(id)
    on delete cascade;

alter table public.payment_allocations
  drop constraint if exists payment_allocations_source_ck;
alter table public.payment_allocations
  add constraint payment_allocations_source_ck
  check (num_nonnulls(receipt_id, payment_id, credit_note_id, withholding_id,
                      contra_id) = 1);

create index payment_allocations_contra_idx
  on public.payment_allocations (contra_id) where contra_id is not null;

-- ---------------------------------------------------------------------
-- A document that stops being settled stops saying it is settled
-- ---------------------------------------------------------------------
--
-- Re-created from 0009, which is the only migration that has ever
-- defined it, with one branch added to each status case.
--
-- The old case said: completed when nothing is left, partial when
-- something has been paid, and otherwise leave the status alone. That
-- last arm is a hole. Take every allocation off an invoice that was
-- settled and it goes back to owing its full amount while still saying
-- `completed` -- which drops it out of every outstanding listing and out
-- of the chasing, permanently and silently.
--
-- It has never been reachable, because until this migration nothing in
-- the system deleted a `payment_allocations` row: a receipt is never
-- unapplied, a credit note is never unallocated. Voiding a contra is
-- the first thing that does, so the hole is closed in the same
-- migration that opens the door to it rather than left for whoever
-- finds it in an aged listing.
--
-- Only `completed` and `partial` are put back to `posted`. A draft, a
-- void or a cancelled document is left exactly as it is: those statuses
-- were not reached by allocating anything and are not undone by
-- unallocating it.
create or replace function app.apply_allocation()
returns trigger
language plpgsql
-- 0023 swept a pinned search_path onto every function that existed
-- then, and re-creating one drops what the sweep applied.
set search_path = public, pg_temp
as $$
declare
  v_invoice_id uuid := coalesce(new.invoice_id, old.invoice_id);
  v_bill_id    uuid := coalesce(new.bill_id, old.bill_id);
  v_receipt_id uuid := coalesce(new.receipt_id, old.receipt_id);
  v_payment_id uuid := coalesce(new.payment_id, old.payment_id);
  v_paid       numeric(18, 2);
begin
  if v_invoice_id is not null then
    select coalesce(sum(amount + discount_amount), 0) into v_paid
      from public.payment_allocations where invoice_id = v_invoice_id;

    update public.sales_documents
       set paid_amount = v_paid,
           balance_amount = total_amount - v_paid,
           status = case
             when total_amount - v_paid <= 0 then 'completed'::app.doc_status
             when v_paid > 0                 then 'partial'::app.doc_status
             when status in ('completed', 'partial')
                                             then 'posted'::app.doc_status
             else status
           end
     where id = v_invoice_id;
  end if;

  if v_bill_id is not null then
    select coalesce(sum(amount + discount_amount), 0) into v_paid
      from public.payment_allocations where bill_id = v_bill_id;

    update public.purchase_documents
       set paid_amount = v_paid,
           balance_amount = total_amount - v_paid,
           status = case
             when total_amount - v_paid <= 0 then 'completed'::app.doc_status
             when v_paid > 0                 then 'partial'::app.doc_status
             when status in ('completed', 'partial')
                                             then 'posted'::app.doc_status
             else status
           end
     where id = v_bill_id;
  end if;

  -- Track how much of the receipt/payment is still sitting unapplied.
  if v_receipt_id is not null then
    update public.receipts r
       set unapplied_amount = r.amount - (
             select coalesce(sum(a.amount), 0)
               from public.payment_allocations a where a.receipt_id = r.id)
     where r.id = v_receipt_id;
  end if;

  if v_payment_id is not null then
    update public.purchase_payments p
       set unapplied_amount = p.amount - (
             select coalesce(sum(a.amount), 0)
               from public.payment_allocations a where a.payment_id = p.id)
     where p.id = v_payment_id;
  end if;

  return coalesce(new, old);
end;
$$;

-- ---------------------------------------------------------------------
-- Whether two contact records are the same party
-- ---------------------------------------------------------------------
--
-- The same row, or the same TIN. Blank TINs are not equal to each
-- other: two contacts with nothing in the field are two contacts
-- nobody has identified, and treating them as one party would let a
-- contra offset one customer's invoice against a different supplier's
-- bill.
create or replace function app.same_party(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select p_a = p_b
      or exists (
           select 1
             from public.contacts a
             join public.contacts b on b.id = p_b
            where a.id = p_a
              and coalesce(nullif(trim(a.tin), ''), '#') =
                  coalesce(nullif(trim(b.tin), ''), '##'));
$$;

revoke all on function app.same_party(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- What a party has on both sides
-- ---------------------------------------------------------------------
--
-- One list, both directions, so the screen can show what there is to
-- offset without the caller having to know that receivables and
-- payables live in different tables.
create or replace function public.contra_candidates(p_contact uuid)
returns table (
  side        text,
  document_id uuid,
  contact_id  uuid,
  doc_no      text,
  doc_date    date,
  currency    character,
  total       numeric,
  outstanding numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select c.org_id into v_org from public.contacts c where c.id = p_contact;
  if v_org is null then
    raise exception 'No such contact.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'sales')
     or not app.can_read_module(v_org, 'purchases') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;

  return query
    select 'receivable', d.id, d.contact_id, d.doc_no, d.doc_date,
           d.currency, d.total_amount, d.balance_amount
      from public.sales_documents d
     where d.org_id = v_org
       and d.doc_type = 'invoice'
       and d.deleted_at is null
       and d.status in ('posted', 'partial')
       and d.balance_amount > 0
       and app.same_party(d.contact_id, p_contact)
    union all
    select 'payable', d.id, d.contact_id, d.doc_no, d.doc_date,
           d.currency, d.total_amount, d.balance_amount
      from public.purchase_documents d
     where d.org_id = v_org
       and d.doc_type = 'bill'
       and d.deleted_at is null
       and d.status in ('posted', 'partial')
       and d.balance_amount > 0
       and app.same_party(d.contact_id, p_contact)
     order by 1, 5;
end;
$$;

revoke all on function public.contra_candidates(uuid) from public, anon;
grant execute on function public.contra_candidates(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Striking one
-- ---------------------------------------------------------------------
--
-- Several invoices against several bills, because that is what a
-- quarter's trading between two businesses looks like. The two sides
-- have to come to the same figure, which is the whole point: a contra
-- moves money between two control accounts and creates none.
create or replace function public.create_contra(
  p_org      uuid,
  p_date     date,
  p_invoices jsonb,
  p_bills    jsonb,
  p_notes    text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id       uuid;
  v_e        jsonb;
  v_base     character(3) := app.base_currency(p_org);
  v_inv_tot  numeric(18, 2) := 0;
  v_bill_tot numeric(18, 2) := 0;
  v_cust     uuid;
  v_sup      uuid;
  v_doc      record;
  v_amt      numeric(18, 2);
  v_ar       uuid;
  v_ap       uuid;
  v_lines    jsonb := '[]'::jsonb;
  v_entry    uuid;
begin
  if not app.can_write_module(p_org, 'sales')
     or not app.can_write_module(p_org, 'purchases') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if jsonb_array_length(coalesce(p_invoices, '[]'::jsonb)) = 0
     or jsonb_array_length(coalesce(p_bills, '[]'::jsonb)) = 0 then
    raise exception
      'A contra needs something on both sides: an invoice to settle and '
      'a bill to settle it against.' using errcode = '23514';
  end if;

  -- The note has to exist before the allocations can point at it, and
  -- both contact columns are not null, so it is seeded from the first
  -- document named and corrected once the loops below have checked
  -- every one of them. The seed is a real contact, not a placeholder:
  -- a nullable column here would let a note survive with no party.
  select d.contact_id into v_cust from public.sales_documents d
   where d.id = (p_invoices->0->>'document')::uuid and d.org_id = p_org
     and d.deleted_at is null;
  if v_cust is null then
    raise exception 'No such invoice.' using errcode = 'P0002';
  end if;

  insert into public.contra_notes
    (org_id, contra_no, contra_date, customer_contact_id,
     supplier_contact_id, amount, notes, created_by)
  values (p_org, app.next_document_number_internal(p_org, 'contra'),
          coalesce(p_date, current_date), v_cust, v_cust, 1, p_notes,
          auth.uid())
  returning id into v_id;

  -- Cleared again so the loop's "all the same customer" check starts
  -- from nothing and actually checks the first document too.
  v_cust := null;

  -- ------------------------------------------------------------------
  -- The receivable side
  -- ------------------------------------------------------------------
  for v_e in select * from jsonb_array_elements(p_invoices) loop
    select d.* into v_doc from public.sales_documents d
     where d.id = (v_e->>'document')::uuid and d.org_id = p_org
       and d.deleted_at is null;
    if v_doc.id is null then
      raise exception 'No such invoice.' using errcode = 'P0002';
    end if;
    if v_doc.doc_type <> 'invoice' or v_doc.status not in ('posted', 'partial') then
      raise exception
        'Invoice % is %, and only an outstanding posted invoice can be '
        'contra''d.', v_doc.doc_no, v_doc.status using errcode = '23514';
    end if;
    if v_doc.currency <> v_base then
      raise exception
        'Invoice % is in %, and a contra in anything but % would have to '
        'strike an exchange rate that only the two parties can agree. '
        'Settle it and pay the difference instead.',
        v_doc.doc_no, v_doc.currency, v_base using errcode = '23514';
    end if;

    v_amt := round((v_e->>'amount')::numeric, 2);
    if v_amt <= 0 then
      raise exception 'A contra line has to be for something.'
        using errcode = '23514';
    end if;
    if v_amt > v_doc.balance_amount then
      raise exception
        'Invoice % has % outstanding and the contra is for %.',
        v_doc.doc_no, v_doc.balance_amount, v_amt using errcode = '23514';
    end if;

    if v_cust is null then
      v_cust := v_doc.contact_id;
    elsif v_cust <> v_doc.contact_id then
      raise exception
        'Those invoices are not all the same customer.' using errcode = '23514';
    end if;

    insert into public.payment_allocations
      (org_id, contra_id, invoice_id, amount, allocated_by)
    values (p_org, v_id, v_doc.id, v_amt, auth.uid());
    v_inv_tot := v_inv_tot + v_amt;
  end loop;

  -- ------------------------------------------------------------------
  -- The payable side
  -- ------------------------------------------------------------------
  for v_e in select * from jsonb_array_elements(p_bills) loop
    select d.* into v_doc from public.purchase_documents d
     where d.id = (v_e->>'document')::uuid and d.org_id = p_org
       and d.deleted_at is null;
    if v_doc.id is null then
      raise exception 'No such bill.' using errcode = 'P0002';
    end if;
    if v_doc.doc_type <> 'bill' or v_doc.status not in ('posted', 'partial') then
      raise exception
        'Bill % is %, and only an outstanding posted bill can be '
        'contra''d.', v_doc.doc_no, v_doc.status using errcode = '23514';
    end if;
    if v_doc.currency <> v_base then
      raise exception
        'Bill % is in %, and a contra in anything but % would have to '
        'strike an exchange rate that only the two parties can agree. '
        'Settle it and pay the difference instead.',
        v_doc.doc_no, v_doc.currency, v_base using errcode = '23514';
    end if;

    v_amt := round((v_e->>'amount')::numeric, 2);
    if v_amt <= 0 then
      raise exception 'A contra line has to be for something.'
        using errcode = '23514';
    end if;
    if v_amt > v_doc.balance_amount then
      raise exception
        'Bill % has % outstanding and the contra is for %.',
        v_doc.doc_no, v_doc.balance_amount, v_amt using errcode = '23514';
    end if;

    if v_sup is null then
      v_sup := v_doc.contact_id;
    elsif v_sup <> v_doc.contact_id then
      raise exception
        'Those bills are not all the same supplier.' using errcode = '23514';
    end if;

    insert into public.payment_allocations
      (org_id, contra_id, bill_id, amount, allocated_by)
    values (p_org, v_id, v_doc.id, v_amt, auth.uid());
    v_bill_tot := v_bill_tot + v_amt;
  end loop;

  -- ------------------------------------------------------------------
  -- The two things that make it a contra rather than a journal
  -- ------------------------------------------------------------------
  if not app.same_party(v_cust, v_sup) then
    raise exception
      'Those are two different parties. A contra needs the same contact '
      'on both sides, or two contacts carrying the same TIN.'
      using errcode = '23514';
  end if;
  if v_inv_tot <> v_bill_tot then
    raise exception
      'The two sides come to % and %. A contra cancels what is owed both '
      'ways; the difference is what somebody still has to pay.',
      v_inv_tot, v_bill_tot using errcode = '23514';
  end if;

  select coalesce(c.receivable_account_id,
                  (select a.id from public.accounts a
                    where a.org_id = p_org and a.code = '1210'))
    into v_ar from public.contacts c where c.id = v_cust;
  select coalesce(c.payable_account_id,
                  (select a.id from public.accounts a
                    where a.org_id = p_org and a.code = '2110'))
    into v_ap from public.contacts c where c.id = v_sup;
  if v_ar is null or v_ap is null then
    raise exception 'This company has no control accounts.'
      using errcode = 'P0002';
  end if;

  -- What he owed us goes off the receivable; what we owed him goes off
  -- the payable. No cash moves, and none is pretended to.
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_ap, 'contact_id', v_sup,
      'description', 'Contra settlement', 'debit', v_inv_tot, 'credit', 0),
    jsonb_build_object('account_id', v_ar, 'contact_id', v_cust,
      'description', 'Contra settlement', 'debit', 0, 'credit', v_inv_tot));

  update public.contra_notes
     set customer_contact_id = v_cust,
         supplier_contact_id = v_sup,
         amount = v_inv_tot
   where id = v_id;

  v_entry := app.create_gl_entry_internal(
    p_org, coalesce(p_date, current_date), 'contra', v_lines,
    'Contra ' || (select n.contra_no from public.contra_notes n where n.id = v_id),
    'contra_notes', v_id);

  update public.contra_notes set gl_entry_id = v_entry where id = v_id;
  return v_id;
end;
$$;

revoke all on function public.create_contra(uuid, date, jsonb, jsonb, text)
  from public, anon;
grant execute on function public.create_contra(uuid, date, jsonb, jsonb, text)
  to authenticated;

comment on function public.create_contra(uuid, date, jsonb, jsonb, text) is
  'Offsets a party''s outstanding invoices against their outstanding bills. Both sides must come to the same figure, both must be in the company''s own currency, and both contacts must be the same party.';

-- ---------------------------------------------------------------------
-- Undoing one
-- ---------------------------------------------------------------------
--
-- The allocations go, and `app.apply_allocation` puts both balances
-- back where they were. The ledger entry stays and is reversed rather
-- than deleted, for the reason 0102 gives: a posted entry that
-- disappears is a hole in the audit trail.
create or replace function public.void_contra(p_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
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
    v_rev := public.reverse_gl_entry(v_note.gl_entry_id, current_date);
  end if;

  update public.contra_notes
     set status = 'void', void_entry_id = v_rev, void_reason = trim(p_reason),
         voided_at = now(), voided_by = auth.uid()
   where id = p_id;
  return v_rev;
end;
$$;

revoke all on function public.void_contra(uuid, text) from public, anon;
grant execute on function public.void_contra(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------
create or replace function public.contra_notes_list(
  p_org uuid, p_status text default null)
returns table (
  id          uuid,
  contra_no   text,
  contra_date date,
  status      text,
  party       text,
  amount      numeric,
  invoices    bigint,
  bills       bigint,
  notes       text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_read_module(p_org, 'sales')
     or not app.can_read_module(p_org, 'purchases') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select n.id, n.contra_no, n.contra_date, n.status::text, c.name, n.amount,
           (select count(*) from public.payment_allocations a
             where a.contra_id = n.id and a.invoice_id is not null),
           (select count(*) from public.payment_allocations a
             where a.contra_id = n.id and a.bill_id is not null),
           n.notes
      from public.contra_notes n
      join public.contacts c on c.id = n.customer_contact_id
     where n.org_id = p_org
       and (p_status is null or n.status::text = p_status)
     order by n.contra_date desc, n.contra_no desc;
end;
$$;

revoke all on function public.contra_notes_list(uuid, text) from public, anon;
grant execute on function public.contra_notes_list(uuid, text) to authenticated;

-- What one contra actually settled, for the sheet that opens it.
create or replace function public.contra_lines(p_id uuid)
returns table (
  side        text,
  document_id uuid,
  doc_no      text,
  doc_date    date,
  amount      numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select n.org_id into v_org from public.contra_notes n where n.id = p_id;
  if v_org is null then
    raise exception 'No such contra.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'sales')
     or not app.can_read_module(v_org, 'purchases') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select 'receivable', d.id, d.doc_no, d.doc_date, a.amount
      from public.payment_allocations a
      join public.sales_documents d on d.id = a.invoice_id
     where a.contra_id = p_id
    union all
    select 'payable', d.id, d.doc_no, d.doc_date, a.amount
      from public.payment_allocations a
      join public.purchase_documents d on d.id = a.bill_id
     where a.contra_id = p_id
     order by 1, 3;
end;
$$;

revoke all on function public.contra_lines(uuid) from public, anon;
grant execute on function public.contra_lines(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.contra_notes enable row level security;

create policy contra_notes_read on public.contra_notes for select
  to authenticated using (app.can_read_module(org_id, 'sales'));

-- No write policy. A client that could insert a note or update its
-- status could produce one with no allocations and no ledger entry,
-- which would appear in the list as a settlement that settled nothing.
revoke all on public.contra_notes from anon, authenticated;
grant select on public.contra_notes to authenticated;
