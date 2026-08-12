-- Multi-currency, part four: what the open balances are worth today.
--
-- 0078 gave documents a rate, 0079 posted the gain or loss when they
-- settle. Between those two moments a foreign invoice sits in
-- receivables at the rate it was raised at, however far the currency has
-- moved since. At year end that is simply wrong: MFRS 121 requires
-- monetary items in a foreign currency to be restated at the closing
-- rate, with the difference through profit and loss.
--
-- A USD 100,000 debtor book raised at 4.70 and unrevalued at a closing
-- rate of 4.20 overstates receivables by RM 50,000 and overstates profit
-- by the same. The balance sheet balances. Nothing else in this system
-- would notice — `journal_source` has carried an `fx_revaluation` value
-- since 0004 with nothing able to produce one.
--
-- How each run relates to the last
-- --------------------------------
-- Every run reverses the revaluation still standing and posts a fresh
-- one measured from each document's own booked rate. So the adjustment
-- never compounds, each period's profit and loss carries that period's
-- movement, and the standing entry at any moment states the whole
-- difference as at the last run. The alternative — posting only the
-- movement since last time — gives the same P&L and a balance that
-- drifts if a run is ever missed or repeated.
--
-- What is not covered
-- -------------------
-- Foreign-currency **bank accounts**. Their balance would have to come
-- from `gl_lines.fc_debit`/`fc_credit`, which only became reliable from
-- 0078 — anything posted before that carries zero there, and revaluing
-- against it would restate a balance that was never recorded in foreign
-- currency at all. Receivables and payables are covered because each
-- open document carries its own currency, amount and rate, so the
-- arithmetic needs nothing that was not written down at the time.

-- ---------------------------------------------------------------------
-- What the difference is, before anything is posted
--
-- One row per currency, so the screen offering this can show the closing
-- rate it is about to apply and what it will do. Raises through
-- app.exchange_rate_for if a rate is missing, rather than reporting a
-- confident zero for a currency it could not price.
-- ---------------------------------------------------------------------
create or replace function public.fx_revaluation_preview(
  p_org_id uuid, p_as_at date default current_date)
