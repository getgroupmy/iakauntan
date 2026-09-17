-- ---------------------------------------------------------------------
-- What day the money moved
--
-- The second of the four that finish what `0419` began. `0420` carries
-- the reasoning: `current_date` is today in the session's zone, on
-- Supabase that is UTC, and for the eight hours between midnight in
-- Kuala Lumpur and midnight in London a row written now is stamped
-- yesterday.
--
-- These are the ones that move money. A cheque received, banked,
-- cleared or returned; a deposit taken, applied, settled or voided; a
-- contra between a customer who is also a supplier; the reversal a void
-- writes; the receipt written when a customer pays a payment link.
--
-- Two are worth naming.
--
-- `public.reverse_gl_entry` is the default every void above falls back
-- to, so pinning it pins the reversal date of anything that reverses
-- without naming a day.
--
-- `public.platform_topup_credit` numbers its invoice
-- `PREFIX-YYYY-nnnn` and finds the next `nnnn` by matching on that same
-- year. On the first of January, for eight hours, it issued the new
-- year's invoice under the old year's prefix and counted it against the
-- old year's series.
--
-- Every one of these still honours a date the caller supplies.
-- `app.today()` replaces the fallback, not the parameter.
-- ---------------------------------------------------------------------

-- A post-dated cheque is received on a day.
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
  v_on     date := coalesce(p_received, app.today());
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

-- Banked on a day.
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
     set status = 'deposited', deposited_on = coalesce(p_on, app.today())
   where id = p_id;
  return true;
end;
$$;

-- Cleared on a day.
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

  v_on  := coalesce(p_on, app.today());
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

-- And returned on a day.
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

  v_on   := coalesce(p_on, app.today());
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

-- Cancelling one reverses its entry, dated today.
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
    v_rev := public.reverse_gl_entry(v_c.gl_entry_id, app.today());
  end if;
  delete from public.payment_allocations where pdc_id = p_id;

  update public.post_dated_cheques
     set status = 'cancelled', bounce_reason = trim(p_reason),
         bounce_entry_id = v_rev
   where id = p_id;
  return v_rev;
end;
$$;

-- A deposit taken before there is anything to bill.
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
  values (p_org, v_no, coalesce(p_date, app.today()), p_kind::app.deposit_kind,
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
    p_org, coalesce(p_date, app.today()), 'deposit', v_lines,
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

-- Applied against a document.
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

-- Settled or refunded.
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
  v_on     date := coalesce(p_date, app.today());
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

-- And voided, which reverses.
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
    v_rev := public.reverse_gl_entry(v_note.gl_entry_id, app.today());
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

-- A contra between a customer who is also a supplier.
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
          coalesce(p_date, app.today()), v_cust, v_cust, 1, p_notes,
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
    p_org, coalesce(p_date, app.today()), 'contra', v_lines,
    'Contra ' || (select n.contra_no from public.contra_notes n where n.id = v_id),
    'contra_notes', v_id);

  update public.contra_notes set gl_entry_id = v_entry where id = v_id;
  return v_id;
end;
$$;

-- And its reversal.
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
    v_rev := public.reverse_gl_entry(v_note.gl_entry_id, app.today());
  end if;

  update public.contra_notes
     set status = 'void', void_entry_id = v_rev, void_reason = trim(p_reason),
         voided_at = now(), voided_by = auth.uid()
   where id = p_id;
  return v_rev;
end;
$$;

