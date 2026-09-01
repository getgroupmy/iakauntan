-- ---------------------------------------------------------------------
-- 0401  The role that is nobody could write everything
-- ---------------------------------------------------------------------
--
-- `0240` swept `TRUNCATE`, `REFERENCES` and `TRIGGER` off every relation
-- in `public` for both client roles, and said explicitly what it was not
-- doing: "SELECT, INSERT, UPDATE and DELETE are not touched anywhere:
-- this migration removes no ability the application uses."
--
-- That was the right scope for `authenticated`, which writes a great
-- many of these tables through PostgREST every day. It was never the
-- right scope for `anon`.
--
-- ## Measured on the hosted project
--
--     anon holds INSERT, UPDATE or DELETE on   251 relations in public
--     of which RLS is enabled on               250
--     the one without is v_stock_valuation, a view
--     policies anywhere naming anon or public for a write ....... 0
--
-- Zero. Not one policy in the schema admits `anon` to insert, update or
-- delete anything. Every one of those 251 grants is a privilege that
-- row-level security refuses on every row, on every table, every time.
--
-- The single relation without RLS is a view, and views do not carry it —
-- `v_stock_valuation` is `security_invoker = on`, so it runs with the
-- caller's rights and the RLS on the tables underneath it applies
-- normally. Checked against the project rather than assumed, because
-- "RLS disabled" on a view is what a real exposure would also look like.
--
-- ## Why this is worth removing anyway
--
-- `0240`'s three privileges were unreachable through PostgREST — it
-- emits no verb that produces a TRUNCATE — and `0240` removed them
-- anyway, on the argument that "anything holding a connection string
-- gets the privilege, not the API's opinion of it".
--
-- These three are the opposite: PostgREST emits POST, PATCH and DELETE
-- all day. RLS is the only thing standing in front of them, which means
-- the whole of `anon`'s inability to write this database rests on every
-- policy being right, forever, on 250 tables. That is a lot to ask of a
-- single layer when the other layer costs nothing — `anon` is the role
-- for a caller who has not signed in, and there is no table in this
-- schema such a caller should write.
--
-- What they *do* legitimately reach is nine SECURITY DEFINER functions —
-- `open_shared_document`, `open_shared_ticket`, `reply_to_shared_ticket`,
-- `place_public_pos_order`, `public_pos_menu`, `corp_sign_with_link`,
-- `corp_decline_with_link`, `site_pages`, `landing_page`. All nine are
-- `prosecdef`, confirmed on the hosted project, so they write as the
-- function's owner and do not consult a grant held by `anon` at any
-- point. Revoking these cannot reach them.
--
-- ## Scope
--
-- `anon` only. `authenticated` is not named and is not affected: the
-- application writes as `authenticated` constantly, and narrowing that
-- is a table-by-table question — `0399` and `0400` are what two of those
-- answers look like — rather than one sweep.
--
-- `service_role` and `postgres` are not named either.
--
-- SELECT is not touched. Anonymous read is a real thing this application
-- does: `site_pages`, the published menu, a shared document.
-- ---------------------------------------------------------------------

do $do$
declare
  r        record;
  v_touched int := 0;
  v_privs  text[] := array['SELECT', 'INSERT', 'UPDATE', 'DELETE'];
  v_auth_before int[];
  v_auth_after  int[];
  v_anon_select_before int;
  v_anon_select_after  int;
  i int;
