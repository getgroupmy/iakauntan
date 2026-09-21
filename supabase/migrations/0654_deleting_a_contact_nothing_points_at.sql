-- =====================================================================
-- iAkauntan :: 0654 deleting a contact nothing points at
--
-- Asked for as: a delete button in the contacts list and on the contact
-- itself; a warning before it happens; and a refusal, said out loud,
-- when the contact has transaction data behind it.
--
-- ---------------------------------------------------------------------
-- Why this is not `delete from contacts`
--
-- The table already has the policies for it -- `contacts_delete` on
-- `app.can_write` and the module gate beside it -- so a client could
-- have issued the delete directly since the day contacts existed. The
-- reason none does is what happens underneath.
--
-- Thirty-eight foreign keys point at `public.contacts`, and they do not
-- agree about what a delete means:
--
--   * RESTRICT or NO ACTION on the documents -- sales, purchases,
--     receipts, payments, matters, POS sales. Postgres refuses, which
--     is right, and the message it gives names a constraint.
--   * SET NULL on nineteen more, including `gl_lines.contact_id`,
--     `expenses.contact_id`, `stock_lots.supplier_id` and
--     `items.preferred_supplier_id`. Postgres does NOT refuse. It
--     quietly detaches a posted ledger line from the party it was
--     posted against and the delete succeeds.
--
-- That second group is the whole reason this function exists. A
-- customer with nothing but a general-ledger history would have been
-- deleted without complaint, taking the contact off every line it
-- appeared on, and the books would still have balanced -- which is
-- exactly why nobody would have noticed for months.
--
-- ---------------------------------------------------------------------
-- Introspected, not listed
--
-- `app.contact_blockers` reads `pg_constraint` and counts rows through
-- every foreign key that points at `contacts.id`. It does not carry a
-- list of tables, and that is deliberate: this repository's recurring
-- failure is a list written out in more than one place -- `0651` put a
-- page slug in three files and missed the fourth, and `0653` had to
-- turn that into one constant. A hand-written list of thirty-eight
-- tables would be wrong the first time somebody adds the thirty-ninth,
-- and it would be wrong in the direction that deletes data.
--
-- Composite keys are read properly rather than by `conkey[1]`. `0511`'s
-- rule gives most of these tables a two-column key, `(org_id,
-- contact_id)` referencing `(org_id, id)`, and in half of them `org_id`
-- comes first -- so the naive read would have counted rows by
-- organization and answered "nothing points at this contact" for every
-- contact in a company that had any.
--
-- ---------------------------------------------------------------------
-- What CASCADE is taken to mean
--
-- Seven of the thirty-eight are declared `on delete cascade`:
-- `contact_addresses`, `contact_persons`, `activities`,
-- `collection_attempts`, `customer_portal_links`, `loyalty_accounts`
-- and `pos_membership_subscriptions`. Those are read as the contact's
-- own belongings -- the addresses are the contact's addresses -- and
-- they go with it, which is what the schema already said would happen.
--
-- They are not counted as blockers, and that is a judgement rather than
-- a fact. A loyalty account with points on it is arguably transaction
-- data. It is left cascading because the alternative is this migration
-- overruling seven tables' own declarations from the outside, and a
-- delete rule that disagrees with the schema is two rules.
--
-- ---------------------------------------------------------------------
-- The refusal names what is in the way
--
-- "Unable to delete, there is data" was the request; "3 sales documents
-- and 1 receipt" is the same refusal with somewhere to go afterwards.
-- The counts come back in the error message AND in `errcode 23503`, so
-- the app can tell this refusal from a permission one without reading
-- English.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What still points at a contact
-- ---------------------------------------------------------------------
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

comment on function app.contact_blockers(uuid) is
  'Counts the rows that still point at a contact, through every '
  'non-cascading foreign key on contacts.id. Read from pg_constraint '
  'rather than listed, so a table added tomorrow is covered. See 0654.';


