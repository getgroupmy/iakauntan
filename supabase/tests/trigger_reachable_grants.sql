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
-- ---------------------------------------------------------------------
create or replace view pg_temp.reachable_by_the_database as
with recursive allfns as (
  -- `oid::regprocedure::text` rather than a name built out of
  -- `pg_get_function_identity_arguments`, which carries PARAMETER NAMES
  -- ("p_term_id uuid") and so cannot be cast back to a regprocedure.
  -- The oid is what the privilege checks below use; the text is only
  -- for the sentence a failure prints.
  select p.oid, p.proname, p.prosrc, p.prosecdef,
         p.oid::regprocedure::text as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
),
exprs as (
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
select a.oid, a.sig, 'a trigger' as why
  from walk join allfns a on a.oid = walk.oid
 where not walk.is_trigger
union
select a.oid, a.sig, e.why
  from allfns a, exprs e
 where e.def ~ ('\m' || a.proname || '\s*\(');

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
  select count(*)::integer into v_n from pg_temp.reachable_by_the_database;
  perform pg_temp.check_true(
    format('the walk reaches the schema at all (%s call sites)', v_n),
    v_n >= 20);
end $$;

-- ---------------------------------------------------------------------
-- And a signed-in user can execute every one of them
-- ---------------------------------------------------------------------
do $$
declare v_left text;
begin
  select string_agg(distinct r.sig || ' (' || r.why || ')', ', ')
    into v_left
    from pg_temp.reachable_by_the_database r
   where not has_function_privilege('authenticated', r.oid, 'execute');

  if v_left is not null then
    raise exception
      'FAIL a signed-in user cannot execute what the database will call '
      'on their behalf: %', v_left
      using errcode = 'P0004';
  end if;
  raise notice
    'ok   everything a trigger, an index or a check constraint calls is '
    'callable by a signed-in user';
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
  -- 0165's event trigger has just stripped PUBLIC and anon from it, and
  -- nothing granted it to anybody, which is the state every one of the
  -- nine in 0620 arrived in.
  create table public.zz_reach_probe_t (
    id integer primary key,
    constraint zz_reach_probe_ck check (public.zz_reach_probe(id))
  );

  select exists (
    select 1 from pg_temp.reachable_by_the_database r
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
