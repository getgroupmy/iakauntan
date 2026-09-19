-- =====================================================================
-- iAkauntan :: 0656 a to-do about somebody
--
-- Asked for as: the "add to the list" popup should have an option to
-- link to contacts.
--
-- ---------------------------------------------------------------------
-- A key, where `link` is a route
--
-- `0526` gave a to-do a `link`: the ADDRESS inside the app of whatever
-- it is about, deliberately not a foreign key, because the thing
-- somebody wants to come back to is as often a screen as a row and a
-- key would have to be to one table.
--
-- That argument is still right and it is not the argument for this.
-- "Chase Ramli" is about a PARTY, not a screen, and a route cannot
-- answer the two questions a party can:
--
--   * what is still open against this customer -- which needs a column
--     to filter on, not a string to parse;
--   * what happens when that contact is deleted. A route to a contact
--     that no longer exists is a link to a page that will not open, and
--     nothing knows. `0654` now refuses to delete a contact anything
--     points at, and a to-do is deliberately NOT one of those things --
--     see below.
--
-- So both. `link` stays what it is, and `contact_id` is the party.
--
-- ---------------------------------------------------------------------
-- ON DELETE SET NULL, and it is not an oversight
--
-- `0654` blocks deleting a contact that any non-cascading key points
-- at, and its rule for which keys count is read out of the catalogue --
-- so a new key here would silently join that list. A to-do must not:
-- "ring Ramli back", left over from a contact somebody is tidying up,
-- is not a reason to refuse the tidying. The note survives with its
-- party cleared, which is the honest outcome.
--
-- `0654` reads `confdeltype = 'c'` -- cascade -- as "the contact's own
-- belongings", and everything else as a blocker. SET NULL is a blocker
-- there by design, because `gl_lines.contact_id` is one. So this key
-- is added to `todos`, which `0654` will then count... and that is
-- WRONG for a private note. The exclusion is made explicit below
-- rather than by choosing a delete action that means something else.
--
-- ---------------------------------------------------------------------
-- The composite key, per `0511`
--
-- `(org_id, contact_id)` referencing `(org_id, id)`, so a to-do at one
-- company cannot name a contact at another. `on delete set null
-- (contact_id)`: the column list matters -- without it Postgres would
-- try to null `org_id` too, which is NOT NULL, and deleting a contact
-- would raise instead of clearing the reference.
-- =====================================================================

alter table public.todos
  add column if not exists contact_id uuid;

do $do$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'todos_contact_same_org') then
    alter table public.todos
      add constraint todos_contact_same_org
      foreign key (org_id, contact_id)
      references public.contacts (org_id, id) on delete set null (contact_id);
  end if;
end $do$;

comment on column public.todos.contact_id is
  'The customer or supplier this is about, if any. Separate from '
  '`link`, which is a route to a screen: this is a party, and it is '
  'what lets "what is still open against Ramli" be a filter rather '
  'than a search. Cleared rather than blocking when the contact goes. '
  'See 0656.';

-- The read the screen makes: my open items about this contact.
create index if not exists todos_contact_idx
  on public.todos (org_id, contact_id)
  where contact_id is not null;


