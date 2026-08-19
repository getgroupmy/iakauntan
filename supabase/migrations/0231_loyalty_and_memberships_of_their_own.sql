-- ---------------------------------------------------------------------
-- 0231  Loyalty and memberships become modules of their own
-- ---------------------------------------------------------------------
--
-- Both were built inside `pos` and gated by it, which made them free
-- with the till and unavailable without it. Neither matches how they
-- are sold: a salon runs memberships and a minimart runs a points card,
-- and a shop that wants only the till should not be paying for either.
--
-- ## What "separate" has to mean to be worth anything
--
-- Registering two codes changes nothing on its own. The gate is the
-- guard inside each SECURITY DEFINER function, because those bypass RLS
-- by definition -- a policy on `loyalty_accounts` does not stop
-- `enrol_loyalty_member` writing to it. So the work is thirteen guards
-- and a set of policies, and the module list is the small part.
--
-- ## Why this migration rewrites rather than restates
--
-- The alternative is to paste thirteen function bodies here with one
-- word changed in each -- six hundred lines in which the reader has to
-- find thirteen differences. This repository's objection to restatement
-- is exactly that: a diff nobody can check.
--
-- So the guards are moved by derivation. `pg_get_functiondef` returns
-- what is installed, the module argument is replaced, and the result is
-- executed. It is deterministic under CI, which applies every migration
-- in order onto an empty database, and it cannot drift from the bodies
-- it edits because it reads them.
--
-- The danger of working this way is a silent no-op: if the guard text
-- ever changes, a replace that matches nothing would quietly leave the
-- old module in place, and every one of these features would stay gated
-- on `pos` while the module list claimed otherwise. That is a hole that
-- looks like a working feature, so both blocks below refuse to finish
-- unless they actually changed something.
--
-- ## Nothing that works today stops working
--
-- Every organization with the till switched on gets both new modules
-- switched on. Shipping a migration that silently withdrew a running
-- loyalty scheme would be taking a feature away from people mid-service
-- and calling it a refactor.

-- ---------------------------------------------------------------------
-- The two new modules
-- ---------------------------------------------------------------------
insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order, is_active)
values
  ('loyalty', 'Loyalty & Points',
   'A points ledger, cards at the counter, and redemption against a bill.',
   false, 29.00, 21, true),
  ('memberships', 'Memberships & Packages',
   'Packages sold once and drawn down over time - ten cuts, a monthly facial.',
   false, 29.00, 22, true)
on conflict (code) do update
  set name          = excluded.name,
      description   = excluded.description,
      monthly_price = excluded.monthly_price,
      sort_order    = excluded.sort_order,
      is_active     = excluded.is_active;

-- ---------------------------------------------------------------------
-- Everybody who has the till keeps what they had
-- ---------------------------------------------------------------------
insert into public.org_modules (org_id, module_code, is_enabled, enabled_at, notes)
select m.org_id, x.code, true, now(),
       'Enabled by 0231: split out of the point of sale module.'
  from public.org_modules m
  cross join (values ('loyalty'), ('memberships')) as x(code)
 where m.module_code = 'pos' and m.is_enabled
on conflict (org_id, module_code) do update set is_enabled = true;

-- ---------------------------------------------------------------------
-- Moving ten guards, and adding two that were never there
-- ---------------------------------------------------------------------
do $$
declare
  v_fn      text;
  v_module  text;
  v_list    text[];
  v_before  text;
  v_after   text;
  v_moved   integer := 0;
  -- Named one by one rather than matched by a pattern.
  -- `pos_sale_member` has no "loyalty" in its name and is entirely a
  -- loyalty read; `pos_settle_loyalty` has one and is handled below,
  -- because it has no guard to move -- it is called by
  -- `complete_pos_sale` and must stay callable, just stop doing
  -- anything.
  -- `adjust_loyalty_points` and `expire_loyalty_points` are not here.
  -- They are gated by `app.can_admin` and by nothing else, so there is
  -- no module argument to move -- which means that today an owner can
  -- hand out points in a company that never bought the till. The
  -- assertion below is what found that: it fired on the first pass and
  -- the two are restated further down with a guard added rather than
  -- changed.
  v_loyalty text[] := array[
    'public.enrol_loyalty_member(uuid, text)',
    'public.loyalty_account_balance(uuid)',
    'public.loyalty_lookup(uuid, text)',
    'public.pos_sale_member(uuid)',
    'public.redeem_loyalty_points(uuid, integer)'];
  v_member text[] := array[
    'public.cover_line_with_membership(uuid, uuid)',
    'public.membership_balance(uuid)',
    'public.membership_billing_gaps(uuid)',
    'public.set_membership_status(uuid, app.pos_membership_status)',
    'public.start_membership(uuid, uuid)'];
