-- ---------------------------------------------------------------------
-- 0458  The ledger itself
-- ---------------------------------------------------------------------
-- Measured: `report_trial_balance` exists and is on the Reports screen.
-- `report_general_ledger` does not exist, and there is no tab for it.
-- A trial balance is a list of *totals*; the general ledger is the
-- thing the totals are made of, and it is the report an auditor asks
-- for first, the one somebody opens to answer "why is this account
-- RM3,412 when it should be RM3,400", and the only one that names the
-- entry to look at.
--
-- The journals screen shows entries, one at a time, in the order they
-- were posted. That is not a ledger: a ledger is by **account**, in
-- date order, with the balance carried down the page.
--
-- ### What this returns
--
-- One row per posted line, with the account's opening balance carried
-- in and a running balance carried down. `is_opening` marks the row
-- that is not a transaction, so a screen can draw it differently and a
-- CSV can be read without guessing.
--
-- The opening balance is the same arithmetic `report_trial_balance`
-- does, and deliberately so: a general ledger whose opening figure
-- disagreed with the trial balance's would make both useless, and the
-- most likely way to get there is to write the sum twice. The
-- assertions check the two against each other rather than each against
-- a number somebody typed.
--
-- ### One account or all of them
--
-- `p_account_id` narrows it. A whole year of a busy company's ledger is
-- tens of thousands of lines, and the question is almost always about
-- one account.
--
-- ### Mutants
--
-- Five, restated into a built database and run against
-- `supabase/tests/general_ledger.sql`. **Two survived the assertions as
-- first written**, and both survivors were about the report's shape
-- rather than its arithmetic:
--
--   * draft entries in the ledger -- killed by "a draft journal is not
--     in the ledger";
--   * the account's own `opening_balance` not carried in -- **survived**,
--     because every fixture account had zero in it. That column is what
--     was on the books the day this system took over, so a ledger that
--     summed only journals would open every migrated company at zero
--     and disagree with its own trial balance from the first line. The
--     fixture now sets it, and the mutant dies on "what the company
--     came in with is brought forward";
--   * the running balance not partitioned by account, so one account's
--     total runs on into the next -- killed by "every account agrees
--     with the trial balance", 4 disagreements out of 4;
--   * nothing carried forward into a period that starts partway through
--     -- killed by "what happened before the period is brought
--     forward", 0 for 10000;
--   * the rows returned in balance order rather than the order the
--     running balance was computed in -- **survived**, because every
--     assertion picked its row by date. A ledger is read *down the
--     page*: a balance that does not follow from the line above it is
--     worse than no balance at all. The fixture gained a fourth journal
--     that puts money back, so the balances are no longer monotonic,
--     and the assertion now reads the sequence: expected
--     `0 10000 7500 5000 8000`, mutant gives `0 10000 8000 7500 5000`.
--
-- Both survivors are the same lesson in a different coat: an assertion
-- that reads a value by name says nothing about the arrangement the
-- value arrives in.
-- ---------------------------------------------------------------------

create or replace function public.report_general_ledger(
  p_org_id     uuid,
  p_from       date default null,
  p_to         date default null,
  p_account_id uuid default null)
returns table (
  account_id   uuid,
  code         text,
  name         text,
  account_type app.account_type,
  entry_date   date,
  entry_no     text,
  line_no      integer,
  source       text,
  description  text,
  reference    text,
  contact_name text,
  debit        numeric,
  credit       numeric,
  balance      numeric,
  is_opening   boolean)
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  with bounds as (
    select coalesce(p_to, app.today()) as upto
  ),
  wanted as (
    select a.id, a.code, a.name, a.account_type, a.opening_balance
      from public.accounts a
     where a.org_id = p_org_id
       and a.deleted_at is null
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
$$;

revoke all on function public.report_general_ledger(uuid, date, date, uuid)
  from public;
grant execute on function public.report_general_ledger(uuid, date, date, uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(to_regprocedure(
    'public.report_general_ledger(uuid, date, date, uuid)'));
begin
  if position('e.status = ''posted''' in v_src) = 0 then
    raise exception '0458: the ledger includes entries nobody posted';
  end if;

  -- The running balance is the whole point. A list of lines with no
  -- balance carried down is the journals screen with different columns.
  if position('rows between unbounded preceding and current row' in v_src) = 0
  then
    raise exception '0458: the ledger carries no balance down the page';
  end if;

  if position('app.today()' in v_src) = 0 then
    raise exception '0458: the ledger asks the caller what day it is';
  end if;
end
$do$;

comment on function public.report_general_ledger(uuid, date, date, uuid) is
  'The ledger by account: balance brought forward, every posted line '
  'in date order, and the balance carried down. What the trial balance '
  'is made of. See 0458.';
