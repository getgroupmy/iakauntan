-- =====================================================================
-- iAkauntan :: the matter a reconciled statement line belongs to
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/matter_on_a_bank_line.sql
--
-- `0723`. `0688` put the matter on every posting path and said the
-- Flutter picker was on the journal editor while "the bill editor,
-- expense form and bank reconciliation still need it". The first two
-- turned out to be done; the reconciliation was not, and
-- `post_bank_transaction` had no argument to carry a matter at all.
--
-- For a solicitor that is the route most likely to feed the matter
-- reports: a disbursement paid to a searcher, a court fee, money in
-- from a client. Every one of them reached `gl_lines` with `matter_id`
-- null and was invisible to `report_matter_ledger`.
--
-- What has to be true:
--
--   * THE CHOSEN ACCOUNT'S LEG CARRIES THE MATTER, both ways round --
--     money in and money out, which take opposite sides of the same
--     rule and must not differ in what they tag.
--   * THE BANK'S LEG DOES NOT. That is `post_expense`'s convention and
--     the reason is in `0723`: a matter ledger is what was spent on the
--     matter, not a balanced set of books for it. Asserting this is
--     what stops somebody "fixing" the trial balance by tagging both.
--   * NO MATTER IS STILL NO MATTER. The argument defaults, and every
--     company that is not a law firm posts exactly as it did.
--   * ANOTHER FIRM'S MATTER IS REFUSED, in words, before the composite
--     foreign key gets to complain about a constraint.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A bank account, and one imported statement line on it.
create or replace function pg_temp.a_line(
  p_org uuid, p_bank uuid, p_amount numeric, p_ref text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.bank_transactions
    (org_id, bank_account_id, transaction_date, description, reference, amount)
  values (p_org, p_bank, date '2026-03-04', 'From the statement', p_ref,
          p_amount)
  returning id into v_id;
  return v_id;
end;
$$;

do $$
declare
  v_owner  uuid := pg_temp.test_user();
  v_org    uuid;
  v_other  uuid;
  v_gl     uuid;
  v_bank   uuid;
  v_client uuid;
  v_matter uuid;
  v_far    uuid;
  v_cost   uuid;
  v_fees   uuid;
  v_line   uuid;
  v_entry  uuid;
  v_got    uuid;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Shaharudin & Partners');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform public.setup_legal_module(v_org);

  v_bank := pg_temp.test_bank_account(
    v_org, 'Maybank current', 'current', 'MYR', 0, 0, '1234');
  v_gl   := pg_temp.bank_gl(v_bank);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'Puan Aminah', 'customer') returning id into v_client;

  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-1', 'Sale of a house', v_client, v_owner)
  returning id into v_matter;

  select id into v_cost from public.accounts
   where org_id = v_org and code = '6250';
  select id into v_fees from public.accounts
   where org_id = v_org and code = '4100';
  if v_cost is null or v_fees is null then
    raise exception 'FAIL: the chart has no account to post against';
  end if;

  -- -------------------------------------------------------------------
  -- Money out: a disbursement paid from the office account
  -- -------------------------------------------------------------------
  v_line := pg_temp.a_line(v_org, v_bank, -350.00, 'LAND-1');
  v_entry := public.post_bank_transaction(
    v_line, v_cost, 'Land search', null, v_matter);

  select matter_id into v_got from public.gl_lines
   where entry_id = v_entry and account_id = v_cost;
  if v_got is distinct from v_matter then
    raise exception
      'FAIL: a disbursement posted from the statement reached the ledger '
      'with matter %, not %. report_matter_ledger reads gl_lines and '
      'cannot see a line that is not tagged.', v_got, v_matter;
  end if;

  -- And the bank's leg is NOT tagged. Deliberate, and the assertion is
  -- what stops it being "fixed".
  select matter_id into v_got from public.gl_lines
   where entry_id = v_entry and account_id = v_gl;
  if v_got is not null then
    raise exception
      'FAIL: the bank leg carries matter %. post_expense leaves its bank '
      'credit untagged and 0723 follows it: the firm''s own bank account '
      'does not belong to a matter.', v_got;
  end if;

  -- -------------------------------------------------------------------
  -- Money in: the opposite side of the same rule, tagged the same way
  -- -------------------------------------------------------------------
  v_line := pg_temp.a_line(v_org, v_bank, 1200.00, 'FEE-1');
  v_entry := public.post_bank_transaction(
    v_line, v_fees, 'Fees on account', null, v_matter);

  select matter_id into v_got from public.gl_lines
   where entry_id = v_entry and account_id = v_fees;
  if v_got is distinct from v_matter then
    raise exception
      'FAIL: money IN reached the ledger with matter %, not %. The two '
      'directions take opposite sides of one rule and must not differ '
      'in what they tag.', v_got, v_matter;
  end if;

  select matter_id into v_got from public.gl_lines
   where entry_id = v_entry and account_id = v_gl;
  if v_got is not null then
    raise exception 'FAIL: the bank leg of a receipt carries matter %.', v_got;
  end if;

  -- -------------------------------------------------------------------
  -- No matter is still no matter
  --
  -- Every company that is not a law firm posts through this function
  -- too, and none of them passes the argument.
  -- -------------------------------------------------------------------
  v_line := pg_temp.a_line(v_org, v_bank, -80.00, 'BANKFEE');
  v_entry := public.post_bank_transaction(v_line, v_cost, 'Bank charges');

  if exists (select 1 from public.gl_lines
              where entry_id = v_entry and matter_id is not null) then
    raise exception
      'FAIL: a posting that named no matter put one on a line anyway.';
  end if;
  perform pg_temp.check_eq('and it still posts both legs',
    (select count(*) from public.gl_lines where entry_id = v_entry), 2);

  -- -------------------------------------------------------------------
  -- Another firm's matter is refused, in words
  -- -------------------------------------------------------------------
  v_other := pg_temp.test_org('Another Firm');
  perform public.create_fiscal_year(v_other, date '2026-01-01');
  perform public.setup_legal_module(v_other);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_other, 'CL9', 'Somebody else', 'customer') returning id into v_got;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_other, 'M-9', 'Not ours', v_got, v_owner)
  returning id into v_far;

  perform pg_temp.sign_in_as(v_owner);
  v_line := pg_temp.a_line(v_org, v_bank, -50.00, 'WRONG');
  begin
    perform public.post_bank_transaction(
      v_line, v_cost, 'Nope', null, v_far);
    raise exception 'FAIL: posted a line against another firm''s matter';
  exception when sqlstate 'P0002' then
    raise notice 'ok   another firm''s matter is refused in words';
  end;

  raise notice 'ok   a reconciled statement line carries its matter';
end;
$$;

rollback;
