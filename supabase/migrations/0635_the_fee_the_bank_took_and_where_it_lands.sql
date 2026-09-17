-- =====================================================================
-- iAkauntan :: 0635 the fee the bank took, and where it lands
--
-- P5 on the AutoCount gap list is "Payment Method with a bank-charge
-- account", and the matrix called it Partial on the strength of
-- `ref_payment_modes`. Reading what actually posts turns that around
-- twice.
--
-- ---------------------------------------------------------------------
-- The bank charge is not missing. Its account is hardcoded.
--
-- `receipts.bank_charges` and `purchase_payments.bank_charges` have
-- been columns since 0005 and 0006, and they post: `post_receipt`
-- debits the charge and credits the customer gross, `post_purchase
-- _payment` does the mirror, `post_bank_transfer` does it for a
-- transfer fee. Three live posting paths, and all three of them say:
--
--     (select id from public.accounts
--       where org_id = ... and code = '6300')
--
-- 6300 is Bank Charges in the bootstrap chart, so for a company that
-- took the chart as given, this is right. For a company that did not,
-- it is not an account at all -- and `gl_lines.account_id` is NOT
-- NULL, so the subquery returning nothing does not fall back to
-- anything. It aborts the posting with
--
--     null value in column "account_id" ... violates not-null
--
-- which names neither the receipt, nor the charge, nor 6300. That is
-- the case for every company migrating a chart of accounts in from
-- somewhere else, which is the entire audience this gap matrix is
-- written for.
--
-- `app.fx_account` -- three lines below the charge block, in the same
-- function, added in 0079 -- already solved this for the exchange
-- gain and loss accounts: look the code up, and if it is not there
-- raise something a person can act on. The charge block was simply
-- never given the same treatment. It gets it here, in the same shape
-- and with the same errcode.
--
-- ---------------------------------------------------------------------
-- What a payment method is, and why ref_payment_modes is not one
--
-- `ref_payment_modes` holds LHDN's eight codes -- 01 Cash, 02 Cheque,
-- 03 Bank Transfer, and so on. It is platform-wide, it is what an
-- e-Invoice reports, and it is not editable by a company, correctly:
-- a company does not get to invent a ninth MyInvois code.
--
-- What a company has is different and narrower: "Maybank cheque",
-- "CIMB FPX", "Stripe", "Cash at the counter". Several of those report
-- as the same LHDN code -- FPX and Stripe are both 03 -- and they
-- differ in the things LHDN does not care about and the ledger does:
-- which bank account the money lands in, and what the provider keeps.
--
-- So `payment_methods` is org-scoped master data that POINTS AT an
-- LHDN mode rather than replacing it.
--
-- ---------------------------------------------------------------------
-- Nothing moves for a company that configures nothing
--
-- The charge account is resolved as: the method named on the document,
-- then the company's default method, then code 6300. Every existing
-- row names no method and no company has one, so every existing
-- posting resolves to 6300 -- the account it was hardcoded to. The
-- suite asserts that directly rather than by inspection: the same
-- receipt, posted with no payment method configured, lands on the same
-- account it landed on before this migration.
--
-- The one behaviour that DOES change is the failure: a company with no
-- 6300 got a not-null violation and now gets a sentence. That is a
-- change from crashing to explaining, and it is the reason this is
-- worth doing at all.
--
-- ---------------------------------------------------------------------
-- The charge rate is recorded and not applied
--
-- A method carries `charge_percent` and `charge_fixed`, because "Stripe
-- keeps 2.9% + RM1" is the fact somebody wants stored once rather than
-- retyped per receipt. `suggested_charge` computes it.
--
-- Nothing in this migration calls `suggested_charge` during posting.
-- `bank_charges` stays exactly what somebody typed on the document.
-- Computing it at post time would mean a receipt whose journal depends
-- on a master-data row that can be edited afterwards, and then the same
-- receipt reposted after a rate change would not reproduce -- which is
-- the property a ledger is for. It is a figure the screen offers; the
-- document records what was taken.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The method
-- ---------------------------------------------------------------------
create table public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,

  name text not null,

  -- What this reports as on an e-Invoice. Nullable because a company
  -- not yet on e-Invoice has no reason to be asked.
  payment_mode_code text references public.ref_payment_modes (code),

  -- Where the money lands, and where the provider's cut goes.
  bank_account_id uuid,
  charge_account_id uuid,

  -- What the provider keeps, recorded so it can be offered. Both may
  -- apply at once: "2.9% + RM1" is one method, not two.
  charge_percent numeric(9, 4) not null default 0
    check (charge_percent >= 0 and charge_percent <= 100),
  charge_fixed numeric(18, 2) not null default 0
    check (charge_fixed >= 0),

  -- The one used when a document names no method. Enforced to at most
  -- one per company by a partial unique index below rather than by a
  -- trigger, so two concurrent writes cannot both win.
  is_default boolean not null default false,

  is_active boolean not null default true,
  sort_order integer not null default 0,

  notes text,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,

  -- So a document can name the pair rather than the id.
  unique (org_id, id),

  constraint payment_methods_bank_account_same_org
    foreign key (org_id, bank_account_id)
    references public.bank_accounts (org_id, id),

  constraint payment_methods_charge_account_same_org
    foreign key (org_id, charge_account_id)
    references public.accounts (org_id, id)
);

