-- =====================================================================
-- iAkauntan :: 0373 a deal died and nobody asked why
--
-- `opportunities.won_reason`, `lost_reason` and `competitor` have been
-- columns since `0008`, and `leads.lost_reason` with them. None has ever
-- been written.
--
-- Dragging a card onto Closed Lost calls `moveOpportunity`, which is one
-- `update` of `stage_id`. `0009`'s trigger then sets `status` to 'lost'
-- and stamps `actual_close_date`, and that is the whole of it. The
-- pipeline records that a deal died, on what day, for how much — and
-- nothing about why.
--
-- That is the one question a pipeline exists to answer. Every other
-- figure on it is arithmetic anybody could do from the invoices after
-- the fact; the reason is the only thing that has to be captured at the
-- moment it is known, because a week later nobody remembers and the
-- salesperson has moved on. "We lost forty per cent of them on price"
-- is a decision about pricing. "We lost forty of them" is a number.
--
-- ---------------------------------------------------------------------
-- Required, and only where it is worth requiring
--
-- A lost or abandoned deal must carry a reason. This is the whole
-- migration: an optional field on a form nobody has time for is a field
-- that stays empty, and the report built on it stays empty with it.
--
-- A won deal need not. There is no decision waiting on why a customer
-- said yes, and the field is offered rather than demanded so that
-- winning stays the easy path.
--
-- `competitor` is asked for on both. A deal lost to somebody names them;
-- a deal won against somebody names them too, and a win-loss report that
-- only knows about the losses is a report about the losses.
--
-- ---------------------------------------------------------------------
-- `abandoned`, which nothing could reach
--
-- `opportunities.status` allows ('open', 'won', 'lost', 'abandoned') and
-- `pipeline_stages.stage_type` allows only ('open', 'won', 'lost'). The
-- trigger derives status from stage type, so the fourth value was
-- unreachable: there is no stage that produces it.
--
-- It earns its place. Lost is the customer buying from somebody else —
-- there is a competitor, a price, a reason. Abandoned is the deal that
-- went quiet, or the one the firm walked away from, and a pipeline that
-- calls those the same thing reports a loss rate that is not true. The
-- card still moves to the Closed Lost column, because a board with no
-- column for it would have nowhere to put the card; the *status* is what
-- separates them, and it is what the report groups by.
--
-- Two statements rather than one, deliberately: `0009`'s trigger writes
-- `status` from the stage whenever `stage_id` changes, so a single
-- update setting both would have the trigger overwrite the second.
--
-- ---------------------------------------------------------------------
-- And reopening
--
-- A deal closed on the wrong card, and a customer who comes back, are
-- both ordinary. Without a way back somebody raises a second
-- opportunity for the same deal, and then the pipeline counts it twice.
-- =====================================================================

