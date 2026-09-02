-- ---------------------------------------------------------------------
-- 0451  Handing a company over
-- ---------------------------------------------------------------------
-- The primitives were all there and the operation was not. Measured on
-- `org_members`, the two policies that decide it:
--
--   delete: can_admin(org_id) and role <> 'owner'
--   update: can_admin(org_id) and (role <> 'owner' or user_id = auth.uid())
--
-- Read together those are careful and correct: **an owner row cannot be
-- deleted by anybody, and no admin can demote an owner but themselves.**
-- A company can never be orphaned, and a colleague cannot stage a coup
-- over breakfast.
--
-- The cost is that a handover is a three-step dance in a particular
-- order -- invite the new owner, demote yourself, have somebody delete
-- your ordinary row -- and it only works while the outgoing owner is
-- present and willing. If they have left the firm, left the country or
-- simply stopped answering, **nobody can do anything at all**. That is
-- the operational risk in the question this came from: a company that
-- cannot be handed to another accountant because the last one is gone.
--
-- ### What this adds
--
-- One transaction that does the dance, and a record that it happened.
--
--   * `transfer_company(org, to_email, note)` -- run by the current
--     owner. The recipient becomes owner, the caller steps down to
--     admin, the firm's borrowed access is dropped, and a row is
--     written saying who handed what to whom and when.
--   * `platform_force_transfer(org, to_email, reason)` -- the way out
--     when the owner is unreachable. Platform administrators only, and
--     it demands a reason in writing, because an escape hatch with no
--     record is indistinguishable from a back door.
--
-- Both leave the books where they are. A company was never inside a
-- firm, so a handover moves a membership and nothing else -- no data is
-- copied, exported, or re-keyed, and the ledger does not notice.
--
-- ### Why the recipient must already exist
--
-- The obvious convenience is to accept any address and send an
-- invitation. It is refused here: ownership would then sit in an
-- unaccepted invite, and a company whose only owner is an email nobody
-- has clicked is a company with no owner. The recipient signs up
-- first, and can be invited as an ordinary member in the meantime.
--
-- ### Mutants
--
-- Five run against `supabase/tests/company_handover.sql`, restated into
-- a built database rather than edited here, because the apply-time
-- guard at the foot of this file catches three of them itself and a
-- mutant a guard refuses to install has not been tested.
--
--   * the outgoing owner left as owner, so the company has two --
--     killed by "the old owner steps down to admin", which read
--     `owner`;
--   * the ownership guard dropped from `transfer_company` -- killed by
--     "an admin cannot give away what they do not own";
--   * the missing-account check dropped -- killed at "a company cannot
--     be handed to nobody", though **by `org_members_identity_ck`
--     underneath rather than by the refusal the assertion names**: with
--     the check gone the function reaches an insert with a null user
--     and the row is refused there. The test goes red either way; it is
--     the constraint doing it;
--   * `platform_force_transfer` passing null where the reason goes --
--     killed the same way, by `forced_transfer_says_why`;
--   * the blank-reason guard dropped from `platform_force_transfer`,
--     leaving only that constraint. **This one survived the assertion
--     as first written.** The call is still refused, with the same
--     SQLSTATE, because the constraint catches what the guard would
--     have -- so "a forced handover says why in writing" passed against
--     a function that no longer asks for one. Held twice is a good
--     place to be, but the two refusals do not say the same thing: one
--     tells the operator to give a reason, the other names a check
--     constraint. The assertion now reads the message, and the mutant
--     dies.
-- ---------------------------------------------------------------------

create table public.company_transfers (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id)
                  on delete cascade,
  from_user_id  uuid references auth.users (id) on delete set null,
  to_user_id    uuid not null references auth.users (id) on delete restrict,
  from_firm_id  uuid references public.firms (id) on delete set null,
  note          text,
  forced_by     uuid references auth.users (id) on delete set null,
  forced_reason text,
  created_at    timestamptz not null default now(),
  constraint forced_transfer_says_why
    check (forced_by is null or nullif(btrim(coalesce(forced_reason, '')), '')
           is not null)
);

create index company_transfers_org_idx
  on public.company_transfers (org_id, created_at desc);

alter table public.company_transfers enable row level security;

-- The company's own administrators, and the platform. Not the outgoing
-- owner once they are gone: this is the company's record, not theirs.
create policy company_transfers_select on public.company_transfers
  for select using (app.can_admin(org_id) or app.is_platform_admin());

revoke all on public.company_transfers from public;
grant select on public.company_transfers to authenticated;

create trigger audit_changes
  after insert or delete or update on public.company_transfers
  for each row execute function app.write_audit_log();

-- ---------------------------------------------------------------------
-- The handover itself
-- ---------------------------------------------------------------------
create or replace function app.hand_company_over(
  p_org_id uuid,
  p_to_user uuid,
  p_from_user uuid,
  p_note text,
  p_forced_by uuid,
  p_forced_reason text)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_firm uuid;
  v_id   uuid;
