-- =====================================================================
-- The cheque dated next month
--
-- A contractor settles a RM 40,000 invoice with a cheque dated the
-- fifteenth of next month. It is a normal way to pay in Malaysian
-- trading and it is not money in the bank: the bank will bounce it if
-- it is presented today, and it may bounce on the fifteenth too.
--
-- `receipts.cheque_date` has existed since 0005 and nothing has ever
-- read it. So the only way to record that cheque is a receipt, and
-- `post_receipt` debits the bank on the day it is entered. The bank
-- balance then includes six weeks of money that cannot be drawn, the
-- cash flow is wrong by the whole post-dated book, and a cheque that
-- bounces leaves an invoice marked paid with nothing behind it.
--
-- ---------------------------------------------------------------------
-- Where it sits until it clears
--
--   received      Dr 1140 Cheques on Hand   Cr Receivable
--   cleared       Dr Bank                   Cr 1140
--   bounced       Dr Receivable             Cr 1140
--
--   issued        Dr Payable                Cr 2115 Cheques Issued
--   presented     Dr 2115                   Cr Bank
--   stopped       Dr 2115                   Cr Payable
--
-- The debtor has discharged his debt with a negotiable instrument, so
-- the receivable goes and the aged listing stops chasing him -- that
-- part is right on the day the cheque is handed over. What is wrong is
-- calling it bank, and 1140 is the difference. Nothing touches the bank
-- balance until the cheque actually clears, which is the whole point of
-- the exercise.
--
-- ---------------------------------------------------------------------
-- Banking it is not clearing it
--
-- `deposited` is a status and posts nothing. A cheque paid in on Monday
-- is still a cheque until it clears on Thursday, and a ledger entry on
-- Monday would put the money in the bank three days early -- the same
-- error this migration exists to fix, made smaller.
--
-- ---------------------------------------------------------------------
-- A bounce puts the invoice back
--
-- The allocations are deleted and `app.apply_allocation` recomputes the
-- invoice from what is left, so it is outstanding again and back in the
-- chasing. That works because 0272 taught the settlement trigger to put
-- a document back to `posted` when everything is unallocated; before
-- that fix a bounced cheque would have left the invoice reading
-- `completed` while owing its full amount, which is exactly the silent
-- failure a bounce must not have.
--
-- ---------------------------------------------------------------------
-- What this is not
--
-- Not a discounting facility: a cheque handed to a bank for advance
-- credit is a borrowing with interest and covenants, and pretending a
-- status change covers it would be worse than not offering it.
-- `receipts.cheque_date` is left alone -- a cheque banked the same day
-- is a receipt, and always was.
-- =====================================================================

alter type app.journal_source add value if not exists 'cheque';

create type app.pdc_direction as enum ('incoming', 'outgoing');
create type app.pdc_status as enum
  ('held', 'deposited', 'cleared', 'bounced', 'cancelled');

-- ---------------------------------------------------------------------
-- Its own number series
-- ---------------------------------------------------------------------
--
-- Re-created from 0273, which is the last migration to define it, with
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
    when 'cheque'               then 'PDC-'
    else upper(left(p_doc_type, 3)) || '-'
  end;
$$;

-- ---------------------------------------------------------------------
-- Where an uncleared cheque lives
-- ---------------------------------------------------------------------
--
-- 1140 for one coming in, 2115 for one going out. Neither is in the
-- seeded chart and both are created on first use, so a company that is
-- never handed a post-dated cheque never grows an account for them.
create or replace function app.cheque_account(p_org_id uuid, p_direction text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id uuid;
  v_in boolean := p_direction = 'incoming';
  v_code text := case when v_in then '1140' else '2115' end;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = v_code and not is_group;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, v_code,
          case when v_in then 'Cheques on Hand' else 'Cheques Issued' end,
          (case when v_in then 'asset' else 'liability' end)::app.account_type,
          (case when v_in then 'current_asset' else 'current_liability' end)
            ::app.account_subtype,
          false, true, v_code::integer,
          (select id from public.accounts
            where org_id = p_org_id
              and code = case when v_in then '1100' else '2100' end))
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function app.cheque_account(uuid, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The register
-- ---------------------------------------------------------------------
create table public.post_dated_cheques (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id)
                  on delete cascade,
  pdc_no        text not null,
  direction     app.pdc_direction not null,
  status        app.pdc_status not null default 'held',

  contact_id    uuid not null references public.contacts(id),
  cheque_no     text not null,

  -- The date on the face of it. The whole register is sorted by this
  -- and the morning question is "what matures this week".
  cheque_date   date not null,
  bank_name     text,

  amount        numeric(18, 2) not null check (amount > 0),
  received_on   date not null default current_date,

  -- Where it will be banked, or which of ours it is drawn on.
  bank_account_id uuid references public.bank_accounts(id),

  deposited_on  date,
  cleared_on    date,
  bounced_on    date,
  bounce_reason text,

  gl_entry_id     uuid references public.gl_entries(id),
  settle_entry_id uuid references public.gl_entries(id),
  bounce_entry_id uuid references public.gl_entries(id),

  notes         text,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, pdc_no)
);

