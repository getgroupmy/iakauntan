-- =====================================================================
-- iAkauntan :: what the database calls on your behalf
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/trigger_reachable_grants.sql
--
-- Three screens broke on the same afternoon with three different
-- function names and one error code:
--
--   permission denied for function identifying_number          (42501)
--   permission denied for function due_date_from_terms         (42501)
--   permission denied for function purchase_document_settled_on
--
-- Adding a supplier, opening a bill, posting one. Nothing exotic, and
-- nothing that calls any of those three: the DATABASE calls them, while
-- a signed-in user is doing something else.
--
-- ## Why nothing caught it
--
-- `table_grants.sql` asks whether a table with a policy is reachable.
-- `function_grants.sql` and `scripts/check_rpc_grants.py` ask whether an
-- RPC somebody calls by name is reachable. None of them is an RPC and
-- none of them is a table. They are:
--
--   * an expression in a UNIQUE INDEX -- evaluated with the privileges
--     of whoever runs the INSERT;
--   * a call inside a BEFORE trigger function -- a trigger function
--     needs no EXECUTE to fire, which is exactly why this hides, but
--     the first thing it calls inside IS checked against the role that
--     caused the write;
--   * a function named in a CHECK constraint.
--
-- And every other file in this directory runs as the superuser, which
-- bypasses privilege checks entirely. So the whole class was invisible
-- here and visible only to somebody using the product.
--
-- Asserted for `service_role` as well as `authenticated`, because the
-- edge functions bypass row level security and do NOT bypass a function
-- privilege. `0621` found four more that way -- none of them reachable
-- yet, because no edge function writes the tables those triggers sit
-- on, which is a reason to close the door rather than a reason not to.
--
-- ## What this asserts
--
-- A walk rather than a list, because the list is what went stale. Out
-- from every non-internal trigger on a table in `public` whose function
-- is not SECURITY DEFINER, and from every index expression, CHECK
-- constraint and column default on those tables; through the calls, for
-- as long as the function doing the calling is not a definer; and at
-- every step, `authenticated` must be able to execute what it reaches.
--
-- The definer boundary is where the walk stops and it is not where the
-- requirement stops: a SECURITY DEFINER function runs as its owner, so
-- what it calls in turn is its own business -- but somebody still has
-- to be allowed to call IT.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The walk
--
-- Materialised into temp tables rather than left as a view, and the
-- call graph computed once. Written as a view first, it took three
-- minutes: the view is read four times below and each read redid a
-- recursive regex join of seven hundred function bodies against seven
-- hundred function names, at every level of the recursion. The edges
-- are the expensive part and they do not change, so they are built once
-- and the recursion walks integers.
--
-- `strpos` before the regex for the same reason: a substring search is
-- cheap and a regex is not, and the regex only has to run on the pairs
-- where the name appears at all.
-- ---------------------------------------------------------------------
-- Rebuildable, because the probe at the bottom of this file adds a
-- function and a constraint AFTER the tables are first built and the
-- whole point of it is that the walk then finds them. A view would need
-- no rebuilding and would cost three minutes; this costs a second and
-- is called twice.
create or replace procedure pg_temp.build_the_walk()
language plpgsql as $walk$
begin
  drop table if exists walk_fns;
  create temp table walk_fns as
  select p.oid, p.proname, p.prosrc, p.prosecdef,
         -- `oid::regprocedure::text` rather than a name built out of
         -- `pg_get_function_identity_arguments`, which carries PARAMETER
         -- NAMES ("p_term_id uuid") and so cannot be cast back to a
         -- regprocedure. The oid is what the privilege checks below
         -- use; the text is only for the sentence a failure prints.
         p.oid::regprocedure::text as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public');
  create index on walk_fns (oid);

