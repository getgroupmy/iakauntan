-- =====================================================================
-- Money before there is anything to bill
--
-- A customer pays half up front for a kitchen that will be delivered in
-- six weeks. A supplier wants a deposit before he books the container.
-- Neither has an invoice or a bill attached to it, because neither has
-- happened yet.
--
-- Today the only place to put the customer's money is an unapplied
-- receipt, and `post_receipt` credits Accounts Receivable. So a deposit
-- from a customer who owes nothing sits in the ledger as a *negative
-- receivable*: the aged listing shows him in credit, the balance sheet
-- shows the asset understated, and the money the company is actually
-- holding on somebody else's behalf never appears as a liability at
-- all. It is not a small presentation quibble -- a deposit is money the
-- company would have to give back, and a balance sheet that nets it off
-- against what other customers owe says the opposite.
--
-- ---------------------------------------------------------------------
-- Where it goes instead
--
--   a customer's deposit    Dr Bank            Cr 2125 Customer Deposits
--   a deposit to a supplier Dr 1235 Deposits Paid   Cr Bank
--
-- A liability and an asset, which is what they are. Then, as the thing
-- it was for actually happens:
--
--   applied to an invoice   Dr 2125            Cr Receivable
--   applied to a bill       Dr Payable         Cr 1235
--   refunded                Dr 2125            Cr Bank     (and reverse)
--   forfeited by a customer Dr 2125            Cr 4930 Deposits Forfeited
--   forfeited by us         Dr 6610 Deposits Forfeited  Cr 1235
--
-- The application also writes a `payment_allocations` row, which is what
-- makes the invoice's own balance move. 0272 put contras in that table
-- for the same reason and this is the same argument: `app.apply_
-- allocation` recomputes a document from every row naming it, so the
-- subsidiary ledger and the control account stay in step without either
-- of them being told about deposits.
--
-- ---------------------------------------------------------------------
-- What is spent is not what is left
--
-- A deposit is drawn down over time -- part applied to the first
-- invoice, part to the second, the remainder refunded when the job
-- finishes. `app.refresh_deposit` recomputes applied, refunded and
-- forfeited from the rows that record them rather than incrementing a
-- counter, so a reversal anywhere puts the balance back with no
-- arithmetic of its own to get wrong.
-- =====================================================================

alter type app.journal_source add value if not exists 'deposit';

create type app.deposit_kind   as enum ('customer', 'supplier');
create type app.deposit_status as enum ('open', 'settled', 'void');

-- What happened to a deposit that was not applying it to a document.
create type app.deposit_event_kind as enum ('refund', 'forfeit');

-- ---------------------------------------------------------------------
-- Its own number series
-- ---------------------------------------------------------------------
--
-- Re-created from 0272, which is the last migration to define it, with
-- one line added.
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
    when 'deposit'              then 'DEP-'
    else upper(left(p_doc_type, 3)) || '-'
  end;
$$;

