-- ---------------------------------------------------------------------
-- 0437  The service tax on a firm's own hours
-- ---------------------------------------------------------------------
-- `app.bill_time_internal` raises the invoice behind
-- `bill_project_time` and `bill_matter_time` -- the fee note a
-- consultancy, a secretarial practice or a law firm sends for the hours
-- it recorded. Every line it writes says:
--
--     values (p_org_id, v_invoice, v_no, 'item',
--             format('%s — %s hours', v_line.who, v_line.hours),
--             1, v_line.amount, v_account, 0);
--                                          ^^^ tax_rate
--
-- Zero, with no `tax_code_id`, for every organization, always. So a
-- service-tax-registered firm bills RM3,330 of professional time and
-- declares nothing on it.
--
-- Professional services are taxable. Group G of the First Schedule to
-- the Service Tax Regulations 2018 covers legal, accounting,
-- surveying, consultancy, management and information technology
-- services; a registered person providing them charges service tax at
-- the rate they registered at. A fee note that carries none is an
-- invoice that understates what was charged, and the shortfall is the
-- registrant's to pay whether or not they collected it.
--
-- Found by measurement, not by reading. `0436` gave Sinar -- which
-- `demo_books_sinar` registers for service tax at ST8 -- a job to bill,
-- and `demo_rebuild.sql`'s "receivables plus what was collected equal
-- revenue plus output SST" went red by exactly the RM3,330 of engineer
-- time. The immediate cause was the revenue account, and widening that
-- assertion was right; but the tax on that RM3,330 was RM0.00 and no
-- assertion anywhere would have said so, because until `0436` no
-- SST-registered tenant had ever billed time.
--
-- The rate is not guessed. `set_sst_registration` already stores which
-- tax a company registered for -- it refuses to be called without it,
-- because "service tax and sales tax are separate registrations under
-- separate Acts, at different rates, and the wrong default is a wrong
-- number on every invoice raised from here on" -- and it records that
-- choice as the one `tax_codes` row with `is_default`. That row is the
-- answer, and this migration reads it rather than inventing a second
-- source of truth.
--
-- And the date matters as much as the rate, though not for the reason
-- it first appeared to. `0145` already installed a posting guard that
-- REFUSES a document dated before registration if it carries tax, so
-- the wrong number was never reachable. What was reachable, the moment
-- a fee note started carrying the default code, was a firm unable to
-- bill work it did before it registered at all -- the guard would have
-- refused the invoice. `app.default_sales_tax` takes the date and
-- returns nothing for a fee note dated before registration, so that
-- invoice raises correctly and carries no tax, which is what it should
-- have carried all along.
-- Four mutants applied and measured:
--
--   * the tax lookup replaced by null -- killed by this migration's own
--     apply-time guard, before the test ran, so it did not exercise the
--     assertion;
--   * the code named and its rate left at zero -- killed by the test,
--     "a registered firm charges service tax on the hours it bills",
--     got 0.00. That is the mutant the first assertion is for, and it
--     is the exact mistake `demo_books_sinar` made on the sales side:
--     totals are recalculated from the line's rate, not from the code;
--   * `app.today()` passed instead of the fee note's date -- killed by
--     the guard again, not by the test;
--   * the date test removed from `app.default_sales_tax`. This one
--     taught something the header had wrong. A posting guard from
--     `0145` ALREADY refuses a document dated before registration that
--     carries tax, so the failure the date test prevents is not a wrong
--     number: it is `bill_project_time` raising "This document is dated
--     2026-02-28, before SST registration took effect on 2026-03-01"
--     and the firm having no way to bill work it did before it
--     registered. The assertion covers that, and says so.
-- ---------------------------------------------------------------------

create or replace function app.default_sales_tax(p_org_id uuid, p_on date)
returns uuid
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  -- Null when the company is not registered, when it had not yet
  -- registered on this date, or when its default code is zero rated --
  -- `set_sst_registration` puts 'NA' there on deregistration. Null
  -- means the caller writes no tax code and no rate, which is what an
  -- unregistered company's invoice must look like.
  select t.id
    from public.organizations o
    join public.tax_codes t
      on t.org_id = o.id and t.is_default and t.is_active
   where o.id = p_org_id
     and o.is_sst_registered
     and o.sst_registered_from is not null
     and p_on >= o.sst_registered_from
     and coalesce(t.rate, 0) > 0
$$;

comment on function app.default_sales_tax(uuid, date) is
  'The tax code a sales line raised on this date should default to: the '
  'company''s registered default when it was registered on that date, '
  'null otherwise. The date is not optional -- a fee note for work done '
  'before registration must not carry tax.';

