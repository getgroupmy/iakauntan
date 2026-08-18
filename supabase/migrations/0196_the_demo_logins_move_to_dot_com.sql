-- =====================================================================
-- The demo logins move from iakauntan.my to iakauntan.com
--
-- Five shared logins — demo, clerk, auditor, secretary, property — plus
-- the platform operator, which moved separately and by hand because it
-- is not demo-flagged and nothing else referenced it.
--
-- Three things have to move together or the rename is worse than not
-- doing it at all.
--
--   * `auth.users.email`, the obvious one.
--
--   * `auth.identities.identity_data ->> 'email'`, where there is one.
--     The `email` column beside it is `generated always as
--     (lower(identity_data ->> 'email'))`, so moving `auth.users` alone
--     leaves an identity pointing at an address that no longer exists.
--
--     Where there is one: these five have none. `app.demo_user` inserts
--     straight into `auth.users`, and an identity row is something
--     GoTrue writes when it signs somebody up — so the seeded logins
--     have zero and the operator, who was signed up properly, has one.
--     The first draft of this migration asserted that the two counts
--     matched and refused to run, which was the assertion being wrong
--     rather than the data: five and zero is the correct answer here.
--     What actually has to hold is the end state, and that is what is
--     checked below.
--
--   * `app.demo_rebuild()` and `app.demo_tickets_sinar()`, which resolve
--     these people *by address* — `app.demo_user('demo@iakauntan.my',
--     'Aisyah Rahman')` finds or creates. Leave those pointing at the
--     old domain and the next rebuild does not fail; it quietly creates
--     five new `.my` users, hands them the tenants, and undoes this.
--     That is the failure worth being careful about, because everything
--     looks fine until somebody presses Rebuild weeks later.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The rows
-- ---------------------------------------------------------------------
do $rename$
declare
  v_users      integer;
  v_identities integer;
begin
  -- `app.demo_credentials_locked` refuses an email change on a
  -- demo-flagged row, and it is right to: these logins are shared, so
  -- one visitor renaming one would take the panel away from everybody.
  -- The flag comes off, the address moves, the flag goes back. The
  -- guard is not weakened and it is not routed around — it is answered.
  --
  -- The trigger reads OLD, so this has to be three statements. Folding
  -- the unflag into the rename leaves OLD still flagged and the whole
  -- thing raises 42501.
  update auth.users
     set raw_app_meta_data = raw_app_meta_data - 'demo'
   where email like '%@iakauntan.my';

  update auth.users
     set email = replace(email, '@iakauntan.my', '@iakauntan.com'),
         updated_at = now()
   where email like '%@iakauntan.my';
  get diagnostics v_users = row_count;

  update auth.identities
     set identity_data = jsonb_set(
           identity_data, '{email}',
           to_jsonb(replace(identity_data ->> 'email',
                            '@iakauntan.my', '@iakauntan.com'))),
         updated_at = now()
   where provider = 'email'
     and identity_data ->> 'email' like '%@iakauntan.my';
  get diagnostics v_identities = row_count;

  -- Named rather than matched, so the operator — already on .com and
  -- deliberately not demo — cannot be swept back into the demo set by
  -- a pattern that happens to fit.
  update auth.users
     set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
                             || jsonb_build_object('demo', true)
   where email in ('demo@iakauntan.com',
                   'clerk@iakauntan.com',
                   'auditor@iakauntan.com',
                   'secretary@iakauntan.com',
                   'property@iakauntan.com');

  -- The end state, which is the thing that actually has to hold. Not a
  -- relationship between the two counts: five users and no identities
  -- is the correct answer on this project, and demanding they match
  -- refuses to run for a reason that is not a problem.
  --
  -- Both are vacuously true on a freshly migrated stack, where nobody
  -- has signed up at all. That is correct and must not fail — this runs
  -- in CI against exactly that.
  if exists (select 1 from auth.users
              where email like '%@iakauntan.my') then
    raise exception 'a user still holds an @iakauntan.my address';
  end if;

  if exists (select 1 from auth.identities
              where identity_data ->> 'email' like '%@iakauntan.my') then
    raise exception 'an identity still names @iakauntan.my';
  end if;

  raise notice 'demo logins moved to .com: % users, % identities',
    v_users, v_identities;
end;
$rename$;

-- ---------------------------------------------------------------------
-- The functions that resolve those people by address
-- ---------------------------------------------------------------------
--
-- Rewritten from the catalogue rather than restated by hand. The two
-- definitions run to 237 lines between them and the change is one
-- literal in each; retyping them to move eleven characters invites the
-- kind of divergence that a body-hash check cannot see, which this
-- branch has already paid for once. `pg_get_functiondef` gives the
-- exact current definition, the replacement is textual, and the
-- assertions below are what make it safe to do it this way.
do $fns$
declare
  r      record;
  v_done integer := 0;
  v_left integer;
begin
  for r in
    select p.oid, n.nspname, p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where p.prosrc like '%@iakauntan.my%'
  loop
    execute replace(pg_get_functiondef(r.oid),
                    '@iakauntan.my', '@iakauntan.com');
    v_done := v_done + 1;
    raise notice 'rewrote %.%', r.nspname, r.proname;
  end loop;

  -- The positive control. An assertion that only counts what is left
  -- passes just as happily when the loop found nothing to do, and the
  -- whole point here is that two specific functions were rewritten.
  if v_done < 2 then
    raise exception
      'expected to rewrite at least 2 functions, rewrote %', v_done;
  end if;

  select count(*) into v_left
    from pg_proc p
   where p.prosrc like '%@iakauntan.my%';

  if v_left <> 0 then
    raise exception '% function(s) still name the old domain', v_left;
  end if;
end;
$fns$;