-- ---------------------------------------------------------------------
-- The four accounts a deposit needs
-- ---------------------------------------------------------------------
--
-- None of them is in the seeded chart, because until now nothing could
-- post to them. Created on first use rather than added to the seed, so
-- that a company that never takes a deposit never grows four accounts
-- it will not use -- the pattern 0268 and 0271 both follow.
create or replace function app.deposit_account(p_org_id uuid, p_kind text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id     uuid;
  v_code   text;
  v_name   text;
  v_type   text;
  v_sub    text;
  v_parent text;
begin
  select case p_kind
    when 'customer' then '2125' when 'supplier' then '1235'
    when 'income'   then '4930' else '6610' end into v_code;
  select case p_kind
    when 'customer' then 'Customer Deposits'
    when 'supplier' then 'Deposits Paid to Suppliers'
    else 'Deposits Forfeited' end into v_name;
  select case p_kind
    when 'customer' then 'liability' when 'supplier' then 'asset'
    when 'income'   then 'revenue'   else 'expense' end into v_type;
  select case p_kind
    when 'customer' then 'current_liability' when 'supplier' then 'current_asset'
    when 'income'   then 'other_income'      else 'other_expense' end into v_sub;
  select case p_kind
    when 'customer' then '2100' when 'supplier' then '1200'
    when 'income'   then '4900' else '6000' end into v_parent;

  select id into v_id from public.accounts
   where org_id = p_org_id and code = v_code and not is_group;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, v_code, v_name, v_type::app.account_type,
          v_sub::app.account_subtype, false, true, v_code::integer,
          (select id from public.accounts
            where org_id = p_org_id and code = v_parent))
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function app.deposit_account(uuid, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The note
-- ---------------------------------------------------------------------
create table public.deposit_notes (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id)
                  on delete cascade,
  deposit_no    text not null,
  deposit_date  date not null default current_date,
  kind          app.deposit_kind not null,
  status        app.deposit_status not null default 'open',

  contact_id    uuid not null references public.contacts(id),
  currency      character(3) not null default 'MYR',
  exchange_rate numeric(18, 8) not null default 1,
  amount        numeric(18, 2) not null check (amount > 0),

  bank_account_id   uuid references public.bank_accounts(id),
  payment_mode_code text,
  reference     text,

  -- Recomputed by app.refresh_deposit from the rows that record them,
  -- never incremented in place.
  applied_amount   numeric(18, 2) not null default 0,
  refunded_amount  numeric(18, 2) not null default 0,
  forfeited_amount numeric(18, 2) not null default 0,
  balance_amount   numeric(18, 2) not null default 0,

  notes         text,
  gl_entry_id   uuid references public.gl_entries(id),
  void_entry_id uuid references public.gl_entries(id),
  void_reason   text,
  voided_at     timestamptz,
  voided_by     uuid references auth.users(id),

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, deposit_no)
);

-- A refund or a forfeit. An application is not here: it is a
-- `payment_allocations` row, because it settles a document and that is
-- where settlements live.
create table public.deposit_events (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  deposit_id  uuid not null references public.deposit_notes(id)
                on delete cascade,
  kind        app.deposit_event_kind not null,
  event_date  date not null default current_date,
  amount      numeric(18, 2) not null check (amount > 0),
  reason      text,
  bank_account_id uuid references public.bank_accounts(id),
  gl_entry_id uuid references public.gl_entries(id),
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now()
);

create index deposit_notes_org_idx
  on public.deposit_notes (org_id, deposit_date desc);
create index deposit_notes_contact_idx on public.deposit_notes (contact_id);
create index deposit_events_deposit_idx on public.deposit_events (deposit_id);

create trigger deposit_notes_touch before update on public.deposit_notes
  for each row execute function app.set_updated_at();

comment on table public.deposit_notes is
  'Money taken or paid before there is a document for it. A customer deposit is a liability and a supplier deposit is an asset — not a negative receivable, which is where an unapplied receipt used to put it.';

-- ---------------------------------------------------------------------
-- A deposit settles documents the same way everything else does
-- ---------------------------------------------------------------------
--
-- Re-created from 0272 with one more source. The constraint has said
-- "exactly one of these" since 0005 and still does.
alter table public.payment_allocations
  add column if not exists deposit_id uuid references public.deposit_notes(id)
    on delete cascade;

alter table public.payment_allocations
  drop constraint if exists payment_allocations_source_ck;
alter table public.payment_allocations
  add constraint payment_allocations_source_ck
  check (num_nonnulls(receipt_id, payment_id, credit_note_id, withholding_id,
                      contra_id, deposit_id) = 1);

create index payment_allocations_deposit_idx
  on public.payment_allocations (deposit_id) where deposit_id is not null;