-- ---------------------------------------------------------------------
-- What to call each of them in a sentence
-- ---------------------------------------------------------------------
--
-- A `case` over the tables somebody will actually hit, and the table
-- name with its underscores taken out for everything else. The fallback
-- is terse rather than wrong -- "forecast lines" reads perfectly well --
-- which is what lets this list be incomplete without being a bug.
create or replace function app.contact_blocker_label(p_table text,
                                                     p_count bigint)
returns text
language sql
immutable
set search_path = public, pg_temp
as $function$
  select p_count || ' ' || case
    when p_count = 1 then
      case p_table
        when 'sales_documents' then 'sales document'
        when 'purchase_documents' then 'purchase document'
        when 'receipts' then 'receipt'
        when 'purchase_payments' then 'supplier payment'
        when 'gl_lines' then 'ledger line'
        when 'expenses' then 'expense'
        when 'pos_sales' then 'counter sale'
        when 'matters' then 'matter'
        when 'projects' then 'project'
        when 'recurring_documents' then 'recurring document'
        when 'post_dated_cheques' then 'post-dated cheque'
        when 'contra_notes' then 'contra note'
        when 'deposit_notes' then 'deposit note'
        when 'tenancies' then 'tenancy'
        when 'stock_lots' then 'stock lot'
        when 'items' then 'item'
        when 'withholding_certificates' then 'withholding certificate'
        when 'received_einvoices' then 'received e-Invoice'
        else rtrim(replace(p_table, '_', ' '), 's')
      end
    else
      case p_table
        when 'sales_documents' then 'sales documents'
        when 'purchase_documents' then 'purchase documents'
        when 'receipts' then 'receipts'
        when 'purchase_payments' then 'supplier payments'
        when 'gl_lines' then 'ledger lines'
        when 'expenses' then 'expenses'
        when 'pos_sales' then 'counter sales'
        when 'matters' then 'matters'
        when 'projects' then 'projects'
        when 'recurring_documents' then 'recurring documents'
        when 'post_dated_cheques' then 'post-dated cheques'
        when 'contra_notes' then 'contra notes'
        when 'deposit_notes' then 'deposit notes'
        when 'tenancies' then 'tenancies'
        when 'stock_lots' then 'stock lots'
        when 'items' then 'items'
        when 'withholding_certificates' then 'withholding certificates'
        when 'received_einvoices' then 'received e-Invoices'
        else replace(p_table, '_', ' ')
      end
  end;
$function$;


