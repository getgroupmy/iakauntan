-- What is sitting in deferred revenue, and why.
--
-- `0309` built the schedule, `0312` showed what is about to be released
-- and `dd0b88c` gave that a button. What none of them answer is the
-- question an auditor actually asks at a year end: *2127 says
-- RM 84,000 — show me what that is.*
--
-- This is that schedule. One row per deferred invoice line, at a date:
-- what the invoice put into the liability, what has been released out of
-- it, what a credit note took back, and what is therefore still there.
--
-- ## Everything is asked at the date, not now
--
-- A balance report that quietly used today's state would be wrong every
-- time it was run for a year end that has passed — which is the only
-- time anybody runs it.
--
-- So each of the three movements is dated by the journal that made it,
-- not by the row that records it:
--
--   * into the liability, when the invoice's own entry posted;
--   * out of it, when the recognition entry for that period posted —
--     `0309` dates that entry on `period_end`, and this joins the entry
--     rather than trusting that, because the join is the thing that
--     stays true if the dating ever changes;
--   * out of it, when the credit note that cancelled it posted —
--     `0310` dates that on the credit note's own `doc_date`.
--
-- A period that has matured but that nobody has run the release for is
-- still in the liability, and shows here as still deferred. That is not
-- a rounding of the truth: the ledger really does still hold it, and a
-- schedule that netted it off would disagree with the balance sheet it
-- is meant to support.
--
-- ## The ledger's own figure comes back with it
--
-- `ledger_balance` is the same on every row: the posted balance of 2127
-- at the date asked for. Repeating a scalar down a column is not
-- elegant, and it is deliberate — the whole value of this report is the
-- two numbers agreeing, and fetching them separately is how a screen
-- ends up showing a schedule from one moment against a balance from
-- another.
--
-- 2127 is looked up by code and never created. `app.deferred_revenue_account`
-- makes it on demand, which is right for a posting path and wrong for a
-- report: running a read should not add an account to the chart of a
-- company that has never deferred anything.
--
-- ## What is left out
--
-- Lines with nothing left. This is a balance report, and a contract
-- fully earned two years ago is not a balance; carried forever it would
-- turn the schedule into a list of everything ever deferred.
--
-- The consequence, written down rather than discovered: a balance in
-- 2127 with no schedule behind it — somebody's manual journal into the
-- account — shows as no rows at all rather than as a discrepancy. That
-- is a manual-journal problem and it belongs in the general ledger
-- listing, not here, but it is the one thing this report cannot see.

create or replace function public.report_deferred_revenue(
  p_org_id uuid, p_as_at date default null)
returns table (
  contact_name   text,
  doc_no         text,
  doc_date       date,
  description    text,
  service_start  date,
  service_end    date,
  deferred       numeric,
  recognised     numeric,
  cancelled      numeric,
  balance        numeric,
  ledger_balance numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_as_at  date := coalesce(p_as_at,
                            (now() at time zone 'Asia/Kuala_Lumpur')::date);
  v_acct   uuid;
  v_ledger numeric := 0;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  select a.id into v_acct
    from public.accounts a
   where a.org_id = p_org_id and a.code = '2127';

  if v_acct is not null then
    select coalesce(sum(l.credit - l.debit), 0) into v_ledger
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
     where l.org_id = p_org_id
       and l.account_id = v_acct
       and e.entry_date <= v_as_at
       and e.status = 'posted';
  end if;

  return query
  with movement as (
    select p.line_id,
           p.amount,
           case when re.id is not null and re.entry_date <= v_as_at
                then p.amount - p.cancelled_amount else 0 end as released,
           case when cn.id is not null and cn.doc_date <= v_as_at
                then p.cancelled_amount else 0 end as taken
      from public.revenue_schedule_periods p
      left join public.gl_entries re on re.id = p.gl_entry_id
      left join public.sales_documents cn on cn.id = p.cancelled_by_id
     where p.org_id = p_org_id
  )
  select c.name,
         d.doc_no,
         d.doc_date,
         l.description,
         l.service_start,
         l.service_end,
         round(sum(m.amount), 2),
         round(sum(m.released), 2),
         round(sum(m.taken), 2),
         round(sum(m.amount - m.released - m.taken), 2),
         v_ledger
    from movement m
    join public.sales_document_lines l on l.id = m.line_id
    join public.sales_documents d on d.id = l.document_id
    join public.gl_entries de on de.id = d.gl_entry_id
    left join public.contacts c on c.id = d.contact_id
   where de.entry_date <= v_as_at
     and de.status = 'posted'
     and d.status <> 'void'
   group by c.name, d.doc_no, d.doc_date, l.description,
            l.service_start, l.service_end, l.id
  having round(sum(m.amount - m.released - m.taken), 2) <> 0
   order by c.name, d.doc_no, l.service_start;
end;
$$;

comment on function public.report_deferred_revenue(uuid, date) is
  'What is sitting in 2127 at a date and which invoice lines it belongs '
  'to, with the account''s own posted balance repeated on every row so '
  'the schedule and the ledger are read as one answer.';

revoke all on function public.report_deferred_revenue(uuid, date)
  from public, anon;
grant execute on function public.report_deferred_revenue(uuid, date)
  to authenticated;