-- ---------------------------------------------------------------------
-- And `0654` is told this key does not count
-- ---------------------------------------------------------------------
--
-- `app.contact_blockers` reads every non-cascading key out of
-- `pg_constraint`, which is what makes it survive a table added
-- tomorrow -- and is exactly why it needs telling about the one case
-- that is not a blocker. A private note mentioning a contact is not a
-- reason to refuse deleting that contact; the note keeps its words and
-- loses its party.
--
-- ONE table named, not a pattern. The moment this becomes "tables whose
-- names look personal" it stops being reviewable, and the next key
-- added to `todos`-like tables joins the exemption without anybody
-- deciding it should.
create or replace function app.contact_blockers(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  r record;
  v_count bigint;
  v_out jsonb := '{}'::jsonb;
  v_id_attnum smallint;
begin
  select attnum into v_id_attnum
    from pg_attribute
   where attrelid = 'public.contacts'::regclass and attname = 'id';

  for r in
    -- One row per referencing COLUMN, not per constraint. A column
    -- often carries two -- a single-column key and `0511`'s composite
    -- one -- and counting a table once per constraint would report
    -- twice as many documents as there are.
    --
    -- `bool_and` on the cascade test rather than `bool_or`: where two
    -- constraints disagree, the stricter one is what Postgres will
    -- enforce, so a column only counts as cascading when every key on
    -- it cascades.
    select c.conrelid::regclass as tbl,
           a.attname as col
      from pg_constraint c
      cross join lateral unnest(c.confkey) with ordinality as f(att, ord)
      join pg_attribute a
        on a.attrelid = c.conrelid and a.attnum = c.conkey[f.ord]
     where c.contype = 'f'
       and c.confrelid = 'public.contacts'::regclass
       -- The position of `contacts.id` inside the referenced key, and
       -- the column opposite it. Not `conkey[1]`: `0511`'s keys are
       -- `(org_id, contact_id)` referencing `(org_id, id)` and in half
       -- of them the organization comes first.
       and f.att = v_id_attnum
       -- 0656. A private to-do mentioning a contact is not a reason to
       -- refuse deleting that contact. The key is SET NULL and the note
       -- keeps its words; naming the table here rather than picking a
       -- delete action that means something else keeps the exemption
       -- where a reviewer will see it.
       and c.conrelid <> 'public.todos'::regclass
     group by c.conrelid, a.attname
    having bool_and(c.confdeltype = 'c') is false
     order by 1, 2
  loop
    -- `%s` on a regclass, which renders schema-qualified and quoted by
    -- itself, and `%I` on the column. Neither comes from a caller --
    -- both are read out of the catalogue a line above -- but the
    -- function is SECURITY DEFINER and building dynamic SQL any other
    -- way in one is how the next one gets it wrong.
    execute format('select count(*) from %s where %I = $1', r.tbl, r.col)
      into v_count
      using p_id;

    if v_count > 0 then
      v_out := v_out || jsonb_build_object(
        r.tbl::text,
        coalesce((v_out ->> r.tbl::text)::bigint, 0) + v_count);
    end if;
  end loop;

  return v_out;
end;
$function$;


-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_deltype "char";
begin
  -- The key exists, is composite, and nulls the CONTACT rather than
  -- trying to null `org_id` -- which is NOT NULL, so getting the
  -- column list wrong turns every contact deletion into an error.
  select confdeltype into v_deltype
    from pg_constraint where conname = 'todos_contact_same_org';
  if v_deltype is null then
    raise exception 'the to-do has no contact to be about';
  end if;
  if v_deltype <> 'n' then
    raise exception 'a to-do about a deleted contact should lose its '
                    'party, not block the deletion: got %', v_deltype;
  end if;
  if (select array_length(conkey, 1) from pg_constraint
       where conname = 'todos_contact_same_org') <> 2 then
    raise exception 'the key is not scoped to one company';
  end if;
  if (select confdelsetcols from pg_constraint
       where conname = 'todos_contact_same_org') is null then
    raise exception 'the key would try to null org_id, which is NOT NULL';
  end if;

  -- And `0654` does not count it. Asserted on the SOURCE rather than
  -- on behaviour, because the behaviour needs a company, a contact and
  -- a to-do, and `contact_delete.sql` is where that is set up.
  if (select prosrc from pg_proc
       where oid = 'app.contact_blockers(uuid)'::regprocedure)
     not like '%public.todos%' then
    raise exception 'contact_blockers would refuse to delete a contact '
                    'somebody once wrote a note about';
  end if;
  -- And still reads the catalogue rather than a list, which is the
  -- property the exemption must not quietly cost.
  if (select prosrc from pg_proc
       where oid = 'app.contact_blockers(uuid)'::regprocedure)
     not like '%pg_constraint%' then
    raise exception 'contact_blockers no longer reads the catalogue';
  end if;
end $do$;
