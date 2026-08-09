-- =====================================================================
-- iAkauntan :: 0016 report corrections
--
-- Two defects found while smoke testing a posted invoice plus a part
-- payment against it:
--
-- 1. report_trial_balance doubled every closing balance. With p_from
--    null the `p_from is null` branch matched both the opening case and
--    the movement case, so each line was counted twice.
--
-- 2. report_balance_sheet included lines belonging to draft, void or
--    out-of-range journals. The gl_entries join is conditional, so those
--    rows arrived with e.id null and were still summed.
-- =====================================================================

create or replace function public.report_trial_balance(
  p_org_id uuid, p_from date default null, p_to date default current_date)
returns table (
  account_id uuid, code text, name text,
  account_type app.account_type, account_subtype app.account_subtype,
  opening_balance numeric, debit numeric, credit numeric, closing_balance numeric)
language sql stable security definer set search_path = public, app, pg_temp as $$
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
     and a.deleted_at is null
     and not a.is_group
     and app.is_org_member(p_org_id)
   order by a.code;
$$;

create or replace function public.report_balance_sheet(
  p_org_id uuid, p_as_at date default current_date)
returns table (
  account_id uuid, code text, name text,
  account_type app.account_type, account_subtype app.account_subtype, balance numeric)
language sql stable security definer set search_path = public, app, pg_temp as $$
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
     and a.deleted_at is null
     and not a.is_group
     and a.account_type in ('asset', 'liability', 'equity')
     and app.is_org_member(p_org_id)
   group by a.id, a.code, a.name, a.account_type, a.account_subtype, a.opening_balance
   order by a.code;
$$;