-- Who calls whom, through non-definer bodies only: once a definer is
-- reached it runs as its owner, so what it calls in turn is its own
-- business. The definer itself still needs the grant, which is why it
-- is an edge rather than a dead end.
  drop table if exists walk_edges;
  create temp table walk_edges as
  select c.oid as caller, f.oid as callee
    from walk_fns c join walk_fns f on f.oid <> c.oid
   where not c.prosecdef
     and strpos(c.prosrc, f.proname) > 0
     and c.prosrc ~ ('\m' || f.proname || '\s*\(');
  create index on walk_edges (caller);

  drop table if exists walk_seeds;
  create temp table walk_seeds as
  select distinct tp.oid
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_proc tp on tp.oid = t.tgfoid
   where n.nspname = 'public' and not t.tgisinternal and not tp.prosecdef;

  drop table if exists reachable_by_the_database;
  create temp table reachable_by_the_database as
with recursive exprs as (
  select pg_get_indexdef(i.indexrelid) as def, 'an index' as why
    from pg_index i
    join pg_class c on c.oid = i.indrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
  union all
  select pg_get_constraintdef(co.oid), 'a check constraint'
    from pg_constraint co
    join pg_class c on c.oid = co.conrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and co.contype = 'c'
  union all
  select pg_get_expr(ad.adbin, ad.adrelid), 'a column default'
    from pg_attrdef ad
    join pg_class c on c.oid = ad.adrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
),
walk as (
  select oid, true as is_trigger from walk_seeds
  union
  select e.callee, false from walk w join walk_edges e on e.caller = w.oid
)
select a.oid, a.sig, 'a trigger' as why
  from walk join walk_fns a on a.oid = walk.oid
 where not walk.is_trigger
union
select a.oid, a.sig, e.why
  from walk_fns a, exprs e
 where strpos(e.def, a.proname) > 0
   and e.def ~ ('\m' || a.proname || '\s*\(');
end
$walk$;

call pg_temp.build_the_walk();

-- ---------------------------------------------------------------------
-- It reaches something, which is the assertion that stops the rest
-- being vacuous
--
-- A walk that matched nothing -- a regex typo, a schema rename -- would
-- report a clean sweep for ever. A floor rather than a pinned number:
-- fifty-nine non-definer trigger functions reach twenty-five functions
-- between them, and three more are named in index expressions and check
-- constraints. Twenty is comfortably under that and comfortably over
-- the value a broken walk returns, which is nought.
--
-- The probe at the bottom of this file is the other half, and the
-- better half: it makes a hole of exactly the shape 0620 fixed and
-- requires the walk to find it.
-- ---------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*)::integer into v_n from reachable_by_the_database;
  perform pg_temp.check_true(
    format('the walk reaches the schema at all (%s call sites)', v_n),
    v_n >= 20);
end $$;

-- ---------------------------------------------------------------------
-- Two the walk names that are not calls
--
-- A regex over a function body cannot tell a call from a sentence, and
-- two trigger functions name the right RPC inside the text of a `raise
-- exception` -- which is exactly what a good refusal does:
--
--   'SST registration is not a field to set. ... Use
--    set_sst_registration().'
--   '... the ones public.declarable_reliefs(%) lists.'
--
-- Excused by name, so that adding to the list is a decision rather than
-- a loosened pattern. And the excuse is CHECKED rather than taken: a
-- name that appears anywhere outside a quoted literal is not excused,
-- so the day one of these is really called from a trigger the exception
-- stops applying and the assertion below fires.
--
-- The direction matters. Matching the whole body over-demands -- it can
-- ask for a grant nothing needs, which is noisy and safe. Stripping the
-- literals before matching would under-demand: `execute format('select
-- app.x(...)')` is a real call inside a string, and missing one is the
-- failure this file exists to catch. So the strip is used only to
-- justify an exception, never to find one.
-- ---------------------------------------------------------------------
-- Only the bodies the walk actually reads: a non-definer trigger
-- function, or a non-definer function reachable from one. Scoping this
-- is not tidiness. `app.demo_company` really does call
-- `set_sst_registration`, and it is SECURITY DEFINER and reached by
-- nothing here -- so a predicate that looked at every function in the
-- schema would refuse to excuse a name on the strength of a call that
-- has nothing to do with triggers.
create temp table bodies_the_walk_reads as
with recursive walk as (
  select oid from walk_seeds
  union
  select e.callee from walk w join walk_edges e on e.caller = w.oid
)
select a.oid, a.prosrc
  from walk join walk_fns a on a.oid = walk.oid
 where not a.prosecdef;

