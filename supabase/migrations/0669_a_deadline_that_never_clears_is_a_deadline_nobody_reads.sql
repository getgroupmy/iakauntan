-- =====================================================================
-- iAkauntan :: 0669 a deadline that never clears is one nobody reads
--
-- `0668` computes every income tax obligation from the company's own
-- periods. It has no way to say one has been dealt with, so the list
-- it produces is permanent: file the Form C and it is still there
-- tomorrow, decide the CP58 does not apply and it is still there next
-- year. That is the exact failure `0668`'s own header names —
-- "listing them anyway trains somebody to ignore the list" — and the
-- migration then did it to itself.
--
-- `corp_filings` solved this for SSM in `0067`: an obligation is
-- computed until somebody opens it, and a lodged one drops off the
-- list. This is the same arrangement for LHDN.
--
-- ---------------------------------------------------------------------
-- Three things this is careful about
--
--   * **Recording a filing is not filing.** Nothing here submits
--     anything and nothing verifies the claim with LHDN. It is a note
--     somebody made, with their name on it, and the screen says so.
--     The alternative — a tick that looks like confirmation — is worse
--     than no tick at all.
--   * **"Does not apply" is a claim, not a hidden row.** Dismissing a
--     statutory obligation carries a person, a date and a reason, and
--     it stays readable afterwards. A CP58 that a company genuinely
--     does not owe should come off the list; a CP58 somebody clicked
--     away should be findable when LHDN asks about it.
--   * **The key is the OBLIGATION, not the financial year.** A filing
--     is identified by its type and the period it covers, because
--     Form E covers a calendar year and Form C covers the basis
--     period — two different periods that can both sit against one
--     fiscal year, and a record keyed on the year alone would let one
--     of them mark the other as done.
--
-- ---------------------------------------------------------------------
-- What comes off the list, and what does not
--
-- `tax_upcoming_filings` is replaced so that a filing recorded as
-- `filed` or `not_applicable` drops out, and one still `in_preparation`
-- stays with its status showing. `tax_filing_history` reads back
-- everything recorded, so nothing disappears — it moves.
--
-- The function is DROPPED and recreated rather than replaced: its
-- return type gains two columns, and Postgres will not replace a
-- function whose OUT parameters have changed.
-- =====================================================================

create table public.tax_filings (
  id     uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  unique (org_id, id),

  -- Which obligation. Not an enum: `0668` seeds these as rows so a
  -- change to the law is a row, and a filing has to name one of them.
  filing_type text not null references public.tax_filing_types (code),

  -- The period the obligation covers, as the calendar computed it --
  -- which for Form E is a calendar year and not this company's own.
  period_from date,
  period_to   date not null,
  year_of_assessment integer not null,

  -- What was due, frozen at the moment somebody recorded against it.
  -- The computed date can move if a rule is corrected, and what the
  -- person was looking at when they said "filed" should survive that.
  due_date date,

  -- The financial year it was computed from, where there is one. Kept
  -- for the join back rather than as the key -- see the header.
  --
  -- The company as well as the row: `tenant_foreign_keys.sql` refuses
  -- a single-column link to anything tenant-scoped, and without the
  -- pair a filing could name ANOTHER company's financial year.
  --
  -- And no `on delete` clause, which means NO ACTION. `set null` is
  -- what this wanted and cannot have: the pair includes `org_id`,
  -- which is NOT NULL, so nulling the reference would null the
  -- tenant -- the same gate refuses that, and it is right to. The
  -- refusal is the correct behaviour anyway: deleting a financial
  -- year that has a recorded filing against it would take the
  -- acknowledgement number with it, and that number is the only
  -- thing proving the return was ever sent.
  fiscal_year_id uuid,
  constraint tax_filings_year_same_org
    foreign key (org_id, fiscal_year_id)
    references public.fiscal_years (org_id, id),

  status text not null default 'in_preparation'
    check (status in ('in_preparation', 'filed', 'not_applicable')),

  filed_on date,
  -- LHDN's acknowledgement, which is the only thing that proves any of
  -- this happened. Free text: the format differs by form and by year.
  reference text,

  -- Required in spirit for `not_applicable` and enforced below: saying
  -- an obligation does not apply without saying why is the version of
  -- this feature that loses somebody a penalty.
  notes text,

  recorded_by uuid references auth.users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  -- One record per obligation. The second attempt updates the first
  -- rather than making a rival claim about the same Form C.
  unique (org_id, filing_type, period_to),

  -- A filing that is filed has a date. Without this the list clears on
  -- a row that says nothing, which is indistinguishable from a row
  -- somebody clicked by accident.
  constraint tax_filings_filed_has_a_date
    check (status <> 'filed' or filed_on is not null),

  -- And one that does not apply says why.
  constraint tax_filings_dismissal_has_a_reason
    check (status <> 'not_applicable'
           or (notes is not null and length(btrim(notes)) > 0))
);