-- ---------------------------------------------------------------------
-- What is left of it
-- ---------------------------------------------------------------------
--
-- Recomputed from the allocations and the events rather than counted
-- down, so a reversal anywhere -- an allocation deleted, an event
-- removed -- puts the balance back with nothing of its own to get
-- wrong. The same argument as `app.apply_allocation`, which is why
-- both of them recompute.
create or replace function app.refresh_deposit(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_note public.deposit_notes;
  v_app  numeric(18, 2);
  v_ref  numeric(18, 2);
  v_for  numeric(18, 2);
begin
  select * into v_note from public.deposit_notes where id = p_id;
  if v_note.id is null then
    return;
  end if;

  select coalesce(sum(a.amount), 0) into v_app
    from public.payment_allocations a where a.deposit_id = p_id;
  select coalesce(sum(e.amount) filter (where e.kind = 'refund'), 0),
         coalesce(sum(e.amount) filter (where e.kind = 'forfeit'), 0)
    into v_ref, v_for
    from public.deposit_events e where e.deposit_id = p_id;

  update public.deposit_notes
     set applied_amount   = v_app,
         refunded_amount  = v_ref,
         forfeited_amount = v_for,
         balance_amount   = amount - v_app - v_ref - v_for,
         status = case
           when status = 'void' then 'void'::app.deposit_status
           when amount - v_app - v_ref - v_for <= 0
             then 'settled'::app.deposit_status
           else 'open'::app.deposit_status
         end
   where id = p_id;
end;
$$;

revoke all on function app.refresh_deposit(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Taking one
-- ---------------------------------------------------------------------
create or replace function public.create_deposit(
  p_org      uuid,
  p_kind     text,
  p_contact  uuid,
  p_date     date,
  p_amount   numeric,
  p_bank     uuid default null,
  p_mode     text default null,
  p_reference text default null,
  p_notes    text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id     uuid;
  v_no     text;
  v_bank   uuid;
  v_held   uuid;
  v_amount numeric(18, 2) := round(coalesce(p_amount, 0), 2);
  v_cur    character(3);
  v_rate   numeric(18, 8);
  v_lines  jsonb;
  v_entry  uuid;
  v_module text := case when p_kind = 'customer' then 'sales' else 'purchases' end;
begin
  if not app.can_write_module(p_org, v_module) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if p_kind not in ('customer', 'supplier') then
    raise exception 'A deposit is either taken from a customer or paid to a '
      'supplier.' using errcode = '23514';
  end if;
  if v_amount <= 0 then
    raise exception 'A deposit has to be for something.' using errcode = '23514';
  end if;
  if not exists (select 1 from public.contacts c
                  where c.id = p_contact and c.org_id = p_org) then
    raise exception 'No such contact.' using errcode = 'P0002';
  end if;

  -- Foreign deposits are refused for the reason 0272 refuses foreign
  -- contras: what is held is worth a different number of ringgit on the
  -- day it is applied, and which rate that difference is struck at is
  -- an answer this cannot guess.
  v_cur  := app.base_currency(p_org);
  v_rate := 1;

  select a.id into v_bank from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = p_bank and b.org_id = p_org;
  if v_bank is null then
    select id into v_bank from public.accounts
     where org_id = p_org and code = '1120' and not is_group;
  end if;
  if v_bank is null then
    raise exception 'This company has no bank account to put it in.'
      using errcode = 'P0002';
  end if;

  v_held := app.deposit_account(p_org, p_kind);
  v_no   := app.next_document_number_internal(p_org, 'deposit');

  insert into public.deposit_notes
    (org_id, deposit_no, deposit_date, kind, contact_id, currency,
     exchange_rate, amount, bank_account_id, payment_mode_code, reference,
     balance_amount, notes, created_by)
  values (p_org, v_no, coalesce(p_date, current_date), p_kind::app.deposit_kind,
          p_contact, v_cur, v_rate, v_amount, p_bank, p_mode, p_reference,
          v_amount, p_notes, auth.uid())
  returning id into v_id;

  if p_kind = 'customer' then
    -- Money in, and a liability for money the company would have to
    -- give back.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'contact_id', p_contact,
        'description', 'Deposit ' || v_no, 'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_held, 'contact_id', p_contact,
        'description', 'Deposit ' || v_no, 'debit', 0, 'credit', v_amount));
  else
    -- Money out, and an asset for money the supplier is holding.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_held, 'contact_id', p_contact,
        'description', 'Deposit ' || v_no, 'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_bank, 'contact_id', p_contact,
        'description', 'Deposit ' || v_no, 'debit', 0, 'credit', v_amount));
  end if;

  v_entry := app.create_gl_entry_internal(
    p_org, coalesce(p_date, current_date), 'deposit', v_lines,
    'Deposit ' || v_no, 'deposit_notes', v_id);

  update public.deposit_notes set gl_entry_id = v_entry where id = v_id;

  if p_bank is not null then
    update public.bank_accounts
       set current_balance = current_balance
             + case when p_kind = 'customer' then v_amount else -v_amount end
     where id = p_bank;
  end if;

  return v_id;
