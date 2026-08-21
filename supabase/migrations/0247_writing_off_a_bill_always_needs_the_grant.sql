-- =====================================================================
-- Writing off a bill always needs the grant
--
-- 0246 asked for `pos_void` only when the kitchen had cooked from the
-- bill. The reasoning was that a bill nobody cooked from is keystrokes
-- the cashier could already remove one at a time, so requiring a
-- manager to clear a mis-tap was friction with nothing behind it.
--
-- That reasoning is wrong about what the control is for. A shop that
-- takes voids away from a cashier is not counting plates -- it is
-- deciding that making a bill disappear is a supervisor's act, and a
-- bill that vanishes before anything reached the kitchen is exactly the
-- shape of an order rung up, paid in cash and made to go away. The line
-- rule does not carry over: taking one unsent line off a bill leaves
-- the bill, and the cashier still has to account for it.
--
-- So the guard moves ahead of the question about what was cooked, and
-- there is no longer a path through this function that does not need
-- the grant.
--
-- ---------------------------------------------------------------------
-- What this costs, said plainly
--
-- 0206 refuses to close a shift over a parked sale. A cashier without
-- `pos_void` who opens a bill by mistake now cannot clear it and cannot
-- close their own drawer -- a supervisor has to. That is the intended
-- shape of the control rather than a side effect of it, and the way a
-- shop avoids it is to grant `pos_void` to whoever closes the till.
--
-- Replaced whole because `create or replace` replaces whole. Only the
-- guard and its message differ from 0246.
-- =====================================================================

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

  -- Ahead of everything about the bill's contents, because whether it
  -- may be written off is not a question about what is on it.
  if not app.can_void_pos(v_sale.org_id) then
    raise exception
      'Writing off a bill needs permission this account has not been '
      'given. Ask a manager.'
      using errcode = '42501';
  end if;

  if v_sale.status <> 'parked' then
    raise exception
      'That bill is % and cannot be voided. Raise a credit note instead.',
      v_sale.status using errcode = '23514';
  end if;

  if p_reason = 'other' and coalesce(btrim(p_note), '') = '' then
    raise exception 'Say what happened.' using errcode = '23514';
  end if;

  -- Still only the lines that became food. `pos_void_summary` answers
  -- "where is the food going", and a line nobody cooked is not food --
  -- who may write the bill off and what the loss was are two different
  -- questions, and only the first one changed.
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

  update public.pos_kitchen_tickets t
     set status = 'cancelled'
   where t.sale_id = p_sale
     and t.status in ('new', 'cooking', 'ready');

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
  'Writes off a whole parked bill, behind the pos_void grant without exception: one void record per line the kitchen cooked, the live dockets cancelled, and the sale marked voided with a reason and a name. The lines are kept -- they are what was written off.';
