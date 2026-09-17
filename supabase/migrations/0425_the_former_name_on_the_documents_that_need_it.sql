-- ---------------------------------------------------------------------
-- The former name the Act requires, on the documents it requires it on
--
-- `0377` implemented section 28(4) of the Companies Act 2016 and wrote
-- down what it is for, in these words: the former name must "appear
-- alongside the new one on every document the company issues for twelve
-- months" from the change, so "a contract, an invoice or a court filing
-- that names only the new company is defective".
--
-- It built `public.corp_display_name(entity, as_at)`, which returns
-- `Baru Sdn Bhd (formerly Lama Sdn Bhd)` for those twelve months and
-- the plain name after. `supabase/tests/corp_particulars.sql` asserts
-- all four cases: the day itself, eleven months later, the day the
-- twelve months run out, and a document dated before the change, which
-- carries the old name alone.
--
-- Nothing ever called it.
--
-- ## What that costs
--
-- `app.corp_merge_context` builds the merge fields for every generated
-- document and set `'company_name'` to `e.name` -- the bare new name.
-- `{{company_name}}` is the letterhead of all seven templates `0066`
-- ships: it is the first line of a directors' resolution, above the
-- registration number.
--
-- So for the twelve months in which the Act requires both names, every
-- board resolution this software generated named only the new company.
-- The rule was written, asserted, granted to `authenticated`, and wired
-- to nothing.
--
-- ## How it was found
--
-- Not by reading. Every SECURITY DEFINER function in `public` with
-- EXECUTE granted to `authenticated` -- five hundred and fifty-two --
-- against every mention of its name in `app/lib` and
-- `supabase/functions`. Four are never named by either.
--
-- `corp_issued_capital` and `pos_item_portions` are called from other
-- SQL and hold the grant only because `0023`'s sweep grants to
-- everything; they are reachable and are not findings.
-- `corp_display_name` is this one. The fourth is `fs_set_entity`, which
-- attaches a set of accounts to the company it belongs to and has no
-- door either -- so `report_fs_deadlines` falls back to the
-- organization's own name for every filing, always. That is a separate
-- piece of work and is recorded rather than half-done here.
--
-- The seven sweeps in `docs/unreachable.md` could not have found this.
-- They start from what Dart declares and look for what nothing
-- references. This starts from what the database offers and looks for
-- what nothing calls, which is the opposite direction and the one that
-- hides a function nobody ever wrote a repository method for.
--
-- ## What changes
--
-- The letterhead of a generated document, for companies that renamed
-- within the last twelve months, and for nobody else:
-- `corp_display_name` returns `e.name` unchanged when there is no
-- former name, no change date, or the twelve months have run out. The
-- demo tenants have no renames, so no seeded document moves.
--
-- The guard cannot refuse anything: `corp_generate_document` already
-- requires `app.can_write`, and `corp_display_name` requires
-- `app.is_org_member`, which is weaker. `corp_merge_context` already
-- calls `public.corp_issued_capital` the same way.
-- ---------------------------------------------------------------------

create or replace function app.corp_merge_context(p_entity_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  e public.corp_entities;
  v jsonb;
  v_directors text;
  v_secretaries text;
  v_members text;
  v_capital text;
begin
  select * into e from public.corp_entities where id = p_entity_id;
  if e.id is null then
    raise exception 'Entity not found' using errcode = 'P0002';
  end if;

  select string_agg(p.full_name || coalesce(' (' || p.nric || ')', ''), E'\n')
    into v_directors
    from public.corp_officers o
    join public.corp_persons p on p.id = o.person_id
   where o.entity_id = p_entity_id and o.role = 'director'
     and o.resigned_on is null;

  select string_agg(p.full_name ||
           coalesce(' (' || o.licence_body || ' ' || o.licence_no || ')', ''), E'\n')
    into v_secretaries
    from public.corp_officers o
    join public.corp_persons p on p.id = o.person_id
   where o.entity_id = p_entity_id and o.role = 'secretary'
     and o.resigned_on is null;

  select string_agg(format('%s — %s %s shares (%s%%)',
           r.member_name, to_char(r.shares, 'FM999,999,999,990'),
           r.share_class, to_char(r.percent, 'FM990.00')), E'\n')
    into v_members
    from public.corp_register_of_members(p_entity_id) r;

  select string_agg(format('%s: %s shares for %s',
           c.share_class, to_char(c.shares, 'FM999,999,999,990'),
           to_char(c.consideration, 'FM"RM "999,999,999,990.00')), E'\n')
    into v_capital
    from public.corp_issued_capital(p_entity_id) c;

  -- FM on the date masks: to_char pads month names to nine characters,
  -- so a plain 'DD Month YYYY' produces "12 March     2024" in the
  -- middle of a resolution.
  v := jsonb_build_object(
    -- Not `e.name`. Section 28(4) requires the former name alongside
    -- the new one on every document the company issues for twelve
    -- months, and `corp_display_name` is where `0377` put that
    -- rule. `{{company_name}}` is the letterhead of every template,
    -- which is exactly where the Act wants it.
    --
    -- Dated `app.today()` rather than left to the default, which is
    -- the same value: the document says `Dated this {{today}}` two
    -- keys below, and a document whose letterhead and date read
    -- from different clocks is the defect `0419` spent four
    -- migrations removing.
    'company_name',        public.corp_display_name(e.id, app.today()),
    'registration_no',     coalesce(e.registration_no, ''),
    'old_registration_no', coalesce(e.old_registration_no, ''),
    'entity_type',         case e.entity_type
                             when 'sdn_bhd' then 'Private company limited by shares (Sdn Bhd)'
                             when 'berhad'  then 'Public company (Berhad)'
                             when 'llp'     then 'Limited liability partnership (PLT)'
                             when 'clbg'    then 'Company limited by guarantee'
                             else initcap(replace(e.entity_type::text, '_', ' ')) end,
    'incorporated_on',     coalesce(to_char(e.incorporated_on, 'FMDD FMMonth YYYY'), ''),
    'registered_office',   coalesce(e.registered_office, ''),
    'business_address',    coalesce(e.business_address, ''),
    'nature_of_business',  coalesce(e.nature_of_business, ''),
    'financial_year_end',  coalesce(
        to_char(app.corp_fye(e, extract(year from app.today())::int),
                'FMDD FMMonth'), ''),
    'directors',           coalesce(v_directors, ''),
    'secretaries',         coalesce(v_secretaries, ''),
    'members',             coalesce(v_members, ''),
    'issued_capital',      coalesce(v_capital, ''),
    'today',               to_char(app.today(), 'FMDD FMMonth YYYY'),
    'today_iso',           to_char(app.today(), 'YYYY-MM-DD'));

  return v;
end;
$$;

-- ---------------------------------------------------------------------
-- And it is actually wired, not merely available
--
-- The defect was a function that existed, was asserted, and was called
-- by nothing. An assertion that `corp_display_name` still returns the
-- right string would not have caught it and did not. This one asks
-- whether the merge context reaches it at all.
-- ---------------------------------------------------------------------
do $$
begin
  if (select regexp_replace(p.prosrc, '--[^\n]*', '', 'g')
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app' and p.proname = 'corp_merge_context')
     !~ '\mcorp_display_name\M' then
    raise exception
      'FAIL 0425: app.corp_merge_context does not call '
      'corp_display_name, so the former name s.28(4) requires is not on '
      'the document.' using errcode = '23514';
  end if;
end $$;
