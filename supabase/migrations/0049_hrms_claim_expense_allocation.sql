-- =====================================================================
-- iAkauntan :: 0049 a reimbursed claim is not salary
--
-- Claims ride out with payroll so nobody has to remember to pay them,
-- but they were being debited to Salaries and Wages along with the rest
-- of gross pay. A conference fee was landing in the payroll figure the
-- accountant reconciles. Split them out and send each to the account its
-- claim type names.
-- =====================================================================

alter table public.payroll_runs
  add column if not exists total_claims numeric(18, 2) not null default 0;

-- Where a claim's money belongs, split across its lines. A line whose
-- claim type names no account falls back to Other Expenses rather than
-- silently rejoining the salary figure.
create or replace function app.claim_expense_allocation(p_claim_id uuid)
returns table (account_id uuid, amount numeric)
language sql stable
set search_path = public, pg_temp as $$
  with claim as (
    select c.id, c.org_id, c.approved_amount,
           nullif(sum(l.amount), 0) as line_total
      from public.expense_claims c
      join public.expense_claim_lines l on l.claim_id = c.id
     where c.id = p_claim_id
     group by c.id, c.org_id, c.approved_amount
  )
  select coalesce(
           ct.expense_account_id,
           (select a.id from public.accounts a
             where a.org_id = claim.org_id and a.code = '6900'
               and not a.is_group limit 1)) as account_id,
         -- Approved amount can differ from what was claimed, so allocate
         -- it across the lines in proportion rather than trusting either.
         round(sum(l.amount) / claim.line_total * claim.approved_amount, 2)
           as amount
    from claim
    join public.expense_claim_lines l on l.claim_id = claim.id
    left join public.claim_types ct on ct.id = l.claim_type_id
   group by 1, claim.line_total, claim.approved_amount
  having round(sum(l.amount) / claim.line_total * claim.approved_amount, 2) <> 0;
$$;

comment on function app.claim_expense_allocation is
  'The accounts an approved claim should be debited to, allocating the approved amount across its lines in proportion.';

-- Post a claim that is being reimbursed on its own rather than with
-- salary. Credits the bank when one is named, otherwise leaves it in
-- Other Payables until it is actually paid.
create or replace function public.post_expense_claim(
  p_claim_id uuid, p_bank_account_id uuid default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_claim public.expense_claims;
  v_lines jsonb := '[]'::jsonb;
  v_credit uuid;
  v_entry uuid;
  v_alloc record;
begin
  select * into v_claim from public.expense_claims where id = p_claim_id;
  if v_claim.id is null then
    raise exception 'Claim not found' using errcode = 'P0002';
  end if;
  if not app.can_post(v_claim.org_id) then
    raise exception 'Insufficient privileges to post to the ledger'
      using errcode = '42501';
  end if;
  if v_claim.status <> 'approved' then
    raise exception 'Only an approved claim can be posted; this one is %',
      v_claim.status using errcode = '22023';
  end if;
  if v_claim.gl_entry_id is not null then
    raise exception 'This claim has already been posted'
      using errcode = '22023';
  end if;
  if v_claim.pay_with_payroll then
    raise exception
      'This claim is set to be reimbursed with payroll, which posts it'
      using errcode = '22023';
  end if;

  for v_alloc in select * from app.claim_expense_allocation(p_claim_id) loop
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_alloc.account_id,
      'description', coalesce(v_claim.title, v_claim.claim_no),
      'debit', v_alloc.amount, 'credit', 0));
  end loop;

  if jsonb_array_length(v_lines) = 0 then
    raise exception 'This claim has nothing to post' using errcode = '22023';
  end if;

  if p_bank_account_id is not null then
    select account_id into v_credit from public.bank_accounts
     where id = p_bank_account_id;
  end if;
  if v_credit is null then
    select id into v_credit from public.accounts
     where org_id = v_claim.org_id and code = '2120' and not is_group limit 1;
  end if;

  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', v_credit,
    'description', format('Claim %s reimbursed', v_claim.claim_no),
    'debit', 0, 'credit', v_claim.approved_amount));

  v_entry := public.create_gl_entry(
    p_org_id       => v_claim.org_id,
    p_entry_date   => v_claim.claim_date,
    p_source       => 'payment'::app.journal_source,
    p_lines        => v_lines,
    p_description  => coalesce(v_claim.title, 'Expense claim'),
    p_source_table => 'expense_claims',
    p_source_id    => p_claim_id,
    p_reference    => v_claim.claim_no);

  update public.expense_claims
     set gl_entry_id = v_entry,
         posted_at = now(),
         paid_at = case when p_bank_account_id is not null
                        then now() else paid_at end
   where id = p_claim_id;

  return v_entry;
end;
$$;

do $do$
declare fn record;
begin
  for fn in
    select n.nspname as s, p.proname as f,
           pg_get_function_identity_arguments(p.oid) as a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app') and p.prosecdef
  loop
    execute format('revoke all on function %I.%I(%s) from public, anon', fn.s, fn.f, fn.a);
    execute format('grant execute on function %I.%I(%s) to authenticated, service_role', fn.s, fn.f, fn.a);
  end loop;
end
$do$;
