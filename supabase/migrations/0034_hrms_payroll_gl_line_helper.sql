-- =====================================================================
-- iAkauntan :: 0034 hrms payroll gl line helper
-- Applied as project migration 20260810055046.
-- =====================================================================

-- Builds one journal line, resolving the account from payroll settings
-- and falling back to the standard chart code when nothing is configured.
-- Returns an empty array for a zero amount so the journal carries no
-- lines for contributions that did not arise.
create or replace function app.payroll_gl_line(
  p_org_id uuid,
  p_account_id uuid,
  p_fallback_code text,
  p_debit numeric,
  p_credit numeric,
  p_description text
)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp as $$
declare
  v_account uuid := p_account_id;
begin
  if coalesce(p_debit, 0) = 0 and coalesce(p_credit, 0) = 0 then
    return '[]'::jsonb;
  end if;

  if v_account is null then
    select id into v_account from public.accounts
     where org_id = p_org_id and code = p_fallback_code and not is_group
     limit 1;
  end if;

  if v_account is null then
    raise exception
      'Payroll needs an account for "%" — configure it in payroll settings '
      'or add account % to the chart of accounts', p_description, p_fallback_code
      using errcode = '23503';
  end if;

  return jsonb_build_array(jsonb_build_object(
    'account_id', v_account,
    'description', p_description,
    'debit', round(coalesce(p_debit, 0), 2),
    'credit', round(coalesce(p_credit, 0), 2)));
end;
$$;