end;
$$;

revoke all on function public.create_deposit(uuid, text, uuid, date, numeric, uuid, text, text, text)
  from public, anon;
grant execute on function public.create_deposit(uuid, text, uuid, date, numeric, uuid, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Using it, when the thing it was for finally happens
-- ---------------------------------------------------------------------
create or replace function public.apply_deposit(
  p_deposit  uuid,
  p_document uuid,
  p_amount   numeric,
  p_date     date default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
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

  v_on   := coalesce(p_date, current_date);
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
      (org_id, deposit_id, invoice_id, amount, allocated_by)
    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid());
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
      (org_id, deposit_id, bill_id, amount, allocated_by)
    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid());
  end if;

  v_entry := app.create_gl_entry_internal(
    v_note.org_id, v_on, 'deposit', v_lines,
    'Deposit ' || v_note.deposit_no || ' applied to ' || v_no,
    'deposit_notes', p_deposit);

  perform app.refresh_deposit(p_deposit);
  return v_entry;
end;
$$;

revoke all on function public.apply_deposit(uuid, uuid, numeric, date)
  from public, anon;
grant execute on function public.apply_deposit(uuid, uuid, numeric, date)
  to authenticated;

-- ---------------------------------------------------------------------
-- Giving it back, or keeping it
-- ---------------------------------------------------------------------
--
-- One function, because the two are the same movement out of the held
-- account and differ only in where the other side lands: a refund goes
-- back to the bank, a forfeit goes to income or to expense depending on
-- whose deposit was lost.
create or replace function public.settle_deposit(
  p_deposit uuid,
  p_kind    text,
  p_amount  numeric,
  p_reason  text default null,
  p_bank    uuid default null,
  p_date    date default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_note   public.deposit_notes;
  v_amount numeric(18, 2) := round(coalesce(p_amount, 0), 2);
  v_held   uuid;
  v_other  uuid;
  v_bank   uuid;
  v_lines  jsonb;
  v_entry  uuid;
  v_on     date := coalesce(p_date, current_date);
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
  if p_kind not in ('refund', 'forfeit') then
    raise exception 'A deposit is either given back or kept.'
      using errcode = '23514';
  end if;
  if v_amount <= 0 then
    raise exception 'That has to be for something.' using errcode = '23514';
  end if;
  if v_amount > v_note.balance_amount then
    raise exception 'Deposit % has % left and this would take %.',
      v_note.deposit_no, v_note.balance_amount, v_amount using errcode = '23514';
  end if;
  if p_kind = 'forfeit' and coalesce(trim(p_reason), '') = '' then
    raise exception
      'Say why. A deposit kept without a reason is the one the customer '
      'rings about.' using errcode = '23514';
  end if;

  v_held := app.deposit_account(v_note.org_id, v_note.kind::text);

  if p_kind = 'refund' then
    select a.id into v_bank from public.bank_accounts b
      join public.accounts a on a.id = b.account_id
     where b.id = coalesce(p_bank, v_note.bank_account_id)
       and b.org_id = v_note.org_id;
    if v_bank is null then
      select id into v_bank from public.accounts
       where org_id = v_note.org_id and code = '1120' and not is_group;
    end if;
    v_other := v_bank;
  else
    -- A customer walking away from his deposit is our income; us
    -- walking away from one we paid is our loss. Two accounts, because
    -- they are two different things and netting them would hide both.
    v_other := app.deposit_account(v_note.org_id,
                 case when v_note.kind = 'customer' then 'income' else 'expense' end);
  end if;
  if v_other is null then
    raise exception 'This company has no account to settle it to.'
      using errcode = 'P0002';
  end if;

  if v_note.kind = 'customer' then
    -- The liability goes; the money leaves, or becomes income.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_held, 'contact_id', v_note.contact_id,
        'description', p_kind || ' ' || v_note.deposit_no,
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_other, 'contact_id', v_note.contact_id,
        'description', p_kind || ' ' || v_note.deposit_no,
        'debit', 0, 'credit', v_amount));
  else
    -- The asset goes; the money comes back, or becomes a loss.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_other, 'contact_id', v_note.contact_id,
        'description', p_kind || ' ' || v_note.deposit_no,
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_held, 'contact_id', v_note.contact_id,
        'description', p_kind || ' ' || v_note.deposit_no,
        'debit', 0, 'credit', v_amount));
  end if;

  v_entry := app.create_gl_entry_internal(
    v_note.org_id, v_on, 'deposit', v_lines,
    initcap(p_kind) || ' of deposit ' || v_note.deposit_no,
    'deposit_notes', p_deposit);

  insert into public.deposit_events
    (org_id, deposit_id, kind, event_date, amount, reason, bank_account_id,
     gl_entry_id, created_by)
  values (v_note.org_id, p_deposit, p_kind::app.deposit_event_kind, v_on,
          v_amount, nullif(trim(coalesce(p_reason, '')), ''),
          case when p_kind = 'refund' then coalesce(p_bank, v_note.bank_account_id) end,
          v_entry, auth.uid());

  if p_kind = 'refund' and coalesce(p_bank, v_note.bank_account_id) is not null then
    update public.bank_accounts
       set current_balance = current_balance
             + case when v_note.kind = 'customer' then -v_amount else v_amount end
     where id = coalesce(p_bank, v_note.bank_account_id);
  end if;

  perform app.refresh_deposit(p_deposit);
  return v_entry;
