-- ---------------------------------------------------------------------
-- A bank account you can actually add
--
-- `bank_accounts` has been readable from the app since 0059 and has
-- never once been writable from it. Every screen that reaches for one —
-- the reconciliation, the expense, the receipt, the payment, the asset
-- disposal, the claim, the transfer, the payment gateway — offers
-- whatever the bootstrap or a demo seed happened to insert, and a
-- company that opens a second account has no way to say so. Reported
-- from the other end: a picker that says "Nothing matches that" and
-- stops.
--
-- WHAT THIS ADDS is one function, because a bank account is two rows
-- that must not disagree: the `bank_accounts` row a screen picks from,
-- and the GL account behind it that the ledger actually posts to. Two
-- inserts done by hand is how a bank account ends up pointing at the
-- receivables control.
--
-- IT MAKES ITS OWN GL ACCOUNT BY DEFAULT, numbered in the 112x range
-- under Current Assets, beside the seeded '1120 Bank Accounts'. The
-- alternative — hanging every bank on the one shared 1120, which the
-- demo seeds do — gives a balance sheet with one "Bank Accounts" line
-- for three banks, and the auditor asking which is which. A caller who
-- wants that anyway passes `p_account_id`.
--
-- IT IS GUARDED BY `app.can_post`, the same guard as `upsert_account`:
-- adding a bank account adds a line to the balance sheet, which is the
-- chart of accounts by another name.
-- ---------------------------------------------------------------------

create or replace function public.upsert_bank_account(
  p_name           text,
  p_bank_name      text    default null,
  p_bank_code      text    default null,
  p_account_number text    default null,
  p_account_type   text    default 'current',
  p_currency       text    default 'MYR',
  p_account_id     uuid    default null,
  p_id             uuid    default null,
  p_org_id         uuid    default null
) returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org      uuid;
  v_old      public.bank_accounts;
  v_gl       uuid := p_account_id;
  v_parent   uuid;
  v_code     text;
  v_name     text := btrim(coalesce(p_name, ''));
  v_currency text := upper(btrim(coalesce(p_currency, 'MYR')));
  v_id       uuid;
begin
  if p_id is not null then
    select * into v_old from public.bank_accounts b where b.id = p_id;
    if v_old.id is null then
      raise exception 'No such bank account.' using errcode = '23503';
    end if;
    v_org := v_old.org_id;
  else
    v_org := p_org_id;
  end if;

  if v_org is null then
    raise exception 'Which company is this bank account for?'
      using errcode = '22023';
  end if;
  if not app.can_post(v_org) then
    raise exception
      'Only somebody who may post the books may add a bank account'
      using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'A bank account needs a name.' using errcode = '23514';
  end if;
  if length(v_currency) <> 3 then
    raise exception 'A currency is three letters.' using errcode = '23514';
  end if;

  -- A GL account handed in has to belong to the same company and be
  -- somewhere money can sit. Posting a receipt into the receivables
  -- control because a picker offered it is the failure this refuses.
  if v_gl is not null then
    if not exists (
      select 1 from public.accounts a
       where a.id = v_gl
         and a.org_id = v_org
         and not a.is_group
         and a.account_subtype in ('bank', 'cash')
    ) then
      raise exception
        'That is not a bank or cash account in this company.'
        using errcode = '23514';
    end if;
  end if;

  if p_id is not null then
    update public.bank_accounts
       set name           = v_name,
           bank_name      = nullif(btrim(p_bank_name), ''),
           bank_code      = nullif(btrim(p_bank_code), ''),
           account_number = nullif(btrim(p_account_number), ''),
           account_type   = coalesce(nullif(btrim(p_account_type), ''),
                                     v_old.account_type),
           -- The GL account behind an account with postings is not
           -- changed here: moving it would leave the balance in one
           -- account and the movements in another. Only what is given
           -- is applied, and null means "leave it".
           account_id     = coalesce(v_gl, v_old.account_id),
           updated_at     = now()
     where id = p_id
    returning id into v_id;
    return v_id;
  end if;

  if v_gl is null then
    select id into v_parent
      from public.accounts
     where org_id = v_org and code = '1100'
     limit 1;

    -- The next free number in the bank range. 1120 itself is the
    -- seeded heading every bootstrap makes, so the search starts after
    -- it and the first account a company adds is 1121.
    select to_char(n, 'FM0000') into v_code
      from generate_series(1121, 1199) as n
     where not exists (
       select 1 from public.accounts a
        where a.org_id = v_org and a.code = to_char(n, 'FM0000')
     )
     order by n
     limit 1;

    if v_code is null then
      raise exception
        'The bank range 1121-1199 is full. Add the account on the chart '
        'first and choose it here.'
        using errcode = '23514';
    end if;

    insert into public.accounts
      (org_id, code, name, account_type, account_subtype, parent_id,
       is_group)
    values (v_org, v_code, v_name, 'asset', 'bank', v_parent, false)
    returning id into v_gl;
  end if;

  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, bank_code, account_number,
     account_type, currency, is_active,
     -- The FIRST one a company has is its default, because every screen
     -- that says "leave blank for the default" has to mean something.
     is_default)
  values (v_org, v_gl, v_name, nullif(btrim(p_bank_name), ''),
          nullif(btrim(p_bank_code), ''),
          nullif(btrim(p_account_number), ''),
          coalesce(nullif(btrim(p_account_type), ''), 'current'),
          v_currency, true,
          not exists (select 1 from public.bank_accounts b
                       where b.org_id = v_org and b.is_active))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.upsert_bank_account is
  'Adds or amends a bank account and the GL account behind it, as one '
  'act, so the two cannot disagree.';

revoke all on function public.upsert_bank_account(
  text, text, text, text, text, text, uuid, uuid, uuid) from public, anon;
grant execute on function public.upsert_bank_account(
  text, text, text, text, text, text, uuid, uuid, uuid) to authenticated;