begin
  foreach v_module in array array['loyalty', 'memberships']
  loop
    v_list := case when v_module = 'loyalty' then v_loyalty else v_member end;
    foreach v_fn in array v_list
    loop
      v_before := pg_get_functiondef(v_fn::regprocedure);

      -- Only the second argument of can_read_module / can_write_module.
      -- A blanket replace of the literal would also rewrite any other
      -- string spelled that way -- an error message, a status, a code --
      -- and silently change behaviour somewhere nobody was looking.
      v_after := regexp_replace(
        v_before,
        '(can_(read|write)_module\([^,]+,\s*)''pos''',
        '\1' || quote_literal(v_module),
        'g');

      if v_after = v_before then
        raise exception
          'FAIL 0231 found no module guard to move in %. The guard text '
          'must have changed; move it by hand rather than leaving it on '
          'the point of sale module.', v_fn
          using errcode = '23514';
      end if;

      execute v_after;
      v_moved := v_moved + 1;
    end loop;
  end loop;

  raise notice '0231 moved % function guard(s) off the pos module', v_moved;
end;
$$;

-- ---------------------------------------------------------------------
-- The two that had no module guard at all
-- ---------------------------------------------------------------------
--
-- Both are already narrower than selling -- only an owner or admin may
-- hand out or sweep points, because that is handing out money. Neither
-- checked whether the company had the feature, so an owner of a
-- company that never bought the till could still adjust a loyalty
-- ledger. Restated rather than derived, because a check that is being
-- added should be visible in the diff that adds it.
create or replace function public.adjust_loyalty_points(
  p_account uuid,
  p_points  integer,
  p_note    text)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
begin
  select a.org_id into v_org from public.loyalty_accounts a where a.id = p_account;
  if v_org is null then
    raise exception 'No such loyalty account.' using errcode = 'P0002';
  end if;

  -- The check 0231 adds.
  if not app.can_read_module(v_org, 'loyalty') then
    raise exception 'This company does not run a loyalty programme.'
      using errcode = '42501';
  end if;

  -- Deliberately narrower than selling. Handing out points is handing
  -- out money, and a cashier who can do it unwitnessed is a control
  -- nobody has.
  if not app.can_admin(v_org) then
    raise exception 'Only an owner or admin can adjust points.'
      using errcode = '42501';
  end if;
  if p_points = 0 then
    raise exception 'An adjustment of nothing is not an adjustment.'
      using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception 'Say why. An unexplained adjustment is the one the '
      'auditor asks about.' using errcode = '23514';
  end if;
  if p_points < 0 and -p_points > app.loyalty_balance(p_account) then
    raise exception 'That would take the account below zero.'
      using errcode = '23514';
  end if;

  insert into public.loyalty_entries
    (org_id, account_id, kind, points, note, created_by)
  values (v_org, p_account, 'adjust', p_points, btrim(p_note), auth.uid());

  return app.loyalty_balance(p_account);
end;
$$;

revoke all on function public.adjust_loyalty_points(uuid, integer, text)
  from public, anon;
grant execute on function public.adjust_loyalty_points(uuid, integer, text)
  to authenticated;