begin
  -- `authenticated`'s four, before. This migration must not move any of
  -- them, and saying so is the only way to know it did not.
  select array_agg(n order by ord) into v_auth_before
    from (
      select p.ord,
             count(*) filter (
               where has_table_privilege('authenticated', c.oid, p.priv)) as n
        from unnest(v_privs) with ordinality as p(priv, ord)
       cross join pg_class c
        join pg_namespace ns on ns.oid = c.relnamespace
       where ns.nspname = 'public' and c.relkind in ('r','p','v','m','f')
       group by p.ord
    ) t;

  select count(*) into v_anon_select_before
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public' and c.relkind in ('r','p','v','m','f')
     and has_table_privilege('anon', c.oid, 'SELECT');

  -- A loop rather than `revoke ... on all tables in schema public`, for
  -- `0240`'s reasons: materialized views are named explicitly, and the
  -- count of what was touched is available to assert on.
  for r in
    select c.oid::regclass as rel
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r','p','v','m','f')
     order by 1
  loop
    execute format('revoke insert, update, delete on %s from anon', r.rel);
    v_touched := v_touched + 1;
  end loop;

  if v_touched < 200 then
    raise exception
      'FAIL 0401: only % relations in public -- the revoke cannot have '
      'covered the schema', v_touched;
  end if;

  select array_agg(n order by ord) into v_auth_after
    from (
      select p.ord,
             count(*) filter (
               where has_table_privilege('authenticated', c.oid, p.priv)) as n
        from unnest(v_privs) with ordinality as p(priv, ord)
       cross join pg_class c
        join pg_namespace ns on ns.oid = c.relnamespace
       where ns.nspname = 'public' and c.relkind in ('r','p','v','m','f')
       group by p.ord
    ) t;

  select count(*) into v_anon_select_after
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public' and c.relkind in ('r','p','v','m','f')
     and has_table_privilege('anon', c.oid, 'SELECT');

  for i in 1 .. array_length(v_privs, 1) loop
    if v_auth_before[i] is distinct from v_auth_after[i] then
      raise exception
        'FAIL 0401: authenticated % went from % relations to % -- this '
        'migration names only anon', v_privs[i],
        v_auth_before[i], v_auth_after[i];
    end if;
  end loop;

  if v_anon_select_before is distinct from v_anon_select_after then
    raise exception
      'FAIL 0401: anon SELECT went from % relations to % -- reading is '
      'not what this migration takes',
      v_anon_select_before, v_anon_select_after;
  end if;

  raise notice
    '0401: revoked on % relations; authenticated unchanged at %, '
    'anon still reads %', v_touched, v_auth_after, v_anon_select_after;
end
$do$;

-- ---------------------------------------------------------------------
-- And on whatever gets created next
-- ---------------------------------------------------------------------
--
-- The revoke above is a fact about the relations that exist today.
-- Supabase's default ACL hands `anon` the data privileges on every new
-- table in `public`, so without this the next migration that creates one
-- re-opens it for that table and nothing says so. `0240` made exactly
-- this argument for its own three.
alter default privileges for role postgres in schema public
  revoke insert, update, delete on tables from anon;

do $do$
begin
  execute 'alter default privileges for role supabase_admin in schema public'
       || ' revoke insert, update, delete on tables from anon';
  raise notice '0401: supabase_admin defaults narrowed as well';
exception when insufficient_privilege or undefined_object then
  -- `0240` measured this rather than predicting it: `postgres` is not a
  -- member of `supabase_admin` and the attempt fails 42501. Left
  -- attempted-and-reported so the day that membership exists, this
  -- starts closing too. Inert while nothing in `public` is created by
  -- `supabase_admin`, which `table_grants.sql` asserts directly.
  raise notice
    '0401: could not narrow supabase_admin defaults (%), postgres '
    'defaults are the ones that govern this project', sqlerrm;
end
$do$;

-- ---------------------------------------------------------------------
-- What is left
-- ---------------------------------------------------------------------
do $do$
declare v_held int; v_offenders text;
begin
  select count(*),
         string_agg(distinct rel || ' (' || priv || ')', ', ')
    into v_held, v_offenders
    from (
      select c.oid::regclass::text as rel, p.priv
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
       cross join unnest(array['INSERT','UPDATE','DELETE']) as p(priv)
       where n.nspname = 'public' and c.relkind in ('r','p','v','m','f')
         and has_table_privilege('anon', c.oid, p.priv)
    ) held;

  if v_held > 0 then
    raise exception 'FAIL 0401: % anon write grants survived: %',
      v_held, left(v_offenders, 400);
  end if;

  -- The positive control, and the first draft of it was wrong in a way
  -- worth keeping. It asserted that `anon` could still SELECT the
  -- `site_pages` *table*, and that failed on a local stack — because
  -- `anon` never reads that table. It calls `public.site_pages()`, a
  -- SECURITY DEFINER function of the same name, which reads the table as
  -- its owner. The anonymous surface of this application is nine
  -- functions, not a set of tables, which is exactly why revoking table
  -- writes from `anon` cannot reach it.
  --
  -- So the control is the surface itself.
  if (select count(*) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('site_pages', 'landing_page',
                           'open_shared_document', 'open_shared_ticket',
                           'reply_to_shared_ticket', 'public_pos_menu',
                           'place_public_pos_order', 'corp_sign_with_link',
                           'corp_decline_with_link')
         and has_function_privilege('anon', p.oid, 'EXECUTE')) < 9
  then
    raise exception
      'FAIL 0401: anon has lost one of the nine functions that are the '
      'whole of what an anonymous caller may reach';
  end if;

  raise notice '0401: anon writes nothing in public and still reads';
end
$do$;