create index post_dated_cheques_org_idx
  on public.post_dated_cheques (org_id, cheque_date);
create index post_dated_cheques_contact_idx
  on public.post_dated_cheques (contact_id);
create index post_dated_cheques_open_idx
  on public.post_dated_cheques (org_id, status)
  where status in ('held', 'deposited');

create trigger post_dated_cheques_touch before update
  on public.post_dated_cheques
  for each row execute function app.set_updated_at();

comment on table public.post_dated_cheques is
  'Cheques dated in the future. The receivable goes when the cheque is handed over; the bank balance does not move until it clears.';

-- ---------------------------------------------------------------------
-- A cheque settles documents the same way everything else does
-- ---------------------------------------------------------------------
--
-- Re-created from 0273 with one more source.
alter table public.payment_allocations
  add column if not exists pdc_id uuid references public.post_dated_cheques(id)
    on delete cascade;

alter table public.payment_allocations
  drop constraint if exists payment_allocations_source_ck;
alter table public.payment_allocations
  add constraint payment_allocations_source_ck
  check (num_nonnulls(receipt_id, payment_id, credit_note_id, withholding_id,
                      contra_id, deposit_id, pdc_id) = 1);

create index payment_allocations_pdc_idx
  on public.payment_allocations (pdc_id) where pdc_id is not null;

