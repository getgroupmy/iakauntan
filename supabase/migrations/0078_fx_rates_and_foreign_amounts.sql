-- Multi-currency, part one: resolving a rate, and remembering the
-- amount that was actually invoiced.
--
-- The storage for all of this already existed and was never used.
-- `exchange_rates` has been in the schema since 0002, `gl_lines` has
-- carried `fc_debit`, `fc_credit`, `currency` and `exchange_rate` since
-- 0004, and the posting functions already multiply by the document's
-- rate — so the ledger has always converted correctly. What was missing
-- is a way to *get* a rate, and the habit of writing down the foreign
-- amount beside the converted one.
--
-- Without the foreign amount, a USD invoice posts RM 47,000 to
-- receivables and the ledger forgets it was ever USD 10,000. You cannot
-- then produce a customer statement in the customer's currency, and you
-- cannot reconcile a USD bank account against a USD bank statement.

-- ---------------------------------------------------------------------
-- The org's own currency
-- ---------------------------------------------------------------------
create or replace function app.base_currency(p_org_id uuid)
returns character
language sql stable security definer
set search_path = public, pg_temp as $$
  select base_currency from public.organizations where id = p_org_id;
$$;

-- ---------------------------------------------------------------------
-- The rate to apply
--
-- Latest rate quoted on or before the date, because a document dated the
-- 15th is converted at the rate that was known on the 15th, not at
-- whatever has been entered since.
--
-- It raises rather than defaulting to 1 when no rate exists. Defaulting
-- would post a USD 10,000 invoice as RM 10,000 — a silent four-fold
-- understatement that balances perfectly and would survive every check
-- in this system. An error naming the currency and the date is the only
-- safe answer.
-- ---------------------------------------------------------------------
create or replace function app.exchange_rate_for(
  p_org_id uuid, p_currency character, p_on_date date)
returns numeric
language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_base character(3) := app.base_currency(p_org_id);
  v_rate numeric(18, 8);
begin
  if p_currency is null or p_currency = v_base then
    return 1;
  end if;

  select rate into v_rate
    from public.exchange_rates
   where org_id = p_org_id
     and from_currency = p_currency
     and to_currency = v_base
     and rate_date <= p_on_date
   order by rate_date desc
   limit 1;

  if v_rate is null then
    raise exception
      'No exchange rate for % to % on or before %. Enter one before posting.',
      p_currency, v_base, p_on_date
      using errcode = 'P0002';
  end if;

  if v_rate <= 0 then
    raise exception 'Exchange rate for % on % is %, which cannot be used.',
      p_currency, p_on_date, v_rate using errcode = '23514';
  end if;

  return v_rate;
end;
$$;

grant execute on function app.base_currency(uuid) to authenticated;
grant execute on function app.exchange_rate_for(uuid, character, date)
  to authenticated;

-- A public reader, so the client can show the rate it is about to use
-- before the document is saved.
create or replace function public.exchange_rate_for(
  p_org_id uuid, p_currency character, p_on_date date default current_date)
returns numeric
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;
  return app.exchange_rate_for(p_org_id, p_currency, p_on_date);
end;
$$;

revoke all on function public.exchange_rate_for(uuid, character, date)
  from public, anon;
grant execute on function public.exchange_rate_for(uuid, character, date)
  to authenticated;

