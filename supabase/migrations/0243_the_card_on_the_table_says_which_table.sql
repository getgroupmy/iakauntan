-- =====================================================================
-- The card on the table says which table
--
-- A dine-in bill has to end up pointing at a table, and until now the
-- only way to put it there was the floor plan: open a second screen,
-- find the table in a drawn room, tap it. That is the right screen for
-- a waiter walking the floor and the wrong one for a cashier at a
-- counter taking an order for table seven, who has the bill in front of
-- them and no reason to go anywhere.
--
-- What shops actually put on the table is a card — a printed code, a
-- QR sticker, an NFC tag on the underside. Every one of those readers
-- in this market presents as a keyboard: it types the code and presses
-- enter, exactly as the barcode gun already pointed at the item search
-- does. So the till needs no new hardware path, only a way to turn the
-- string that arrives into a table.
--
-- `pos_tables.code` is already unique per outlet, so the lookup itself
-- is one row. What this function adds is the normalisation, which is
-- the part that must not live in the client:
--
--   * a bare code, `T7`, as a printed label or a typed entry;
--   * a URL, `https://iakauntan.com/t/T7`, because a QR sticker a
--     customer might also scan with a phone has to be a link;
--   * a prefixed token, `table:T7`, which is what a tag writer
--     defaults to.
--
-- All three are the same table, and a shop that changes its sticker
-- printer must not need a client release. The rule is: drop a query
-- string or fragment, then take what follows the last `/` or `:`.
--
-- It also reports how many bills are already open on the table, which
-- the caller needs and must not have to ask a second question for.
-- Two bills on one table is legitimate — a split leaves exactly that,
-- and `pos_floor_plan` draws it — so this is a fact to show the
-- cashier, not a reason to refuse.
-- =====================================================================

create or replace function public.pos_table_by_code(
  p_outlet uuid,
  p_code   text)
returns table (
  table_id   uuid,
  table_code text,
  table_name text,
  area       text,
  seats      integer,
  open_bills integer)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_raw text;
begin
  v_raw := btrim(coalesce(p_code, ''));
  if v_raw = '' then
    return;
  end if;

  -- A URL carries `?utm=` and `#frag` that no table code contains.
  v_raw := split_part(split_part(v_raw, '#', 1), '?', 1);
  -- A trailing slash would otherwise make the last segment empty.
  v_raw := regexp_replace(v_raw, '/+$', '');
  -- The last segment. One rule covering a bare code, a URL path and a
  -- prefixed token, because the greedy match simply finds nothing to
  -- strip when the string is already just a code.
  v_raw := btrim(regexp_replace(v_raw, '^.*[/:]', ''));
  if v_raw = '' then
    return;
  end if;

  return query
    select t.id,
           t.code,
           coalesce(t.name, t.code),
           a.name,
           t.seats,
           (select count(*)::integer
              from public.pos_sales s
             where s.table_id = t.id
               and s.status = 'parked')
      from public.pos_tables t
      left join public.pos_floor_areas a on a.id = t.area_id
     where t.outlet_id = p_outlet
       and t.is_active
       -- Case-insensitively, because a code printed as `T7` is typed
       -- as `t7` by somebody who could not find the card.
       and upper(t.code) = upper(v_raw)
       and app.can_read_module(t.org_id, 'pos');
end;
$$;

revoke all on function public.pos_table_by_code(uuid, text) from public, anon;
grant execute on function public.pos_table_by_code(uuid, text) to authenticated;

comment on function public.pos_table_by_code(uuid, text) is
  'The table a scanned card, QR sticker or typed code names, with how many bills are already open on it. Normalises a URL or a prefixed token down to the code, so what a shop prints on its cards is not a client concern.';