create or replace function public.expire_loyalty_points(p_org uuid)
returns table (
  account_id    uuid,
  contact       text,
  points        integer,
  last_activity timestamptz)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_program public.loyalty_programs;
  v_row     record;
  v_balance integer;
begin
  -- The check 0231 adds.
  if not app.can_read_module(p_org, 'loyalty') then
    return;
  end if;

  if not app.can_admin(p_org) then
    raise exception 'Only an owner or admin can expire points.'
      using errcode = '42501';
  end if;

  select * into v_program from public.loyalty_programs p
   where p.org_id = p_org and p.is_active;
  if v_program.id is null or v_program.dormancy_expiry_months is null then
    return;                       -- nothing expires
  end if;

  for v_row in
    select a.id, c.name as contact_name,
           coalesce(max(e.created_at), a.joined_on::timestamptz) as last_at
      from public.loyalty_accounts a
      join public.contacts c on c.id = a.contact_id
      left join public.loyalty_entries e on e.account_id = a.id
     where a.program_id = v_program.id
     group by a.id, c.name, a.joined_on
    having coalesce(max(e.created_at), a.joined_on::timestamptz)
             < now() - make_interval(months => v_program.dormancy_expiry_months)
  loop
    v_balance := app.loyalty_balance(v_row.id);
    if v_balance <= 0 then
      continue;
    end if;
    insert into public.loyalty_entries
      (org_id, account_id, kind, points, note, created_by)
    values (p_org, v_row.id, 'expire', -v_balance,
            format('Dormant since %s', to_char(v_row.last_at, 'DD Mon YYYY')),
            auth.uid());

    account_id := v_row.id;
    contact := v_row.contact_name;
    points := v_balance;
    last_activity := v_row.last_at;
    return next;
  end loop;
end;
$$;

