-- Every function this project defines pins its search_path.
--
-- The rule is not "most of them do". A SECURITY DEFINER function with a
-- caller-controlled search_path is the standard Postgres privilege
-- escalation: the caller creates `pg_temp.round(numeric)`, calls the
-- function, and their code runs with the definer's rights. Every guard
-- in this schema — `app.can_write`, `app.is_org_member`, every posting
-- routine — is a SECURITY DEFINER function, so this is the floor the
-- whole permission model stands on.
--
-- SECURITY INVOKER functions are covered too. They cannot escalate, but
-- exempting them would mean this test says nothing about the next
-- function somebody writes, and whether that one is a definer is a
-- one-word difference in a file this test does not read.
--
-- Extension members are excluded — `citext` and `pg_trgm` are installed
-- in `public` on the hosted project and their sixty-odd C functions are
-- owned by `supabase_admin`. They are excluded by `pg_depend`, which is
-- what actually makes something part of an extension, rather than by a
-- list of names that would go stale the first time an extension is added.

\set ON_ERROR_STOP on

do $$
declare
  v_checked  integer;
  v_definer  integer;
  v_unpinned text;
begin
  select count(*),
         count(*) filter (where p.prosecdef),
         string_agg(
           case when not exists (
             select 1 from unnest(coalesce(p.proconfig, '{}')) c
              where c like 'search\_path=%')
           then n.nspname || '.' || p.proname
                || '(' || pg_get_function_identity_arguments(p.oid) || ')'
                || case when p.prosecdef then ' [SECURITY DEFINER]' else '' end
           end, e'\n  ')
    into v_checked, v_definer, v_unpinned
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app')
     and p.prokind = 'f'
     and not exists (
       select 1 from pg_depend d
        where d.objid = p.oid
          and d.classid = 'pg_proc'::regclass
          and d.deptype = 'e');

  -- The positive control. `string_agg` over nothing is null, and so is
  -- `string_agg` over a query that matched nothing at all — which is
  -- what this test silently becomes the day a schema is renamed or the
  -- extension filter grows a leg it should not have. Assert what was
  -- examined before believing what was not found.
  if v_checked < 300 then
    raise exception
      'search_path test examined only % functions in public and app — '
      'it is not looking where the functions are', v_checked;
  end if;
  if v_definer < 250 then
    raise exception
      'search_path test saw only % SECURITY DEFINER functions — '
      'the ones it exists to protect are not in the sample', v_definer;
  end if;

  if v_unpinned is not null then
    raise exception 'These functions do not pin search_path:%  %',
      e'\n', v_unpinned;
  end if;

  raise notice 'search_path: % functions pinned, % of them SECURITY DEFINER',
    v_checked, v_definer;
end $$;
