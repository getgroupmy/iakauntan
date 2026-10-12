-- =====================================================================
-- iAkauntan :: a relief is claimed within its ceiling (0836)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/relief_ceiling_on_form_b.sql
--
-- A Form B or BE takes the reliefs in `tax_relief_claims` off total
-- income as typed. Before `0836` the claim dialog showed each relief's
-- ceiling under the box and nothing refused more: lifestyle typed as
-- 25,000 took RM4,545 off a RM10,525 tax, and the same relief claimed
-- twice was claimed twice. Asked as the owner with the role
-- `authenticated`, as the Form B screen asks, and the tax as
-- `tax_computation_individual` works it out.
--
-- Every ceiling is asked at its edge: a sen over refused, the ceiling
-- itself taken.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.two_lines(
  p_debit uuid, p_credit uuid, p_amount numeric)
returns jsonb language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('account_id', p_debit, 'debit', p_amount,
                       'credit', 0),
    jsonb_build_object('account_id', p_credit, 'debit', 0,
                       'credit', p_amount));
$$;

create or replace function pg_temp.tax_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end; $$;

create or replace function pg_temp.tax_comp(p_org uuid, p_form text)
returns uuid language plpgsql as $$
declare v_fy uuid; v_id uuid;
begin
  select id into v_fy from public.fiscal_years
   where org_id = p_org and end_date between date '2026-01-01'
                                         and date '2026-12-31'
   order by end_date limit 1;
  v_id := public.open_tax_computation(p_org, v_fy);
  update public.tax_computations set form = p_form where id = v_id;
  return v_id;
end; $$;

create or replace function pg_temp.trade(
  p_org uuid, p_revenue numeric, p_expense numeric)
returns void language plpgsql as $$
declare v_bank uuid; v_sales uuid; v_expense uuid;
begin
  select id into v_bank from public.accounts
   where org_id = p_org and account_subtype = 'bank'
     and not is_group order by code limit 1;
  select id into v_sales from public.accounts
   where org_id = p_org and account_type = 'revenue'
     and not is_group order by code limit 1;
  select id into v_expense from public.accounts
   where org_id = p_org and code = '6100';

  if p_revenue > 0 then
    perform public.post_manual_journal(p_org, date '2026-06-30',
      pg_temp.two_lines(v_bank, v_sales, p_revenue), 'Sales', 'S-1');
  end if;
  if p_expense > 0 then
    perform public.post_manual_journal(p_org, date '2026-06-30',
      pg_temp.two_lines(v_expense, v_bank, p_expense), 'Costs', 'E-1');
  end if;
end; $$;

create or replace function pg_temp.b_figure(p_comp uuid, p_column text)
returns numeric language plpgsql as $$
declare v numeric;
begin
  execute format(
    'select %I from public.tax_computation_individual($1)', p_column)
    into v using p_comp;
  return v;
end; $$;


create temporary table t_rc (org uuid, b uuid, other_b uuid, lifestyle uuid);
grant select, update on t_rc to authenticated;

do $$
declare r t_rc; v_other uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.tax_org('Kedai Had Pelepasan');
  perform pg_temp.trade(r.org, 300000, 180000);
  r.b := pg_temp.tax_comp(r.org, 'B');
  -- Somebody else's Form B, whose claims are its own.
  v_other := pg_temp.tax_org('Kedai Sebelah');
  perform pg_temp.trade(v_other, 300000, 180000);
  r.other_b := pg_temp.tax_comp(v_other, 'B');
  insert into public.tax_relief_claims (org_id, computation_id, relief_code, label, amount)
  values (v_other, r.other_b, 'lifestyle', 'Lifestyle', 2500);
  insert into t_rc select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_rc; v uuid;
