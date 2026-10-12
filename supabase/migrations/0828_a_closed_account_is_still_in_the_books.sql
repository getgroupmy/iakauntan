-- =====================================================================
-- iAkauntan :: 0828 a closed account is still in the books
--
-- `retire_account` closes a ledger account: switched off, hidden from
-- the chart, kept (`0619`). It refuses an account the ledger posts to
-- by number and one with open accounts under it -- and nothing else.
-- `report_trial_balance`, `report_balance_sheet`,
-- `report_general_ledger`, `report_changes_in_equity` and
-- `report_matter_trial_balance` then leave a closed account out, and
-- `report_cash_flow` leaves out its opening balance, whatever it holds
-- -- its lines in the period they all counted, its balance they did
-- not.
--
-- Found in production on 12 October 2026, read-only: one company's
-- trial balance showed RM832.50 of debits against RM922.50 of credits.
-- Its ledger balances -- RM1,732.50 a side -- but a bank sub-account,
-- `1120-M001`, had been closed through `retire_account` on 30 September
-- carrying a RM90.00 debit, and the bank account it belongs to is still
-- active and still posts to it. The RM90 was gone from the trial
-- balance and from the balance sheet's assets.
--
-- Answered "reports and refuse":
--
-- 1. The six reports show a closed account that carries posted lines.
--    The trial balance and the balance sheet ask it of the lines they
--    already read; the general ledger, changes in equity and the cash
--    flow's opening-balance sums ask whether any posted line names the
--    account; the matter trial balance only ever listed an account the
--    matter moved, so its filter is simply dropped. A closed account
--    with nothing but a typed opening balance stays out, as
--    `general_ledger.sql` and `financial_statements.sql` assert it
--    should. That company's RM90 is back in both reports, and no row of
--    its data is touched.
-- 2. `retire_account` refuses an account that still carries a balance,
--    signed as the trial balance signs it, and one an active bank
--    account posts to.
--
-- A client closing or deleting an account by hand, past
-- `retire_account` altogether, is `0829`.
--
-- Each function is restated from `pg_get_functiondef` of the live one,
-- with only what is marked `0828` changed.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.report_trial_balance(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, account_subtype app.account_subtype, opening_balance numeric, debit numeric, credit numeric, closing_balance numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with movements as (
    select l.account_id,
           -- With no start date every posted line is inside the period,
           -- so there is nothing to carry forward as an opening balance.
           sum(case when p_from is not null and e.entry_date < p_from
                    then l.debit - l.credit else 0 end) as opening,
           sum(case when p_from is null or e.entry_date >= p_from
                    then l.debit else 0 end) as dr,
           sum(case when p_from is null or e.entry_date >= p_from
                    then l.credit else 0 end) as cr
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
     where l.org_id = p_org_id
       and e.status = 'posted'
       and e.entry_date <= p_to
     group by l.account_id)
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(coalesce(m.opening, 0) + case when a.account_type in ('asset','expense')
               then a.opening_balance else -a.opening_balance end, 2),
         round(coalesce(m.dr, 0), 2),
         round(coalesce(m.cr, 0), 2),
         round(coalesce(m.opening, 0) + coalesce(m.dr, 0) - coalesce(m.cr, 0)
               + case when a.account_type in ('asset','expense')
                      then a.opening_balance else -a.opening_balance end, 2)
    from public.accounts a
    left join movements m on m.account_id = a.id
   where a.org_id = p_org_id
     -- Open, or closed with posted lines in it (0828). A closed account
     -- carrying lines is still part of the books, and leaving it out
     -- leaves the trial balance out by it. One with only a typed
     -- opening balance stays out, as `0458`'s ledger has it.
     and (a.deleted_at is null or m.account_id is not null)
     and not a.is_group
     and app.is_org_member(p_org_id)
   order by a.code;
$function$;

CREATE OR REPLACE FUNCTION public.report_balance_sheet(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, account_subtype app.account_subtype, balance numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(coalesce(sum(
           -- e.id is null when the journal did not satisfy the join
           -- conditions (draft, void, or after the cut-off date).
           case when e.id is null then 0
                when a.account_type in ('asset', 'expense')
                then l.debit - l.credit
                else l.credit - l.debit end), 0) + a.opening_balance, 2) as balance
    from public.accounts a
    left join public.gl_lines l on l.account_id = a.id
    left join public.gl_entries e on e.id = l.entry_id
         and e.status = 'posted' and e.entry_date <= p_as_at
   where a.org_id = p_org_id
     and not a.is_group
     and a.account_type in ('asset', 'liability', 'equity')
     and app.is_org_member(p_org_id)
   group by a.id, a.code, a.name, a.account_type, a.account_subtype, a.opening_balance
  -- Open, or closed with posted lines by the date (0828): what a closed
  -- account still holds is still an asset, a liability or equity.
  having a.deleted_at is null or count(e.id) > 0
   order by a.code;
$function$;

CREATE OR REPLACE FUNCTION public.report_general_ledger(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_account_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, entry_date date, entry_no text, line_no integer, source text, description text, reference text, contact_name text, debit numeric, credit numeric, balance numeric, is_opening boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with bounds as (
    select coalesce(p_to, app.today()) as upto
  ),
  wanted as (
    select a.id, a.code, a.name, a.account_type, a.opening_balance
      from public.accounts a
     where a.org_id = p_org_id
       -- Open, or closed with posted lines (0828): a closed account
       -- with lines is part of the ledger. One with only a typed opening
       -- balance is still not.
       and (a.deleted_at is null
            or exists (select 1 from public.gl_lines pl
                          join public.gl_entries pe on pe.id = pl.entry_id
                         where pl.account_id = a.id and pe.status = 'posted'))
       and not a.is_group
       and (p_account_id is null or a.id = p_account_id)
  ),
  -- What the account stood at before the period began. The same sum
  -- `report_trial_balance` makes, including the account's own recorded
  -- opening balance signed by its type.
  opening as (
    select w.id as account_id,
           coalesce((
             select sum(l.debit - l.credit)
               from public.gl_lines l
               join public.gl_entries e on e.id = l.entry_id
              where l.account_id = w.id
                and l.org_id = p_org_id
                and e.status = 'posted'
                and p_from is not null
                and e.entry_date < p_from), 0)
           + case when w.account_type in ('asset', 'expense')
                  then w.opening_balance else -w.opening_balance end
             as amount
      from wanted w
  ),
  lines as (
    select w.id as account_id, w.code, w.name, w.account_type,
           e.entry_date, e.entry_no, e.source::text, l.description,
           e.reference, c.name as contact_name,
           l.debit, l.credit, l.line_no, e.created_at
      from wanted w
      join public.gl_lines l on l.account_id = w.id
      join public.gl_entries e on e.id = l.entry_id
      left join public.contacts c on c.id = l.contact_id
      cross join bounds b
     where l.org_id = p_org_id
       and e.status = 'posted'
       and e.entry_date <= b.upto
       and (p_from is null or e.entry_date >= p_from)
  ),
  running as (
    select l.*,
           o.amount + sum(l.debit - l.credit) over (
             partition by l.account_id
             order by l.entry_date, l.entry_no, l.line_no, l.created_at
             rows between unbounded preceding and current row) as balance
      from lines l
      join opening o on o.account_id = l.account_id
  )
  -- The line the balance is carried forward on, and then the account's
  -- movements under it.
  select w.id, w.code, w.name, w.account_type,
         p_from, null::text, null::integer, null::text,
         'Balance brought forward'::text, null::text, null::text,
         0::numeric, 0::numeric, round(o.amount, 2), true
    from wanted w
    join opening o on o.account_id = w.id
   where app.is_org_member(p_org_id)
     -- An account with nothing in it and nothing brought forward is not
     -- part of anybody's ledger.
     and (o.amount <> 0
          or exists (select 1 from lines l where l.account_id = w.id))
  union all
  select r.account_id, r.code, r.name, r.account_type,
         r.entry_date, r.entry_no, r.line_no, r.source, r.description,
         r.reference, r.contact_name, round(r.debit, 2), round(r.credit, 2),
         round(r.balance, 2), false
    from running r
   where app.is_org_member(p_org_id)
  -- The same order the running balance was computed in. Printing the
  -- rows any other way would show balances that do not follow from the
  -- lines above them, which is the one thing a ledger may not do.
   order by 2, 15 desc, 5, 6, 7;
$function$;

CREATE OR REPLACE FUNCTION public.report_changes_in_equity(p_org_id uuid, p_from date, p_to date)
 RETURNS TABLE(account_id uuid, code text, name text, opening_balance numeric, movement numeric, closing_balance numeric, sort_order integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with equity as (
    select a.id, a.code, a.name, a.sort_order,
           -- Credit side positive, the way the balance sheet shows it.
           a.opening_balance
         + coalesce((select sum(l.credit - l.debit)
                       from public.gl_lines l
                       join public.gl_entries e on e.id = l.entry_id
                      where l.account_id = a.id and e.status = 'posted'
                        and e.entry_date < p_from), 0) as opening,
           coalesce((select sum(l.credit - l.debit)
                       from public.gl_lines l
                       join public.gl_entries e on e.id = l.entry_id
                      where l.account_id = a.id and e.status = 'posted'
                        and e.entry_date between p_from and p_to), 0) as moved
      from public.accounts a
     where a.org_id = p_org_id
       and a.account_type = 'equity'
       -- Open, or closed with posted lines (0828).
       and (a.deleted_at is null
            or exists (select 1 from public.gl_lines pl
                           join public.gl_entries pe on pe.id = pl.entry_id
                          where pl.account_id = a.id and pe.status = 'posted'))
       and not a.is_group
  ),
  result_for_period as (
    select coalesce(sum(l.credit - l.debit), 0) as profit
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
      join public.accounts a on a.id = l.account_id
     where l.org_id = p_org_id
       and e.status = 'posted'
       and a.account_type in ('revenue', 'expense')
       and e.entry_date between p_from and p_to
  )
  select e.id, e.code, e.name,
         round(e.opening, 2), round(e.moved, 2), round(e.opening + e.moved, 2),
         e.sort_order
    from equity e
   where app.is_org_member(p_org_id)
     and (e.opening <> 0 or e.moved <> 0)
  union all
  select null::uuid, null::text, 'Profit for the financial period',
         0, round(r.profit, 2), round(r.profit, 2), 999999
    from result_for_period r
   where app.is_org_member(p_org_id)
     and round(r.profit, 2) <> 0
   order by 7, 2;
$function$;

CREATE OR REPLACE FUNCTION public.report_matter_trial_balance(p_org_id uuid, p_matter_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, account_subtype app.account_subtype, opening_balance numeric, debit numeric, credit numeric, closing_balance numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  with movements as (
    select l.account_id,
           sum(case when p_from is not null and e.entry_date < p_from
                    then l.debit - l.credit else 0 end) as opening,
           sum(case when p_from is null or e.entry_date >= p_from
                    then l.debit else 0 end) as dr,
           sum(case when p_from is null or e.entry_date >= p_from
                    then l.credit else 0 end) as cr
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
     where l.org_id = p_org_id
       and app.can_read_ledger(p_org_id)
       and l.matter_id is not null
       and l.matter_id = p_matter_id
       and e.status = 'posted'
       and e.entry_date <= p_to
     group by l.account_id)
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(coalesce(m.opening, 0), 2),
         round(coalesce(m.dr, 0), 2),
         round(coalesce(m.cr, 0), 2),
         round(coalesce(m.opening, 0) + coalesce(m.dr, 0)
               - coalesce(m.cr, 0), 2)
    from public.accounts a
    join movements m on m.account_id = a.id
   -- Closed ones too (0828): the join already keeps only an account
   -- with posted lines this matter moved.
   where a.org_id = p_org_id
   order by a.code;
$function$;

CREATE OR REPLACE FUNCTION public.report_cash_flow(p_org_id uuid, p_from date, p_to date)
 RETURNS TABLE(section text, label text, amount numeric, sort_order integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with movements as (
    select a.id, a.code, a.name, a.account_type, a.account_subtype,
           -- What this account did to cash. A debit used cash up, a
           -- credit freed it, so the sign is the other way round from
           -- the ledger.
           round(-sum(l.debit - l.credit), 2) as contributed
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
      join public.accounts a on a.id = l.account_id
     where l.org_id = p_org_id
       and e.status = 'posted'
       and e.entry_date between p_from and p_to
       and e.source <> 'year_end_close'
     group by a.id, a.code, a.name, a.account_type, a.account_subtype
  ),
  classified as (
    select m.*,
           case
             when m.account_subtype in ('bank', 'cash') then 'cash'
             when m.account_type in ('revenue', 'expense') then 'profit'
             -- The add-back. Sitting in operating alongside the
             -- depreciation charge is what makes the two cancel.
             when m.account_subtype = 'accumulated_depreciation' then 'noncash'
             when m.account_subtype in ('fixed_asset', 'other_asset')
               then 'investing'
             when m.account_subtype in ('long_term_liability', 'share_capital',
                                        'retained_earnings', 'reserves',
                                        'drawings') then 'financing'
             -- Receivables, inventory, payables, accruals, tax: the
             -- working capital the business turns over.
             else 'working_capital'
           end as bucket
      from movements m
  ),
  cash_now as (
    select
      coalesce((select sum(l.debit - l.credit)
                  from public.gl_lines l
                  join public.gl_entries e on e.id = l.entry_id
                  join public.accounts a on a.id = l.account_id
                 where l.org_id = p_org_id and e.status = 'posted'
                   and a.account_subtype in ('bank', 'cash')
                   and e.entry_date < p_from), 0)
    -- And a closed account's opening balance where it has posted lines
    -- (0828), as the trial balance counts it; the lines beside this sum
    -- never asked whether an account was open.
    + coalesce((select sum(a.opening_balance) from public.accounts a
                 where a.org_id = p_org_id
                   and (a.deleted_at is null
                        or exists (select 1 from public.gl_lines ol
                                    join public.gl_entries oe on oe.id = ol.entry_id
                                   where ol.account_id = a.id and oe.status = 'posted'))
                   and not a.is_group
                   and a.account_subtype in ('bank', 'cash')), 0) as opening,
      coalesce((select sum(l.debit - l.credit)
                  from public.gl_lines l
                  join public.gl_entries e on e.id = l.entry_id
                  join public.accounts a on a.id = l.account_id
                 where l.org_id = p_org_id and e.status = 'posted'
                   and a.account_subtype in ('bank', 'cash')
                   and e.entry_date <= p_to), 0)
    + coalesce((select sum(a.opening_balance) from public.accounts a
                 where a.org_id = p_org_id
                   and (a.deleted_at is null
                        or exists (select 1 from public.gl_lines cl
                                    join public.gl_entries ce2 on ce2.id = cl.entry_id
                                   where cl.account_id = a.id and ce2.status = 'posted'))
                   and not a.is_group
                   and a.account_subtype in ('bank', 'cash')), 0) as closing
  ),
  lines as (
    -- Operating: the result for the period, then what did not move cash,
    -- then what working capital did with it.
    select 'operating'::text as section,
           'Profit for the period'::text as label,
           coalesce(sum(c.contributed), 0) as amount,
           10 as sort_order
      from classified c where c.bucket = 'profit'
    union all
    select 'operating', 'Depreciation and amortisation',
           coalesce(sum(c.contributed), 0), 20
      from classified c where c.bucket = 'noncash'
      having coalesce(sum(c.contributed), 0) <> 0
    union all
    select 'operating', c.name, c.contributed, 30
      from classified c
     where c.bucket = 'working_capital' and c.contributed <> 0
    union all
    select 'investing', c.name, c.contributed, 10
      from classified c
     where c.bucket = 'investing' and c.contributed <> 0
    union all
    select 'financing', c.name, c.contributed, 10
      from classified c
     where c.bucket = 'financing' and c.contributed <> 0
    union all
    -- The reconciliation. `Net movement` is the sum of every
    -- contribution above, and the two cash figures come straight from
    -- the bank and cash accounts, so the statement proves itself.
    select 'reconciliation', 'Net movement in cash',
           coalesce((select sum(c.contributed) from classified c
                      where c.bucket <> 'cash'), 0), 10
    union all
    select 'reconciliation', 'Cash and cash equivalents brought forward',
           (select round(opening, 2) from cash_now), 20
    union all
    select 'reconciliation', 'Cash and cash equivalents carried forward',
           (select round(closing, 2) from cash_now), 30
  )
  select l.section, l.label, l.amount, l.sort_order
    from lines l
   where app.is_org_member(p_org_id)
   order by
     case l.section when 'operating' then 1 when 'investing' then 2
                    when 'financing' then 3 else 4 end,
     l.sort_order, l.label;
$function$;

CREATE OR REPLACE FUNCTION public.retire_account(p_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_a       public.accounts;
  v_balance numeric;
  v_bank    text;
begin
  select * into v_a from public.accounts a where a.id = p_id;
  if v_a.id is null then
    raise exception 'No such account.' using errcode = '22023';
  end if;
  if not app.can_post(v_a.org_id) then
    raise exception 'Only somebody who may post the books may change the chart'
      using errcode = '42501';
  end if;
  if v_a.deleted_at is not null then
    raise exception 'Account % is already closed.', v_a.code
      using errcode = '23505';
  end if;

  if exists (select 1 from app.posting_account_codes() c
              where c.code = v_a.code) then
    raise exception
      'Account % is one the ledger posts to by number. It can be renamed '
      'but not removed.', v_a.code
      using errcode = '23514';
  end if;

  if exists (select 1 from public.accounts a
              where a.parent_id = p_id and a.deleted_at is null) then
    raise exception
      'Account % still has accounts under it.', v_a.code
      using errcode = '23514';
  end if;

  -- What it holds (0828). A closed account is left out of the chart,
  -- and an account closed with a balance took that balance with it:
  -- the trial balance came out by it until 0828 put closed accounts
  -- with lines back in. Signed as `report_trial_balance` signs it.
  select coalesce(sum(l.debit - l.credit), 0)
    into v_balance
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where l.account_id = p_id and e.status = 'posted';
  v_balance := v_balance
    + case when v_a.account_type in ('asset', 'expense')
           then v_a.opening_balance else -v_a.opening_balance end;
  if v_balance <> 0 then
    raise exception
      'Account % still carries a balance of %. Journal it to another '
      'account first, then close it.',
      v_a.code, to_char(abs(v_balance), 'FM999,999,999,990.00')
        || case when v_balance > 0 then ' debit' else ' credit' end
      using errcode = '23514';
  end if;

  -- And what still posts to it (0828): a bank account's receipts and
  -- payments go to its ledger account whether or not that is open.
  select b.name into v_bank
    from public.bank_accounts b
   where b.account_id = p_id and b.is_active
   order by b.name
   limit 1;
  if v_bank is not null then
    raise exception
      'Account % is the ledger account of the bank account %, which '
      'still posts to it.', v_a.code, v_bank
      using errcode = '23514';
  end if;

  perform app.record_closure(
    'ledger_account', v_a.id, v_a.org_id, v_a.code || ' ' || v_a.name,
    jsonb_build_object(
      'code', v_a.code,
      'name', v_a.name,
      'account_type', v_a.account_type,
      'account_subtype', v_a.account_subtype,
      'was_active', v_a.is_active,
      'posted_lines', (select count(*) from public.gl_lines l
                        where l.account_id = v_a.id)),
    null, 'self_service', auth.uid());

  update public.accounts
     set is_active = false, deleted_at = now()
   where id = p_id;

  return 'closed';
end $function$;

comment on function public.retire_account(uuid) is
  'Closes a ledger account: switched off, hidden from the chart, and '
  'kept. 0619 took out 0459''s outright delete. Refuses an account the '
  'ledger posts to by number, one with open accounts under it, and '
  '(0828) one that still carries a balance or that an active bank '
  'account posts to: a closed account''s balance would otherwise leave '
  'the books with nothing to show for it.';