comment on table public.tax_filings is
  'What somebody has recorded against an obligation `0668` computes. '
  'A note, not a submission -- nothing here reaches LHDN and nothing '
  'verifies the claim. Keyed on the type and the period, because '
  'Form E covers a calendar year while Form C covers the basis period '
  'and both can sit against one fiscal year.';

comment on column public.tax_filings.due_date is
  'Frozen at the moment of recording. The computed date can move when '
  'a rule is corrected, and what the person was looking at when they '
  'said "filed" should survive that.';

create index tax_filings_org_idx
  on public.tax_filings (org_id, period_to desc);
create index tax_filings_year_idx
  on public.tax_filings (fiscal_year_id, period_to desc);

alter table public.tax_filings enable row level security;
create policy tax_filings_select on public.tax_filings
  for select to authenticated using (app.is_org_member(org_id));
create policy tax_filings_insert on public.tax_filings
  for insert to authenticated with check (app.can_post(org_id));
create policy tax_filings_update on public.tax_filings
  for update to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));
-- Deleting the record of a statutory filing is an admin's act. It puts
-- the obligation back on the list, which is the safe direction, but it
-- also erases the acknowledgement number somebody may need.
create policy tax_filings_delete on public.tax_filings
  for delete to authenticated using (app.can_admin(org_id));
grant select, insert, update, delete on public.tax_filings to authenticated;

create trigger live_change_insert after insert on public.tax_filings
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.tax_filings
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.tax_filings
  referencing old table as old_rows
  for each statement execute function app.note_live_change();


