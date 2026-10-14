-- =====================================================================
-- iAkauntan :: 0893 the tax is paid over after it was withheld
--
-- `remit_withholding` took any date. A certificate's date is the day
-- the payment to the non-resident was made or credited -- the day the
-- tax was withheld -- and its journal is dated then; the remittance
-- journal could be dated before it, so the withholding-tax account sat
-- in debit, paid over before anything had been withheld.
--
-- Measured on 14 October 2026, locally, as an accountant with the role
-- `authenticated`: a certificate dated ten days ago remitted dated
-- thirty days ago, and one dated twenty days ahead (its bill's date,
-- the default) remitted today. Both posted. The withholding screen's
-- Remit sends today, so the second is one tap away.
--
-- Production held no withholding certificate on 14 October.
--
-- Answered "not before the certificate": a remittance dated before the
-- certificate's date is refused, naming it. For a certificate dated
-- ahead, Remit gives that message until its day comes.
--
-- The body is `pg_get_functiondef` of what was applied, with the block
-- marked 0893 added.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.remit_withholding(p_id uuid, p_paid_on date DEFAULT app.today(), p_bank_account_id uuid DEFAULT NULL::uuid, p_reference text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
  -- 0893: the tax is paid over no earlier than it was withheld. The
  -- certificate's date is the day the payment was made or credited.
  if p_paid_on < c.cert_date then
    raise exception
      'Certificate % is dated %, and the tax it withheld cannot be paid '
      'over before then.', c.certificate_no,
      to_char(c.cert_date, 'DD Mon YYYY') using errcode = '23514';
  end if;

  if p_bank_account_id is not null
     and not exists (select 1 from public.bank_accounts b
                      where b.id = p_bank_account_id and b.org_id = c.org_id)
  then
    raise exception 'That bank account belongs to another organization'
      using errcode = '42501';
  end if;

  -- A remittance that named no account used to be credited to 1120
  -- Bank Accounts -- the heading the real accounts hang under -- which
  -- moved no bank balance and showed on no reconciliation. This
  -- function's own comment already named that harm while doing it: it
  -- documented refusing ANOTHER COMPANY's account because "falling back
  -- to the default cash account would post the entry anyway and leave
  -- nobody any the wiser", and then fell back for a missing one.
  --
  -- `0506` read this function and left it alone, correctly, for the
  -- cross-tenant guard above. Its header's "neither needed changing"
  -- was about that guard and said nothing about the fallback; it was
  -- read as a verdict on the whole function, which is how this survived
  -- `0728`.
  if p_bank_account_id is null then
    raise exception
      'Say which account the remittance was paid from. Without one there '
      'is no bank balance to move and nothing for a reconciliation to '
      'match.' using errcode = '23514';
  end if;

  select a.id into v_bank from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = p_bank_account_id and b.org_id = c.org_id;
  if v_bank is null then
    raise exception 'That account is not on this company''s chart.'
      using errcode = 'P0002';
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

  update public.bank_accounts
     set current_balance = current_balance - v_base
   where id = p_bank_account_id
     and org_id = c.org_id;

  update public.withholding_certificates
     set remitted_on = p_paid_on, remittance_ref = p_reference,
         remittance_gl_entry_id = v_entry, status = 'completed'
   where id = p_id;

  return v_entry;
end; $function$;