-- Two live methods cannot share a name, but an archived one does not
-- block reusing it: a company that stopped taking Stripe and started
-- again should not have to call it "Stripe 2".
create unique index payment_methods_name_key
  on public.payment_methods (org_id, lower(name))
  where deleted_at is null;

create unique index payment_methods_one_default
  on public.payment_methods (org_id)
  where is_default and deleted_at is null;

create index payment_methods_org_idx
  on public.payment_methods (org_id, sort_order, name)
  where deleted_at is null;

comment on table public.payment_methods is
  'A company''s own payment methods -- "Maybank cheque", "Stripe" -- '
  'each pointing at one LHDN mode in ref_payment_modes, and each '
  'naming the account its bank charge is posted to. 0635.';

comment on column public.payment_methods.charge_account_id is
  'Where this method''s bank charge is debited. Null falls back to the '
  'company default method, then to account code 6300.';

comment on column public.payment_methods.charge_percent is
  'Offered on the screen by suggested_charge. Never applied during '
  'posting: bank_charges is what the document says it is.';

create trigger set_updated_at before update on public.payment_methods
  for each row execute function app.set_updated_at();

alter table public.payment_methods enable row level security;

create policy payment_methods_select on public.payment_methods
  for select to authenticated using (app.is_org_member(org_id));

grant select on public.payment_methods to authenticated;
revoke all on public.payment_methods from anon;

-- A payment method names two ledger accounts, so a quiet change to one
-- redirects money. That is the test 0055 applied to `bank_accounts`
-- and `accounts`, and it applies here for the same reason.
create trigger audit_changes after insert or update or delete
  on public.payment_methods
  for each row execute function app.write_audit_log();

create trigger live_change_insert after insert on public.payment_methods
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.payment_methods
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.payment_methods
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

-- ---------------------------------------------------------------------
-- The document says which method
-- ---------------------------------------------------------------------
alter table public.receipts
  add column payment_method_id uuid,
  add constraint receipts_payment_method_same_org
    foreign key (org_id, payment_method_id)
    references public.payment_methods (org_id, id);

alter table public.purchase_payments
  add column payment_method_id uuid,
  add constraint purchase_payments_payment_method_same_org
    foreign key (org_id, payment_method_id)
    references public.payment_methods (org_id, id);

comment on column public.receipts.payment_method_id is
  'Which of the company''s own payment methods took this money. Null '
  'on every row written before 0635, and resolved the same way: the '
  'company default, then account code 6300.';