-- ---------------------------------------------------------------------
-- Recording one
-- ---------------------------------------------------------------------
create or replace function public.record_tax_filing(
  p_org_id      uuid,
  p_filing_type text,
  p_period_to   date,
  p_status      text default 'filed',
  p_filed_on    date default null,
  p_reference   text default null,
  p_notes       text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_row public.tax_filings;
  v_id  uuid;
  v_found record;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Not permitted to record a tax filing'
      using errcode = '42501';
  end if;

  if not exists (select 1 from public.tax_filing_types t
                  where t.code = p_filing_type) then
    raise exception 'Unknown filing type %', p_filing_type
      using errcode = '22023';
  end if;

  -- The obligation has to be one this company actually has. Recording
  -- a Form C against a sole proprietorship is not a typo to tidy up
  -- later; it is a person marking as done a return they do not file,
  -- and then not filing the one they do.
  select * into v_found
    from public.tax_upcoming_filings(p_org_id, 3650) f
   where f.filing_type = p_filing_type and f.period_to = p_period_to;

  -- `found` rather than `v_found is null`: a record variable tests as
  -- null only when EVERY field is, which is true of a real row whose
  -- columns all happen to be empty. Here they cannot all be -- but
  -- the habit is what matters, because the version that reads a row
  -- as "not found" fails silently and in the wrong direction.
  if not found then
    -- Also true of an obligation already recorded, which is how a
    -- second call reaches this: the row is no longer in the computed
    -- list because the first call took it off. Update it instead.
    select * into v_row from public.tax_filings
     where org_id = p_org_id and filing_type = p_filing_type
       and period_to = p_period_to;
    if v_row.id is null then
      raise exception
        'No % obligation for a period ending % — check the entity '
        'type and the basis period', p_filing_type, p_period_to
        using errcode = '22023';
    end if;
  end if;

  -- `filed` with no date defaults to today rather than being refused.
  -- Somebody recording a filing almost always means "now", and the
  -- check constraint would otherwise turn the common case into an
  -- error message about a column.
  insert into public.tax_filings
    (org_id, filing_type, period_from, period_to, year_of_assessment,
     due_date, fiscal_year_id, status, filed_on, reference, notes,
     recorded_by)
  values (p_org_id, p_filing_type,
          coalesce(v_found.period_from, v_row.period_from),
          p_period_to,
          coalesce(v_found.year_of_assessment, v_row.year_of_assessment),
          coalesce(v_found.due_date, v_row.due_date),
          coalesce(v_found.fiscal_year_id, v_row.fiscal_year_id),
          p_status,
          case when p_status = 'filed'
               then coalesce(p_filed_on, app.today()) else p_filed_on end,
          p_reference, p_notes, auth.uid())
  on conflict (org_id, filing_type, period_to) do update
     set status = excluded.status,
         filed_on = excluded.filed_on,
         reference = excluded.reference,
         notes = excluded.notes,
         recorded_by = excluded.recorded_by,
         updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function
  public.record_tax_filing(uuid, text, date, text, date, text, text)
  from public, anon;
grant execute on function
  public.record_tax_filing(uuid, text, date, text, date, text, text)
  to authenticated;

comment on function
  public.record_tax_filing(uuid, text, date, text, date, text, text) is
  'Records what somebody has done about one obligation, keyed on the '
  'type and the period it covers. A note rather than a submission: '
  'nothing here reaches LHDN. Refuses an obligation this company does '
  'not have, so a Form C cannot be ticked off by a sole proprietor.';


-- Putting it back on the list.
create or replace function public.clear_tax_filing(
  p_org_id uuid, p_filing_type text, p_period_to date)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.can_post(p_org_id) then
    raise exception 'Not permitted to clear a tax filing'
      using errcode = '42501';
  end if;

  delete from public.tax_filings
   where org_id = p_org_id and filing_type = p_filing_type
     and period_to = p_period_to;
end;
$$;

revoke all on function public.clear_tax_filing(uuid, text, date)
  from public, anon;
grant execute on function public.clear_tax_filing(uuid, text, date)
  to authenticated;

comment on function public.clear_tax_filing(uuid, text, date) is
  'Undoes a recording, putting the obligation back on the computed '
  'list. The safe direction -- a deadline that reappears is a '
  'nuisance, one that vanished wrongly is a penalty -- but it also '
  'erases the acknowledgement number, so it is a deliberate act.';


-- ---------------------------------------------------------------------
-- What has been recorded
-- ---------------------------------------------------------------------
create or replace function public.tax_filing_history(
  p_org_id uuid, p_limit integer default 100)
returns table (
  filing_id   uuid,
  filing_type text,
  filing_name text,
  form_label  text,
  period_from date,
  period_to   date,
  year_of_assessment integer,
  due_date    date,
  status      text,
  filed_on    date,
  reference   text,
  notes       text,
  was_late    boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select f.id, f.filing_type, t.name, t.form_label,
         f.period_from, f.period_to, f.year_of_assessment,
         f.due_date, f.status, f.filed_on, f.reference, f.notes,
         -- Recorded as filed AFTER the date it was due. Worth its own
         -- column rather than left to the reader to subtract, because
         -- it is the thing a penalty is assessed on and the two dates
         -- sit in different columns of the same row.
         (f.status = 'filed' and f.filed_on is not null
            and f.due_date is not null and f.filed_on > f.due_date)
    from public.tax_filings f
    join public.tax_filing_types t on t.code = f.filing_type
   where f.org_id = p_org_id
   order by f.period_to desc, t.sort_order
   limit greatest(coalesce(p_limit, 100), 1);
end;
$$;

revoke all on function public.tax_filing_history(uuid, integer)
  from public, anon;
grant execute on function public.tax_filing_history(uuid, integer)
  to authenticated;

comment on function public.tax_filing_history(uuid, integer) is
  'Everything recorded against an obligation, including what was '
  'dismissed as not applicable and why. Nothing disappears when it '
  'comes off the calendar -- it moves here.';


-- ---------------------------------------------------------------------
-- The calendar, now that something can come off it
-- ---------------------------------------------------------------------
-- Dropped and recreated rather than replaced: the return type gains
-- `status` and `filing_id`, and Postgres refuses to replace a function
-- whose OUT parameters have changed. Everything else about it is
-- `0668`'s, unchanged.
drop function if exists public.tax_upcoming_filings(uuid, integer);

-- `create or replace` after the drop rather than a bare `create`: the
-- drop is what the changed return type needs, and the `or replace` is
-- what `scripts/mutate_sql.py` looks for when it extracts one
-- function's block to break on purpose. A bare `create` is invisible
-- to it, and the sweep reports a harness error rather than pretending
-- to have tested this.
create or replace function public.tax_upcoming_filings(
  p_org_id uuid,
  p_within_days integer default 240)
returns table (
  filing_type text,
  filing_name text,
  form_label text,
  statute_ref text,
  fiscal_year_id uuid,
  period_from date,
  period_to date,
  year_of_assessment integer,
  due_date date,
  efiling_due_date date,
  days_left integer,
  is_overdue boolean,
  needs_employees boolean,
  description text,
  computation_id uuid,
  estimate_id uuid,
  status text,
  filing_id uuid)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_today date := app.today();
  v_entity text;
  v_has_staff boolean;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  select o.entity_type into v_entity
    from public.organizations o where o.id = p_org_id;

  -- An employer for this purpose is anybody who has ever had somebody
  -- on the payroll: a company that let its last employee go in March
  -- still files a Form E for that year.
  select exists (
    select 1 from public.employees e where e.org_id = p_org_id
  ) into v_has_staff;

  return query
  select t.code,
         t.name,
         t.form_label,
         t.statute_ref,
         fy.id,
         -- Form E and Form EA cover a calendar year whatever the
         -- company's year end is, so they are labelled with one. The
         -- date below is the same either way; this is not.
         case when t.basis = 'month_day_after_year'
              then make_date(extract(year from fy.end_date)::integer, 1, 1)
              else fy.start_date end,
         case when t.basis = 'month_day_after_year'
              then make_date(extract(year from fy.end_date)::integer, 12, 31)
              else fy.end_date end,
         extract(year from fy.end_date)::integer,
         d.due,
         case when t.efiling_grace_months is null
                   and t.efiling_grace_days is null then null
              else (d.due
                    + make_interval(months => coalesce(t.efiling_grace_months, 0))
                    + make_interval(days => coalesce(t.efiling_grace_days, 0)))::date
         end,
         (d.due - v_today)::integer,
         d.due < v_today,
         t.needs_employees,
         t.description,
         tc.id,
         te.id,
         -- Nothing recorded reads as nothing recorded rather than as
         -- null, so a screen can switch on one value.
         coalesce(tf.status, 'not_started'),
         tf.id
    from public.fiscal_years fy
    join public.tax_filing_types t
      on coalesce(v_entity, 'other') = any (t.applies_to)
     and (not t.needs_employees or v_has_staff)
    cross join lateral (
      select app.tax_filing_due(
               t.basis, t.days_before, t.months_after, t.period_month,
               t.due_month, t.due_day, fy.start_date, fy.end_date) as due
    ) d
    left join public.tax_computations tc
      on tc.fiscal_year_id = fy.id and tc.org_id = fy.org_id
    -- The estimate still in force: a revision is a NEW row in `0667`
    -- that names the one it replaces, so the current one is whichever
    -- nothing has revised.
    left join public.tax_estimates te
      on te.fiscal_year_id = fy.id and te.org_id = fy.org_id
     and not exists (select 1 from public.tax_estimates r
                      where r.revises_id = te.id)
    -- Keyed on the obligation rather than the year -- see `0669`'s
    -- header. Joined on the period this row is FOR, which for Form E
    -- is the calendar year computed two columns up, so the expression
    -- is repeated rather than referenced: a select-list alias is not
    -- in scope in the from clause.
    left join public.tax_filings tf
      on tf.org_id = fy.org_id and tf.filing_type = t.code
     and tf.period_to = case when t.basis = 'month_day_after_year'
              then make_date(extract(year from fy.end_date)::integer, 12, 31)
              else fy.end_date end
   where fy.org_id = p_org_id
     and d.due is not null
     -- Dealt with, one way or the other. An obligation still in
     -- preparation STAYS: somebody opening a Form C has not filed it,
     -- and a list that cleared on the intention to do something would
     -- be worse than one that never cleared at all.
     and coalesce(tf.status, 'not_started') not in
           ('filed', 'not_applicable')
     -- A year either side of the window: an obligation that is already
     -- late is the one somebody most needs to see, and dropping it the
     -- day after it was due is exactly backwards.
     and d.due between v_today - 365
                   and v_today + greatest(coalesce(p_within_days, 240), 1)
   order by d.due, t.sort_order;
end;
$$;

revoke all on function public.tax_upcoming_filings(uuid, integer)
  from public, anon;
grant execute on function public.tax_upcoming_filings(uuid, integer)
  to authenticated;

comment on function public.tax_upcoming_filings(uuid, integer) is
  'Every income tax obligation this company still has against its own '
  'basis periods, computed rather than stored, with what is already '
  'late kept in the list and what has been filed or dismissed taken '
  'out of it. The e-filing date is shown beside the statutory one, '
  'never instead of it.';
