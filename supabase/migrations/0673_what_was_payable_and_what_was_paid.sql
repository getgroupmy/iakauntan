-- =====================================================================
-- iAkauntan :: 0673 what was payable, and what was paid
--
-- `0672` finished the first half: `tax_estimate_schedule` now says
-- what every instalment was PAYABLE at, correctly, even across two
-- revisions. It has never known what was paid. A company that has met
-- nine of twelve sees the same twelve rows as one that has paid
-- nothing, and the ledger cannot tell a CP204 instalment from any
-- other payment to LHDN.
--
-- That matters beyond bookkeeping, because a late instalment carries
-- its own penalty. s.107C(9) adds 10% of any instalment not paid by
-- its due date — a separate charge from the under-estimation penalty
-- `0667` already measures, and one a company can incur in a year it
-- estimated perfectly.
--
-- ---------------------------------------------------------------------
-- A payment survives a revision
--
-- This is the whole difficulty. A revision is a NEW estimate row, so
-- a payment recorded in month three sits against a row that month
-- nine has superseded — and keying payments to the row they were made
-- against would lose five instalments' worth of history the moment
-- somebody revised.
--
-- So they are keyed to the CHAIN ROOT: the original estimate, which
-- is stable however many times the figure is revised. `app.tax_estimate_root`
-- walks back to it, the payment stores both (the root for the key,
-- the row it was recorded against for the record), and the schedule
-- finds them whichever estimate in the chain it is asked about.
--
-- ---------------------------------------------------------------------
-- What it deliberately does not do
--
--   * **It does not post to the ledger.** Recording a payment here is
--     a note that it happened; the bank side is a bank transaction
--     like any other. Claiming otherwise would put a journal in a
--     place nobody would look for one.
--   * **It does not check the amount.** LHDN accepts what it is sent.
--     A payment that differs from the scheduled figure is recorded as
--     it was made, and the difference is shown rather than refused —
--     `outstanding` per instalment is the whole point of that.
--   * **It does not collect the penalty.** It says which instalments
--     were late and what 10% of them comes to. Whether LHDN raised it
--     is not something this can know.
-- =====================================================================

-- The late-payment penalty, in the rules table with everything else
-- that is a policy lever rather than arithmetic.
alter table public.tax_estimate_rules
  add column late_instalment_penalty_percent numeric(6, 2) not null
    default 10 check (late_instalment_penalty_percent >= 0);

comment on column public.tax_estimate_rules.late_instalment_penalty_percent is
  'Added to an instalment not paid by its due date — s.107C(9) for a '
  'company, s.107B(3) for a person. A SEPARATE charge from the '
  'under-estimation penalty, and one a taxpayer can incur in a year '
  'they estimated perfectly.';


-- ---------------------------------------------------------------------
-- Which estimate a chain started from
-- ---------------------------------------------------------------------
create or replace function app.tax_estimate_root(p_estimate_id uuid)
returns uuid
language plpgsql stable
set search_path = pg_catalog, public, pg_temp
as $$
declare v_cur uuid := p_estimate_id; v_prev uuid; i integer;
begin
  -- Bounded rather than `while v_prev is not null`: at most an
  -- original and two permitted revisions, and a loop that trusts the
  -- data not to contain a cycle is a loop that hangs the request when
  -- it does.
  for i in 1..10 loop
    select te.revises_id into v_prev
      from public.tax_estimates te where te.id = v_cur;
    exit when v_prev is null;
    v_cur := v_prev;
  end loop;
  return v_cur;
end; $$;

comment on function app.tax_estimate_root(uuid) is
  'The original estimate a revision chain started from. Payments are '
  'keyed to it rather than to the row they were made against, because '
  'a revision supersedes that row and the payment has to outlive it.';


-- ---------------------------------------------------------------------
-- What was paid
-- ---------------------------------------------------------------------
create table public.tax_estimate_payments (
  id     uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  unique (org_id, id),

  -- The chain root. See the header: this is what makes a payment
  -- survive the revision that supersedes the estimate it was made
  -- against.
  root_estimate_id uuid not null,
  constraint tax_estimate_payments_root_same_org
    foreign key (org_id, root_estimate_id)
    references public.tax_estimates (org_id, id) on delete cascade,

  -- The row it was actually recorded against, for the record. Not the
  -- key, and NOT a second answer to the same question: if the two ever
  -- disagree the root is right, because it is the one that cannot be
  -- superseded.
  recorded_against_id uuid,
  constraint tax_estimate_payments_against_same_org
    foreign key (org_id, recorded_against_id)
    references public.tax_estimates (org_id, id),

  instalment_no integer not null check (instalment_no > 0),

  paid_on date not null,
  -- What was actually sent, which LHDN accepts whether or not it is
  -- the scheduled figure. Checked only for sign.
  amount numeric(18, 2) not null check (amount >= 0),

  reference text,
  notes text,

  recorded_by uuid references auth.users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  -- One payment per instalment. A second recording corrects the first
  -- rather than making a rival claim about the same instalment.
  unique (org_id, root_estimate_id, instalment_no)
);

