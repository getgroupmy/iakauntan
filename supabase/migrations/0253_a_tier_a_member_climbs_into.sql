-- =====================================================================
-- A tier a member climbs into
--
-- 0212 made points a ledger and 0227 put the card at the counter. What
-- neither gave a shop is the thing customers actually talk about: that
-- somebody is *Gold*. A points balance is a number that goes up and
-- down; a tier is a name a customer keeps, and it is the half of a
-- loyalty scheme that changes how people behave.
--
-- ---------------------------------------------------------------------
-- Measured on what was earned, never on the balance
--
-- The obvious implementation is "Gold at 5,000 points" against the
-- account balance, and it is wrong in a way that takes months to
-- notice: redeeming demotes you. The scheme would punish the exact
-- behaviour it exists to encourage, and the customer who spent their
-- points on a teh tarik discovers at the counter that they are Silver
-- again.
--
-- So a tier is earned on the `earn` entries over a window, and nothing
-- a customer spends can take it away. `tier_window_months` on the
-- program says how long the window is; null means for ever, which is
-- the scheme that never demotes anybody.
--
-- ---------------------------------------------------------------------
-- A tier that does nothing is a badge
--
-- Each tier carries an `earn_multiplier`. Gold at 1.5 earns half again
-- on every ringgit, which is what makes the climb worth making. The
-- default is 1.0000 and a company with no tiers configured is exactly
-- where it was before this migration: `app.pos_settle_loyalty` looks
-- the tier up, finds nothing, multiplies by one.
--
-- The multiplication happens before the floor, not after, so a 1.5x
-- member buying something worth 7 points gets 10 and not 11 -- rounding
-- up would pay points for money nobody handed over, which is the rule
-- 0212 set when it decided to earn on what was paid rather than on the
-- basket.
-- =====================================================================

alter table public.loyalty_programs
  add column if not exists tier_window_months integer
    check (tier_window_months is null or tier_window_months > 0);

comment on column public.loyalty_programs.tier_window_months is
  'How far back the tier looks at what was earned. Null is for ever — the scheme that never demotes anybody. Twelve is the usual answer.';

create table if not exists public.loyalty_tiers (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  program_id  uuid not null references public.loyalty_programs (id) on delete cascade,
  code        text not null,
  name        text not null,

  -- Points earned in the window at or above which somebody is in this
  -- tier. The lowest tier is usually nought: everybody is Something.
  min_points  integer not null default 0 check (min_points >= 0),

  -- What a ringgit is worth to this member. One is the plain rate.
  earn_multiplier numeric(9, 4) not null default 1
                  check (earn_multiplier >= 0),

  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (program_id, code),
  -- Two tiers at the same threshold is a coin toss deciding who is
  -- Gold, and it would decide differently on different days.
  unique (program_id, min_points)
);

create index if not exists loyalty_tiers_program_idx
  on public.loyalty_tiers (program_id, min_points desc) where is_active;

comment on table public.loyalty_tiers is
  'The names a scheme gives its members, and what each is worth. Bands over points earned in the program''s window — never over the balance, because a tier that falls when somebody redeems punishes the behaviour the scheme exists to encourage.';

-- ---------------------------------------------------------------------
-- What an account earned in the window
-- ---------------------------------------------------------------------
--
-- `earn` only. An adjustment a manager makes to settle an argument is
-- not spending, and neither is an expiry; counting either would let a
-- goodwill gesture buy a tier.
create or replace function app.loyalty_earned(
  p_account uuid,
  p_months  integer default null)
returns integer
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(sum(e.points), 0)::integer
    from public.loyalty_entries e
   where e.account_id = p_account
     and e.kind = 'earn'
     and (p_months is null
          or e.created_at >= now() - make_interval(months => p_months));
$$;

revoke all on function app.loyalty_earned(uuid, integer)
  from public, anon, authenticated;

-- The multiplier alone, with no question about who is asking.
--
-- `loyalty_member_tier` below is for a screen and checks
-- `can_read_module` as every screen-facing function does. Settling a
-- sale must not go through that check: the offline landing path and
-- the nightly jobs have no signed-in user, and a Gold member would
-- quietly earn at the plain rate whenever their sale landed from a
-- device instead of a counter. Same answer, no audience.
create or replace function app.loyalty_multiplier(p_account uuid)
returns numeric
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(
    (select t.earn_multiplier
       from public.loyalty_tiers t
       join public.loyalty_accounts a on a.program_id = t.program_id
       join public.loyalty_programs p on p.id = a.program_id
      where a.id = p_account
        and t.is_active
        and t.min_points <= app.loyalty_earned(a.id, p.tier_window_months)
      order by t.min_points desc
      limit 1),
    1);
$$;

revoke all on function app.loyalty_multiplier(uuid)
  from public, anon, authenticated;

-- The tier itself, and how far off the next one is -- because "830
-- more points and you are Gold" is the sentence that sells the scheme,
-- and a screen cannot work it out without knowing both bands.
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
       and app.can_read_module(a.org_id, 'pos')
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

grant execute on function public.loyalty_member_tier(uuid) to authenticated;

comment on function public.loyalty_member_tier(uuid) is
  'Which tier an account is in, what it earned to get there, and how many points short of the next one — the sentence a cashier reads out.';

-- ---------------------------------------------------------------------
-- Keeping the bands
-- ---------------------------------------------------------------------
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
  if not app.can_write_module(v_prog.org_id, 'pos') then
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

revoke all on function public.upsert_loyalty_tier(
  uuid, text, text, integer, numeric, uuid, boolean) from public, anon;
grant execute on function public.upsert_loyalty_tier(
  uuid, text, text, integer, numeric, uuid, boolean) to authenticated;

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
  if not app.can_write_module(v_tier.org_id, 'pos') then
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

revoke all on function public.retire_loyalty_tier(uuid) from public, anon;
grant execute on function public.retire_loyalty_tier(uuid) to authenticated;

-- The bands themselves, with how many members are sitting in each --
-- the number that tells a shop whether Gold is an achievement or a
-- participation prize.
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
     and app.can_read_module(p_org, 'pos')
   order by t.is_active desc, t.min_points desc;
$$;

grant execute on function public.loyalty_tiers_admin(uuid) to authenticated;

comment on function public.loyalty_tiers_admin(uuid) is
  'Every tier a company has, retired ones included, with how many members are actually sitting in each — which is how a shop finds out whether Gold means anything.';

-- ---------------------------------------------------------------------
-- Earning at the member's own rate
-- ---------------------------------------------------------------------
--
-- Replaced whole because `create or replace` replaces whole. The only
-- change is the multiplier, and a company with no tiers gets exactly
-- what it got before: the lookup finds nothing and one is the identity.
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

-- ---------------------------------------------------------------------
-- Who may look
-- ---------------------------------------------------------------------
alter table public.loyalty_tiers enable row level security;

create policy loyalty_tiers_read on public.loyalty_tiers for select
  using (app.can_read_module(org_id, 'pos'));
create policy loyalty_tiers_write on public.loyalty_tiers for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

grant select, insert, update, delete on public.loyalty_tiers to authenticated;

create trigger set_updated_at before update on public.loyalty_tiers
  for each row execute function app.set_updated_at();