-- ---------------------------------------------------------------------
-- Where the charge lands
--
-- Modelled on `app.fx_account` (0079), down to the errcode: look it
-- up, and if the chart has nothing to put it in, say so in a sentence
-- naming the code rather than letting a null reach a NOT NULL column.
--
-- The fallback chain is ordered most specific first, and each step is
-- skipped rather than failed when it is merely unset -- a method with
-- no charge account of its own is not an error, it is a method that
-- uses the company's.
-- ---------------------------------------------------------------------
create or replace function app.bank_charge_account(
  p_org_id uuid, p_payment_method_id uuid default null)
returns uuid
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  if p_payment_method_id is not null then
    select charge_account_id into v_id from public.payment_methods
     where id = p_payment_method_id and org_id = p_org_id
       and deleted_at is null;
  end if;

  if v_id is null then
    select charge_account_id into v_id from public.payment_methods
     where org_id = p_org_id and is_default and deleted_at is null;
  end if;

  if v_id is null then
    select id into v_id from public.accounts
     where org_id = p_org_id and code = '6300';
  end if;

  if v_id is null then
    raise exception
      'No account to post a bank charge to. Set one on a payment '
      'method, or add account 6300 (Bank Charges) to the chart.'
      using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

comment on function app.bank_charge_account(uuid, uuid) is
  'Resolves the account a bank charge is debited to: the named payment '
  'method''s, then the company default method''s, then code 6300. '
  'Raises rather than returning null, because gl_lines.account_id is '
  'NOT NULL and a null there aborts the posting without naming why. '
  '0635.';

