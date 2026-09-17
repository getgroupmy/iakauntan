-- =====================================================================
-- iAkauntan :: closing an account
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/close_my_account.sql
--
-- Two assertions carry this file and they pull against each other, which
-- is the point of writing it this way:
--
--   * The identity goes. Name, email, phone and avatar are gone from
--     `profiles` and from `auth.users`, push tokens are deleted, every
--     membership stops conferring anything, and sign-in is shut.
--   * The audit trail stays. `organizations.created_by`,
--     `gl_entries.posted_by` and ninety-odd other columns still resolve
--     to the same row. A ledger that cannot say who posted an entry is
--     not evidence of anything, and destroying that is not privacy — it
--     is just destroying records the Companies Act requires kept.
--
-- Either one alone passes for the wrong reason. Scrubbing nothing keeps
-- the trail; deleting the user keeps no trail at all.
--
-- What 0619 changed, and what this file had to change with it: the
-- identity now MOVES into `account_closures` rather than being
-- overwritten, and the membership rows are suspended rather than
-- deleted. `account_closure.sql` is where that half is asserted. Here
-- the question is only the one this file has always asked -- is it gone
-- from the product -- and the answer is still yes.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.check_text(
  p_label text, p_actual text, p_expected text)
returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected %, got %',
      p_label, coalesce(p_expected, '(null)'), coalesce(p_actual, '(null)');
  end if;
  raise notice 'ok   % = %', p_label, coalesce(p_actual, '(null)');
end;
$$;

-- ---------------------------------------------------------------------
-- The sole owner is refused, and refused by name
--
-- Letting them go would leave a company's books with nobody able to
-- administer them, no way to invite a replacement and no way back in.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.another_user('solo@close.test');
  v_org   uuid;
  v_msg   text;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Solo Sdn Bhd', 'solo-' || gen_random_uuid(), 'sdn_bhd', 'MYR',
          v_owner)
  returning id into v_org;
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_owner, 'owner') on conflict do nothing;
  update public.profiles set full_name = 'Solo Owner' where id = v_owner;

  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_text('the blocker names the company',
    (select b.organization from public.my_account_deletion_blockers() b),
    'Solo Sdn Bhd');

  begin
    perform public.delete_my_account();
    v_msg := null;
  exception when sqlstate '23514' then
    v_msg := 'refused';
  end;
  -- A caught exception unwinds the sign-in with it.
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_text('and the sole owner is refused', v_msg, 'refused');

  -- The refusal is only worth having if it left everything alone, and
  -- that has to be checked against a name fixed up front — comparing the
  -- row with itself would pass whatever the function had done to it.
  perform pg_temp.check_text('nothing was scrubbed',
    (select full_name from public.profiles where id = v_owner),
    'Solo Owner');
  perform pg_temp.check_eq('and membership is intact',
    (select count(*) from public.org_members where user_id = v_owner), 1);
end $$;

-- ---------------------------------------------------------------------
-- Once somebody else can hold the company, it goes through
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.another_user('leaving@close.test');
  v_mate  uuid := pg_temp.another_user('staying@close.test');
  v_org   uuid;
  v_res   jsonb;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Shared Sdn Bhd', 'shared-' || gen_random_uuid(), 'sdn_bhd', 'MYR',
          v_owner)
  returning id into v_org;
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_owner, 'owner'), (v_org, v_mate, 'owner')
  on conflict do nothing;
  update public.profiles set full_name = 'Team Mate' where id = v_mate;
  update public.profiles set full_name = 'Leaving Person',
         email = 'leaving@close.test', phone = '+60123456789'
   where id = v_owner;
  insert into public.device_tokens (user_id, token, platform)
  values (v_owner, 'tok-' || gen_random_uuid(), 'android');

  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('nothing blocks it now',
    (select count(*) from public.my_account_deletion_blockers()), 0);

  v_res := public.delete_my_account();
  perform pg_temp.check_text('it reports what it did',
    (v_res ->> 'closed'), 'true');

  -- ------------------------------------------------------------------
  -- The identity is gone.
  -- ------------------------------------------------------------------
  perform pg_temp.check_text('the name is replaced',
    (select full_name from public.profiles where id = v_owner),
    'Closed account');
  perform pg_temp.check_true('the email is gone',
    (select email is null from public.profiles where id = v_owner));
  perform pg_temp.check_true('and the phone',
    (select phone is null from public.profiles where id = v_owner));
  perform pg_temp.check_true('the auth address is replaced with a dead one',
    (select email like 'closed-%@deleted.invalid' from auth.users
      where id = v_owner));
  perform pg_temp.check_true('and sign-in is shut',
    (select banned_until is not null from auth.users where id = v_owner));
  -- 0619: the row stays and confers nothing, rather than going. Both
  -- halves asserted, because either alone is the bug -- a deleted row
  -- loses the record that the person was ever here, and a row left
  -- 'active' leaves them holding the books they just left.
  perform pg_temp.check_eq('the membership row is kept',
    (select count(*) from public.org_members where user_id = v_owner), 1);
  perform pg_temp.check_eq('suspended rather than deleted',
    (select status::text from public.org_members where user_id = v_owner),
    'suspended');
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('and it opens nothing',
    not app.is_org_member(v_org));
  perform pg_temp.check_eq('and the devices are forgotten',
    (select count(*) from public.device_tokens where user_id = v_owner), 0);

  -- ------------------------------------------------------------------
  -- The audit trail is not.
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the company still records who created it',
    (select created_by = v_owner from public.organizations where id = v_org));
  perform pg_temp.check_true('and the user row is still there to point at',
    exists (select 1 from auth.users where id = v_owner));

  -- Nobody else was touched, which a scrub written with a missing WHERE
  -- would fail and every assertion above would still pass.
  perform pg_temp.sign_in_as(v_mate);
  perform pg_temp.check_text('the colleague is untouched',
    (select full_name from public.profiles where id = v_mate), 'Team Mate');
  perform pg_temp.check_eq('and still holds the company',
    (select count(*) from public.org_members where user_id = v_mate), 1);
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('closing is closed to anon',
    not has_function_privilege('anon',
      'public.delete_my_account()', 'execute'));
  perform pg_temp.check_true('and open to authenticated',
    has_function_privilege('authenticated',
      'public.delete_my_account()', 'execute'));
  perform pg_temp.check_true('the blockers likewise',
    has_function_privilege('authenticated',
      'public.my_account_deletion_blockers()', 'execute'));
end $$;

rollback;