create or replace function pg_temp.only_ever_in_a_message(p_name text)
returns boolean language sql stable as $fn$
  select not exists (
    select 1 from bodies_the_walk_reads b
     where regexp_replace(b.prosrc, '''[^'']*''', '', 'g')
           ~ ('\m' || p_name || '\s*\(')
  );
$fn$;

do $$
begin
  perform pg_temp.check_true(
    'set_sst_registration is named in a refusal, never called',
    pg_temp.only_ever_in_a_message('set_sst_registration'));
  perform pg_temp.check_true(
    'and declarable_reliefs likewise',
    pg_temp.only_ever_in_a_message('declarable_reliefs'));

  -- The other half: the check is capable of saying no. `uom_qty` is
  -- really called, from `app.calc_document_line`.
  perform pg_temp.check_true(
    'while something really called is not excused',
    not pg_temp.only_ever_in_a_message('uom_qty'));
end $$;

-- ---------------------------------------------------------------------
-- And every client role can execute every one of them
--
-- Both roles, because both write. `authenticated` is the product;
-- `service_role` is the edge functions, which bypass row level security
-- and do NOT bypass a function privilege -- the distinction that makes
-- this worth asserting twice rather than once.
-- ---------------------------------------------------------------------
do $$
declare
  v_role text;
  v_left text;
begin
  foreach v_role in array array['authenticated', 'service_role']
  loop
    select string_agg(distinct r.sig || ' (' || r.why || ')', ', ')
      into v_left
      from reachable_by_the_database r
     where not has_function_privilege(v_role, r.oid, 'execute')
       and not (
         r.sig ~ '\m(set_sst_registration|declarable_reliefs)\('
         and pg_temp.only_ever_in_a_message(
               substring(r.sig from '([a-z_]+)\(')));

    if v_left is not null then
      raise exception
        'FAIL % cannot execute what the database will call on its '
        'behalf: %', v_role, v_left
        using errcode = 'P0004';
    end if;
    raise notice
      'ok   everything a trigger, an index or a check constraint calls '
      'is callable by %', v_role;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- The probe: a hole of this shape is actually caught
--
-- The assertion above is a string_agg that is null when all is well,
-- and null is also what a broken query returns. So make the hole on
-- purpose: a function with no grant, named in a CHECK constraint on a
-- table created here, and rolled back with the rest of the file.
-- ---------------------------------------------------------------------
do $$
declare v_caught boolean;
begin
  create function public.zz_reach_probe(p integer)
  returns boolean language sql immutable as 'select $1 >= 0';
  -- And then CLOSED by hand, which is the whole point of the probe.
  --
  -- It used to rely on a new function arriving callable by nobody, and
  -- that premise was wrong: Supabase's default privilege grants
  -- `authenticated` EXECUTE on everything created in `public`, and
  -- `0165`'s trigger takes away only PUBLIC and `anon`. So the probe
  -- was not the hole it claimed to be, and would have passed whatever
  -- the walk did. See `supabase/tests/_local_stack.sql`.
  --
  -- `from public, anon, authenticated` in full, for the reason `0657`
  -- discovered: revoking from the PUBLIC pseudo-role does not touch a
  -- grant held directly by a role.
  revoke execute on function public.zz_reach_probe(integer)
    from public, anon, authenticated;
  create table public.zz_reach_probe_t (
    id integer primary key,
    constraint zz_reach_probe_ck check (public.zz_reach_probe(id))
  );

  -- Rebuilt, so the walk sees the table and constraint just created.
  call pg_temp.build_the_walk();

  select exists (
    select 1 from reachable_by_the_database r
     -- `regprocedure` leaves the schema off a name that is visible in
     -- the search path, so this matches the bare name too.
     where r.sig like '%zz_reach_probe(%'
       and not has_function_privilege('authenticated', r.oid, 'execute'))
    into v_caught;

  perform pg_temp.check_true(
    'a function a check constraint calls, granted to nobody, is caught',
    v_caught);

  drop table public.zz_reach_probe_t;
  drop function public.zz_reach_probe(integer);
end $$;

rollback;
