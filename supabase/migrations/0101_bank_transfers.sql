-- =====================================================================
-- iAkauntan :: 0101 bank-to-bank transfer
--
-- Moving money between the company's own accounts has meant writing a
-- manual journal since 0089. That works and posts correctly, and it is
-- still the wrong tool: nothing records that the two sides are one
-- movement, so a transfer cannot be voided as a unit, cannot be found
-- again by either bank, and shows up on a reconciliation as two
-- unrelated entries somebody has to recognise.
--
-- Three things this has to get right, and only the first is obvious:
--
-- **It is not a cash flow.** Both ends are cash, so the money has not
-- entered or left the business. `report_cash_flow` classifies anything
-- with subtype `bank` or `cash` as cash and nets it out, so a transfer
-- moves no figure on the statement — except the fee, which is a real
-- expense. `supabase/tests/bank_transfers.sql` asserts exactly that,
-- because a transfer that inflated operating cash flow would flatter
-- every set of accounts the company files.
--
-- **The three amounts have to add up, and are checked rather than
-- assumed.** What the bank took out of one account, what arrived in the
-- other, and the fee are three separate facts, and which of them the
-- fee was deducted from varies by bank. Recording all three and
-- insisting they reconcile handles either arrangement and catches a
-- typo; guessing one from the others would silently bury it.
--
-- **A residual is only exchange.** When the two accounts share a
-- currency, anything left over after the fee is an error and is
-- refused. When they do not, it is realised exchange difference and is
-- posted as such — the same treatment settlement gets in 0079.
-- =====================================================================

create table if not exists public.bank_transfers (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  transfer_no     text not null,
  transfer_date   date not null default current_date,

  from_account_id uuid not null references public.bank_accounts (id) on delete restrict,
  to_account_id   uuid not null references public.bank_accounts (id) on delete restrict,

  -- What the bank took out of one, what arrived in the other, and what
  -- it charged. Each in the currency of the account it touches; the fee
  -- follows the sending account.
  amount_sent     numeric(18, 2) not null check (amount_sent > 0),
  amount_received numeric(18, 2) not null check (amount_received > 0),
  bank_charges    numeric(18, 2) not null default 0 check (bank_charges >= 0),

  -- The rates the two sides were converted at, kept so the entry can be
  -- read back without asking the rate table what it says today.
  from_rate       numeric(18, 8) not null default 1 check (from_rate > 0),
  to_rate         numeric(18, 8) not null default 1 check (to_rate > 0),
  fx_difference   numeric(18, 2) not null default 0,

  reference       text,
  notes           text,

  status          app.doc_status not null default 'draft',
  gl_entry_id     uuid references public.gl_entries (id) on delete set null,
  posted_at       timestamptz,
  posted_by       uuid references auth.users (id),

  created_by      uuid references auth.users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,

  unique (org_id, transfer_no),
  -- Money cannot move from an account to itself, and a journal that
  -- debits and credits the same account is a journal that does nothing.
  constraint bank_transfers_distinct_ck check (from_account_id <> to_account_id)
);

create index if not exists bank_transfers_by_date
  on public.bank_transfers (org_id, transfer_date desc);
create index if not exists bank_transfers_from on public.bank_transfers (from_account_id);
create index if not exists bank_transfers_to on public.bank_transfers (to_account_id);

drop trigger if exists set_updated_at on public.bank_transfers;
create trigger set_updated_at before update on public.bank_transfers
  for each row execute function app.set_updated_at();

alter table public.bank_transfers enable row level security;

drop policy if exists bank_transfers_select on public.bank_transfers;
create policy bank_transfers_select on public.bank_transfers
  for select to authenticated using (app.is_org_member(org_id));
drop policy if exists bank_transfers_write on public.bank_transfers;
create policy bank_transfers_write on public.bank_transfers
  for all to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));

-- Supabase grants `anon` and `authenticated` every privilege on a new
-- public table, which leaves RLS as the only barrier. These rows say
-- how much money the company has and where it keeps it.
revoke all on public.bank_transfers from anon;
revoke all on public.bank_transfers from authenticated;
grant select, insert, update, delete on public.bank_transfers to authenticated;

-- 'transfer' has no prefix of its own in `app.default_doc_prefix`, and
-- the fallback would give it 'TRA-'.
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
    when 'bank_transfer'        then 'TRF-'
    else upper(left(p_doc_type, 3)) || '-'
  end;
$$;