revoke all on function app.default_sales_tax(uuid, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The fee note, restated to charge it
-- ---------------------------------------------------------------------
-- Restated from the live `pg_get_functiondef`, which is what is
-- actually installed rather than what a migration once said.

CREATE OR REPLACE FUNCTION app.bill_time_internal(p_org_id uuid, p_project_id uuid, p_matter_id uuid, p_contact_id uuid, p_subject text, p_from date, p_to date, p_due date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_invoice uuid;
  v_account uuid;
  v_tax uuid;
  v_rate numeric := 0;
  v_line record;
  v_no integer := 0;
  v_total numeric(18, 2) := 0;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to raise an invoice'
      using errcode = '42501';
  end if;
  if p_contact_id is null then
    raise exception
      'There is no client on this engagement, so there is nobody to '
      'invoice.' using errcode = '23502';
  end if;
  if p_to < p_from then
    raise exception 'The period ends before it starts' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.time_entries t
     where t.org_id = p_org_id
       and t.project_id is not distinct from p_project_id
       and t.matter_id is not distinct from p_matter_id
       and t.entry_date between p_from and p_to
       and t.is_billable and not t.is_billed and t.amount > 0)
  then
    raise exception
      'No unbilled chargeable time on this engagement between % and %.',
      p_from, p_to using errcode = 'P0002';
  end if;

  v_account := app.time_income_account(p_org_id);

  -- 0437. The tax the firm registered for, if it was registered on the
  -- day this fee note is dated. Null for an unregistered company, and
  -- null for one whose registration began after `p_to` -- work done
  -- before a firm registered is billed without tax.
  v_tax := app.default_sales_tax(p_org_id, p_to);
  select coalesce(rate, 0) into v_rate from public.tax_codes
   where id = v_tax;

  insert into public.sales_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id,
    subject, reference, currency, exchange_rate, status)
  values (
    p_org_id, 'invoice',
    app.next_document_number_internal(p_org_id, 'invoice'),
    p_to, coalesce(p_due, p_to), p_contact_id,
    p_subject, format('%s to %s', p_from, p_to),
    app.base_currency(p_org_id), 1, 'draft')
  returning id into v_invoice;

  -- One line per person, with the hours on it. `sum(minutes)/60` is
  -- rounded once at the end rather than per entry, so six ten-minute
  -- calls bill as one hour and not as 0.996 of one.
  for v_line in
    select t.user_id,
           coalesce(p.full_name, p.email, 'Fee earner') as who,
           round(sum(t.minutes)::numeric / 60.0, 2) as hours,
           sum(t.amount) as amount
      from public.time_entries t
      left join public.profiles p on p.id = t.user_id
     where t.org_id = p_org_id
       and t.project_id is not distinct from p_project_id
       and t.matter_id is not distinct from p_matter_id
       and t.entry_date between p_from and p_to
       and t.is_billable and not t.is_billed and t.amount > 0
     group by t.user_id, p.full_name, p.email
     order by 2
  loop
    v_no := v_no + 1;
    -- `tax_rate` as well as `tax_code_id`. The rate is stored on the
    -- line, not looked up from the code when totals are recalculated,
    -- so a line naming ST8 without its 8 produces a fee note with no
    -- tax on it at all -- the same mistake `demo_books_sinar` made on
    -- the sales side and had to be measured to find.
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, account_id, tax_code_id, tax_rate)
    values (p_org_id, v_invoice, v_no, 'item',
            format('%s — %s hours', v_line.who, v_line.hours),
            1, v_line.amount, v_account, v_tax, coalesce(v_rate, 0));
    v_total := v_total + v_line.amount;
  end loop;

  update public.time_entries t
     set is_billed = true, invoice_id = v_invoice
   where t.org_id = p_org_id
     and t.project_id is not distinct from p_project_id
     and t.matter_id is not distinct from p_matter_id
     and t.entry_date between p_from and p_to
     and t.is_billable and not t.is_billed and t.amount > 0;

  perform app.post_sales_document_internal(v_invoice);
  return v_invoice;
end $function$;

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = to_regprocedure(
     'app.bill_time_internal(uuid, uuid, uuid, uuid, text, date, date,'
     ' date)');

  if v_src !~ 'default_sales_tax' then
    raise exception
      'FAIL 0437: a fee note still carries no tax code, so a registered '
      'firm bills its hours and declares nothing on them';
  end if;

  -- Both halves. The rate lives on the line, not on the code, so a
  -- restatement that named the code and left the rate at zero would
  -- satisfy the check above and produce a fee note with a tax code on
  -- it and no tax in it.
  if v_src !~ 'tax_code_id' or v_src !~ 'v_rate' then
    raise exception
      'FAIL 0437: the fee note names a tax code without its rate, which '
      'is a line that charges nothing';
  end if;

  -- And the date reached the lookup. `app.default_sales_tax` exists to
  -- refuse tax on work billed before the firm registered, and a caller
  -- that passed `app.today()` instead of the invoice date would undo
  -- that silently.
  if v_src !~ 'default_sales_tax\(p_org_id, p_to\)' then
    raise exception
      'FAIL 0437: the tax lookup is not being asked about the date the '
      'fee note is dated';
  end if;

  raise notice
    '0437: a registered firm charges service tax on the hours it bills';
end
$do$;