begin
  select * into d from t_rc;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- Each at its ceiling is taken.
  insert into public.tax_relief_claims (org_id, computation_id, relief_code, label, amount)
  values (d.org, d.b, 'individual', 'Individual', 9000),
         (d.org, d.b, 'epf', 'EPF', 4000);
  insert into public.tax_relief_claims (org_id, computation_id, relief_code, label, amount)
  values (d.org, d.b, 'lifestyle', 'Lifestyle', 2500) returning id into v;
  update t_rc set lifestyle = v;
  perform pg_temp.check_eq('each relief at its ceiling is taken',
    (select sum(amount) from public.tax_relief_claims where computation_id = d.b), 15500);

  -- What was measured: typed over the ceiling, and claimed twice.
  perform pg_temp.check_refused('lifestyle typed as 25,000',
    format('update public.tax_relief_claims set amount = 25000 where id = %L', v),
    'LHDN allows up to RM2,500.00 on lifestyle for the year to 2026-12-31; this would claim RM25,000.00 under it on this computation.',
    '23514');
  perform pg_temp.check_refused('the individual relief claimed twice',
    format($q$insert into public.tax_relief_claims (org_id, computation_id, relief_code, label, amount)
              values (%L, %L, 'individual', 'Individual again', 9000)$q$, d.org, d.b),
    'LHDN allows up to RM9,000.00 on individual for the year to 2026-12-31; this would claim RM18,000.00 under it on this computation.',
    '23514');

  -- At the edge: a sen over, on the claim itself and by a second one.
  perform pg_temp.check_refused('a sen over the ceiling',
    format('update public.tax_relief_claims set amount = 2500.01 where id = %L', v),
    'LHDN allows up to RM2,500.00 on lifestyle %RM2,500.01 under it%', '23514');
  perform pg_temp.check_refused('or a sen more by another claim',
    format($q$insert into public.tax_relief_claims (org_id, computation_id, relief_code, label, amount)
              values (%L, %L, 'lifestyle', 'Lifestyle, a book', 0.01)$q$, d.org, d.b),
    'LHDN allows up to RM2,500.00 on lifestyle %RM2,500.01 under it%', '23514');

  -- A claim amended counts once: down and back to the ceiling.
  update public.tax_relief_claims set amount = 2000 where id = v;
  update public.tax_relief_claims set amount = 2500 where id = v;
  perform pg_temp.check_eq('a claim amended to its own ceiling counts once',
    (select amount from public.tax_relief_claims where id = v), 2500);

  -- Split under the ceiling is one claim's worth.
  update public.tax_relief_claims set amount = 1500 where id = v;
  insert into public.tax_relief_claims (org_id, computation_id, relief_code, label, amount)
  values (d.org, d.b, 'lifestyle', 'Lifestyle, gym', 1000);
  perform pg_temp.check_eq('two claims of one relief up to its ceiling are taken',
    (select sum(amount) from public.tax_relief_claims
      where computation_id = d.b and relief_code = 'lifestyle'), 2500);

  -- As typed: a relief the catalogue does not carry, and one without a
  -- ceiling.
  insert into public.tax_relief_claims (org_id, computation_id, relief_code, label, amount)
  values (d.org, d.b, null, 'Something else', 50000),
         (d.org, d.b, 'child', 'Two children', 4000);
  perform pg_temp.check_eq('an uncoded claim and an uncapped relief are taken as typed',
    (select sum(amount) from public.tax_relief_claims where computation_id = d.b), 69500);
end $$;

reset role;

do $$
declare d t_rc;
begin
  select * into d from t_rc;
  perform pg_temp.check_eq('the computation takes what was claimed',
    pg_temp.b_figure(d.b, 'reliefs_claimed'), 69500);
  perform pg_temp.check_eq('and the other company''s lifestyle is its own',
    pg_temp.b_figure(d.other_b, 'reliefs_claimed'), 2500);
  -- A trigger, so the owner is held to it too.
  perform pg_temp.check_refused('the owner is not let through',
    format('update public.tax_relief_claims set amount = 4001 where computation_id = %L and relief_code = %L',
           d.b, 'epf'),
    'LHDN allows up to RM4,000.00 on epf%', '23514');
end $$;

rollback;
