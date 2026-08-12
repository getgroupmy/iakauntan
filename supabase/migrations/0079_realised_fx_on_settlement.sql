-- Multi-currency, part two: the difference between what was invoiced and
-- what the money turned out to be worth.
--
-- A USD 10,000 invoice raised at 4.70 puts RM 47,000 into receivables.
-- If the customer pays in full three months later at 4.50, the receipt
-- clears RM 45,000. The customer owes nothing — they paid every dollar —
-- but RM 2,000 is left sitting in receivables against them, and stays
-- there forever.
--
-- That RM 2,000 is a realised exchange loss. Without this, it silently
-- overstates receivables and overstates profit, the AR ageing shows a
-- debt nobody owes, and the balance sheet is wrong by the whole currency
-- movement on every settled foreign invoice.
--
-- `receipts.fx_gain_loss` and `purchase_payments.fx_gain_loss` have been
-- in the schema since 0005 and 0006 and were never written. This writes
-- them, and posts the matching journal.

-- ---------------------------------------------------------------------
-- What the movement was worth
--
-- Positive is a gain, negative a loss, always in base currency.
--
-- The sign flips between the two sides, and it is worth being explicit
-- about why rather than trusting a minus sign: a receivable is an asset,
-- so a rate that falls between invoice and receipt means the asset was
-- worth less than booked — a loss. A payable is a liability, so a rate
-- that rises between bill and payment means settling it cost more than
-- booked — also a loss. Same direction of travel, opposite arithmetic.
-- ---------------------------------------------------------------------
create or replace function app.realised_fx_on_settlement(
  p_settlement_id uuid,
  p_is_receipt boolean,
  p_currency character,
  p_rate numeric)
returns numeric
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_fx numeric(18, 2) := 0;
  r record;
begin
  if p_is_receipt then
    for r in
      select a.amount, d.currency as doc_currency,
             coalesce(d.exchange_rate, 1) as doc_rate, d.doc_no
        from public.payment_allocations a
        join public.sales_documents d on d.id = a.invoice_id
       where a.receipt_id = p_settlement_id
    loop
      if r.doc_currency is distinct from p_currency then
        raise exception
          'Receipt is in % but % is in %. Settling a document in another '
          'currency needs a conversion this system does not yet make.',
          p_currency, r.doc_no, r.doc_currency using errcode = '22023';
      end if;
      v_fx := v_fx + round(r.amount * (p_rate - r.doc_rate), 2);
    end loop;
  else
    for r in
      select a.amount, d.currency as doc_currency,
             coalesce(d.exchange_rate, 1) as doc_rate, d.doc_no
        from public.payment_allocations a
        join public.purchase_documents d on d.id = a.bill_id
       where a.payment_id = p_settlement_id
    loop
      if r.doc_currency is distinct from p_currency then
        raise exception
          'Payment is in % but % is in %. Settling a document in another '
          'currency needs a conversion this system does not yet make.',
          p_currency, r.doc_no, r.doc_currency using errcode = '22023';
      end if;
      v_fx := v_fx + round(r.amount * (r.doc_rate - p_rate), 2);
    end loop;
  end if;

  return v_fx;
end;
$$;

-- The two accounts the difference lands in. Named rather than assumed,
-- so a company on a hand-built chart gets told what is missing instead
-- of a null account_id three frames down.
create or replace function app.fx_account(p_org_id uuid, p_gain boolean)
returns uuid
language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_id uuid; v_code text := case when p_gain then '4920' else '6500' end;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = v_code;
  if v_id is null then
    raise exception
      'No account % (%) in the chart. Add it before posting in a foreign currency.',
      v_code, case when p_gain then 'Foreign Exchange Gain'
                   else 'Foreign Exchange Loss' end
      using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Receipts
-- ---------------------------------------------------------------------
create or replace function public.post_receipt(p_id uuid)
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
  if not app.can_post(v_rcp.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
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
      'account_id', (select id from public.accounts where org_id = v_rcp.org_id and code = '6300'),
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

-- ---------------------------------------------------------------------
-- Supplier payments
-- ---------------------------------------------------------------------
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
      'account_id', (select id from public.accounts where org_id = v_pay.org_id and code = '6300'),
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