revoke all on function app.bank_charge_account(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- What the screen may offer
--
-- Separate from posting on purpose: see the header. This computes, it
-- does not write.
-- ---------------------------------------------------------------------
create or replace function public.suggested_charge(
  p_payment_method_id uuid, p_amount numeric)
returns numeric
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_m public.payment_methods;
begin
  select * into v_m from public.payment_methods
   where id = p_payment_method_id and deleted_at is null;
  if not found then
    raise exception 'Payment method % not found', p_payment_method_id
      using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_m.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  -- A negative amount is a refund, and a provider does not pay a fee
  -- back. Clamped rather than signed, so the suggestion is never a
  -- credit somebody accepts without noticing.
  return round(
    greatest(coalesce(p_amount, 0), 0) * v_m.charge_percent / 100
      + v_m.charge_fixed, 2);
end;
$$;

comment on function public.suggested_charge(uuid, numeric) is
  'What a payment method''s stated rate comes to on this amount. '
  'Offered on the screen; never applied during posting. 0635.';

-- ---------------------------------------------------------------------
-- Writing one
-- ---------------------------------------------------------------------
create or replace function public.save_payment_method(
  p_org_id uuid,
  p_name text,
  p_id uuid default null,
  p_payment_mode_code text default null,
  p_bank_account_id uuid default null,
  p_charge_account_id uuid default null,
  p_charge_percent numeric default 0,
  p_charge_fixed numeric default 0,
  p_is_default boolean default false,
  p_is_active boolean default true,
  p_sort_order integer default 0,
  p_notes text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'A payment method needs a name' using errcode = '23514';
  end if;

  -- The partial unique index makes at most one default possible, so
  -- clearing the old one has to happen first or the insert trips over
  -- it. Inside the same statement's transaction, so a failure below
  -- leaves the previous default standing.
  if p_is_default then
    update public.payment_methods set is_default = false
     where org_id = p_org_id and is_default and deleted_at is null
       and (p_id is null or id <> p_id);
  end if;

  if p_id is null then
    insert into public.payment_methods (
      org_id, name, payment_mode_code, bank_account_id, charge_account_id,
      charge_percent, charge_fixed, is_default, is_active, sort_order,
      notes, created_by)
    values (
      p_org_id, trim(p_name), p_payment_mode_code, p_bank_account_id,
      p_charge_account_id, coalesce(p_charge_percent, 0),
      coalesce(p_charge_fixed, 0), p_is_default, p_is_active,
      coalesce(p_sort_order, 0), p_notes, auth.uid())
    returning id into v_id;
  else
    update public.payment_methods set
      name = trim(p_name),
      payment_mode_code = p_payment_mode_code,
      bank_account_id = p_bank_account_id,
      charge_account_id = p_charge_account_id,
      charge_percent = coalesce(p_charge_percent, 0),
      charge_fixed = coalesce(p_charge_fixed, 0),
      is_default = p_is_default,
      is_active = p_is_active,
      sort_order = coalesce(p_sort_order, 0),
      notes = p_notes
     where id = p_id and org_id = p_org_id and deleted_at is null
    returning id into v_id;
    if v_id is null then
      raise exception 'Payment method % not found', p_id using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end;
$$;

comment on function public.save_payment_method(
  uuid, text, uuid, text, uuid, uuid, numeric, numeric,
  boolean, boolean, integer, text) is
  'Creates or amends one of a company''s payment methods. Writes '
  'payment_methods. 0635.';

create or replace function public.archive_payment_method(p_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  select org_id into v_org from public.payment_methods
   where id = p_id and deleted_at is null;
  if v_org is null then
    raise exception 'Payment method % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_write(v_org) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  -- Soft, because receipts already name it and a document that cannot
  -- say how it was paid is worse than a method nobody can pick again.
  -- `is_default` is deliberately left alone. Every reader of it --
  -- the partial unique index, `app.bank_charge_account`, and
  -- `payment_methods_for` -- already requires `deleted_at is null`, so
  -- clearing it here would be a write nothing can observe, and an
  -- assertion for it would be an assertion about nothing.
  update public.payment_methods
     set deleted_at = now(), is_active = false
   where id = p_id;
end;
$$;

comment on function public.archive_payment_method(uuid) is
  'Retires a payment method without breaking the documents that name '
  'it. Writes payment_methods. 0635.';

create or replace function public.payment_methods_for(p_org_id uuid)
returns setof public.payment_methods
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select * from public.payment_methods
   where org_id = p_org_id and deleted_at is null
     and app.is_org_member(p_org_id)
   order by sort_order, name;
$$;

comment on function public.payment_methods_for(uuid) is
  'A company''s payment methods, live ones first by sort order. 0635.';

-- ---------------------------------------------------------------------
-- The three postings that debit a bank charge
--
-- Restated verbatim from the live bodies -- `app.post_receipt_internal`
-- from 0209, `post_purchase_payment` from 0079, `post_bank_transfer`
-- from 0504 -- with ONE line changed in each: the hardcoded lookup of
-- account 6300 becomes `app.bank_charge_account`.
--
-- Nothing else differs, and that is asserted rather than claimed: the
-- suite posts a receipt, a payment and a transfer with no payment
-- method anywhere in the company, and checks that the charge landed on
-- 6300 and that the rest of the journal is what it was.
--
-- A bank transfer passes null for the method. A transfer is between
-- two of the company's own accounts and nobody was paid, so there is
-- no payment method to name; it takes the company default, or 6300.
-- ---------------------------------------------------------------------

create or replace function app.post_receipt_internal(p_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rcp        public.receipts;
  v_entries    jsonb := '[]'::jsonb;
  v_bank_acct  uuid;
  v_ar_acct    uuid;
  v_entry_id   uuid;
  v_rate       numeric(18, 8);
  v_net        numeric(18, 2);
  v_fx         numeric(18, 2) := 0;
begin
  select * into v_rcp from public.receipts where id = p_id;
  if not found then raise exception 'Receipt % not found', p_id; end if;
  if v_rcp.gl_entry_id is not null then
    raise exception 'Receipt % is already posted', v_rcp.receipt_no;
  end if;

  v_rate := coalesce(v_rcp.exchange_rate, 1);

  select a.id into v_bank_acct from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_rcp.bank_account_id;

  if v_bank_acct is null then
    select id into v_bank_acct from public.accounts
     where org_id = v_rcp.org_id and code = '1120';
  end if;

  select coalesce(c.receivable_account_id,
                  (select id from public.accounts where org_id = v_rcp.org_id and code = '1210'))
    into v_ar_acct from public.contacts c where c.id = v_rcp.contact_id;

  v_net := round((v_rcp.amount - coalesce(v_rcp.bank_charges, 0)) * v_rate, 2);

  -- Dr Bank (net of charges), Dr Bank charges, Cr Receivable.
  v_entries := v_entries || jsonb_build_object(
    'account_id', v_bank_acct, 'description', 'Receipt ' || v_rcp.receipt_no,
    'debit', v_net, 'credit', 0, 'contact_id', v_rcp.contact_id);

  if coalesce(v_rcp.bank_charges, 0) > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.bank_charge_account(v_rcp.org_id, v_rcp.payment_method_id),
      'description', 'Bank charges',
      'debit', round(v_rcp.bank_charges * v_rate, 2), 'credit', 0);
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_ar_acct, 'description', 'Receipt ' || v_rcp.receipt_no,
    'debit', 0, 'credit', round(v_rcp.amount * v_rate, 2), 'contact_id', v_rcp.contact_id);

  -- The currency movement between invoice and receipt.
  --
  -- fc_debit and fc_credit are stated as zero rather than left to be
  -- derived: this is a ringgit adjustment with no foreign amount behind
  -- it, and deriving one would invent dollars that were never invoiced.
  v_fx := app.realised_fx_on_settlement(p_id, true, v_rcp.currency, v_rate);

  if v_fx > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_ar_acct, 'description', 'Exchange gain on ' || v_rcp.receipt_no,
      'debit', v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,
      'contact_id', v_rcp.contact_id);
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(v_rcp.org_id, true),
      'description', 'Exchange gain on ' || v_rcp.receipt_no,
      'debit', 0, 'credit', v_fx, 'fc_debit', 0, 'fc_credit', 0);
  elsif v_fx < 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(v_rcp.org_id, false),
      'description', 'Exchange loss on ' || v_rcp.receipt_no,
      'debit', -v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_ar_acct, 'description', 'Exchange loss on ' || v_rcp.receipt_no,
      'debit', 0, 'credit', -v_fx, 'fc_debit', 0, 'fc_credit', 0,
      'contact_id', v_rcp.contact_id);
  end if;

  v_entry_id := public.create_gl_entry(
    v_rcp.org_id, v_rcp.receipt_date, 'receipt'::app.journal_source, v_entries,
    'Receipt ' || v_rcp.receipt_no, 'receipts', v_rcp.id, v_rcp.reference,
    v_rcp.currency, v_rate);

  update public.receipts
     set gl_entry_id = v_entry_id, status = 'posted',
         base_amount = round(v_rcp.amount * v_rate, 2),
         fx_gain_loss = v_fx,
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  update public.bank_accounts
     set current_balance = current_balance + v_net
   where id = v_rcp.bank_account_id;

  return v_entry_id;