revoke all on function public.expire_loyalty_points(uuid) from public, anon;
grant execute on function public.expire_loyalty_points(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What earning points is gated on
-- ---------------------------------------------------------------------
--
-- `app.pos_settle_loyalty` is called by `complete_pos_sale` on every
-- sale and takes no module argument, so the block above cannot reach
-- it. It already returns early when the company runs no programme; this
-- adds the second reason to do nothing. Written out rather than derived
-- because it gains a check rather than changing one, and a reader
-- should be able to see what a sale does when the module is off: it
-- completes, and it earns nothing.
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
begin
  select * into v_sale from public.pos_sales where id = p_sale;

  -- The module gate. A shop that has not bought loyalty still sells;
  -- the sale simply earns nothing and redeems nothing, which is the
  -- behaviour it already had when no programme was running.
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

  -- The redemption, now that the sale is real. Checked again against
  -- the ledger: the basket may have been parked for an hour, and the
  -- customer may have spent the same points at the other till.
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

  -- Earned on what was actually paid. Earning on the pre-discount
  -- basket pays points for money nobody handed over.
  v_earned := floor(greatest(coalesce(p_paid, 0), 0) * v_program.earn_points_per_myr)::integer;
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
-- And the policies on the seven tables
-- ---------------------------------------------------------------------
--
-- Derived too, and for a sharper reason than the functions. These
-- tables do not carry a uniform set of policies and must not be given
-- one:
--
--   * `loyalty_entries`, `pos_membership_sessions` and
--     `pos_membership_subscriptions` have a read policy and no write
--     policy at all. That is deliberate -- they are ledgers, written
--     only through the functions above, and a client that could write
--     them directly could hand itself points or sessions. A block that
--     said "create a read and a write policy on each" would have
--     granted exactly that.
--   * `loyalty_programs_write` is not gated on the module; it is
--     narrower. Replacing it with a module check would widen who can
--     change a company's earning rate.
--
-- So each existing policy is rebuilt as itself with one word changed,
-- and any policy that never mentioned the till's module is left alone.
do $$
declare
  r       record;
  v_qual  text;
  v_check text;
  v_sql   text;
  v_n     integer := 0;
begin
  for r in
    select p.tablename, p.policyname, p.cmd, p.qual, p.with_check, p.roles,
           case when p.tablename like 'loyalty%' then 'loyalty'
                else 'memberships' end as module
      from pg_policies p
     where p.schemaname = 'public'
       and p.tablename in ('loyalty_programs', 'loyalty_accounts', 'loyalty_entries',
                           'pos_memberships', 'membership_items',
                           'pos_membership_subscriptions', 'pos_membership_sessions')
       and (coalesce(p.qual, '') like '%''pos''%'
         or coalesce(p.with_check, '') like '%''pos''%')
  loop
    v_qual := regexp_replace(coalesce(r.qual, ''),
                '(can_(read|write)_module\([^,]+,\s*)''pos''',
                '\1' || quote_literal(r.module), 'g');
    v_check := regexp_replace(coalesce(r.with_check, ''),
                '(can_(read|write)_module\([^,]+,\s*)''pos''',
                '\1' || quote_literal(r.module), 'g');

    execute format('drop policy %I on public.%I', r.policyname, r.tablename);

    v_sql := format('create policy %I on public.%I for %s to %s using (%s)',
                    r.policyname, r.tablename, r.cmd,
                    array_to_string(r.roles, ', '), v_qual);
    if nullif(v_check, '') is not null then
      v_sql := v_sql || format(' with check (%s)', v_check);
    end if;
    execute v_sql;
    v_n := v_n + 1;
  end loop;

  -- The positive control. Zero moved would mean the pattern stopped
  -- matching, and every one of these tables would still be readable by
  -- anyone holding the till.
  if v_n = 0 then
    raise exception
      'FAIL 0231 moved no policies. The guard text must have changed; '
      'move them by hand rather than leaving them on the pos module.'
      using errcode = '23514';
  end if;
  raise notice '0231 moved % polic(ies) off the pos module', v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- The demo tenant that demonstrates loyalty needs the module
-- ---------------------------------------------------------------------
--
-- The backfill above reaches every organization that exists when this
-- migration runs. It cannot reach the demo tenants, because
-- `demo_rebuild` deletes and recreates them afterwards -- and on a
-- fresh CI stack it runs after every migration, so the warung would be
-- created with the till and without loyalty.
--
-- That is not a cosmetic problem. `app.demo_warung_loyalty` calls
-- `adjust_loyalty_points`, which as of this migration refuses a company
-- that does not hold the module, so the seed itself would fail.
--
-- Restated rather than worked around because the fix belongs where the
-- demo says what it is demonstrating: a tenant seeded to show a loyalty
-- card is a tenant that has bought loyalty.
create or replace function app.demo_warung_loyalty(
  p_org   uuid,
  p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_acct   uuid;
  v_least  integer;
  v_now    integer;
  v_target constant integer := 500;
begin
  -- Since 0231 this is a module of its own, and the seed has to say so
  -- before it can hand out a point.
  perform app.demo_modules(p_org, array['loyalty']);

  -- As the owner, because `adjust_loyalty_points` is deliberately
  -- narrower than selling: handing out points is handing out money, and
  -- a cashier who can do it unwitnessed is a control nobody has.
  perform app.demo_act_as(p_owner);

  select a.id, p.min_redeem_points into v_acct, v_least
    from public.loyalty_accounts a
    join public.loyalty_programs p on p.id = a.program_id
   where a.org_id = p_org and a.is_active and p.is_active
   limit 1;

  if v_acct is null then
    perform set_config('request.jwt.claims', '', true);
    return 'No loyalty card to top up.';
  end if;

  v_now := app.loyalty_balance(v_acct);
  if v_now < v_target then
    perform public.adjust_loyalty_points(
      v_acct, v_target - v_now,
      'Mata terkumpul sebelum sistem dipasang');
  end if;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'The card holds %s points, redeemable from %s.',
    app.loyalty_balance(v_acct), coalesce(v_least, 0));
end;
$$;

revoke all on function app.demo_warung_loyalty(uuid, uuid)
  from public, anon, authenticated;
