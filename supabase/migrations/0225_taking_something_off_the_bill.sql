-- Taking something off a bill, and when that stops being free.
--
-- ## Two different acts wearing one word
--
-- "Remove that" means one thing before the kitchen has been told and
-- another after, and a till that treats them alike gets one of them
-- wrong:
--
--   * **Before it is sent** the line is a keystroke. Nobody has cooked
--     anything, no stock has moved, the customer has not been promised
--     it. Taking it off is a correction and should cost nothing -- no
--     dialog, no reason, no trace.
--
--   * **After it is sent** food exists. Somebody stood at a pan. The
--     line may be wrong, the plate may have been dropped, the customer
--     may never have received it -- but *something happened*, and a
--     till that lets a waiter make it disappear silently is a till
--     that cannot tell a mistake from a theft.
--
-- So the first is a delete and the second needs a reason, a name and a
-- timestamp. `sent_to_kitchen_at`, which 0215 already keeps on the
-- line, is the whole test.
--
-- ## Why the line is deleted either way
--
-- The tempting alternative is a `voided_at` column, leaving the line on
-- the bill struck through. It was rejected because of what it would
-- cost everywhere else: `recalc_pos_sale`, the "a sale has to have a
-- line" guard, the loop that writes the invoice lines and the loyalty
-- basket all read `pos_sale_lines` and would each need restating to
-- say "and not voided". Four places to remember, one of them the
-- invoice -- and forgetting any one bills the customer for a plate
-- that was taken off.
--
-- Deleting the line and keeping the evidence beside it means the
-- arithmetic simply sees fewer lines, and nothing downstream changes.
-- The audit lives in `pos_sale_line_voids`, which holds what the line
-- said rather than a pointer to a row that no longer exists.
--
-- 0215 already anticipated this: `pos_kitchen_ticket_lines.sale_line_id`
-- is `on delete set null`, with the comment "the food was cooked;
-- whether it is charged for is a different question". The docket keeps
-- its own copy of the description and quantity, so the kitchen's record
-- of what it made survives the line coming off the bill.
--
-- ## What this does not do
--
-- It does not invent a cashier role. The rule "only at the counter"
-- is real, but this schema has no role that distinguishes a waiter's
-- tablet from a till, and inventing one here would be inventing a
-- permission model in a migration about voids. What the database
-- enforces is that a sent line cannot go without a reason and a name
-- against it; where that action is offered -- the till, not the floor
-- plan -- is the client's part of the same rule.

do $$ begin
  create type app.pos_void_reason as enum (
    'wrong_item',        -- ordered or rung up as the wrong thing
    'item_issue',        -- came out wrong, cold, spilled
    'not_received',      -- never reached the table
    'customer_cancelled',-- changed their mind after it was sent
    'other'              -- anything else, and the note is required
  );
exception when duplicate_object then null; end $$;

create table if not exists public.pos_sale_line_voids (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  sale_id     uuid not null references public.pos_sales (id) on delete cascade,

  -- What the line said, not a pointer to it. The line is gone by the
  -- time anybody reads this, and a void that cannot say what was taken
  -- off is not evidence of anything.
  line_no     integer,
  item_id     uuid references public.items (id) on delete set null,
  description text not null,
  quantity    numeric(18, 4) not null,
  unit_price  numeric(18, 4) not null,
  line_total  numeric(18, 2) not null,

  -- Whether the kitchen had already been told. Recorded because it is
  -- the difference between a correction and a loss: an unsent line
  -- never reaches this table at all, so every row here is food that
  -- existed.
  was_sent_at timestamptz,

  reason      app.pos_void_reason not null,
  note        text,
  voided_by   uuid references auth.users (id) on delete set null,
  voided_at   timestamptz not null default now(),

  constraint pos_sale_line_voids_note_ck
    check (reason <> 'other' or coalesce(btrim(note), '') <> '')
);

create index if not exists pos_sale_line_voids_sale_idx
  on public.pos_sale_line_voids (sale_id);
create index if not exists pos_sale_line_voids_day_idx
  on public.pos_sale_line_voids (org_id, voided_at desc);

alter table public.pos_sale_line_voids enable row level security;

drop policy if exists pos_sale_line_voids_read on public.pos_sale_line_voids;
create policy pos_sale_line_voids_read on public.pos_sale_line_voids
  for select using (app.can_read_module(org_id, 'pos'));

-- No insert, update or delete policy on purpose. Rows arrive through
-- `void_pos_sale_line` and never leave: a void log somebody can edit is
-- a void log that proves nothing.