comment on table public.tax_estimate_payments is
  'What was actually paid against each instalment. Keyed to the chain '
  'ROOT so a payment outlives the revision that supersedes the '
  'estimate it was made against. A note that money moved -- nothing '
  'here posts to the ledger.';

create index tax_estimate_payments_root_idx
  on public.tax_estimate_payments (root_estimate_id, instalment_no);
create index tax_estimate_payments_org_idx
  on public.tax_estimate_payments (org_id, paid_on desc);

alter table public.tax_estimate_payments enable row level security;
create policy tax_estimate_payments_select on public.tax_estimate_payments
  for select to authenticated using (app.is_org_member(org_id));
create policy tax_estimate_payments_insert on public.tax_estimate_payments
  for insert to authenticated with check (app.can_post(org_id));
create policy tax_estimate_payments_update on public.tax_estimate_payments
  for update to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));
create policy tax_estimate_payments_delete on public.tax_estimate_payments
  for delete to authenticated using (app.can_post(org_id));
grant select, insert, update, delete on public.tax_estimate_payments
  to authenticated;

create trigger live_change_insert after insert on public.tax_estimate_payments
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.tax_estimate_payments
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.tax_estimate_payments
  referencing old table as old_rows
  for each statement execute function app.note_live_change();


-- ---------------------------------------------------------------------
-- Recording one
-- ---------------------------------------------------------------------
create or replace function public.record_tax_instalment(
  p_estimate_id   uuid,
  p_instalment_no integer,
  p_paid_on       date default null,
  p_amount        numeric default null,
  p_reference     text default null,
  p_notes         text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  e        record;
  v_root   uuid;
  v_sched  numeric;
  v_count  integer;
  v_id     uuid;
begin
  select te.* into e from public.tax_estimates te where te.id = p_estimate_id;
  if e.id is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.can_post(e.org_id) then
    raise exception 'Not permitted to record an instalment'
      using errcode = '42501';
  end if;

  -- The instalment has to be one the schedule actually has. Recording
  -- a thirteenth against a twelve-instalment estimate is not a typo to
  -- tidy up later; it is money somebody will look for and not find.
  select count(*), max(case when s.instalment_no = p_instalment_no
                            then s.amount end)
    into v_count, v_sched
    from public.tax_estimate_schedule(p_estimate_id) s;

  if p_instalment_no > v_count then
    raise exception
      'This estimate has % instalments, not %', v_count, p_instalment_no
      using errcode = '22023';
  end if;

  v_root := app.tax_estimate_root(p_estimate_id);

  insert into public.tax_estimate_payments
    (org_id, root_estimate_id, recorded_against_id, instalment_no,
     paid_on, amount, reference, notes, recorded_by)
  values
    (e.org_id, v_root, p_estimate_id, p_instalment_no,
     -- Today rather than an error about a column: somebody recording a
     -- payment almost always means now.
     coalesce(p_paid_on, app.today()),
     -- And the scheduled figure rather than nothing, because paying
     -- exactly what was asked for is the ordinary case and typing it
     -- again is a chance to mistype it.
     coalesce(p_amount, v_sched, 0),
     p_reference, p_notes, auth.uid())
  on conflict (org_id, root_estimate_id, instalment_no) do update
     set paid_on = excluded.paid_on,
         amount = excluded.amount,
         reference = excluded.reference,
         notes = excluded.notes,
         recorded_against_id = excluded.recorded_against_id,
         recorded_by = excluded.recorded_by,
         updated_at = now()
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function
  public.record_tax_instalment(uuid, integer, date, numeric, text, text)
  from public, anon;
grant execute on function
  public.record_tax_instalment(uuid, integer, date, numeric, text, text)
  to authenticated;

comment on function
  public.record_tax_instalment(uuid, integer, date, numeric, text, text) is
  'Records that one instalment was paid. Defaults to today and to the '
  'scheduled amount, because paying what was asked for on the day is '
  'the ordinary case. Keyed to the chain root so it survives a '
  'revision, and refuses an instalment number the schedule does not '
  'have.';


create or replace function public.clear_tax_instalment(
  p_estimate_id uuid, p_instalment_no integer)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare e record;
begin
  select te.* into e from public.tax_estimates te where te.id = p_estimate_id;
  if e.id is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.can_post(e.org_id) then
    raise exception 'Not permitted to clear an instalment'
      using errcode = '42501';
  end if;

  delete from public.tax_estimate_payments
   where org_id = e.org_id
     and root_estimate_id = app.tax_estimate_root(p_estimate_id)
     and instalment_no = p_instalment_no;
end; $$;

revoke all on function public.clear_tax_instalment(uuid, integer)
  from public, anon;
grant execute on function public.clear_tax_instalment(uuid, integer)
  to authenticated;

comment on function public.clear_tax_instalment(uuid, integer) is
  'Unrecords a payment, putting the instalment back to unpaid.';


-- ---------------------------------------------------------------------
-- The schedule, with what was paid against it
-- ---------------------------------------------------------------------
-- Everything about the amounts is `0672`'s and unchanged. What is new
-- is four columns on the end and one join.
drop function if exists public.tax_estimate_schedule(uuid);

create or replace function public.tax_estimate_schedule(p_estimate_id uuid)
returns table (
  instalment_no    integer,
  due_on           date,
  amount           numeric,
  set_by_revision  boolean,
  paid_on          date,
  paid_amount      numeric,
  -- Paid AFTER the due date. Its own column rather than two dates for
  -- the reader to subtract, because it is what s.107C(9) charges 10%
  -- on and the two sit in different columns of the same row.
  paid_late        boolean,
  -- Scheduled less paid, floored at nothing. An overpayment is not a
  -- negative outstanding: LHDN keeps it against the assessment.
  outstanding      numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  e        record;
  r        record;
  totals   numeric[];
  months   integer[];
  v_cur    uuid;
  v_prev   uuid;
  v_root   uuid;
  v_first  date;
  v_month  date;
  v_due    date;
  v_in_force integer := 1;
  v_each   numeric;
  v_sofar  numeric := 0;
  v_amount numeric;
  v_imonth integer;
  i        integer;
  j        integer;
  v_exempt boolean;
  p        record;
begin
  select te.*, fy.start_date into e
    from public.tax_estimates te
    join public.fiscal_years fy on fy.id = te.fiscal_year_id
   where te.id = p_estimate_id;

  if e is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.is_org_member(e.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select * into r from public.tax_estimate_rules ru
   where ru.year_of_assessment = e.year_of_assessment
     and ru.form = e.form;
  if r is null then
    raise exception 'No % rules for year of assessment %',
      e.form, e.year_of_assessment using errcode = 'P0002';
  end if;

  -- A qualifying new SME owes none. Twelve rows of demands for money
  -- on dates nobody has to meet is worse than an empty list with a
  -- sentence under it, which is what the screen draws instead.
  select fp.exempt_instalments into v_exempt
    from public.tax_estimate_first_period(p_estimate_id) fp;
  if v_exempt then
    return;
  end if;

  -- The chain, OLDEST first. `revises_id` points backwards, so this
  -- walks back to the original and then reverses -- there are at most
  -- three links (an original and two permitted revisions), and the
  -- loop is bounded by that rather than trusting the data not to
  -- contain a cycle.
  totals := array[]::numeric[];
  months := array[]::integer[];
  v_cur := p_estimate_id;
  for j in 1..10 loop
    exit when v_cur is null;
    -- `v_prev` is a separate variable on purpose. Reading the row's
    -- own id and its `revises_id` into the SAME variable in one INTO
    -- list assigns both, the second wins, and the chain quietly ends
    -- up holding every link's PARENT rather than the link.
    select te.estimated_tax, te.revises_id, te.revision_month
      into v_amount, v_prev, v_imonth
      from public.tax_estimates te where te.id = v_cur;
    -- Prepend: the walk is newest-first and the arithmetic below needs
    -- oldest-first.
    --
    -- The ids themselves are deliberately NOT collected. A third array
    -- holding them was written first, never read, and a mutation
    -- sweep proved it: breaking what went into it changed nothing.
    totals := array_prepend(v_amount, totals);
    months := array_prepend(coalesce(v_imonth, 0), months);
    v_cur := v_prev;
  end loop;

  -- Payments hang off the ROOT, so they are found whichever estimate
  -- in the chain this was asked about.
  v_root := app.tax_estimate_root(p_estimate_id);

  v_each := round(totals[1] / r.instalments, 2);

  -- The month the first instalment falls in, counted from the start of
  -- the basis period.
  v_first := date_trunc('month',
               e.start_date
               + make_interval(months => r.first_instalment_month - 1))::date;

  for i in 1..r.instalments loop
    v_month := (v_first
                + make_interval(
                    months => (i - 1) * r.months_between))::date;

    -- Which month of the BASIS PERIOD this instalment falls in, so it
    -- can be compared with the month a revision was made in.
    v_imonth := r.first_instalment_month + (i - 1) * r.months_between;

    -- Has a later estimate come into force by now? A revision made in
    -- month 9 governs the instalments due in month 9 and after, and
    -- leaves the earlier ones exactly as they were payable.
    while v_in_force < array_length(totals, 1)
          and months[v_in_force + 1] <= v_imonth loop
      v_in_force := v_in_force + 1;
      -- Spread what is left of the REVISED total over the instalments
      -- that remain, including this one. Never below nothing: a
      -- company that revised downward owes nil for the rest of the
      -- year rather than being shown money coming back on a date when
      -- none is.
      v_each := round(
        greatest(totals[v_in_force] - v_sofar, 0)
        / (r.instalments - i + 1), 2);
    end loop;

    v_amount := case
      -- The last one absorbs whatever the division left over, so the
      -- schedule adds up to whatever is in force exactly.
      when i = r.instalments
        then round(greatest(totals[v_in_force] - v_sofar, 0), 2)
      else v_each
    end;
    v_sofar := v_sofar + v_amount;

    v_due := app.tax_filing_fixed_date(
      extract(year from v_month)::integer,
      extract(month from v_month)::integer,
      r.instalment_day);

    select tp.paid_on, tp.amount into p
      from public.tax_estimate_payments tp
     where tp.root_estimate_id = v_root and tp.instalment_no = i;

    return query select
      i,
      v_due,
      v_amount,
      (v_in_force > 1),
      p.paid_on,
      p.amount,
      (p.paid_on is not null and v_due is not null and p.paid_on > v_due),
      greatest(v_amount - coalesce(p.amount, 0), 0);
  end loop;
end; $$;

revoke all on function public.tax_estimate_schedule(uuid) from public, anon;
grant execute on function public.tax_estimate_schedule(uuid)
  to authenticated;

comment on function public.tax_estimate_schedule(uuid) is
  'The instalments an estimate is paid in -- what was payable on each '
  'date, and what was paid against it. Payments are found through the '
  'chain root, so they survive a revision. Nothing here posts to the '
  'ledger.';


-- ---------------------------------------------------------------------
-- Where the year stands
-- ---------------------------------------------------------------------
create or replace function public.tax_estimate_payment_summary(
  p_estimate_id uuid)
returns table (
  scheduled_total   numeric,
  paid_total        numeric,
  outstanding_total numeric,
  instalments       integer,
  instalments_paid  integer,
  overdue_count     integer,
  overdue_total     numeric,
  late_count        integer,
  late_penalty      numeric,
  next_due_on       date,
  next_due_amount   numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare e record; r record; v_today date := app.today();
begin
  select te.* into e from public.tax_estimates te where te.id = p_estimate_id;
  if e.id is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.is_org_member(e.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select * into r from public.tax_estimate_rules ru
   where ru.year_of_assessment = e.year_of_assessment
     and ru.form = e.form;

  return query
  with s as (select * from public.tax_estimate_schedule(p_estimate_id))
  select
    coalesce(sum(s.amount), 0),
    coalesce(sum(s.paid_amount), 0),
    coalesce(sum(s.outstanding), 0),
    count(*)::integer,
    count(*) filter (where s.paid_on is not null)::integer,
    -- Due, unpaid, and the date has gone. An instalment of nothing --
    -- which a downward revision leaves behind -- is not overdue,
    -- because there was nothing to pay.
    count(*) filter (
      where s.paid_on is null and s.due_on < v_today and s.amount > 0
    )::integer,
    coalesce(sum(s.outstanding) filter (
      where s.paid_on is null and s.due_on < v_today), 0),
    count(*) filter (where s.paid_late)::integer,
    -- 10% of what was paid late. Says what the charge comes to, not
    -- that LHDN raised it -- which is not something this can know.
    round(coalesce(sum(s.paid_amount) filter (where s.paid_late), 0)
          * coalesce(r.late_instalment_penalty_percent, 0) / 100, 2),
    min(s.due_on) filter (where s.paid_on is null and s.amount > 0),
    (array_agg(s.amount order by s.due_on)
       filter (where s.paid_on is null and s.amount > 0))[1]
  from s;
end; $$;

revoke all on function public.tax_estimate_payment_summary(uuid)
  from public, anon;
grant execute on function public.tax_estimate_payment_summary(uuid)
  to authenticated;

comment on function public.tax_estimate_payment_summary(uuid) is
  'Where the instalment year stands: scheduled, paid, outstanding, '
  'what is overdue now, and what the s.107C(9) charge on the ones '
  'already paid late comes to. An instalment of nothing -- which a '
  'downward revision leaves behind -- is never overdue.';