-- ---------------------------------------------------------------------
-- Carry the foreign amount onto every line
--
-- Callers pass base amounts, because that is what the ledger balances
-- on and every existing caller already multiplies by the rate. Rather
-- than change all of them, the foreign amount is derived back out of the
-- base amount unless the caller states it.
--
-- Deriving means dividing by the rate, which can land a sen away from
-- the figure on the document when the base amount was itself rounded.
-- That is acceptable here and would not be if the ledger balanced on
-- these columns — it does not; they are a record of what was invoiced,
-- and `debit`/`credit` remain the only figures that must foot. A caller
-- that cares about the sen passes `fc_debit` and `fc_credit` explicitly.
-- ---------------------------------------------------------------------
create or replace function app.create_gl_entry_internal(
  p_org_id uuid, p_entry_date date, p_source app.journal_source, p_lines jsonb,
  p_description text default null, p_source_table text default null,
  p_source_id uuid default null, p_reference text default null,
  p_currency character default 'MYR', p_exchange_rate numeric default 1)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_entry_id uuid; v_period_id uuid; v_status text; v_line jsonb;
  v_no integer := 0; v_debit numeric(18,2) := 0; v_credit numeric(18,2) := 0;
  v_base character(3) := app.base_currency(p_org_id);
  v_foreign boolean;
  v_rate numeric(18,8) := coalesce(p_exchange_rate, 1);
  v_ln_debit numeric(18,2); v_ln_credit numeric(18,2);
  v_fc_debit numeric(18,2); v_fc_credit numeric(18,2);
begin
  v_period_id := app.period_for_date(p_org_id, p_entry_date);
  if v_period_id is null then
    raise exception
      'No fiscal period covers %. Create the fiscal year before posting to it.',
      p_entry_date using errcode = '23514';
  end if;

  select status into v_status from public.fiscal_periods where id = v_period_id;
  if v_status <> 'open' then
    raise exception 'Fiscal period for % is %', p_entry_date, v_status using errcode = '23514';
  end if;

  -- A foreign entry with no usable rate would post zeroes and balance,
  -- which is the worst way to be wrong.
  v_foreign := p_currency is not null and p_currency <> v_base;
  if v_foreign and v_rate <= 0 then
    raise exception 'A % entry needs an exchange rate; got %',
      p_currency, p_exchange_rate using errcode = '23514';
  end if;

  insert into public.gl_entries (
    org_id, entry_no, entry_date, fiscal_period_id, source,
    source_table, source_id, description, reference,
    currency, exchange_rate, status, posted_at, posted_by, created_by
  ) values (
    p_org_id, app.next_document_number_internal(p_org_id, 'journal'),
    p_entry_date, v_period_id, p_source, p_source_table, p_source_id,
    p_description, p_reference, p_currency, v_rate,
    'posted', now(), auth.uid(), auth.uid()
  ) returning id into v_entry_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    v_ln_debit  := round(coalesce((v_line ->> 'debit')::numeric, 0), 2);
    v_ln_credit := round(coalesce((v_line ->> 'credit')::numeric, 0), 2);

    if not v_foreign then
      -- Nothing foreign about it. Left at zero rather than repeating the
      -- base amount, so a non-zero fc figure always means "this line was
      -- in another currency".
      v_fc_debit := 0;
      v_fc_credit := 0;
    else
      v_fc_debit := round(coalesce((v_line ->> 'fc_debit')::numeric,
                                   v_ln_debit / v_rate), 2);
      v_fc_credit := round(coalesce((v_line ->> 'fc_credit')::numeric,
                                    v_ln_credit / v_rate), 2);
    end if;

    insert into public.gl_lines (
      org_id, entry_id, line_no, account_id, description, debit, credit,
      fc_debit, fc_credit,
      currency, exchange_rate, contact_id, item_id, tax_code_id, tax_amount,
      project_code, department_code
    ) values (
      p_org_id, v_entry_id, v_no,
      (v_line ->> 'account_id')::uuid, v_line ->> 'description',
      v_ln_debit, v_ln_credit, v_fc_debit, v_fc_credit,
      p_currency, v_rate,
      nullif(v_line ->> 'contact_id', '')::uuid,
      nullif(v_line ->> 'item_id', '')::uuid,
      nullif(v_line ->> 'tax_code_id', '')::uuid,
      round(coalesce((v_line ->> 'tax_amount')::numeric, 0), 2),
      v_line ->> 'project_code', v_line ->> 'department_code');

    v_debit := v_debit + v_ln_debit;
    v_credit := v_credit + v_ln_credit;
  end loop;

  if v_debit <> v_credit then
    raise exception 'Journal does not balance: debits %, credits %', v_debit, v_credit
      using errcode = '23514';
  end if;
  return v_entry_id;
end; $$;