-- ---------------------------------------------------------------------
-- Taking one in, or writing one out
-- ---------------------------------------------------------------------
--
-- Each entry of p_documents is `{document, amount}` — invoices for a
-- cheque coming in, bills for one going out. They must come to the
-- cheque, because a cheque that settles less than its face value is two
-- facts pretending to be one.
create or replace function public.record_pdc(
  p_org       uuid,
  p_direction text,
  p_contact   uuid,
  p_cheque_no text,
  p_cheque_date date,
  p_amount    numeric,
  p_documents jsonb default '[]'::jsonb,
  p_bank      uuid default null,
  p_bank_name text default null,
  p_received  date default null,
  p_notes     text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id     uuid;
  v_no     text;
  v_in     boolean := p_direction = 'incoming';
  v_module text := case when p_direction = 'incoming' then 'sales' else 'purchases' end;
  v_amount numeric(18, 2) := round(coalesce(p_amount, 0), 2);
  v_held   uuid;
  v_ctrl   uuid;
  v_e      jsonb;
  v_doc    record;
  v_amt    numeric(18, 2);
  v_alloc  numeric(18, 2) := 0;
  v_lines  jsonb;
  v_entry  uuid;
  v_on     date := coalesce(p_received, current_date);
begin
  if p_direction not in ('incoming', 'outgoing') then
    raise exception 'A cheque is either taken in or written out.'
      using errcode = '23514';
  end if;
  if not app.can_write_module(p_org, v_module) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_amount <= 0 then
    raise exception 'A cheque has to be for something.' using errcode = '23514';
  end if;
  if coalesce(trim(p_cheque_no), '') = '' then
    raise exception 'A cheque has a number on it.' using errcode = '23514';
  end if;
  if p_cheque_date is null then
    raise exception 'A cheque has a date on it.' using errcode = '23514';
  end if;
  -- A cheque dated today or earlier is not post-dated; it is a receipt,
  -- and recording it here would park money in 1140 that could have been
  -- banked this morning.
  if p_cheque_date <= v_on then
    raise exception
      'That cheque is dated % and was received on %. A cheque that can be '
      'banked today is a receipt, not a post-dated cheque.',
      p_cheque_date, v_on using errcode = '23514';
  end if;
  if not exists (select 1 from public.contacts c
                  where c.id = p_contact and c.org_id = p_org) then
    raise exception 'No such contact.' using errcode = 'P0002';
  end if;

  v_no := app.next_document_number_internal(p_org, 'cheque');

  insert into public.post_dated_cheques
    (org_id, pdc_no, direction, contact_id, cheque_no, cheque_date, bank_name,
     amount, received_on, bank_account_id, notes, created_by)
  values (p_org, v_no, p_direction::app.pdc_direction, p_contact,
          trim(p_cheque_no), p_cheque_date, p_bank_name, v_amount, v_on,
          p_bank, p_notes, auth.uid())
  returning id into v_id;

  -- What it settles.
  for v_e in select * from jsonb_array_elements(coalesce(p_documents, '[]'::jsonb))
  loop
    v_amt := round((v_e->>'amount')::numeric, 2);
    if v_amt <= 0 then
      raise exception 'A settlement has to be for something.'
        using errcode = '23514';
    end if;

    if v_in then
      select d.doc_no, d.balance_amount, d.status::text, d.contact_id, d.currency
        into v_doc
        from public.sales_documents d
       where d.id = (v_e->>'document')::uuid and d.org_id = p_org
         and d.doc_type = 'invoice' and d.deleted_at is null;
    else
      select d.doc_no, d.balance_amount, d.status::text, d.contact_id, d.currency
        into v_doc
        from public.purchase_documents d
       where d.id = (v_e->>'document')::uuid and d.org_id = p_org
         and d.doc_type = 'bill' and d.deleted_at is null;
    end if;

    if v_doc.doc_no is null then
      raise exception 'No such %.',
        case when v_in then 'invoice' else 'bill' end using errcode = 'P0002';
    end if;
    if v_doc.status not in ('posted', 'partial') then
      raise exception '% is %, and a cheque settles an outstanding document.',
        v_doc.doc_no, v_doc.status using errcode = '23514';
    end if;
    if v_doc.contact_id <> p_contact then
      raise exception 'That cheque is not %''s.', v_doc.doc_no
        using errcode = '23514';
    end if;
    if v_doc.currency <> app.base_currency(p_org) then
      raise exception
        '% is in %, and a cheque held for weeks in another currency has an '
        'exchange difference that only clearing settles. Bank it as a '
        'receipt when it matures.', v_doc.doc_no, v_doc.currency
        using errcode = '23514';
    end if;
    if v_amt > v_doc.balance_amount then
      raise exception '% has % outstanding and the cheque would settle %.',
        v_doc.doc_no, v_doc.balance_amount, v_amt using errcode = '23514';
    end if;

    if v_in then
      insert into public.payment_allocations
        (org_id, pdc_id, invoice_id, amount, allocated_by)
      values (p_org, v_id, (v_e->>'document')::uuid, v_amt, auth.uid());
    else
      insert into public.payment_allocations
        (org_id, pdc_id, bill_id, amount, allocated_by)
      values (p_org, v_id, (v_e->>'document')::uuid, v_amt, auth.uid());
    end if;
    v_alloc := v_alloc + v_amt;
  end loop;

  if v_alloc <> 0 and v_alloc <> v_amount then
    raise exception
      'The cheque is for % and it has been put against %. A cheque that '
      'settles less than its face value is two facts pretending to be one.',
      v_amount, v_alloc using errcode = '23514';
  end if;

  -- Nothing to post when the cheque is not against anything yet: it is
  -- in the register, and the register is the point.
  if v_alloc = 0 then
    return v_id;
  end if;

  v_held := app.cheque_account(p_org, p_direction);
  if v_in then
    select coalesce(c.receivable_account_id,
                    (select a.id from public.accounts a
                      where a.org_id = p_org and a.code = '1210'))
      into v_ctrl from public.contacts c where c.id = p_contact;
    -- He has discharged the debt with a negotiable instrument. The
    -- receivable goes; the bank does not move.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_held, 'contact_id', p_contact,
        'description', 'Cheque ' || trim(p_cheque_no),
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_ctrl, 'contact_id', p_contact,
        'description', 'Cheque ' || trim(p_cheque_no),
        'debit', 0, 'credit', v_amount));
  else
    select coalesce(c.payable_account_id,
                    (select a.id from public.accounts a
                      where a.org_id = p_org and a.code = '2110'))
      into v_ctrl from public.contacts c where c.id = p_contact;
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_ctrl, 'contact_id', p_contact,
        'description', 'Cheque ' || trim(p_cheque_no),
        'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_held, 'contact_id', p_contact,
        'description', 'Cheque ' || trim(p_cheque_no),
        'debit', 0, 'credit', v_amount));
  end if;

  v_entry := app.create_gl_entry_internal(
    p_org, v_on, 'cheque', v_lines,
    'Post-dated cheque ' || v_no, 'post_dated_cheques', v_id);
  update public.post_dated_cheques set gl_entry_id = v_entry where id = v_id;

  return v_id;
