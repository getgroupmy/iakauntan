-- =====================================================================
-- The gate 0253 walked past
--
-- 0231 moved loyalty out of the till's module and onto its own, and the
-- first line of `pos_settle_loyalty` became the check that says so: a
-- company that has not bought loyalty earns nothing on a sale, the same
-- as a company with no programme running.
--
-- 0253 replaced that function whole to multiply the earning by the
-- member's tier. It was written from 0212's copy -- the one that
-- predates the module split -- so the multiplier arrived and the gate
-- left with it. Every company running the till and not paying for
-- loyalty started earning points again the moment 0253 applied.
--
-- The test that caught it is `pos_loyalty.sql`'s "the till keeps
-- selling without loyalty / and the sale earns nothing", which is
-- exactly the assertion that file exists for and exactly the reason
-- these run in CI rather than by eye.
--
-- ---------------------------------------------------------------------
-- Why this is a whole function again rather than a patch
--
-- `create or replace` replaces whole; there is no way to reinstate four
-- lines of a function without restating the rest of it. What follows is
-- 0253's version with 0231's gate put back at the top and nothing else
-- touched -- the tier multiplier, the redemption re-check and the
-- flooring all stand as 0253 wrote them.
--
-- The order matters and is the order 0231 chose: the module first, then
-- the programme, then the account. Asking about the tier before asking
-- whether the company holds loyalty at all would read a table the
-- company has no business in.
-- =====================================================================

create or replace function app.pos_settle_loyalty(
  p_sale uuid,
  p_paid numeric)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale    public.pos_sales;
  v_program public.loyalty_programs;
  v_account uuid;
  v_earned  integer := 0;
  v_mult    numeric := 1;
begin
  select * into v_sale from public.pos_sales where id = p_sale;

  -- 0231's gate, restored. A shop that has not bought loyalty still
  -- sells; the sale simply earns nothing and redeems nothing, which is
  -- the behaviour it already had when no programme was running.
  if not app.can_read_module(v_sale.org_id, 'loyalty') then
    return;
  end if;

  select * into v_program from public.loyalty_programs p
   where p.org_id = v_sale.org_id and p.is_active;
  if v_program.id is null then
    return;
  end if;

  v_account := v_sale.loyalty_account_id;
  if v_account is null then
    select a.id into v_account from public.loyalty_accounts a
     where a.program_id = v_program.id
       and a.contact_id = v_sale.contact_id
       and a.is_active;
  end if;
  if v_account is null then
    return;                       -- the walk-in earns nothing
  end if;

  if coalesce(v_sale.loyalty_points_redeemed, 0) > 0 then
    if v_sale.loyalty_points_redeemed > app.loyalty_balance(v_account) then
      raise exception
        'Those points are no longer on the account. Take the redemption '
        'off and ring the sale up again.'
        using errcode = '23514';
    end if;
    insert into public.loyalty_entries
      (org_id, account_id, sale_id, kind, points, note, created_by)
    values (v_sale.org_id, v_account, p_sale, 'redeem',
            -v_sale.loyalty_points_redeemed,
            'Redeemed on ' || v_sale.sale_no, v_sale.sold_by);
  end if;

  -- The tier the member is in as the sale settles, read before this
  -- sale's own points land: a bill that crosses the threshold earns at
  -- the old rate and the next one earns at the new. Any other reading
  -- makes the rate depend on the order two tills happened to settle in.
  v_mult := app.loyalty_multiplier(v_account);

  -- Floored after the multiplier, not before. See the header: rounding
  -- up would pay points for money nobody handed over.
  v_earned := floor(greatest(coalesce(p_paid, 0), 0)
                    * v_program.earn_points_per_myr * v_mult)::integer;
  if v_earned > 0 then
    insert into public.loyalty_entries
      (org_id, account_id, sale_id, kind, points, note, created_by)
    values (v_sale.org_id, v_account, p_sale, 'earn', v_earned,
            'Earned on ' || v_sale.sale_no, v_sale.sold_by);
  end if;

  update public.pos_sales s
     set loyalty_account_id = v_account,
         loyalty_points_earned = v_earned
   where s.id = p_sale;
end;
$$;

revoke all on function app.pos_settle_loyalty(uuid, numeric)
  from public, anon, authenticated;

comment on function app.pos_settle_loyalty(uuid, numeric) is
  'Settles the points on a completed sale: the module gate from 0231, the redemption re-check from 0212, and the tier multiplier from 0253, in that order.';

-- ---------------------------------------------------------------------
-- And the module the tiers themselves hang off
-- ---------------------------------------------------------------------
--
-- The same mistake, seven more times. Every guard 0253 wrote asks about
-- `pos`, because that is what the loyalty code said before 0231 split
-- the two apart. The effect is smaller than the earning bug above --
-- nobody gets free points from it -- but it is the same wrong answer:
-- a company that runs a till and has never bought loyalty could open
-- the tier editor, name its bands and read its members' standing.
--
-- Rebuilt below with `loyalty` in place of `pos` and nothing else
-- changed. The RLS policies are dropped and recreated rather than
-- replaced because Postgres has no `create or replace policy`.