end;
$$;

revoke all on function public.settle_deposit(uuid, text, numeric, text, uuid, date)
  from public, anon;
grant execute on function public.settle_deposit(uuid, text, numeric, text, uuid, date)
  to authenticated;

comment on function public.settle_deposit(uuid, text, numeric, text, uuid, date) is
  'Gives a deposit back or keeps it. A customer''s forfeited deposit is income; one we paid and lost is an expense.';

-- ---------------------------------------------------------------------
-- Undoing one
-- ---------------------------------------------------------------------
--
-- Only while nothing has been done with it. Once part of a deposit has
-- settled an invoice or been given back, the way to undo it is to undo
-- that -- a note that vanished from under a posted settlement would
-- leave the settlement pointing at nothing.
create or replace function public.void_deposit(p_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
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
    v_rev := public.reverse_gl_entry(v_note.gl_entry_id, current_date);
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
$$;

revoke all on function public.void_deposit(uuid, text) from public, anon;
grant execute on function public.void_deposit(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- The lists
-- ---------------------------------------------------------------------
create or replace function public.deposit_notes_list(
  p_org uuid, p_kind text default null, p_status text default null)
returns table (
  id          uuid,
  deposit_no  text,
  deposit_date date,
  kind        text,
  status      text,
  party       text,
  amount      numeric,
  applied     numeric,
  refunded    numeric,
  forfeited   numeric,
  balance     numeric,
  notes       text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_read_module(p_org, 'sales')
     and not app.can_read_module(p_org, 'purchases') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select n.id, n.deposit_no, n.deposit_date, n.kind::text, n.status::text,
           c.name, n.amount, n.applied_amount, n.refunded_amount,
           n.forfeited_amount, n.balance_amount, n.notes
      from public.deposit_notes n
      join public.contacts c on c.id = n.contact_id
     where n.org_id = p_org
       and (p_kind is null or n.kind::text = p_kind)
       and (p_status is null or n.status::text = p_status)
       -- A customer deposit is only visible to somebody who can see
       -- sales, and a supplier deposit to somebody who can see
       -- purchases. A company that bought one module does not get the
       -- other's money in a list.
       and ((n.kind = 'customer' and app.can_read_module(p_org, 'sales'))
         or (n.kind = 'supplier' and app.can_read_module(p_org, 'purchases')))
     order by n.deposit_date desc, n.deposit_no desc;
end;
$$;

revoke all on function public.deposit_notes_list(uuid, text, text)
  from public, anon;
grant execute on function public.deposit_notes_list(uuid, text, text)
  to authenticated;

-- What a party has sitting with us, or with them: the number somebody
-- needs before raising the invoice the deposit was taken for.
create or replace function public.deposits_held_for(p_contact uuid)
returns table (
  deposit_id uuid,
  deposit_no text,
  kind       text,
  deposit_date date,
  amount     numeric,
  balance    numeric)
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
     and not app.can_read_module(v_org, 'purchases') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select n.id, n.deposit_no, n.kind::text, n.deposit_date, n.amount,
           n.balance_amount
      from public.deposit_notes n
     where n.contact_id = p_contact
       and n.status = 'open'
       and n.balance_amount > 0
       and ((n.kind = 'customer' and app.can_read_module(v_org, 'sales'))
         or (n.kind = 'supplier' and app.can_read_module(v_org, 'purchases')))
     order by n.deposit_date, n.deposit_no;
end;
$$;

revoke all on function public.deposits_held_for(uuid) from public, anon;
grant execute on function public.deposits_held_for(uuid) to authenticated;

-- Everything that has happened to one.
create or replace function public.deposit_history(p_id uuid)
returns table (
  happened   text,
  on_date    date,
  amount     numeric,
  document   text,
  reason     text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_kind text;
begin
  select n.org_id, n.kind::text into v_org, v_kind
    from public.deposit_notes n where n.id = p_id;
  if v_org is null then
    raise exception 'No such deposit.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'sales')
     and not app.can_read_module(v_org, 'purchases') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select 'applied', d.doc_date, a.amount, d.doc_no, null::text
      from public.payment_allocations a
      join public.sales_documents d on d.id = a.invoice_id
     where a.deposit_id = p_id
    union all
    select 'applied', d.doc_date, a.amount, d.doc_no, null::text
      from public.payment_allocations a
      join public.purchase_documents d on d.id = a.bill_id
     where a.deposit_id = p_id
    union all
    select e.kind::text, e.event_date, e.amount, null::text, e.reason
      from public.deposit_events e
     where e.deposit_id = p_id
     order by 2, 1;
end;
$$;

revoke all on function public.deposit_history(uuid) from public, anon;
grant execute on function public.deposit_history(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.deposit_notes  enable row level security;
alter table public.deposit_events enable row level security;

create policy deposit_notes_read on public.deposit_notes for select
  to authenticated using (
    (kind = 'customer' and app.can_read_module(org_id, 'sales'))
    or (kind = 'supplier' and app.can_read_module(org_id, 'purchases')));

create policy deposit_events_read on public.deposit_events for select
  to authenticated using (
    exists (select 1 from public.deposit_notes n
             where n.id = deposit_id
               and ((n.kind = 'customer' and app.can_read_module(n.org_id, 'sales'))
                 or (n.kind = 'supplier' and app.can_read_module(n.org_id, 'purchases')))));

-- No write policies. A client that could write a note or an event
-- directly could hold money in the books that never arrived, or spend a
-- deposit twice.
revoke all on public.deposit_notes  from anon, authenticated;
revoke all on public.deposit_events from anon, authenticated;

grant select on public.deposit_notes  to authenticated;
grant select on public.deposit_events to authenticated;
