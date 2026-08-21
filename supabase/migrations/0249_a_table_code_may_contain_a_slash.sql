-- =====================================================================
-- A table code may contain a slash
--
-- 0243 normalises a scanned string down to a table code by dropping a
-- query string, then taking whatever follows the last `/` or `:`. That
-- turns `https://iakauntan.com/t/T7` and `table:T7` into `T7`, which is
-- the whole point.
--
-- It also turns `A/1` into `1`.
--
-- `pos_tables.code` is free text a shop chooses, and `A/1` is an
-- ordinary way to write "row A, table 1". Under 0243 scanning that
-- card either finds nothing, or -- worse, and this is why it is worth a
-- migration -- finds a *different* table called `1` and seats the party
-- at it. A lookup that quietly returns the wrong table is the expensive
-- kind of wrong this module keeps refusing to commit elsewhere.
--
-- ---------------------------------------------------------------------
-- Ask for what was scanned before deciding it was a wrapper
--
-- The fix is to try the string as it arrived, and only strip it when
-- nothing answers to it. A code that exists wins; a URL or a prefixed
-- token matches nothing as written and falls through to exactly the
-- normalisation 0243 already does.
--
-- Nothing that worked before changes. `T7` matched the raw string then
-- and matches it now; the URL and the token still miss and still get
-- stripped. The only behaviour that moves is the case that was wrong.
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
  v_raw  text;
  v_try  text;
  v_hit  boolean;
begin
  v_raw := btrim(coalesce(p_code, ''));
  if v_raw = '' then
    return;
  end if;

  -- A query string or fragment is never part of a code, so it goes
  -- before anything is tried. A shop cannot type `?` into a table code
  -- and mean it.
  v_raw := split_part(split_part(v_raw, '#', 1), '?', 1);
  v_try := btrim(v_raw);

  -- As scanned, first. This is the line 0243 was missing.
  select true into v_hit
    from public.pos_tables t
   where t.outlet_id = p_outlet
     and t.is_active
     and upper(t.code) = upper(v_try)
   limit 1;

  if v_hit is not true then
    -- Nothing answers to it, so it was a wrapper: drop a trailing
    -- slash, then take the last segment. One rule covering a URL path
    -- and a prefixed token.
    v_try := regexp_replace(v_raw, '/+$', '');
    v_try := btrim(regexp_replace(v_try, '^.*[/:]', ''));
    if v_try = '' then
      return;
    end if;
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
       and upper(t.code) = upper(v_try)
       and app.can_read_module(t.org_id, 'pos');
end;
$$;

revoke all on function public.pos_table_by_code(uuid, text) from public, anon;
grant execute on function public.pos_table_by_code(uuid, text) to authenticated;

comment on function public.pos_table_by_code(uuid, text) is
  'The table a scanned card, QR sticker or typed code names, with how many bills are already open on it. Tries the string as scanned before treating it as a URL or a prefixed token, so a code that legitimately contains a slash is not stripped down to something else.';
