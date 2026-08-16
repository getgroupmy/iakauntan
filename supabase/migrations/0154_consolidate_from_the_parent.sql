-- =====================================================================
-- iAkauntan :: 0154 a consolidation is prepared by the parent
--
-- 0148 refuses to produce a consolidated trial balance until every
-- company in the group except the one being looked at has an owner
-- recorded. Standing in the *parent* that is exactly right. Standing in
-- a subsidiary it is nonsense, and it took shipping the ownership screen
-- to make it reachable:
--
--   Nobody has recorded who owns Top Holdings. A consolidation cannot be
--   produced without it… Record it in Settings.
--
-- Nobody owns Top Holdings. It is the top of the group; that is what
-- being the parent means. So the message asks for something that does
-- not exist, and somebody who took it at its word and recorded an owner
-- anyway would be refused again by the chain-of-holdings rule two lines
-- further down. A dead end dressed as an instruction.
--
-- The real answer is not about ownership at all. Consolidated accounts
-- are prepared by the parent — that is what consolidation *is*, and a
-- subsidiary consolidating upward would be claiming to own its own
-- owner. The refusal stands; only the sentence was wrong.
--
-- Checked before the unowned test, so the specific case answers first.
-- What is left for that test is the case it was written for: standing in
-- a company that is nobody's subsidiary, with another company in the
-- group that nobody has recorded an owner for. That message is right and
-- is unchanged.
-- =====================================================================

create or replace function public.report_group_consolidated_trial_balance(
  p_org_id uuid, p_from date default null, p_to date default current_date)
returns table (
  code                 text,
  name                 text,
  account_type         app.account_type,
  account_subtype      app.account_subtype,
  companies            integer,
  combined_balance     numeric,
  elimination          numeric,
  consolidated_balance numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_partial text;
  v_unowned text;
  v_parent  text;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;

  -- Anything short of wholly owned needs minority interest, and this
  -- does not compute one. Named rather than refused in general, because
  -- "cannot consolidate" is not an answer somebody can act on.
  select string_agg(o.name || ' (' || o.owned_percent || '%)', ', ')
    into v_partial
    from app.group_orgs(p_org_id) g
    join public.organizations o on o.id = g.org_id
   where o.id <> p_org_id and o.owned_percent is not null
     and o.owned_percent < 100;

  if v_partial is not null then
    raise exception
      'These companies are not wholly owned: %. Consolidating them needs '
      'minority interest, which is not built — the group''s share of '
      'their profit and net assets would have to be split out, and this '
      'report would understate it silently.', v_partial
      using errcode = '22000';
  end if;

  -- Standing in a subsidiary. Answered before the unowned test below,
  -- which would otherwise report the parent as having no owner — true,
  -- and not a problem, and not something anybody can fix.
  select p.name into v_parent
    from public.organizations o
    join public.organizations p on p.id = o.parent_org_id
   where o.id = p_org_id;

  if v_parent is not null then
    raise exception
      'Consolidated accounts are prepared by the parent, and this company '
      'is owned by %. Switch to it and run the report there. The combined '
      'trial balance and the inter-company check work from here.', v_parent
      using errcode = '22000';
  end if;

  select string_agg(o.name, ', ') into v_unowned
    from app.group_orgs(p_org_id) g
    join public.organizations o on o.id = g.org_id
   where o.id <> p_org_id and o.parent_org_id is null;

  if v_unowned is not null then
    raise exception
      'Nobody has recorded who owns %. A consolidation cannot be produced '
      'without it: whether the whole of a subsidiary belongs to the group '
      'is the question minority interest turns on. Record it in Settings.',
      v_unowned
      using errcode = '22000';
  end if;

  return query
  with e as (
    select g.code, sum(g.adjustment) as adjustment
      from app.group_eliminations(p_org_id, p_from, p_to) g
     group by g.code)
  select t.code, t.name, t.account_type, t.account_subtype, t.companies,
         t.closing_balance,
         coalesce(e.adjustment, 0),
         round(t.closing_balance + coalesce(e.adjustment, 0), 2)
    from public.report_group_trial_balance(p_org_id, p_from, p_to) t
    left join e on e.code = t.code
   order by t.code;
end; $$;

revoke all on function
  public.report_group_consolidated_trial_balance(uuid, date, date)
  from public, anon;
grant execute on function
  public.report_group_consolidated_trial_balance(uuid, date, date)
  to authenticated;
