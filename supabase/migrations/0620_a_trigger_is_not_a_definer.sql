-- =====================================================================
-- iAkauntan :: 0620 a trigger is not a definer
--
-- Three screens were reported broken within a minute of each other,
-- with three different function names and one error code:
--
--   Could not create the supplier:
--     permission denied for function identifying_number   (42501)
--   Could not start it:
--     permission denied for function due_date_from_terms  (42501)
--   New Bill -> Post:
--     permission denied for function purchase_document_settled_on
--
-- Adding a supplier, opening a bill and posting one. Not edge cases.
--
-- ---------------------------------------------------------------------
-- What this is
--
-- `0618` wrote the grant that was never written for eight RPCs, and
-- `scripts/check_rpc_grants.py` was added so it could not happen again
-- to an RPC. This is the same hole through a door that script cannot
-- see: nothing here is an RPC. Nobody calls these functions. The
-- DATABASE calls them, while a signed-in user is doing something else:
--
--   * `app.identifying_number(text)` is the expression of two unique
--     indexes on `contacts` (`0481`). Inserting a contact evaluates the
--     index, and an index expression is evaluated with the privileges
--     of whoever is doing the INSERT.
--   * `app.due_date_from_terms(uuid, date)` is called by
--     `app.document_due_date_guard`, a BEFORE trigger on
--     `sales_documents` and `purchase_documents` (`0385`).
--   * `app.purchase_document_settled_on(uuid)`, `app.same_party(uuid,
--     uuid)`, `app.appraisal_part_of(...)`, `app.business_activity_of`,
--     `app.pcb_schedule_for_year`, `app.ai_arg_types` and
--     `app.einvoice_version_supported` are the same shape: called from
--     inside a trigger function, or named in a CHECK constraint.
--
-- A trigger function does not need EXECUTE to fire -- Postgres does not
-- check it -- which is exactly why this hides. The trigger fires, and
-- the first thing it calls inside is checked against the role that
-- caused the write. Nine functions, all created after `0165`'s event
-- trigger began stripping PUBLIC from everything new and after `0023`'s
-- sweep had already granted everything that existed at the time. So
-- each one arrived reachable by postgres and by nobody else, and the
-- feature it belonged to shipped green because every test in
-- `supabase/tests` runs as the superuser, which bypasses this entirely.
--
-- ---------------------------------------------------------------------
-- What is being exposed
--
-- Nothing that was not already reachable, and it is worth saying which
-- way round that is. These are derivations over rows the caller is
-- already being allowed to write: the normalised form of a number they
-- just typed, the due date implied by terms they chose, the date a bill
-- they own was settled. Each takes an id and answers about it, which is
-- `0165`'s "gated behind an unguessable uuid" -- a narrower door than
-- the RPC beside it, not a wider one.
--
-- `authenticated` and `service_role`, which is the pair `0023` granted
-- across the schema and the convention every migration since has
-- followed. Not `anon`: `statutory.sql` keeps an allowlist of what a
-- stranger may execute and none of these belongs on it.
--
-- ---------------------------------------------------------------------
-- What stops the tenth
--
-- `supabase/tests/trigger_reachable_grants.sql`, added with this. It
-- walks out from every non-definer trigger on a table in `public` and
-- from every index expression, CHECK constraint and column default,
-- follows the calls through, and fails the build on anything
-- `authenticated` cannot execute. Written as a walk rather than a list
-- because the list is what went stale.
-- =====================================================================

grant execute on function app.identifying_number(text)
  to authenticated, service_role;
grant execute on function app.due_date_from_terms(uuid, date)
  to authenticated, service_role;
grant execute on function app.purchase_document_settled_on(uuid)
  to authenticated, service_role;
grant execute on function app.same_party(uuid, uuid)
  to authenticated, service_role;
grant execute on function app.appraisal_part_of(uuid, uuid, uuid)
  to authenticated, service_role;
grant execute on function app.business_activity_of(uuid)
  to authenticated, service_role;
grant execute on function app.pcb_schedule_for_year(integer)
  to authenticated, service_role;
grant execute on function app.ai_arg_types()
  to authenticated, service_role;
grant execute on function app.einvoice_version_supported(text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- The same walk, at apply time
--
-- The test is the gate; this is the migration refusing to claim it
-- fixed something it did not. If a tenth turns up between the writing
-- of this file and its application, the apply fails and names it rather
-- than leaving a screen broken and a migration saying otherwise.
-- ---------------------------------------------------------------------
do $do$
declare v_left text;
begin
  with recursive allfns as (
    select p.oid, p.proname, p.prosrc, p.prosecdef,
           n.nspname || '.' || p.proname || '(' ||
           pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'public')
  ),
  exprs as (
    select pg_get_indexdef(i.indexrelid) as def
      from pg_index i
      join pg_class c on c.oid = i.indrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
    union all
    select pg_get_constraintdef(co.oid)
      from pg_constraint co
      join pg_class c on c.oid = co.conrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and co.contype = 'c'
    union all
    select pg_get_expr(ad.adbin, ad.adrelid)
      from pg_attrdef ad
      join pg_class c on c.oid = ad.adrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
  ),
  -- Out from the trigger functions, following calls only through
  -- functions that are NOT security definer: once a definer is reached
  -- it runs as its owner, so what it calls in turn is its own business.
  -- The definer itself still needs the grant, which is why it is
  -- reported rather than skipped.
  walk as (
    select tp.oid, true as is_trigger
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
      join pg_proc tp on tp.oid = t.tgfoid
     where n.nspname = 'public' and not t.tgisinternal and not tp.prosecdef
    union
    select f.oid, false
      from walk w
      join allfns c on c.oid = w.oid and not c.prosecdef
      join allfns f on f.oid <> c.oid
       and c.prosrc ~ ('\m' || f.proname || '\s*\(')
  )
  select string_agg(sig, ', ' order by sig) into v_left from (
    select a.sig
      from walk join allfns a on a.oid = walk.oid
     where not walk.is_trigger
       and not has_function_privilege('authenticated', a.oid, 'execute')
    union
    select a.sig
      from allfns a, exprs e
     where e.def ~ ('\m' || a.proname || '\s*\(')
       and not has_function_privilege('authenticated', a.oid, 'execute')
  ) t;

  if v_left is not null then
    raise exception
      'A signed-in user still cannot execute what a trigger, an index '
      'expression or a check constraint will call on their behalf: %',
      v_left;
  end if;
end
$do$;

comment on function app.identifying_number(text) is
  'A registration number, ID or TIN reduced to what identifies: '
  'letters and digits in upper case, or null for a placeholder (N/A, '
  'NIL, a dash) or one of LHDN''s general TINs. See 0481. Two unique '
  'indexes on contacts are written over it, so anybody who may insert '
  'a contact must be able to execute it -- 0620.';
