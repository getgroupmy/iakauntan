-- One main contact, one default delivery address.
--
-- `contact_persons.is_primary` and `contact_addresses.is_default` are
-- ordinary booleans with nothing enforcing that only one row carries
-- them. That did not matter while both tables were empty and
-- unreachable; now that there is a screen writing them, it does.
--
-- Two defaults is the same as none. Whichever row the query happens to
-- return first wins, the answer can change between two runs of the same
-- query, and the thing it decides is where goods get delivered.
--
-- The app clears the flag on the other rows before setting it, which is
-- correct and is not enough: two people editing the same customer at
-- the same time both clear, both set, and both succeed. A partial
-- unique index makes the second one fail instead, which is the outcome
-- anybody would choose if asked.

-- Both tables are empty in every environment this has run in, but a
-- unique index that fails to build leaves the migration half-applied,
-- so demote any duplicates first. Oldest row keeps the flag: it is the
-- one that has been the default for longest, and so the one other
-- people's habits are built around.
with ranked as (
  select id, row_number() over (
           partition by contact_id order by created_at, id) as rn
    from public.contact_addresses where is_default)
update public.contact_addresses a set is_default = false
  from ranked r where r.id = a.id and r.rn > 1;

with ranked as (
  select id, row_number() over (
           partition by contact_id order by created_at, id) as rn
    from public.contact_persons where is_primary)
update public.contact_persons p set is_primary = false
  from ranked r where r.id = p.id and r.rn > 1;

create unique index if not exists contact_addresses_one_default
  on public.contact_addresses (contact_id) where is_default;

create unique index if not exists contact_persons_one_primary
  on public.contact_persons (contact_id) where is_primary;