-- ---------------------------------------------------------------------
-- Raising one
-- ---------------------------------------------------------------------
create or replace function public.create_bank_transfer(
  p_from_account_id uuid,
  p_to_account_id uuid,
  p_amount_sent numeric,
  p_transfer_date date default current_date,
  p_amount_received numeric default null,
  p_bank_charges numeric default 0,
  p_reference text default null,
  p_notes text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  f public.bank_accounts;
  t public.bank_accounts;
  v_base char(3);
  v_charges numeric(18, 2) := round(coalesce(p_bank_charges, 0), 2);
  v_sent numeric(18, 2) := round(p_amount_sent, 2);
  v_received numeric(18, 2);
  v_from_rate numeric(18, 8);
  v_to_rate numeric(18, 8);
  v_diff numeric(18, 2);
  v_id uuid;
begin
  select * into f from public.bank_accounts where id = p_from_account_id;
  if not found then
    raise exception 'No such bank account to send from' using errcode = 'P0002';
  end if;
  select * into t from public.bank_accounts where id = p_to_account_id;
  if not found then
    raise exception 'No such bank account to send to' using errcode = 'P0002';
  end if;

  if not app.can_post(f.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  -- Two companies' bank accounts in one journal would breach the
  -- boundary every other part of this system is built around.
  if f.org_id <> t.org_id then
    raise exception 'Those accounts belong to different organizations'
      using errcode = '42501';
  end if;
  if f.id = t.id then
    raise exception 'That is the same account at both ends'
      using errcode = '22023';
  end if;
  if v_sent <= 0 then
    raise exception 'A transfer needs an amount' using errcode = '22023';
  end if;

  select base_currency into v_base from public.organizations where id = f.org_id;
  v_from_rate := case when f.currency = coalesce(v_base, 'MYR') then 1
    else app.exchange_rate_for(f.org_id, f.currency, p_transfer_date) end;
  v_to_rate := case when t.currency = coalesce(v_base, 'MYR') then 1
    else app.exchange_rate_for(f.org_id, t.currency, p_transfer_date) end;

  if v_from_rate is null or v_to_rate is null then
    raise exception
      'No exchange rate for % on %. Add one before moving money between '
      'accounts in different currencies.',
      case when v_from_rate is null then f.currency else t.currency end,
      p_transfer_date using errcode = '22023';
  end if;

  -- Same currency and nobody said otherwise: what arrives is what left,
  -- less the fee. Across currencies there is nothing to assume, and
  -- guessing would be inventing a rate.
  v_received := round(coalesce(p_amount_received,
    case when f.currency = t.currency then v_sent - v_charges else null end), 2);
  if v_received is null then
    raise exception
      'Say how much arrived in %: the accounts are in different currencies',
      t.currency using errcode = '22023';
  end if;
  if v_received <= 0 then
    raise exception 'Nothing arrived at the other end' using errcode = '22023';
  end if;

  v_diff := round(v_sent * v_from_rate, 2)
          - round(v_received * v_to_rate, 2)
          - round(v_charges * v_from_rate, 2);

  -- In one currency the three figures are arithmetic, not judgement, so
  -- a residual is a typo rather than an exchange difference.
  if f.currency = t.currency and v_diff <> 0 then
    raise exception
      'Sent %, received % and % in charges do not add up — % is left over',
      v_sent, v_received, v_charges, v_diff using errcode = '22023';
  end if;

  insert into public.bank_transfers
    (org_id, transfer_no, transfer_date, from_account_id, to_account_id,
     amount_sent, amount_received, bank_charges, from_rate, to_rate,
     fx_difference, reference, notes, created_by)
  values (
    f.org_id, public.next_document_number(f.org_id, 'bank_transfer'),
    p_transfer_date, f.id, t.id,
    v_sent, v_received, v_charges, v_from_rate, v_to_rate, v_diff,
    p_reference, p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end; $$;

-- ---------------------------------------------------------------------
-- Posting it
--
--   Dr  receiving account   what arrived
--   Dr  bank charges        what the bank kept
--   Dr/Cr exchange          whatever the two currencies did to it
--   Cr  sending account     what left
-- ---------------------------------------------------------------------
create or replace function public.post_bank_transfer(p_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r public.bank_transfers;
  f public.bank_accounts;
  t public.bank_accounts;
  v_from_gl uuid;
  v_to_gl uuid;
  v_entries jsonb := '[]'::jsonb;
  v_sent numeric(18, 2);
  v_received numeric(18, 2);
  v_charges numeric(18, 2);
  v_entry uuid;
begin
  select * into r from public.bank_transfers where id = p_id and deleted_at is null;
  if not found then
    raise exception 'Transfer % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_post(r.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if r.gl_entry_id is not null then
    raise exception 'Transfer % is already posted', r.transfer_no;
  end if;

  select * into f from public.bank_accounts where id = r.from_account_id;
  select * into t from public.bank_accounts where id = r.to_account_id;
  v_from_gl := f.account_id;
  v_to_gl := t.account_id;

  v_sent := round(r.amount_sent * r.from_rate, 2);
  v_received := round(r.amount_received * r.to_rate, 2);
  v_charges := round(r.bank_charges * r.from_rate, 2);

  v_entries := v_entries
    || jsonb_build_object(
         'account_id', v_to_gl,
         'description', 'Transfer in ' || r.transfer_no,
         'debit', v_received, 'credit', 0)
    || jsonb_build_object(
         'account_id', v_from_gl,
         'description', 'Transfer out ' || r.transfer_no,
         'debit', 0, 'credit', v_sent);

  if v_charges > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', (select id from public.accounts
                      where org_id = r.org_id and code = '6300'),
      'description', 'Bank charges ' || r.transfer_no,
      'debit', v_charges, 'credit', 0);
  end if;

  -- Only ever non-zero across currencies: `create_bank_transfer`
  -- refuses a residual when both ends are in the same one.
  if r.fx_difference <> 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', (select id from public.accounts where org_id = r.org_id
                      and code = case when r.fx_difference > 0
                                      then '6500' else '4920' end),
      'description', 'Exchange difference on ' || r.transfer_no,
      'debit', greatest(r.fx_difference, 0),
      'credit', greatest(-r.fx_difference, 0));
  end if;

  v_entry := public.create_gl_entry(
    r.org_id, r.transfer_date, 'bank_transaction'::app.journal_source,
    v_entries,
    'Transfer ' || r.transfer_no || ': ' || f.name || ' to ' || t.name,
    'bank_transfers', r.id, r.reference);

  -- `current_balance` is carried in the base currency everywhere else
  -- in this schema, so it is carried in the base currency here.
  update public.bank_accounts
     set current_balance = current_balance - v_sent - v_charges
   where id = r.from_account_id;
  update public.bank_accounts
     set current_balance = current_balance + v_received
   where id = r.to_account_id;

  update public.bank_transfers
     set gl_entry_id = v_entry, status = 'posted',
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  return v_entry;
end; $$;

