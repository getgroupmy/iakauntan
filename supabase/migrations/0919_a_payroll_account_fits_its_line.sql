-- =====================================================================
-- iAkauntan :: 0919 a payroll account fits its line
--
-- `post_payroll_run` posts eleven lines to accounts a company may name
-- in `payroll_settings` -- five expenses and six payables -- and
-- `app.payroll_gl_line` takes each one as it is given, falling back to
-- a numbered account only where none is named. Whoever may run payroll
-- may write the settings, and nothing asked what kind of account each
-- one was. `0912` asked it of a contact, a document line and an item.
--
-- Measured on 22 November 2026, locally, as the owner with the role
-- `authenticated`: EPF payable and salary expense set to the bank
-- (1120) and net salaries payable to a revenue account (4100) -- all
-- accepted, as was a heading for PCB payable. A payroll of RM5,000 then
-- posted 1120 3,800 / 4100 -4,415 with the other lines in their
-- places: no salary expense, no EPF owed to KWSP, RM3,800 in a bank
-- that never received it and RM4,415 of revenue nobody earned.
--
-- The app has no screen for these columns. Production on 22 November:
-- no `payroll_settings` row at all; every company posts to the
-- numbered accounts.
--
-- Answered "each account must fit its line", for every writer: an
-- expense line's account is an active expense account that is not a
-- heading, and a payable line's an active liability account that is
-- not a heading. Asked when an account is set or changed, so a row
-- that already names one is still written. Unset still means the
-- numbered account. The same company is already asked by each
-- column's composite foreign key, and is left to it: another company's
-- account is looked up by nobody here, so its name is in no refusal.
-- =====================================================================

create or replace function app.a_payroll_account_fits_its_line()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line  text[];
  v_col   text;
  v_kind  text;
  v_label text;
  v_id    uuid;
  v_acct  public.accounts;
  v_what  text;
  v_new   jsonb := to_jsonb(new);
  v_old   jsonb;
begin
  -- SECURITY DEFINER because it reads the account, and a writer who may
  -- not read the chart must not be waved through by reading nothing.
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
  end if;

  -- column, the kind of account its line posts to, what the line is.
  foreach v_line slice 1 in array array[
    ['salary_expense_account_id', 'expense',   'The salary expense'],
    ['epf_expense_account_id',    'expense',   'The employer''s EPF expense'],
    ['socso_expense_account_id',  'expense',   'The employer''s SOCSO expense'],
    ['eis_expense_account_id',    'expense',   'The employer''s EIS expense'],
    ['hrdf_expense_account_id',   'expense',   'The HRD Corp levy expense'],
    ['salary_payable_account_id', 'liability', 'The net salary payable'],
    ['epf_payable_account_id',    'liability', 'The EPF payable'],
    ['socso_payable_account_id',  'liability', 'The SOCSO payable'],
    ['eis_payable_account_id',    'liability', 'The EIS payable'],
    ['pcb_payable_account_id',    'liability', 'The PCB payable'],
    ['zakat_payable_account_id',  'liability', 'The zakat payable']
  ] loop
    v_col   := v_line[1];
    v_kind  := v_line[2];
    v_label := v_line[3];
    v_id    := (v_new ->> v_col)::uuid;
    continue when v_id is null;
    continue when tg_op = 'UPDATE'
                  and (v_new -> v_col) is not distinct from (v_old -> v_col);

    select * into v_acct
      from public.accounts a
     where a.id = v_id and a.org_id = new.org_id;
    -- An account that does not exist, or is another company's, is the
    -- foreign key's to refuse -- and is not described to this writer.
    continue when v_acct.id is null;

    if v_acct.is_group or not v_acct.is_active
       or v_acct.account_type::text is distinct from v_kind then
      v_what := case
        when v_acct.is_group then 'a heading'
        when not v_acct.is_active then 'retired'
        when left(v_acct.account_type::text, 1) in ('a', 'e', 'i', 'o', 'u')
          then 'an ' || v_acct.account_type::text || ' account'
        else 'a ' || v_acct.account_type::text || ' account'
      end;
      raise exception
        '% belongs in an active % account that is not a heading, and % % '
        'is %. Payroll would post it there every month. Leave it unset to '
        'use the chart''s own account.',
        v_label, v_kind, v_acct.code, v_acct.name, v_what
        using errcode = '23514';
    end if;
  end loop;
  return new;
end;
$$;

revoke all on function app.a_payroll_account_fits_its_line() from public, anon, authenticated;

comment on function app.a_payroll_account_fits_its_line() is
  'Refuses, for every writer, a payroll_settings account that is not an '
  'active, non-heading account of its line''s kind: expense for the five '
  'expense lines, liability for the six payable lines. Asked when an '
  'account is set or changed. 0919.';

create trigger a_payroll_account_fits_its_line
  before insert or update of
    salary_expense_account_id, epf_expense_account_id, socso_expense_account_id,
    eis_expense_account_id, hrdf_expense_account_id, salary_payable_account_id,
    epf_payable_account_id, socso_payable_account_id, eis_payable_account_id,
    pcb_payable_account_id, zakat_payable_account_id
  on public.payroll_settings
  for each row execute function app.a_payroll_account_fits_its_line();