create or replace function public.loyalty_member_tier(p_account uuid)
returns table (
  tier_id      uuid,
  tier_name    text,
  multiplier   numeric,
  earned       integer,
  window_months integer,
  next_name    text,
  points_to_next integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  with acc as (
    select a.id, a.org_id, a.program_id, p.tier_window_months
      from public.loyalty_accounts a
      join public.loyalty_programs p on p.id = a.program_id
     where a.id = p_account
       and app.can_read_module(a.org_id, 'loyalty')
  ),
  earned as (
    select acc.*, app.loyalty_earned(acc.id, acc.tier_window_months) as pts
      from acc
  ),
  here as (
    select t.* from public.loyalty_tiers t, earned e
     where t.program_id = e.program_id and t.is_active
       and t.min_points <= e.pts
     order by t.min_points desc
     limit 1
  ),
  next_up as (
    select t.* from public.loyalty_tiers t, earned e
     where t.program_id = e.program_id and t.is_active
       and t.min_points > e.pts
     order by t.min_points
     limit 1
  )
  select h.id, h.name, coalesce(h.earn_multiplier, 1), e.pts,
         e.tier_window_months, n.name,
         case when n.id is null then null
              else greatest(n.min_points - e.pts, 0) end
    from earned e
    left join here    h on true
    left join next_up n on true;
$$;
create or replace function public.upsert_loyalty_tier(
  p_program    uuid,
  p_code       text,
  p_name       text,
  p_min_points integer default 0,
  p_multiplier numeric default 1,
  p_id         uuid    default null,
  p_is_active  boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_prog public.loyalty_programs;
  v_id   uuid;
begin
  select * into v_prog from public.loyalty_programs where id = p_program;
  if v_prog.id is null then
    raise exception 'No such loyalty programme.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_prog.org_id, 'loyalty') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_code, '')), '') is null
     or nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A tier needs a code and a name.' using errcode = '23514';
  end if;
  if coalesce(p_min_points, 0) < 0 then
    raise exception 'A tier cannot start below nothing.'
      using errcode = '23514';
  end if;
  -- A multiplier of nought is a tier that earns nothing, which is a
  -- punishment dressed as a reward. If a shop means "no points", the
  -- scheme itself is the place to turn earning off.
  if coalesce(p_multiplier, 1) <= 0 then
    raise exception 'A tier earns at least the plain rate of nothing above nought.'
      using errcode = '23514';
  end if;

  if p_id is null then
    insert into public.loyalty_tiers
      (org_id, program_id, code, name, min_points, earn_multiplier, is_active)
    values (v_prog.org_id, p_program, btrim(p_code), btrim(p_name),
            coalesce(p_min_points, 0), coalesce(p_multiplier, 1),
            coalesce(p_is_active, true))
    returning id into v_id;
    return v_id;
  end if;

  update public.loyalty_tiers t
     set code            = btrim(p_code),
         name            = btrim(p_name),
         min_points      = coalesce(p_min_points, t.min_points),
         earn_multiplier = coalesce(p_multiplier, t.earn_multiplier),
         is_active       = coalesce(p_is_active, t.is_active),
         updated_at      = now()
   where t.id = p_id and t.program_id = p_program;
  if not found then
    raise exception 'No such tier.' using errcode = 'P0002';
  end if;
  return p_id;
end;
$$;
create or replace function public.retire_loyalty_tier(p_tier uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_tier public.loyalty_tiers;
begin
  select * into v_tier from public.loyalty_tiers where id = p_tier;
  if v_tier.id is null then
    raise exception 'No such tier.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_tier.org_id, 'loyalty') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;

  -- Retired rather than deleted, the same rule as everywhere else:
  -- members drop to whichever band is below it, and a shop that
  -- retired one by mistake can put it back.
  update public.loyalty_tiers t
     set is_active = false, updated_at = now()
   where t.id = p_tier;
  return p_tier;
end;
$$;
create or replace function public.loyalty_tiers_admin(p_org uuid)
returns table (
  id          uuid,
  program_id  uuid,
  program     text,
  code        text,
  name        text,
  min_points  integer,
  multiplier  numeric,
  is_active   boolean,
  members     integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select t.id, t.program_id, p.name, t.code, t.name, t.min_points,
         t.earn_multiplier, t.is_active,
         (select count(*)::integer
            from public.loyalty_accounts a
           where a.program_id = t.program_id
             and a.is_active
             and app.loyalty_earned(a.id, p.tier_window_months) >= t.min_points
             and not exists (
                   select 1 from public.loyalty_tiers h
                    where h.program_id = t.program_id and h.is_active
                      and h.min_points > t.min_points
                      and app.loyalty_earned(a.id, p.tier_window_months)
                          >= h.min_points))
    from public.loyalty_tiers t
    join public.loyalty_programs p on p.id = t.program_id
   where t.org_id = p_org
     and app.can_read_module(p_org, 'loyalty')
   order by t.is_active desc, t.min_points desc;
$$;

grant execute on function public.loyalty_member_tier(uuid) to authenticated;
revoke all on function public.retire_loyalty_tier(uuid) from public, anon;
grant execute on function public.retire_loyalty_tier(uuid) to authenticated;
grant execute on function public.loyalty_tiers_admin(uuid) to authenticated;

drop policy if exists loyalty_tiers_read on public.loyalty_tiers;
drop policy if exists loyalty_tiers_write on public.loyalty_tiers;

create policy loyalty_tiers_read on public.loyalty_tiers for select
  using (app.can_read_module(org_id, 'loyalty'));
create policy loyalty_tiers_write on public.loyalty_tiers for all
  using (app.can_write_module(org_id, 'loyalty'))
  with check (app.can_write_module(org_id, 'loyalty'));

comment on table public.loyalty_tiers is
  'The bands a scheme puts its members in. Guarded on the loyalty module, not the till: 0231 separated the two and 0253 did not notice.';