end;
$$;

revoke all on function public.record_pdc(uuid, text, uuid, text, date, numeric, jsonb, uuid, text, date, text)
  from public, anon;
grant execute on function public.record_pdc(uuid, text, uuid, text, date, numeric, jsonb, uuid, text, date, text)
  to authenticated;

comment on function public.record_pdc(uuid, text, uuid, text, date, numeric, jsonb, uuid, text, date, text) is
  'Puts a post-dated cheque in the register and takes the document it settles off the aged listing, without touching the bank balance.';

-- ---------------------------------------------------------------------
-- Paying it in, which is not the same as it clearing
-- ---------------------------------------------------------------------
create or replace function public.deposit_pdc(p_id uuid, p_on date default null)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_c public.post_dated_cheques;
begin
  select * into v_c from public.post_dated_cheques where id = p_id;
  if v_c.id is null then
    raise exception 'No such cheque.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_c.org_id,
        case when v_c.direction = 'incoming' then 'sales' else 'purchases' end) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_c.status <> 'held' then
    raise exception 'That cheque is %.', v_c.status using errcode = '23514';
  end if;

  -- Deliberately posts nothing. A cheque paid in on Monday is still a
  -- cheque until it clears, and an entry on Monday would put the money
  -- in the bank three days early.
  update public.post_dated_cheques
     set status = 'deposited', deposited_on = coalesce(p_on, current_date)
   where id = p_id;
  return true;
end;
$$;

revoke all on function public.deposit_pdc(uuid, date) from public, anon;
grant execute on function public.deposit_pdc(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- It cleared
-- ---------------------------------------------------------------------
create or replace function public.clear_pdc(
  p_id uuid, p_on date default null, p_bank uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_c     public.post_dated_cheques;
  v_held  uuid;
  v_bank  uuid;
  v_bid   uuid;
  v_lines jsonb;
  v_entry uuid;
  v_on    date;
begin
  select * into v_c from public.post_dated_cheques where id = p_id;
  if v_c.id is null then
    raise exception 'No such cheque.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_c.org_id,
        case when v_c.direction = 'incoming' then 'sales' else 'purchases' end) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_c.status not in ('held', 'deposited') then
    raise exception 'That cheque is %.', v_c.status using errcode = '23514';
  end if;

  v_on  := coalesce(p_on, current_date);
  v_bid := coalesce(p_bank, v_c.bank_account_id);
  select a.id into v_bank from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_bid and b.org_id = v_c.org_id;
  if v_bank is null then
    select id into v_bank from public.accounts
     where org_id = v_c.org_id and code = '1120' and not is_group;
  end if;
  if v_bank is null then
    raise exception 'This company has no bank account.' using errcode = 'P0002';
  end if;

  v_held := app.cheque_account(v_c.org_id, v_c.direction::text);

  if v_c.direction = 'incoming' then
    -- Now, and only now, it is money.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'contact_id', v_c.contact_id,
        'description', 'Cheque ' || v_c.cheque_no || ' cleared',
        'debit', v_c.amount, 'credit', 0),
      jsonb_build_object('account_id', v_held, 'contact_id', v_c.contact_id,
        'description', 'Cheque ' || v_c.cheque_no || ' cleared',
        'debit', 0, 'credit', v_c.amount));
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_held, 'contact_id', v_c.contact_id,
        'description', 'Cheque ' || v_c.cheque_no || ' presented',
        'debit', v_c.amount, 'credit', 0),
      jsonb_build_object('account_id', v_bank, 'contact_id', v_c.contact_id,
        'description', 'Cheque ' || v_c.cheque_no || ' presented',
        'debit', 0, 'credit', v_c.amount));
  end if;

  v_entry := app.create_gl_entry_internal(
    v_c.org_id, v_on, 'cheque', v_lines,
    'Cheque ' || v_c.pdc_no || ' cleared', 'post_dated_cheques', p_id);

  if v_bid is not null then
    update public.bank_accounts
       set current_balance = current_balance
             + case when v_c.direction = 'incoming' then v_c.amount
                    else -v_c.amount end
     where id = v_bid;
  end if;

  update public.post_dated_cheques
     set status = 'cleared', cleared_on = v_on, settle_entry_id = v_entry,
         bank_account_id = coalesce(v_bid, bank_account_id)
   where id = p_id;
  return v_entry;
