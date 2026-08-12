-- =====================================================================
-- iAkauntan :: 0102 a reversal leaves the original standing
--
-- `reverse_gl_entry` did both of the two things you can do to a posted
-- journal, and doing both is the one combination that is wrong. It
-- posted a mirror entry *and* marked the original `void`. Every report
-- in this system filters `status = 'posted'`, so the original dropped
-- out and only the mirror remained — leaving the ledger holding the
-- exact opposite of the entry instead of nothing.
--
-- Voiding a RM 1,000 invoice left revenue 1,000 on the wrong side and
-- the customer showing 1,000 in credit. Found while building
-- `void_bank_transfer`, which needs the same primitive; confirmed by
-- posting an invoice, voiding it, and reading the trial balance.
--
-- It reached three callers:
--
--   `void_sales_document`      every voided invoice, credit note and
--                              debit note
--   `revalue_foreign_balances` every revaluation after the first, which
--                              undoes the standing one before posting
--                              a fresh one
--   the Reverse button on the journal screen
--
-- The fix is to stop voiding. Contra-ing a journal rather than deleting
-- it is the point of a reversal: 0059 already refuses to post one into
-- a closed period, which only makes sense if the original stays where
-- it is and the correction lands in an open period. An entry that has
-- already been reversed is now refused rather than reversed again.
--
-- `supabase/tests/reversal.sql` asserts that all three come to zero.
-- =====================================================================

create or replace function public.reverse_gl_entry(
  p_entry_id uuid, p_date date default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_entry public.gl_entries;
  v_new_id uuid;
  v_period_id uuid;
  v_status text;
  v_on date := coalesce(p_date, current_date);
begin
  select * into v_entry from public.gl_entries where id = p_entry_id;
  if not found then raise exception 'Journal % not found', p_entry_id; end if;
  if not app.can_post(v_entry.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_entry.status <> 'posted' then
    raise exception 'Only posted journals can be reversed' using errcode = '22023';
  end if;

  -- Reversing twice would contra the contra and put the entry back,
  -- which is the shape of the bug this migration exists to fix.
  if exists (select 1 from public.gl_entries r
              where r.reversed_entry_id = p_entry_id and r.status = 'posted') then
    raise exception 'Journal % has already been reversed', v_entry.entry_no
      using errcode = '22023';
  end if;

  v_period_id := app.period_for_date(v_entry.org_id, v_on);
  if v_period_id is null then
    raise exception
      'No fiscal period covers %. Create the fiscal year before posting to it.',
      v_on using errcode = '23514';
  end if;
  select status into v_status from public.fiscal_periods where id = v_period_id;
  if v_status <> 'open' then
    raise exception 'Fiscal period for % is %', v_on, v_status using errcode = '23514';
  end if;

  insert into public.gl_entries (
    org_id, entry_no, entry_date, fiscal_period_id, source, source_table, source_id,
    description, reference, currency, exchange_rate, status, is_reversal,
    reversed_entry_id, posted_at, posted_by, created_by
  ) values (
    v_entry.org_id, app.next_document_number_internal(v_entry.org_id, 'journal'),
    v_on, v_period_id, v_entry.source,
    v_entry.source_table, v_entry.source_id,
    'Reversal of ' || v_entry.entry_no, v_entry.reference,
    v_entry.currency, v_entry.exchange_rate, 'posted', true, v_entry.id,
    now(), auth.uid(), auth.uid()
  ) returning id into v_new_id;

  insert into public.gl_lines (
    org_id, entry_id, line_no, account_id, description, debit, credit,
    currency, exchange_rate, contact_id, item_id, tax_code_id)
  select org_id, v_new_id, line_no, account_id,
         'Reversal: ' || coalesce(description, ''),
         credit, debit, currency, exchange_rate, contact_id, item_id, tax_code_id
    from public.gl_lines where entry_id = p_entry_id;

  -- The original stays posted. The pair nets to zero, and both halves
  -- are on the page where an auditor can see what happened.
  return v_new_id;
end; $$;

revoke all on function public.reverse_gl_entry(uuid, date) from public, anon;
grant execute on function public.reverse_gl_entry(uuid, date)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- The one caller that was relying on the void
--
-- It looks for the standing revaluation to undo before posting a fresh
-- one, and found it with `status = 'posted' and is_reversal = false` —
-- which worked only because a reversed entry stopped being posted. Now
-- that the original stays where it is, "standing" has to be said
-- properly: posted, not itself a reversal, and not already reversed.
--
-- Everything else in this function is 0083's, unchanged.
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
  select e.id into v_prior
    from public.gl_entries e
   where e.org_id = p_org_id and e.source = 'fx_revaluation'
     and e.status = 'posted' and e.is_reversal = false
     and not exists (select 1 from public.gl_entries x
                      where x.reversed_entry_id = e.id and x.status = 'posted')
   order by e.entry_date desc, e.created_at desc
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
