-- ---------------------------------------------------------------------
-- 0239  TRUNCATE ignores every policy you have written
-- ---------------------------------------------------------------------
--
-- 0238 dropped the update and delete policies on `gl_entries` and
-- `gl_lines` and revoked the matching grants, and said the ledger was
-- append-only. It was not. Measured on production, as `authenticated`,
-- with 0238 already applied:
--
--     truncate public.gl_lines cascade;   -- 10 rows -> 0 rows
--
-- Row level security does not apply to TRUNCATE. There is no row to
-- filter: the command empties the table and every policy in the schema
-- is irrelevant to it. The only thing standing between a client role and
-- an empty ledger is the TRUNCATE privilege, and Supabase grants that to
-- `authenticated` on every table in `public` by default -- 238 of them
-- here, counted rather than assumed.
--
-- PostgREST has no verb that emits TRUNCATE, so this was not reachable
-- over the API as it stands. That is a property of the client in front
-- of the database, not of the database, and it is not what "append-only"
-- should mean.
--
-- ## Scope
--
-- The ledger only. TRUNCATE, and with it REFERENCES and TRIGGER, which
-- have no business being held by a client role on a set of books --
-- TRIGGER in particular is the right to attach code to the table.
--
-- The same three grants sit on 238 tables in this schema. Revoking them
-- across the board is very likely correct and is deliberately not done
-- here: it is a decision about the whole database rather than about the
-- ledger, and it belongs to whoever owns that decision, in a change that
-- can be reviewed and reverted on its own.
--
-- `service_role` and `postgres` are untouched: the revokes name
-- `authenticated, anon` and nothing else. Nothing in the schema
-- truncates either table -- checked across every migration and edge
-- function before writing this.

revoke truncate, references, trigger on public.gl_entries from authenticated, anon;
revoke truncate, references, trigger on public.gl_lines   from authenticated, anon;

-- ---------------------------------------------------------------------
-- What a client role is left holding
-- ---------------------------------------------------------------------
do $do$
declare
  v_left text;
begin
  select string_agg(distinct privilege_type, ', ' order by privilege_type)
    into v_left
    from information_schema.role_table_grants
   where grantee = 'authenticated'
     and table_schema = 'public'
     and table_name in ('gl_entries', 'gl_lines');

  if v_left is distinct from 'INSERT, SELECT' then
    raise exception
      'FAIL 0239: a client role holds % on the ledger, expected INSERT, SELECT',
      coalesce(v_left, 'nothing');
  end if;

  -- The positive control, in the same breath. Revoking everything would
  -- satisfy the check above by leaving `v_left` null, and a ledger that
  -- cannot be posted to or read is not the goal.
  if not has_table_privilege('authenticated', 'public.gl_entries', 'INSERT')
     or not has_table_privilege('authenticated', 'public.gl_lines', 'SELECT')
  then
    raise exception 'FAIL 0239: posting and reading must both survive';
  end if;

  -- `service_role` is deliberately not asserted here, and the first
  -- version of this migration got that wrong: it checked that
  -- service_role still had UPDATE on `gl_entries`, which is a fact about
  -- the environment rather than about this migration.
  --
  -- The revokes above name `authenticated, anon` and nothing else, so
  -- service_role is out of scope by construction. And the two
  -- environments genuinely differ -- on the hosted project service_role
  -- holds DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  -- on the ledger; on a freshly migrated local stack it holds none of
  -- them, and every CI run this project has ever had was green that way.
  -- Which also settles whether anything needs them: nothing does. The
  -- edge functions reach the ledger through SECURITY DEFINER functions,
  -- not through table grants.
end
$do$;
