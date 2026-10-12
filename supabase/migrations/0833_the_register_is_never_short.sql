-- =====================================================================
-- iAkauntan :: 0833 the register is never short
--
-- The register of members is computed from `corp_share_events`, the
-- way the ledger computes balances from journals -- `0061`: "a register
-- that can be edited directly is a register that will drift from the
-- returns already lodged". `0064`'s trigger refuses a movement out of a
-- holding that is not there: "a register that can go negative has
-- already lied to the Registrar". But it counted the holding only up to
-- the movement's own date, and `0067`'s policy let a client update and
-- delete any movement.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`: A allotted 100 on 1 January and transferring all 100
-- to B on 1 March; a transfer of 100 from A to C dated 1 February was
-- then accepted -- A held 100 on 1 February -- and the register showed
-- A at minus 100. The movement sheet's date picker takes any past day,
-- so a secretary keying in history out of order does this through the
-- screen. The allotment edited from 100 to 10 left A at minus 190 and
-- the issued capital at 10 against 200 held; deleted, A at minus 200.
-- And a movement in one company's register named another company's
-- class of shares: Saham's issued capital said 600 while the 500 sat in
-- Lain's register.
--
-- Answered "every date, and append-only":
--
-- 1. `app.corp_check_share_event` refuses a movement that leaves the
--    holder short on its own date, as before, or on any later date the
--    holder's shares moved. A holder's movement to themselves moves
--    nothing; it had counted as shares gained.
-- 2. It refuses a class of shares that is not the company's own.
-- 3. Client update and delete are revoked and `corp_share_events_write`
--    is replaced by an insert policy with the same test. The app only
--    ever inserts, and a wrong entry is reversed by a movement the
--    other way, as the movement sheet says.
--
-- Production held eight movements on 12 October, every one an
-- allotment in a demonstration company, none leaving anybody short.
-- =====================================================================

create or replace function app.corp_check_share_event()
returns trigger language plpgsql
set search_path = public, app, pg_temp as $$
declare
  v_held  numeric;
  v_short record;
begin
  -- 0833. A movement is in the company's own shares.
  if not exists (select 1 from public.corp_share_classes c
                  where c.id = NEW.share_class_id
                    and c.entity_id = NEW.entity_id) then
    raise exception
      'That class of shares is another company''s. A movement is in '
      'the shares of the company whose register it is on.'
      using errcode = '23514';
  end if;

  if NEW.from_person_id is null then return NEW; end if;

  -- 0833: a movement from the holder to the holder moves nothing.
  select coalesce(sum(
           (case when e.to_person_id = NEW.from_person_id
                 then e.quantity else 0 end)
         - (case when e.from_person_id = NEW.from_person_id
                 then e.quantity else 0 end)), 0)
    into v_held
    from public.corp_share_events e
   where e.entity_id = NEW.entity_id
     and e.share_class_id = NEW.share_class_id
     and (e.to_person_id = NEW.from_person_id
          or e.from_person_id = NEW.from_person_id)
     and e.event_date <= NEW.event_date
     and e.id is distinct from NEW.id;

  if v_held < NEW.quantity then
    raise exception
      'Holder has % shares of that class on %, cannot move %',
      v_held, NEW.event_date, NEW.quantity using errcode = '23514';
  end if;

  -- 0833. And on every later date the holder's shares moved: the
  -- holding as it will stand with this movement in it, day by day, the
  -- first day it falls below none.
  select m.d, m.held into v_short
    from (select x.d, sum(x.delta) over (order by x.d) as held
            from (select e.event_date as d,
                         (case when e.to_person_id = NEW.from_person_id
                               then e.quantity else 0 end)
                       - (case when e.from_person_id = NEW.from_person_id
                               then e.quantity else 0 end) as delta
                    from public.corp_share_events e
                   where e.entity_id = NEW.entity_id
                     and e.share_class_id = NEW.share_class_id
                     and (e.to_person_id = NEW.from_person_id
                          or e.from_person_id = NEW.from_person_id)
                     and e.id is distinct from NEW.id
                  union all
                  select NEW.event_date, -NEW.quantity) x) m
   where m.d > NEW.event_date
     and m.held < 0
   order by m.d
   limit 1;

  if v_short.d is not null then
    raise exception
      'Moving % on % would leave the holder % short on %, when a '
      'movement already recorded moves those shares. Record movements '
      'in the order they happened, or reverse the later one first.',
      NEW.quantity, NEW.event_date, -v_short.held, v_short.d
      using errcode = '23514';
  end if;
  return NEW;
end;
$$;

comment on function app.corp_check_share_event() is
  'Before a share movement: refuses a class of shares from another '
  'company, and a movement that leaves the holder short on its own date '
  'or on any later date the holder''s shares moved. 0064, 0833.';

-- A register kept as events is added to, not edited.
revoke update, delete on public.corp_share_events from authenticated, anon;

drop policy if exists corp_share_events_write on public.corp_share_events;
create policy corp_share_events_insert on public.corp_share_events
  for insert
  with check (app.can_write(org_id) and app.has_module(org_id, 'secretarial'));