-- ---------------------------------------------------------------------
-- The delete itself
-- ---------------------------------------------------------------------
create or replace function public.delete_contact(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $function$
declare
  v_org uuid;
  v_name text;
  v_blockers jsonb;
  v_parts text[] := array[]::text[];
  r record;
begin
  select org_id, name into v_org, v_name
    from public.contacts where id = p_id;

  -- Absent rather than refused, and said as absent. Somebody deleting
  -- the same contact twice from two tabs is the ordinary way to get
  -- here, and "you may not" would send them looking for a permission
  -- they have.
  if v_org is null then
    raise exception 'That contact has already been deleted'
      using errcode = 'P0002';
  end if;

  -- Both guards, because the table has both policies and this function
  -- runs as its definer -- so neither of them applies to the delete
  -- below unless it is asked here. A SECURITY DEFINER function that
  -- forgets one is a way round RLS rather than a wrapper over it.
  if not app.can_write(v_org) then
    raise exception 'Deleting a contact needs permission to change this '
                    'company''s records'
      using errcode = '42501';
  end if;
  if not app.can_write_module(v_org, 'contacts') then
    raise exception 'The contacts module is not switched on for this company'
      using errcode = '42501';
  end if;

  v_blockers := app.contact_blockers(p_id);

  if v_blockers <> '{}'::jsonb then
    for r in select key, value::text::bigint as n
               from jsonb_each(v_blockers)
              order by value::text::bigint desc, key
    loop
      v_parts := v_parts || app.contact_blocker_label(r.key, r.n);
    end loop;

    -- The counts in the message, because "there is data" leaves
    -- somebody with a contact they cannot delete and nowhere to look.
    -- `23503` so the app can tell this from the permission refusals
    -- above without reading the sentence.
    raise exception '% cannot be deleted while it still has %',
                    coalesce(nullif(btrim(v_name), ''), 'That contact'),
                    array_to_string(v_parts, ', ')
      using errcode = '23503';
  end if;

  delete from public.contacts where id = p_id;

  return jsonb_build_object('deleted', true, 'name', v_name);
end;
$function$;

revoke all on function public.delete_contact(uuid) from public;
grant execute on function public.delete_contact(uuid) to authenticated;

comment on function public.delete_contact(uuid) is
  'Deletes a contact, or refuses with errcode 23503 naming what still '
  'points at it. Needed because nineteen of the foreign keys on '
  'contacts.id are ON DELETE SET NULL, so a plain delete would detach '
  'posted ledger lines and succeed. See 0654.';


-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare
  v_cascading int;
  v_blocking int;
  v_composite int;
begin
  -- The catalogue read has to find the keys at all. A `conkey[1]`
  -- version of this query finds the composite ones by their org_id
  -- column, which is a query that runs, returns rows, and counts the
  -- wrong thing -- so the count is asserted against something that
  -- cannot be satisfied by looking at the wrong column.
  select count(*) filter (where cascading),
         count(*) filter (where not cascading)
    into v_cascading, v_blocking
    from (
      select c.conrelid::regclass as tbl, a.attname as col,
             bool_and(c.confdeltype = 'c') as cascading
        from pg_constraint c
        cross join lateral unnest(c.confkey) with ordinality as f(att, ord)
        join pg_attribute a
          on a.attrelid = c.conrelid and a.attnum = c.conkey[f.ord]
       where c.contype = 'f'
         and c.confrelid = 'public.contacts'::regclass
         and f.att = (select attnum from pg_attribute
                       where attrelid = 'public.contacts'::regclass
                         and attname = 'id')
       group by c.conrelid, a.attname) q;

  if v_blocking < 20 then
    raise exception 'only % columns would block a delete, which is too '
                    'few to be the whole schema', v_blocking;
  end if;
  if v_cascading < 1 then
    raise exception 'no cascading keys found, so the catalogue read is '
                    'not distinguishing them';
  end if;

  -- And that the composite keys are among what it found. This is the
  -- assertion `conkey[1]` fails: `0511`'s keys are two columns wide and
  -- half of them name the organization first.
  select count(*) into v_composite
    from pg_constraint c
    cross join lateral unnest(c.confkey) with ordinality as f(att, ord)
   where c.contype = 'f'
     and c.confrelid = 'public.contacts'::regclass
     and array_length(c.conkey, 1) > 1
     and f.ord > 1
     and f.att = (select attnum from pg_attribute
                   where attrelid = 'public.contacts'::regclass
                     and attname = 'id');
  if v_composite < 1 then
    raise exception 'no composite key names contacts.id in second '
                    'position, so this migration is guarding against a '
                    'shape the schema no longer has';
  end if;

  -- The delete is a function rather than a policy, so the two guards
  -- have to be in its body. A SECURITY DEFINER function that forgot
  -- them would be a way round RLS that every signed-in user can call.
  if (select prosrc from pg_proc
       where oid = 'public.delete_contact(uuid)'::regprocedure)
     not like '%can_write_module%' then
    raise exception 'delete_contact does not check the module gate';
  end if;
  if (select prosrc from pg_proc
       where oid = 'public.delete_contact(uuid)'::regprocedure)
     not like '%can_write(v_org)%' then
    raise exception 'delete_contact does not check write permission';
  end if;

  -- And that anonymous callers cannot reach it.
  if has_function_privilege('anon', 'public.delete_contact(uuid)', 'execute')
  then
    raise exception 'delete_contact is callable without signing in';
  end if;
end $do$;