-- ---------------------------------------------------------------------
-- Undoing one
--
-- Reversed rather than deleted: the journal happened, and a bank
-- statement that has already been reconciled against it should not
-- silently lose the entry it was matched to.
-- ---------------------------------------------------------------------
create or replace function public.void_bank_transfer(
  p_id uuid, p_reason text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r public.bank_transfers;
  v_sent numeric(18, 2);
  v_received numeric(18, 2);
  v_charges numeric(18, 2);
  v_reversal uuid;
begin
  select * into r from public.bank_transfers where id = p_id and deleted_at is null;
  if not found then
    raise exception 'Transfer % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_post(r.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if r.status = 'void' then
    raise exception 'Transfer % is already void', r.transfer_no
      using errcode = '22023';
  end if;

  if r.gl_entry_id is not null then
    v_reversal := public.reverse_gl_entry(r.gl_entry_id, r.transfer_date);

    v_sent := round(r.amount_sent * r.from_rate, 2);
    v_received := round(r.amount_received * r.to_rate, 2);
    v_charges := round(r.bank_charges * r.from_rate, 2);

    update public.bank_accounts
       set current_balance = current_balance + v_sent + v_charges
     where id = r.from_account_id;
    update public.bank_accounts
       set current_balance = current_balance - v_received
     where id = r.to_account_id;
  end if;

  update public.bank_transfers
     set status = 'void',
         notes = trim(both E'\n' from
                      coalesce(notes, '') || E'\n' ||
                      'Voided: ' || coalesce(p_reason, 'no reason given'))
   where id = p_id;

  return v_reversal;
end; $$;

revoke all on function public.create_bank_transfer(
  uuid, uuid, numeric, date, numeric, numeric, text, text) from public, anon;
revoke all on function public.post_bank_transfer(uuid) from public, anon;
revoke all on function public.void_bank_transfer(uuid, text) from public, anon;
grant execute on function public.create_bank_transfer(
  uuid, uuid, numeric, date, numeric, numeric, text, text) to authenticated;
grant execute on function public.post_bank_transfer(uuid) to authenticated;
grant execute on function public.void_bank_transfer(uuid, text) to authenticated;