end;
$$;

revoke all on function public.clear_pdc(uuid, date, uuid) from public, anon;
grant execute on function public.clear_pdc(uuid, date, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- It bounced
-- ---------------------------------------------------------------------
--
-- The allocations go and `app.apply_allocation` puts the invoice back
-- into the aged listing. That only works because 0272 taught the
-- settlement trigger to return a fully unallocated document to
-- `posted`; before that a bounced cheque would have left an invoice
-- reading `completed` while owing its whole value, which is exactly the
-- silent failure a bounce must not have.
create or replace function public.bounce_pdc(
  p_id uuid, p_reason text, p_on date default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_c     public.post_dated_cheques;
  v_held  uuid;
  v_ctrl  uuid;
  v_lines jsonb;
  v_entry uuid;
  v_on    date;
begin
  select * into v_c from public.post_dated_cheques where id = p_id;
  if v_c.id is null then
    raise exception 'No such cheque.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_c.org_id,
        case when v_c.direction = 'incoming' then 'sales' else 'purchases' end) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_c.status not in ('held', 'deposited') then
    raise exception 'That cheque is %.', v_c.status using errcode = '23514';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception
      'Say why. "Bounced" is not something anybody can act on, and the '
      'reason decides whether it is re-presented or chased.'
      using errcode = '23514';
  end if;

  v_on   := coalesce(p_on, current_date);
  v_held := app.cheque_account(v_c.org_id, v_c.direction::text);

  if v_c.gl_entry_id is not null then
    if v_c.direction = 'incoming' then
      select coalesce(c.receivable_account_id,
                      (select a.id from public.accounts a
                        where a.org_id = v_c.org_id and a.code = '1210'))
        into v_ctrl from public.contacts c where c.id = v_c.contact_id;
      -- He owes it again.
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', v_ctrl, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' returned',
          'debit', v_c.amount, 'credit', 0),
        jsonb_build_object('account_id', v_held, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' returned',
          'debit', 0, 'credit', v_c.amount));
    else
      select coalesce(c.payable_account_id,
                      (select a.id from public.accounts a
                        where a.org_id = v_c.org_id and a.code = '2110'))
        into v_ctrl from public.contacts c where c.id = v_c.contact_id;
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', v_held, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' stopped',
          'debit', v_c.amount, 'credit', 0),
        jsonb_build_object('account_id', v_ctrl, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' stopped',
          'debit', 0, 'credit', v_c.amount));
    end if;

    v_entry := app.create_gl_entry_internal(
      v_c.org_id, v_on, 'cheque', v_lines,
      'Cheque ' || v_c.pdc_no || ' returned', 'post_dated_cheques', p_id);
  end if;

  delete from public.payment_allocations where pdc_id = p_id;

  update public.post_dated_cheques
     set status = 'bounced', bounced_on = v_on,
         bounce_reason = trim(p_reason), bounce_entry_id = v_entry
   where id = p_id;
  return v_entry;
end;
$$;

revoke all on function public.bounce_pdc(uuid, text, date) from public, anon;
grant execute on function public.bounce_pdc(uuid, text, date) to authenticated;

comment on function public.bounce_pdc(uuid, text, date) is
  'Returns a cheque: the document it settled goes back into the aged listing and the money leaves the cheques account.';

-- ---------------------------------------------------------------------
-- Handing it back
-- ---------------------------------------------------------------------
create or replace function public.cancel_pdc(p_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_c   public.post_dated_cheques;
  v_rev uuid;
begin
  select * into v_c from public.post_dated_cheques where id = p_id;
  if v_c.id is null then
    raise exception 'No such cheque.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_c.org_id,
        case when v_c.direction = 'incoming' then 'sales' else 'purchases' end) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_c.status <> 'held' then
    raise exception
      'That cheque is %. One that has been paid in, cleared or returned is '
      'not cancelled — it is what happened.', v_c.status using errcode = '23514';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'Say why.' using errcode = '23514';
  end if;

  if v_c.gl_entry_id is not null then
    v_rev := public.reverse_gl_entry(v_c.gl_entry_id, current_date);
  end if;
  delete from public.payment_allocations where pdc_id = p_id;

  update public.post_dated_cheques
     set status = 'cancelled', bounce_reason = trim(p_reason),
         bounce_entry_id = v_rev
   where id = p_id;
  return v_rev;
