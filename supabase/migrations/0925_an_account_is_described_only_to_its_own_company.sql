-- =====================================================================
-- iAkauntan :: 0925 an account is described only to its own company
--
-- `0912`'s trigger asks what kind of account a contact, an item or a
-- document line names, and says what it found: "An item's sales
-- account may not be 1120 Bank Accounts, a bank account". It looked
-- the account up by id alone. Given the id of ANOTHER company's
-- account of the wrong kind, it answered with that account's number,
-- name and kind.
--
-- Measured on 23 November 2026, locally, as the owner with the role
-- `authenticated`: an item, and a contact, in one company given
-- another company's 1120 were each refused with "1120 Bank Accounts"
-- in the message. The write never succeeds -- each column's tenant key
-- refuses it in any case -- and the id has to be known first; but the
-- refusal told one company something of another's chart.
--
-- Answered "look up own accounts only". The function is restated from
-- `0912` with only the lines marked 0925 changed: it reads an account
-- only where it belongs to the row's own company. Another company's
-- account is then left to the tenant key, which names no account.
-- `0919` and `0923` were written this way from the start. Nothing else
-- about the rule moves.
-- =====================================================================

create or replace function app.an_account_fits_where_it_is_used()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_arg   text;
  v_col   text;
  v_rule  text;
  v_label text;
  v_id    uuid;
  v_acct  public.accounts;
  v_what  text;
  v_want  text;
  v_new   jsonb := to_jsonb(new);
  v_old   jsonb;
begin
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
  end if;

  -- Each argument is `column:rule:what it is called`.
  foreach v_arg in array tg_argv loop
    v_col   := split_part(v_arg, ':', 1);
    v_rule  := split_part(v_arg, ':', 2);
    v_label := split_part(v_arg, ':', 3);
    v_id    := (v_new ->> v_col)::uuid;
    continue when v_id is null;
    continue when tg_op = 'UPDATE'
                  and (v_new -> v_col) is not distinct from (v_old -> v_col);

    -- 0925: only the writer's own company's accounts are read. One that
    -- does not exist, or is another company's, is the tenant key's to
    -- refuse -- and is described to nobody.
    select * into v_acct
      from public.accounts a
     where a.id = v_id and a.org_id = new.org_id;
    continue when v_acct.id is null;
    v_what := case
      when v_acct.is_group then 'a heading'
      when not v_acct.is_active then 'retired'
      when left(v_acct.account_subtype::text, 1) in ('a', 'e', 'i', 'o', 'u')
        then 'an ' || replace(v_acct.account_subtype::text, '_', ' ') || ' account'
      else 'a ' || replace(v_acct.account_subtype::text, '_', ' ') || ' account'
    end;

    if v_rule in ('receivable', 'payable') then
      v_want := case v_rule when 'receivable' then 'accounts_receivable'
                            else 'accounts_payable' end;
      if v_acct.is_group or not v_acct.is_active
         or v_acct.account_subtype::text is distinct from v_want then
        raise exception
          '% is an active % account that is not a heading, and % % is %. '
          'The aged listing reconciles against it, and every document '
          'for this party posts its balance there.',
          v_label, case v_rule when 'receivable' then 'receivables' else 'payables' end,
          v_acct.code, v_acct.name, v_what
          using errcode = '23514';
      end if;
    elsif v_acct.is_group then
      raise exception
        '% may not be % %, which is a heading: nothing posts to a heading, '
        'only to the accounts under it.',
        v_label, v_acct.code, v_acct.name
        using errcode = '23514';
    elsif v_acct.account_subtype in ('bank', 'cash') then
      raise exception
        '% may not be % %, %: money reaches a bank or a till through a '
        'receipt or a payment, where the reconciliation can see it.',
        v_label, v_acct.code, v_acct.name, v_what
        using errcode = '23514';
    elsif v_acct.account_subtype in ('accounts_receivable', 'accounts_payable') then
      raise exception
        '% may not be % %, %: a receivable or a payable is posted by the '
        'document it belongs to, against its customer or supplier, so the '
        'aged listing still agrees with the account.',
        v_label, v_acct.code, v_acct.name, v_what
        using errcode = '23514';
    end if;
  end loop;
  return new;
end;
$$;

revoke all on function app.an_account_fits_where_it_is_used() from public, anon, authenticated;
