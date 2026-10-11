-- =====================================================================
-- iAkauntan :: 0824 an expense is kept as it was posted
--
-- The app records an expense as a draft and posts it with
-- `post_expense`, which journals it -- the account, the bank it was paid
-- from, the amount and its tax, on its date -- and marks it posted;
-- `set_expense_split` keeps its lines. It never updates or deletes one
-- after that, and its attachments live in their own table. `0238`
-- freezes a posted invoice or bill to the columns its journal was built
-- from and refuses deleting one, for the reason "deleting it would
-- leave that journal with nothing to explain it". An expense had only
-- `refuse_reposting`, which keeps the journal link and nothing else.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: a posted RM500 expense of 4 March rewritten to RM50
-- on 1 May, set back to draft, and deleted -- each accepted, and the
-- RM500 out of the bank still in the ledger with nothing to say why.
--
-- Answered "freeze once posted", as `0814` did for a stocktake. A
-- trigger refuses a client's own statement -- role `authenticated` or
-- `anon`, at the top trigger depth -- that changes a posted expense's
-- figures, accounts, dates, dimensions, state or deletion mark, or
-- deletes it; that creates an expense other than as a draft; or that
-- moves a draft's state, which is the functions' to move. The
-- description and the reference of a posted expense stay editable --
-- its receipt is in the attachments module, a table of its own -- and
-- a draft is as editable as before. The functions
-- run as their owner and pass. NOT security definer.
--
-- Production held one expense, posted, on 11 October.
-- =====================================================================

create or replace function app.a_posted_expense_is_kept()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  -- What `post_expense` journals, and what says it did.
  c_frozen constant text[] := array[
    'org_id', 'expense_no', 'expense_date', 'contact_id', 'account_id',
    'bank_account_id', 'payment_mode_code', 'currency', 'exchange_rate',
    'amount', 'tax_code_id', 'tax_amount', 'total_amount', 'branch_id',
    'department_code', 'project_code', 'matter_id', 'status',
    'gl_entry_id', 'posted_at', 'deleted_at'];
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.gl_entry_id is not null
       or new.posted_at is not null then
      raise exception
        'An expense is recorded as a draft (this one said %). It is '
        'posted by posting it, which journals it.', new.status
        using errcode = '42501';
    end if;
    return new;
  end if;

  if old.gl_entry_id is not null then
    if tg_op = 'DELETE' then
      raise exception
        '% is posted: its journal is in the ledger, and deleting it would '
        'leave that journal with nothing to explain it.', old.expense_no
        using errcode = '42501';
    end if;
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    foreach v_col in array c_frozen loop
      if v_new -> v_col is distinct from v_old -> v_col then
        raise exception
          '% is posted, and its % is what its journal was built from. '
          'Its description and reference can still be put right.',
          old.expense_no, v_col
          using errcode = '42501';
      end if;
    end loop;
    return new;
  end if;

  if tg_op = 'UPDATE'
     and (new.status is distinct from old.status
          or new.gl_entry_id is distinct from old.gl_entry_id
          or new.posted_at is distinct from old.posted_at) then
    raise exception
      '% becomes posted by posting it, which journals it -- not by being '
      'marked so.', old.expense_no
      using errcode = '42501';
  end if;

  return coalesce(new, old);
end $$;

revoke all on function app.a_posted_expense_is_kept() from public, anon, authenticated;

comment on function app.a_posted_expense_is_kept() is
  'On expenses: refuses a client''s own statement that changes a posted '
  'expense''s journalled columns, state or deletion mark, deletes it, '
  'creates an expense other than as a draft, or moves a draft''s state. '
  'post_expense and set_expense_split pass. 0824.';

create trigger a_posted_expense_is_kept
  before insert or update or delete on public.expenses
  for each row execute function app.a_posted_expense_is_kept();