end;
$$;

revoke all on function public.cancel_pdc(uuid, text) from public, anon;
grant execute on function public.cancel_pdc(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- The register, and the morning question
-- ---------------------------------------------------------------------
create or replace function public.pdc_list(
  p_org uuid, p_direction text default null, p_status text default null)
returns table (
  id           uuid,
  pdc_no       text,
  direction    text,
  status       text,
  party        text,
  cheque_no    text,
  cheque_date  date,
  bank_name    text,
  amount       numeric,
  received_on  date,
  days_to_go   integer,
  settles      bigint,
  bounce_reason text)
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
    select c.id, c.pdc_no, c.direction::text, c.status::text, ct.name,
           c.cheque_no, c.cheque_date, c.bank_name, c.amount, c.received_on,
           (c.cheque_date - current_date)::integer,
           (select count(*) from public.payment_allocations a
             where a.pdc_id = c.id),
           c.bounce_reason
      from public.post_dated_cheques c
      join public.contacts ct on ct.id = c.contact_id
     where c.org_id = p_org
       and (p_direction is null or c.direction::text = p_direction)
       and (p_status is null or c.status::text = p_status)
       and ((c.direction = 'incoming' and app.can_read_module(p_org, 'sales'))
         or (c.direction = 'outgoing' and app.can_read_module(p_org, 'purchases')))
     order by c.cheque_date, c.pdc_no;
end;
$$;

revoke all on function public.pdc_list(uuid, text, text) from public, anon;
grant execute on function public.pdc_list(uuid, text, text) to authenticated;

-- What matures between two dates and is still outstanding: the list
-- somebody reads on a Monday morning, and the one a cash flow needs.
create or replace function public.pdc_maturing(
  p_org uuid, p_from date default null, p_to date default null)
returns table (
  id          uuid,
  pdc_no      text,
  direction   text,
  status      text,
  party       text,
  cheque_no   text,
  cheque_date date,
  amount      numeric,
  overdue     boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_from date := coalesce(p_from, current_date);
  v_to   date := coalesce(p_to, current_date + 30);
begin
  if not app.can_read_module(p_org, 'sales')
     and not app.can_read_module(p_org, 'purchases') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select c.id, c.pdc_no, c.direction::text, c.status::text, ct.name,
           c.cheque_no, c.cheque_date, c.amount,
           -- A cheque whose date has passed and which has not cleared is
           -- the one somebody has forgotten to bank, and it is the whole
           -- reason to look at this list.
           c.cheque_date < current_date
      from public.post_dated_cheques c
      join public.contacts ct on ct.id = c.contact_id
     where c.org_id = p_org
       and c.status in ('held', 'deposited')
       and (c.cheque_date <= v_to)
       and (c.cheque_date >= v_from or c.cheque_date < current_date)
       and ((c.direction = 'incoming' and app.can_read_module(p_org, 'sales'))
         or (c.direction = 'outgoing' and app.can_read_module(p_org, 'purchases')))
     order by c.cheque_date, c.pdc_no;
end;
$$;

revoke all on function public.pdc_maturing(uuid, date, date) from public, anon;
grant execute on function public.pdc_maturing(uuid, date, date) to authenticated;

comment on function public.pdc_maturing(uuid, date, date) is
  'Cheques still outstanding that mature by a date, plus any already past their date and not banked — which is the whole reason to look.';

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.post_dated_cheques enable row level security;

create policy post_dated_cheques_read on public.post_dated_cheques for select
  to authenticated using (
    (direction = 'incoming' and app.can_read_module(org_id, 'sales'))
    or (direction = 'outgoing' and app.can_read_module(org_id, 'purchases')));

-- No write policy. A client that could set `status` directly could mark
-- a cheque cleared without the entry that moves the money, and the bank
-- balance would then be whatever the client said it was.
revoke all on public.post_dated_cheques from anon, authenticated;
grant select on public.post_dated_cheques to authenticated;