end;
$$;

create or replace function public.post_purchase_payment(p_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_pay       public.purchase_payments;
  v_entries   jsonb := '[]'::jsonb;
  v_bank_acct uuid;
  v_ap_acct   uuid;
  v_entry_id  uuid;
  v_rate      numeric(18, 8);
  v_total     numeric(18, 2);
  v_fx        numeric(18, 2) := 0;
begin
  select * into v_pay from public.purchase_payments where id = p_id;
  if not found then raise exception 'Payment % not found', p_id; end if;
  if not app.can_post(v_pay.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_pay.gl_entry_id is not null then
    raise exception 'Payment % is already posted', v_pay.payment_no;
  end if;

  v_rate := coalesce(v_pay.exchange_rate, 1);

  select a.id into v_bank_acct from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_pay.bank_account_id;
  if v_bank_acct is null then
    select id into v_bank_acct from public.accounts
     where org_id = v_pay.org_id and code = '1120';
  end if;

  select coalesce(c.payable_account_id,
                  (select id from public.accounts where org_id = v_pay.org_id and code = '2110'))
    into v_ap_acct from public.contacts c where c.id = v_pay.contact_id;

  v_total := round((v_pay.amount + coalesce(v_pay.bank_charges, 0)) * v_rate, 2);

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_ap_acct, 'description', 'Payment ' || v_pay.payment_no,
    'debit', round(v_pay.amount * v_rate, 2), 'credit', 0, 'contact_id', v_pay.contact_id);

  if coalesce(v_pay.bank_charges, 0) > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.bank_charge_account(v_pay.org_id, v_pay.payment_method_id),
      'description', 'Bank charges',
      'debit', round(v_pay.bank_charges * v_rate, 2), 'credit', 0);
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_bank_acct, 'description', 'Payment ' || v_pay.payment_no,
    'debit', 0, 'credit', v_total, 'contact_id', v_pay.contact_id);

  v_fx := app.realised_fx_on_settlement(p_id, false, v_pay.currency, v_rate);

  if v_fx > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_ap_acct, 'description', 'Exchange gain on ' || v_pay.payment_no,
      'debit', v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,
      'contact_id', v_pay.contact_id);
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(v_pay.org_id, true),
      'description', 'Exchange gain on ' || v_pay.payment_no,
      'debit', 0, 'credit', v_fx, 'fc_debit', 0, 'fc_credit', 0);
  elsif v_fx < 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(v_pay.org_id, false),
      'description', 'Exchange loss on ' || v_pay.payment_no,
      'debit', -v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_ap_acct, 'description', 'Exchange loss on ' || v_pay.payment_no,
      'debit', 0, 'credit', -v_fx, 'fc_debit', 0, 'fc_credit', 0,
      'contact_id', v_pay.contact_id);
  end if;

  v_entry_id := public.create_gl_entry(
    v_pay.org_id, v_pay.payment_date, 'payment'::app.journal_source, v_entries,
    'Payment ' || v_pay.payment_no, 'purchase_payments', v_pay.id, v_pay.reference,
    v_pay.currency, v_rate);

  update public.purchase_payments
     set gl_entry_id = v_entry_id, status = 'posted',
         base_amount = round(v_pay.amount * v_rate, 2),
         fx_gain_loss = v_fx,
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  update public.bank_accounts
     set current_balance = current_balance - v_total
   where id = v_pay.bank_account_id;

  return v_entry_id;
