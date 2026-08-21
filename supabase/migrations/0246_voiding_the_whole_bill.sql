-- =====================================================================
-- Voiding the whole bill
--
-- 0225 gave a till a way to take one line off after the kitchen had it,
-- with a reason and a name on it. What it never gave anybody was a way
-- to write off the whole thing: a party walks out on six lines and the
-- cashier voids six lines, six reasons, six records, for one event.
--
-- The gap has been visible in the product the whole time. 0206 refuses
-- to close a shift over a parked sale and says "Finish or void them
-- before closing" -- naming an action that did not exist. So a cashier
-- with an abandoned bill could not close their own drawer without
-- dismantling it line by line.
--
-- ---------------------------------------------------------------------
-- The lines stay
--
-- A line void deletes the line, because the bill carries on and has to
-- re-total without it. A bill void is the opposite case: the bill stops
-- here, and what was on it is the evidence. Deleting the lines would
-- leave a voided sale of nothing, and "RM 86.00 walked out" is the
-- fact a manager needs.
--
-- So nothing is deleted and nothing is recalculated. `status` becomes
-- `voided`, which every aggregate in the schema already excludes --
-- each of them filters `parked` or `completed`, checked one by one, so
-- a voided sale falls out of expected cash, the floor plan, the open
-- orders list, the consolidated e-Invoice and the channel report
-- without any of them being touched.
--
-- ---------------------------------------------------------------------
-- What lands in the void record
--
-- One row per line the kitchen was told about, and none for the rest.
-- `pos_void_summary` sums `line_total` to answer "where is the food
-- going", and a line nobody cooked is not food. Recording it would
-- inflate the one report this table exists for.
--
-- The bill's own trace is the sale row: voided, when, why, by whom.
--
-- ---------------------------------------------------------------------
-- Who may
--
-- The same `pos_void` grant 0244 put on the line void -- but only when
-- there is something to lose. A bill where nothing reached the kitchen
-- is a handful of keystrokes the cashier could already remove one at a
-- time with no grant at all, and requiring a manager to clear a mis-tap
-- would leave somebody unable to close their own till at the end of a
-- shift. Once one line has been cooked, the bill is a write-off and
-- needs the grant, which is exactly the rule 0225 set for a single
-- line.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Who wrote it off, and what they said
-- ---------------------------------------------------------------------
--
-- `voided_at` and `void_reason` have been on the table since 0208,
-- declared alongside a status nothing ever set. These are the two
-- columns that were missing to make the record answerable.
alter table public.pos_sales
  add column if not exists voided_by uuid
    references auth.users (id) on delete set null,
  add column if not exists void_note text;

comment on column public.pos_sales.void_reason is
  'Why the whole bill was written off, as an app.pos_void_reason value. Null unless the status is voided.';
comment on column public.pos_sales.voided_by is
  'Who wrote it off. The point of the record: a void is where a till leaks, and an unattributed one tells nobody anything.';

-- ---------------------------------------------------------------------
-- Writing off a bill
-- ---------------------------------------------------------------------
--
-- Returns how many lines were recorded as voided, which is how many
-- had been cooked -- not how many were on the bill. The caller can say
-- "six items written off" or, when it comes back nought, stay quiet:
-- nothing was lost and there is nothing to announce.
create or replace function public.void_pos_sale(
  p_sale   uuid,
  p_reason app.pos_void_reason,
  p_note   text default null)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale public.pos_sales;
  v_sent integer;
  v_done integer;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such bill.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  if v_sale.status <> 'parked' then
    raise exception
      'That bill is % and cannot be voided. Raise a credit note instead.',
      v_sale.status using errcode = '23514';
  end if;

  select count(*)::integer into v_sent
    from public.pos_sale_lines l
   where l.sale_id = p_sale and l.sent_to_kitchen_at is not null;

  -- The grant is asked for exactly when there is something to lose.
  -- See the header: a bill nobody cooked from is keystrokes, and a
  -- cashier who cannot clear one cannot close their own drawer.
  if v_sent > 0 and not app.can_void_pos(v_sale.org_id) then
    raise exception
      'Writing off a bill the kitchen has cooked from needs permission '
      'this account has not been given. Ask a manager.'
      using errcode = '42501';
  end if;

  if p_reason = 'other' and coalesce(btrim(p_note), '') = '' then
    raise exception 'Say what happened.' using errcode = '23514';
  end if;

  -- The evidence, one row per line that became food. Written before
  -- the status changes for no reason other than that it reads in the
  -- order it happened.
  insert into public.pos_sale_line_voids (
    org_id, sale_id, line_no, item_id, description, quantity,
    unit_price, line_total, was_sent_at, reason, note, voided_by)
  select l.org_id, l.sale_id, l.line_no, l.item_id, l.description,
         l.quantity, l.unit_price, l.line_total, l.sent_to_kitchen_at,
         p_reason, nullif(btrim(p_note), ''), auth.uid()
    from public.pos_sale_lines l
   where l.sale_id = p_sale
     and l.sent_to_kitchen_at is not null;
  get diagnostics v_done = row_count;

  -- Tell the kitchen to stop. A ticket already served is history and
  -- stays served -- that food went out, and rewriting it would make
  -- the pass disagree with what the room actually got.
  update public.pos_kitchen_tickets t
     set status = 'cancelled'
   where t.sale_id = p_sale
     and t.status in ('new', 'cooking', 'ready');

  -- The lines are left exactly as they are, and so are the totals.
  -- They are what the bill was, and that is the thing being written
  -- off.
  update public.pos_sales s
     set status     = 'voided',
         voided_at  = now(),
         void_reason = p_reason::text,
         void_note  = nullif(btrim(p_note), ''),
         voided_by  = auth.uid()
   where s.id = p_sale;

  return v_done;
end;
$$;

revoke all on function public.void_pos_sale(uuid, app.pos_void_reason, text)
  from public, anon;
grant execute on function public.void_pos_sale(uuid, app.pos_void_reason, text)
  to authenticated;

comment on function public.void_pos_sale(uuid, app.pos_void_reason, text) is
  'Writes off a whole parked bill: one void record per line the kitchen cooked, the live dockets cancelled, and the sale marked voided with a reason and a name. The lines are kept -- they are what was written off.';