create or replace function public.close_opportunity(
  p_opportunity uuid,
  p_outcome text,
  p_reason text default null,
  p_competitor text default null,
  p_closed_on date default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_o      public.opportunities;
  v_stage  uuid;
  v_type   text;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  select * into v_o from public.opportunities
   where id = p_opportunity and deleted_at is null;
  if v_o.id is null then
    raise exception 'No such opportunity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_o.org_id) then
    raise exception 'not permitted to close a deal' using errcode = '42501';
  end if;
  if p_outcome not in ('won', 'lost', 'abandoned') then
    raise exception
      'A deal closes as won, lost or abandoned; got %.', p_outcome
      using errcode = '22023';
  end if;
  if v_o.status <> 'open' then
    raise exception 'That deal is already closed as %.', v_o.status
      using errcode = '23514';
  end if;

  -- The point of the whole migration.
  if p_outcome <> 'won' and v_reason is null then
    raise exception
      'Say why it was %. A pipeline that records that deals died and not '
      'why cannot answer the only question it is for.', p_outcome
      using errcode = '23514';
  end if;

  -- The column the card lands in. Abandoned has no column of its own and
  -- should not: the board needs somewhere to put it, and the difference
  -- lives in the status.
  v_type := case when p_outcome = 'won' then 'won' else 'lost' end;
  select s.id into v_stage
    from public.pipeline_stages s
   where s.pipeline_id = v_o.pipeline_id and s.stage_type = v_type
   order by s.sort_order desc limit 1;
  if v_stage is null then
    raise exception
      'This pipeline has no % stage to close into. Add one in the '
      'pipeline setup first.', v_type using errcode = 'P0002';
  end if;

  -- First the stage, which lets `0009`'s trigger write the stage
  -- history, the probability and the close date exactly as a drag would.
  update public.opportunities
     set stage_id = v_stage, updated_at = now()
   where id = p_opportunity;

  -- Then the answers. `status` is set here rather than above because the
  -- trigger derives it from the stage and would overwrite it.
  update public.opportunities set
    status            = p_outcome,
    actual_close_date = coalesce(p_closed_on, actual_close_date, current_date),
    won_reason        = case when p_outcome = 'won' then v_reason else null end,
    lost_reason       = case when p_outcome = 'won' then null else v_reason end,
    competitor        = nullif(trim(coalesce(p_competitor, '')), ''),
    updated_at        = now()
  where id = p_opportunity;
end $$;

create or replace function public.reopen_opportunity(
  p_opportunity uuid, p_stage uuid default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_o     public.opportunities;
  v_stage uuid;
begin
  select * into v_o from public.opportunities
   where id = p_opportunity and deleted_at is null;
  if v_o.id is null then
    raise exception 'No such opportunity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_o.org_id) then
    raise exception 'not permitted to reopen a deal' using errcode = '42501';
  end if;
  if v_o.status = 'open' then
    raise exception 'That deal is already open.' using errcode = '23514';
  end if;

  -- Back to where it was working, or to the first open stage. Not to
  -- the stage it died in: that one is a closed column.
  select s.id into v_stage
    from public.pipeline_stages s
   where s.id = p_stage and s.pipeline_id = v_o.pipeline_id
     and s.stage_type = 'open';
  if v_stage is null then
    select s.id into v_stage
      from public.pipeline_stages s
     where s.pipeline_id = v_o.pipeline_id and s.stage_type = 'open'
     order by s.sort_order limit 1;
  end if;
  if v_stage is null then
    raise exception
      'This pipeline has no open stage to put it back into.'
      using errcode = 'P0002';
  end if;

  update public.opportunities
     set stage_id = v_stage, updated_at = now()
   where id = p_opportunity;

  update public.opportunities set
    status            = 'open',
    actual_close_date = null,
    won_reason        = null,
    lost_reason       = null,
    updated_at        = now()
  where id = p_opportunity;
end $$;

-- ---------------------------------------------------------------------
-- The lead that never became anything
--
-- `leads.lost_reason` is the same column one table earlier, and the same
-- silence. `convert_lead` already refuses a lost lead and tells the
-- caller to reopen it first, which was advice about a state nothing
-- could deliberately enter and nothing could leave.
-- ---------------------------------------------------------------------
create or replace function public.close_lead(
  p_lead uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_l      public.leads;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  select * into v_l from public.leads
   where id = p_lead and deleted_at is null;
  if v_l.id is null then
    raise exception 'No such lead.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_l.org_id) then
    raise exception 'not permitted to close a lead' using errcode = '42501';
  end if;
  if v_l.converted_contact_id is not null then
    raise exception
      'That lead became a customer. It cannot also be a lost one.'
      using errcode = '23514';
  end if;
  if v_reason is null then
    raise exception
      'Say why the lead came to nothing. A list of dead leads with no '
      'reasons on it is a list nobody reads twice.'
      using errcode = '23514';
  end if;

  update public.leads set
    status      = 'lost',
    lost_reason = v_reason,
    updated_at  = now()
  where id = p_lead;
end $$;

create or replace function public.reopen_lead(p_lead uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_l public.leads;
begin
  select * into v_l from public.leads
   where id = p_lead and deleted_at is null;
  if v_l.id is null then
    raise exception 'No such lead.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_l.org_id) then
    raise exception 'not permitted to reopen a lead' using errcode = '42501';
  end if;
  if v_l.status <> 'lost' then
    raise exception 'That lead is not lost.' using errcode = '23514';
  end if;

  -- To contacted rather than new. Somebody spoke to them; pretending
  -- otherwise loses the only thing the record knew.
  update public.leads set
    status = 'contacted', lost_reason = null, updated_at = now()
  where id = p_lead;
end $$;

-- ---------------------------------------------------------------------
-- What the reasons are for
--
-- Grouped by outcome and reason, with the count and the money. Written
-- here rather than assembled in Dart because it is the thing that makes
-- the columns worth filling, and a report that lives in one screen is a
-- report the next screen cannot use.
--
-- Deals rather than leads: the two are different populations and adding
-- them would give a percentage of nothing in particular.
-- ---------------------------------------------------------------------
create or replace function public.report_win_loss(
  p_org_id uuid, p_from date, p_to date)
returns table (
  outcome text, reason text, deals integer, amount numeric,
  competitors text)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select o.status,
         coalesce(nullif(trim(coalesce(o.won_reason, o.lost_reason)), ''),
                  'Not given'),
         count(*)::integer,
         coalesce(sum(o.amount), 0),
         -- Named rather than counted: a report saying "three
         -- competitors" tells nobody who to go and look at.
         nullif(string_agg(distinct nullif(trim(o.competitor), ''), ', '), '')
    from public.opportunities o
   where o.org_id = p_org_id
     and o.deleted_at is null
     and o.status in ('won', 'lost', 'abandoned')
     and o.actual_close_date between p_from and p_to
     and app.is_org_member(p_org_id)
   group by 1, 2
   order by 1, 4 desc;
$$;

revoke all on function public.close_opportunity(uuid, text, text, text, date)
  from public, anon;
revoke all on function public.reopen_opportunity(uuid, uuid) from public, anon;
revoke all on function public.close_lead(uuid, text) from public, anon;
revoke all on function public.reopen_lead(uuid) from public, anon;
revoke all on function public.report_win_loss(uuid, date, date) from public, anon;
grant execute on function public.close_opportunity(uuid, text, text, text, date)
  to authenticated;
grant execute on function public.reopen_opportunity(uuid, uuid) to authenticated;
grant execute on function public.close_lead(uuid, text) to authenticated;
grant execute on function public.reopen_lead(uuid) to authenticated;
grant execute on function public.report_win_loss(uuid, date, date) to authenticated;

comment on function public.close_opportunity(uuid, text, text, text, date) is
  'Closes a deal and insists on a reason for the ones worth learning '
  'from. Dragging a card to Closed Lost recorded that a deal died and '
  'nothing about why, which is the only question a pipeline is for.';
comment on function public.report_win_loss(uuid, date, date) is
  'Why deals closed, by outcome and reason, with the money and the '
  'competitors named. The thing that makes the reasons worth asking '
  'for.';