end;
$$;

CREATE OR REPLACE FUNCTION public.post_bank_transfer(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
      'account_id', app.bank_charge_account(r.org_id, null),
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
  --
  -- By `v_sent` alone. The fee is already inside the amount sent --
  -- `create_bank_transfer` refuses a same-currency transfer unless
  -- sent = received + charges -- and the journal above credits this
  -- account `v_sent` and debits the fee to 6300, which is a different
  -- account. Subtracting the charge again here took it twice.
  update public.bank_accounts
     set current_balance = current_balance - v_sent
   where id = r.from_account_id;
  update public.bank_accounts
     set current_balance = current_balance + v_received
   where id = r.to_account_id;

  update public.bank_transfers
     set gl_entry_id = v_entry, status = 'posted',
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  return v_entry;
end; $function$;

-- ---------------------------------------------------------------------
-- Who may call these
--
-- None of them is a public-link path, so anon is revoked from all four
-- rather than allowlisted. `suggested_charge` and `payment_methods_for`
-- check `is_org_member` inside; the two writers check `can_write`.
-- ---------------------------------------------------------------------
revoke all on function public.suggested_charge(uuid, numeric)
  from public, anon;
grant execute on function public.suggested_charge(uuid, numeric)
  to authenticated, service_role;

revoke all on function public.payment_methods_for(uuid)
  from public, anon;
grant execute on function public.payment_methods_for(uuid)
  to authenticated, service_role;

revoke all on function public.save_payment_method(
  uuid, text, uuid, text, uuid, uuid, numeric, numeric,
  boolean, boolean, integer, text) from public, anon;
grant execute on function public.save_payment_method(
  uuid, text, uuid, text, uuid, uuid, numeric, numeric,
  boolean, boolean, integer, text) to authenticated, service_role;

revoke all on function public.archive_payment_method(uuid)
  from public, anon;
grant execute on function public.archive_payment_method(uuid)
  to authenticated, service_role;