-- Voiding an invoice reverses its entry, dated today.
create or replace function public.void_sales_document(p_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_doc public.sales_documents;
begin
  select * into v_doc from public.sales_documents where id = p_id;
  if not found then raise exception 'Document % not found', p_id; end if;
  if not app.can_post(v_doc.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_doc.paid_amount > 0 then
    raise exception 'Cannot void %: payments have been applied', v_doc.doc_no;
  end if;
  if v_doc.einvoice_status = 'valid' then
    raise exception 'Cannot void %: cancel the e-Invoice with LHDN first', v_doc.doc_no;
  end if;

  if v_doc.gl_entry_id is not null then
    perform public.reverse_gl_entry(v_doc.gl_entry_id, app.today());
  end if;

  update public.sales_documents
     set status = 'void',
         internal_notes = coalesce(internal_notes || E'\n', '') || 'Voided: ' || coalesce(p_reason, '')
   where id = p_id;
end;
$$;

-- Which is the default date every reversal above falls back to.
create or replace function public.reverse_gl_entry(
  p_entry_id uuid, p_date date default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_entry public.gl_entries;
  v_new_id uuid;
  v_period_id uuid;
  v_status text;
  v_on date := coalesce(p_date, app.today());
begin
  select * into v_entry from public.gl_entries where id = p_entry_id;
  if not found then raise exception 'Journal % not found', p_entry_id; end if;
  if not app.can_post(v_entry.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_entry.status <> 'posted' then
    raise exception 'Only posted journals can be reversed' using errcode = '22023';
  end if;

  -- Reversing twice would contra the contra and put the entry back,
  -- which is the shape of the bug this migration exists to fix.
  if exists (select 1 from public.gl_entries r
              where r.reversed_entry_id = p_entry_id and r.status = 'posted') then
    raise exception 'Journal % has already been reversed', v_entry.entry_no
      using errcode = '22023';
  end if;

  v_period_id := app.period_for_date(v_entry.org_id, v_on);
  if v_period_id is null then
    raise exception
      'No fiscal period covers %. Create the fiscal year before posting to it.',
      v_on using errcode = '23514';
  end if;
  select status into v_status from public.fiscal_periods where id = v_period_id;
  if v_status <> 'open' then
    raise exception 'Fiscal period for % is %', v_on, v_status using errcode = '23514';
  end if;

  insert into public.gl_entries (
    org_id, entry_no, entry_date, fiscal_period_id, source, source_table, source_id,
    description, reference, currency, exchange_rate, status, is_reversal,
    reversed_entry_id, posted_at, posted_by, created_by
  ) values (
    v_entry.org_id, app.next_document_number_internal(v_entry.org_id, 'journal'),
    v_on, v_period_id, v_entry.source,
    v_entry.source_table, v_entry.source_id,
    'Reversal of ' || v_entry.entry_no, v_entry.reference,
    v_entry.currency, v_entry.exchange_rate, 'posted', true, v_entry.id,
    now(), auth.uid(), auth.uid()
  ) returning id into v_new_id;

  insert into public.gl_lines (
    org_id, entry_id, line_no, account_id, description, debit, credit,
    currency, exchange_rate, contact_id, item_id, tax_code_id)
  select org_id, v_new_id, line_no, account_id,
         'Reversal: ' || coalesce(description, ''),
         credit, debit, currency, exchange_rate, contact_id, item_id, tax_code_id
    from public.gl_lines where entry_id = p_entry_id;

  -- The original stays posted. The pair nets to zero, and both halves
  -- are on the page where an auditor can see what happened.
  return v_new_id;
end; $$;

-- The receipt written when a customer pays the link they were sent.
create or replace function public.settle_shared_payment(
  p_gateway      text,
  p_provider_ref text,
  p_paid         boolean,
  p_paid_amount  numeric,
  p_payload      jsonb default null)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $fn$
declare
  v_pay     public.sales_gateway_payments;
  v_doc     public.sales_documents;
  v_cfg     public.org_payment_gateways;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb) - 'x_signature';
  v_no      text;
  v_rcp     uuid;
  v_take    numeric;
begin
  select * into v_pay from public.sales_gateway_payments
   where gateway_code = lower(btrim(coalesce(p_gateway, '')))
     and provider_ref = btrim(coalesce(p_provider_ref, ''));

  -- A confirmation for a payment this system never started. Quiet on
  -- purpose: `settle_gateway_payment` made the same choice, and for the
  -- same reason -- an answer that distinguishes a wrong guess from a
  -- right one is an oracle.
  if v_pay.id is null then
    return 'unknown';
  end if;

  -- Acquirers retry. A retry is not a payment.
  if v_pay.state = 'paid' then
    return 'already_paid';
  end if;

  if not coalesce(p_paid, false) then
    update public.sales_gateway_payments
       set state = 'failed', provider_payload = v_payload
     where id = v_pay.id;
    return 'not_paid';
  end if;

  -- What was handed over has to cover what was owed. Recorded and
  -- refused, never rounded up into a settled invoice.
  if coalesce(p_paid_amount, 0) < v_pay.amount then
    update public.sales_gateway_payments
       set state = 'underpaid', paid_amount = coalesce(p_paid_amount, 0),
           provider_payload = v_payload
     where id = v_pay.id;
    return 'underpaid';
  end if;

  select * into v_doc from public.sales_documents where id = v_pay.document_id;
  select * into v_cfg from public.org_payment_gateways
   where org_id = v_pay.org_id and gateway_code = v_pay.gateway_code
     and mode = v_pay.mode;

  -- Never more than is still owed. Two customers paying the same link
  -- twice, or a payment that landed after somebody keyed the cheque in,
  -- must not leave the invoice in credit through this door.
  v_take := least(v_pay.amount, coalesce(v_doc.balance_amount, 0));

  if v_take > 0 then
    v_no := app.next_document_number_internal(v_pay.org_id, 'receipt');

    insert into public.receipts
      (org_id, receipt_no, receipt_date, contact_id, payment_mode_code,
       bank_account_id, currency, exchange_rate, amount, base_amount,
       status, reference, notes)
    values (
      v_pay.org_id, v_no, app.today(), v_doc.contact_id,
      coalesce(v_cfg.payment_mode_code, '03'),
      v_cfg.settlement_bank_account_id,
      v_doc.currency, coalesce(v_doc.exchange_rate, 1), v_take, v_take,
      'draft', v_pay.provider_ref,
      'Paid online through ' || v_pay.gateway_code
        || ' (' || v_pay.provider_ref || ')')
    returning id into v_rcp;

    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount)
    values (v_pay.org_id, v_rcp, v_doc.id, v_take);

    -- The one path into the ledger. Nothing here writes gl_entries:
    -- `0399` closed that door and this migration does not reopen it.
    perform app.post_receipt_internal(v_rcp);
  end if;

  update public.sales_gateway_payments
     set state = 'paid', paid_amount = p_paid_amount, paid_at = now(),
         receipt_id = v_rcp, provider_payload = v_payload
   where id = v_pay.id;

  return 'paid';
end
$fn$;

-- And the invoice for a credit top-up, number and all.
create or replace function public.platform_topup_credit(
  p_org_id uuid,
  p_amount numeric,
  p_note   text default null)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_issuer  jsonb;
  v_org     public.organizations;
  v_no      text;
  v_prefix  text;
  v_seq     integer;
  v_rate    numeric(6, 3) := 0;
  v_tax     numeric(18, 2) := 0;
  v_invoice uuid;
  v_balance numeric(18, 2);
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A top-up has to be more than nothing'
      using errcode = '23514';
  end if;

  select * into v_org from public.organizations where id = p_org_id;
  if v_org.id is null then
    raise exception 'No such organization' using errcode = '42704';
  end if;

  select value into v_issuer from public.platform_settings
   where key = 'platform_issuer';
  v_issuer := coalesce(v_issuer, '{}'::jsonb);

  if coalesce((v_issuer ->> 'sst_registered')::boolean, false) then
    v_rate := coalesce((v_issuer ->> 'sst_rate')::numeric, 0);
    v_tax  := round(p_amount * v_rate / 100, 2);
  end if;

  -- One number at a time, per year. The advisory lock is transaction
  -- scoped, so two administrators topping up at once queue rather than
  -- both reading the same max and colliding on the unique index.
  perform pg_advisory_xact_lock(hashtext('platform_invoice_no'));
  v_prefix := coalesce(nullif(v_issuer ->> 'invoice_prefix', ''), 'KH');
  select coalesce(max(substring(i.invoice_no from '[0-9]+$')::integer), 0) + 1
    into v_seq
    from public.platform_invoices i
   where i.invoice_no like v_prefix || '-' || to_char(app.today(), 'YYYY') || '-%';
  v_no := format('%s-%s-%s', v_prefix, to_char(app.today(), 'YYYY'),
                 lpad(v_seq::text, 4, '0'));

  insert into public.platform_invoices (
    invoice_no, org_id, issue_date, currency,
    issuer_name, issuer_registration_no, issuer_old_registration_no,
    issuer_sst_no, issuer_address,
    bill_to_name, bill_to_registration_no, bill_to_tin, bill_to_address,
    description, subtotal, tax_rate, tax_amount, total_amount,
    notes, issued_by)
  values (
    v_no, p_org_id, app.today(), 'MYR',
    coalesce(v_issuer ->> 'name', 'Kabeer Holdings Sdn Bhd'),
    v_issuer ->> 'registration_no',
    v_issuer ->> 'old_registration_no',
    nullif(v_issuer ->> 'sst_no', ''),
    nullif(v_issuer ->> 'address', ''),
    v_org.name, v_org.registration_no, v_org.tin, v_org.address_line1,
    'Document scanning credit', p_amount, v_rate, v_tax, p_amount + v_tax,
    p_note, auth.uid())
  returning id into v_invoice;

  v_balance := app.move_credit(
    p_org_id, 'topup', p_amount,
    format('Top-up on invoice %s', v_no), null, v_invoice, false);

  return jsonb_build_object(
    'invoice_id', v_invoice,
    'invoice_no', v_no,
    'subtotal',   p_amount,
    'tax_amount', v_tax,
    'total',      p_amount + v_tax,
    'balance',    v_balance);
end;
$$;