returns table (
  currency character, closing_rate numeric, documents integer,
  booked numeric, restated numeric, difference numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_base character(3);
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;
  v_base := app.base_currency(p_org_id);

  return query
  with open_items as (
    select d.currency, d.balance_amount as amount,
           coalesce(d.exchange_rate, 1) as rate
      from public.sales_documents d
     where d.org_id = p_org_id and d.currency <> v_base
       and d.balance_amount <> 0 and d.doc_date <= p_as_at
       and d.deleted_at is null and d.gl_entry_id is not null
       and d.status <> 'void'
    union all
    select d.currency, -d.balance_amount, coalesce(d.exchange_rate, 1)
      from public.purchase_documents d
     where d.org_id = p_org_id and d.currency <> v_base
       and d.balance_amount <> 0 and d.doc_date <= p_as_at
       and d.deleted_at is null and d.gl_entry_id is not null
       and d.status <> 'void'
  )
  select o.currency,
         app.exchange_rate_for(p_org_id, o.currency, p_as_at),
         count(*)::integer,
         round(sum(o.amount * o.rate), 2),
         round(sum(o.amount * app.exchange_rate_for(p_org_id, o.currency, p_as_at)), 2),
         round(sum(o.amount * app.exchange_rate_for(p_org_id, o.currency, p_as_at))
             - sum(o.amount * o.rate), 2)
    from open_items o
   group by o.currency
   order by o.currency;
end;
$$;

-- ---------------------------------------------------------------------
-- Post it
--
-- Returns the new journal, or null when there was nothing to restate.
-- Null rather than an empty journal: a zero-value entry in the ledger is
-- a thing somebody has to explain at audit.
-- ---------------------------------------------------------------------
create or replace function public.revalue_foreign_balances(
  p_org_id uuid, p_as_at date default current_date)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_base     character(3);
  v_prior    uuid;
  v_entries  jsonb := '[]'::jsonb;
  v_gain     numeric(18, 2) := 0;
  v_loss     numeric(18, 2) := 0;
  v_entry_id uuid;
  r          record;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;

  v_base := app.base_currency(p_org_id);

  -- Undo the standing revaluation first, dated the same day, so this run
  -- measures from the booked rates rather than from the last estimate.
  select id into v_prior
    from public.gl_entries
   where org_id = p_org_id and source = 'fx_revaluation'
     and status = 'posted' and is_reversal = false
   order by entry_date desc, created_at desc
   limit 1;

  if v_prior is not null then
    perform public.reverse_gl_entry(v_prior, p_as_at);
  end if;

  -- Receivables, then payables, grouped by the account and contact they
  -- sit against so the subledger still agrees with the nominal after
  -- the adjustment.
  for r in
    with items as (
      select coalesce(c.receivable_account_id,
               (select id from public.accounts
                 where org_id = p_org_id and code = '1210')) as account_id,
             d.contact_id, d.currency,
             d.balance_amount as amount, coalesce(d.exchange_rate, 1) as rate
        from public.sales_documents d
        join public.contacts c on c.id = d.contact_id
       where d.org_id = p_org_id and d.currency <> v_base
         and d.balance_amount <> 0 and d.doc_date <= p_as_at
         and d.deleted_at is null and d.gl_entry_id is not null
         and d.status <> 'void'
      union all
      select coalesce(c.payable_account_id,
               (select id from public.accounts
                 where org_id = p_org_id and code = '2110')),
             d.contact_id, d.currency,
             -d.balance_amount, coalesce(d.exchange_rate, 1)
        from public.purchase_documents d
        join public.contacts c on c.id = d.contact_id
       where d.org_id = p_org_id and d.currency <> v_base
         and d.balance_amount <> 0 and d.doc_date <= p_as_at
         and d.deleted_at is null and d.gl_entry_id is not null
         and d.status <> 'void'
    )
    select i.account_id, i.contact_id, i.currency,
           round(sum(i.amount * app.exchange_rate_for(p_org_id, i.currency, p_as_at))
               - sum(i.amount * i.rate), 2) as diff
      from items i
     group by i.account_id, i.contact_id, i.currency
    having round(sum(i.amount * app.exchange_rate_for(p_org_id, i.currency, p_as_at))
              - sum(i.amount * i.rate), 2) <> 0
  loop
    -- The sign carries the meaning and does not need a second rule:
    -- amounts were signed positive for receivables and negative for
    -- payables above, so a positive difference is always more asset or
    -- less liability, which is always a gain.
    if r.diff > 0 then
      v_entries := v_entries || jsonb_build_object(
        'account_id', r.account_id,
        'description', 'Revaluation of ' || r.currency || ' balance',
        'debit', r.diff, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,
        'contact_id', r.contact_id);
      v_gain := v_gain + r.diff;
    else
      v_entries := v_entries || jsonb_build_object(
        'account_id', r.account_id,
        'description', 'Revaluation of ' || r.currency || ' balance',
        'debit', 0, 'credit', -r.diff, 'fc_debit', 0, 'fc_credit', 0,
        'contact_id', r.contact_id);
      v_loss := v_loss + (-r.diff);
    end if;
  end loop;

  if v_gain = 0 and v_loss = 0 then
    return null;
  end if;

  -- Gains and losses are stated separately rather than netted. A year
  -- with RM 80,000 of each is not the same year as one with neither,
  -- and netting to zero would say it was.
  if v_gain <> 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(p_org_id, true),
      'description', 'Unrealised exchange gain at ' || p_as_at,
      'debit', 0, 'credit', v_gain, 'fc_debit', 0, 'fc_credit', 0);
  end if;
  if v_loss <> 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(p_org_id, false),
      'description', 'Unrealised exchange loss at ' || p_as_at,
      'debit', v_loss, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
  end if;

  v_entry_id := app.create_gl_entry_internal(
    p_org_id, p_as_at, 'fx_revaluation'::app.journal_source, v_entries,
    'Revaluation of foreign balances at ' || p_as_at,
    null, null, null, v_base, 1);

  return v_entry_id;
end;
$$;

revoke all on function public.fx_revaluation_preview(uuid, date) from public, anon;
grant execute on function public.fx_revaluation_preview(uuid, date) to authenticated;

revoke all on function public.revalue_foreign_balances(uuid, date) from public, anon;
grant execute on function public.revalue_foreign_balances(uuid, date) to authenticated;