begin
  select firm_id into v_firm from public.organizations where id = p_org_id;

  -- The recipient becomes owner. If they were already a member in some
  -- other capacity they are promoted rather than duplicated, and the
  -- row stops belonging to any firm: an owner holds their place in
  -- their own right or the firm could later take the company away by
  -- resigning.
  insert into public.org_members
    (org_id, user_id, role, status, joined_at, via_firm_id)
  values (p_org_id, p_to_user, 'owner', 'active', now(), null)
  on conflict (org_id, user_id) do update
     set role = 'owner', status = 'active', via_firm_id = null;

  -- The outgoing owner steps down rather than out. Somebody has to be
  -- able to answer questions about last year, and an admin can be
  -- removed by the new owner in one click if they are not wanted.
  if p_from_user is not null then
    update public.org_members
       set role = 'admin'
     where org_id = p_org_id and user_id = p_from_user
       and role = 'owner';
  end if;

  -- Whoever was keeping the books stops keeping them. The new owner can
  -- appoint the same practice again in one call if that is the
  -- arrangement, but continuing by default would mean a handover that
  -- quietly leaves the old firm's staff logged in.
  if v_firm is not null then
    delete from public.org_members m
     where m.org_id = p_org_id and m.via_firm_id = v_firm;
    update public.organizations set firm_id = null where id = p_org_id;
  end if;

  insert into public.company_transfers
    (org_id, from_user_id, to_user_id, from_firm_id, note,
     forced_by, forced_reason)
  values (p_org_id, p_from_user, p_to_user, v_firm, p_note,
          p_forced_by, p_forced_reason)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.transfer_company(
  p_org_id uuid,
  p_to_email text,
  p_note text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_to uuid;
begin
  if not app.has_org_role(p_org_id, array['owner']::app.member_role[]) then
    raise exception
      'Only the owner may hand a company over. An administrator can '
      'run the company; giving it away is a different thing.'
      using errcode = '42501';
  end if;

  select u.id into v_to from auth.users u
   where lower(u.email) = lower(btrim(coalesce(p_to_email, '')));

  if v_to is null then
    raise exception
      'Nobody here has that address. Ask them to sign up first: a '
      'company whose owner is an unaccepted invitation has no owner.'
      using errcode = 'P0002';
  end if;

  if v_to = auth.uid() then
    raise exception 'That is already you.' using errcode = '23514';
  end if;

  return app.hand_company_over(p_org_id, v_to, auth.uid(), p_note,
                               null, null);
end;
$$;

-- ---------------------------------------------------------------------
-- And the way out when the owner has gone
-- ---------------------------------------------------------------------
create or replace function public.platform_force_transfer(
  p_org_id uuid,
  p_to_email text,
  p_reason text)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_to   uuid;
  v_from uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception
      'Say why. A forced handover with no reason recorded is not '
      'distinguishable from a back door.'
      using errcode = '23514';
  end if;

  select u.id into v_to from auth.users u
   where lower(u.email) = lower(btrim(coalesce(p_to_email, '')));
  if v_to is null then
    raise exception 'Nobody here has that address.' using errcode = 'P0002';
  end if;

  select m.user_id into v_from from public.org_members m
   where m.org_id = p_org_id and m.role = 'owner' and m.status = 'active'
   limit 1;

  return app.hand_company_over(p_org_id, v_to, v_from, null,
                               auth.uid(), btrim(p_reason));
end;
$$;

create or replace function public.company_transfer_history(p_org_id uuid)
returns table (
  at timestamptz,
  handed_by text,
  handed_to text,
  from_firm text,
  note text,
  forced_by text,
  forced_reason text)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may read the handover history'
      using errcode = '42501';
  end if;

  return query
  select t.created_at,
         coalesce(pf.full_name, pf.email, 'somebody who has since left'),
         coalesce(pt.full_name, pt.email, 'unknown'),
         f.name,
         t.note,
         pfo.full_name,
         t.forced_reason
    from public.company_transfers t
    left join public.profiles pf  on pf.id = t.from_user_id
    left join public.profiles pt  on pt.id = t.to_user_id
    left join public.profiles pfo on pfo.id = t.forced_by
    left join public.firms f      on f.id = t.from_firm_id
   where t.org_id = p_org_id
   order by t.created_at desc;
end;
$$;

revoke all on function public.transfer_company(uuid, text, text) from public;
revoke all on function public.platform_force_transfer(uuid, text, text)
  from public;
revoke all on function public.company_transfer_history(uuid) from public;

grant execute on function public.transfer_company(uuid, text, text)
  to authenticated;
grant execute on function public.platform_force_transfer(uuid, text, text)
  to authenticated;
grant execute on function public.company_transfer_history(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_hand text := pg_get_functiondef(to_regprocedure(
    'app.hand_company_over(uuid, uuid, uuid, text, uuid, text)'));
  v_pub text := pg_get_functiondef(
    to_regprocedure('public.transfer_company(uuid, text, text)'));
begin
  if position('''owner''' in v_pub) = 0 then
    raise exception '0451: anybody may hand a company over';
  end if;

  if position('set role = ''admin''' in v_hand) = 0 then
    raise exception '0451: the outgoing owner is left as owner';
  end if;

  if position('m.via_firm_id = v_firm' in v_hand) = 0 then
    raise exception
      '0451: a handover leaves the old firm''s people logged in';
  end if;

  if not exists (select 1 from pg_constraint
                  where conname = 'forced_transfer_says_why') then
    raise exception '0451: a forced handover need not say why';
  end if;
end
$do$;

comment on function public.transfer_company(uuid, text, text) is
  'Hand a company to another person in one transaction: they become '
  'owner, the caller steps down to admin, any firm''s borrowed access '
  'ends, and the handover is recorded. The books do not move because '
  'they were never anywhere else. See 0451.';