comment on table public.pos_sale_line_voids is
  'Every line taken off a bill after the kitchen was told, with what it '
  'said and why it went. Append-only: written by void_pos_sale_line and '
  'readable by the module, with no policy that would let it be changed.';

-- ---------------------------------------------------------------------
-- Before it is sent: a correction
-- ---------------------------------------------------------------------
create or replace function public.remove_pos_sale_line(p_line uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line public.pos_sale_lines;
  v_sale public.pos_sales;
begin
  select * into v_line from public.pos_sale_lines where id = p_line;
  if v_line.id is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_line.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  select * into v_sale from public.pos_sales where id = v_line.sale_id;
  if v_sale.status <> 'parked' then
    raise exception
      'That bill is % and cannot be edited. Raise a credit note instead.',
      v_sale.status using errcode = '23514';
  end if;

  -- The whole rule, in one condition.
  if v_line.sent_to_kitchen_at is not null then
    raise exception
      'That has already gone to the kitchen. Void it with a reason '
      'instead of removing it.'
      using errcode = '23514';
  end if;

  delete from public.pos_sale_lines where id = p_line;
  perform app.recalc_pos_sale(v_line.sale_id);
end;
$$;

revoke all on function public.remove_pos_sale_line(uuid) from public, anon;
grant execute on function public.remove_pos_sale_line(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- After it is sent: a loss, with somebody's name on it
-- ---------------------------------------------------------------------
create or replace function public.void_pos_sale_line(
  p_line   uuid,
  p_reason app.pos_void_reason,
  p_note   text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line public.pos_sale_lines;
  v_sale public.pos_sales;
  v_void uuid;
begin
  select * into v_line from public.pos_sale_lines where id = p_line;
  if v_line.id is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_line.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  select * into v_sale from public.pos_sales where id = v_line.sale_id;
  if v_sale.status <> 'parked' then
    raise exception
      'That bill is % and cannot be edited. Raise a credit note instead.',
      v_sale.status using errcode = '23514';
  end if;

  if p_reason = 'other' and coalesce(btrim(p_note), '') = '' then
    raise exception 'Say what happened.' using errcode = '23514';
  end if;

  -- Written before the delete, because after it there is nothing left
  -- to copy.
  insert into public.pos_sale_line_voids (
    org_id, sale_id, line_no, item_id, description, quantity,
    unit_price, line_total, was_sent_at, reason, note, voided_by)
  values (
    v_line.org_id, v_line.sale_id, v_line.line_no, v_line.item_id,
    v_line.description, v_line.quantity, v_line.unit_price,
    v_line.line_total, v_line.sent_to_kitchen_at, p_reason,
    nullif(btrim(p_note), ''), auth.uid())
  returning id into v_void;

  -- The kitchen docket line loses its pointer and keeps its text, by
  -- the `on delete set null` 0215 put there for exactly this.
  delete from public.pos_sale_lines where id = p_line;
  perform app.recalc_pos_sale(v_line.sale_id);
  return v_void;
end;
$$;

revoke all on function public.void_pos_sale_line(uuid, app.pos_void_reason, text)
  from public, anon;
grant execute on function public.void_pos_sale_line(uuid, app.pos_void_reason, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- What went off the bills today
-- ---------------------------------------------------------------------
--
-- The screen a manager opens when the food cost does not match the
-- takings. Grouped by reason rather than listed, because one void is
-- an accident and thirty "not received" in a week is a conversation.
create or replace function public.pos_void_summary(
  p_org  uuid,
  p_from date default (now() at time zone 'Asia/Kuala_Lumpur')::date,
  p_to   date default (now() at time zone 'Asia/Kuala_Lumpur')::date)
returns table (
  reason     app.pos_void_reason,
  lines      integer,
  quantity   numeric,
  value      numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select v.reason, count(*)::integer, sum(v.quantity), sum(v.line_total)
    from public.pos_sale_line_voids v
   where v.org_id = p_org
     and (v.voided_at at time zone 'Asia/Kuala_Lumpur')::date
         between p_from and p_to
     and app.can_read_module(p_org, 'pos')
   group by v.reason
   order by sum(v.line_total) desc;
$$;

grant execute on function public.pos_void_summary(uuid, date, date) to authenticated;

comment on function public.remove_pos_sale_line(uuid) is
  'Takes an unsent line off a parked bill. Refuses once the kitchen has '
  'been told -- that is void_pos_sale_line, which wants a reason.';

comment on function public.void_pos_sale_line(uuid, app.pos_void_reason, text) is
  'Takes a line off after the kitchen was told, recording what it said, '
  'why it went and who did it. The line is deleted so no downstream '
  'arithmetic has to remember to exclude it; the evidence lives in '
  'pos_sale_line_voids.';
