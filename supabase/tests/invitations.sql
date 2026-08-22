-- =====================================================================
-- iAkauntan :: letting somebody into a company, and who stays in charge
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/invitations.sql
--
-- invite_member and accept_invitation are the door into a company, and
-- neither had ever been called by a test. Two things were wrong behind
-- that, and 0284 fixes both.
--
-- The first is that the door did not open at all. The invite token came
-- from gen_random_bytes, which is pgcrypto, which lives in `extensions`
-- -- a schema this function's pinned search_path cannot see. Every
-- invitation raised `function gen_random_bytes(integer) does not exist`.
-- The very first assertion below would have caught it on the day it was
-- written.
--
-- The second is that an admin could demote the owner: through
-- invite_member, by "inviting" the owner's own address at a lesser
-- role, and equally by a direct update, because org_members_update
-- checked only app.can_admin. Nothing in the schema puts a role back to
-- owner, so it did not undo.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org      uuid;
  v_owner    uuid := pg_temp.test_user();
  v_admin    uuid;
  v_clerk    uuid;
  v_joiner   uuid;
  v_owner_em text;
  v_id       uuid;
  v_id2      uuid;
  v_token    text;
  v_role     text;
  v_demoted  boolean;
  v_promoted boolean;
  v_deleted  boolean;
  v_took     boolean;
  r          record;
begin
  v_org := pg_temp.test_org('Pintu Masuk Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  select email::text into v_owner_em from public.profiles where id = v_owner;

  v_admin  := pg_temp.another_user('admin@example.test');
  v_clerk  := pg_temp.another_user('clerk@example.test');
  v_joiner := pg_temp.another_user('joiner@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_admin, 'admin', 'active'),
         (v_org, v_clerk, 'accounts_clerk', 'active');

  -- ==================================================================
  -- An invitation can actually be issued
  -- ==================================================================
  v_id := public.invite_member(v_org, 'Joiner@Example.test', 'sales');
  select * into r from public.org_members where id = v_id;
  perform pg_temp.check_true('an invitation is issued', v_id is not null);
  perform pg_temp.check_eq('with a token to accept it with',
    length(r.invite_token), 64);
  perform pg_temp.check_eq('the address, folded to lower case',
    r.invited_email::text, 'joiner@example.test');
  perform pg_temp.check_eq('the role it was offered at', r.role::text, 'sales');
  perform pg_temp.check_eq('and it is not a membership yet',
    r.status::text, 'invited');
  perform pg_temp.check_true('nobody is attached to it', r.user_id is null);
  perform pg_temp.check_eq('recording who sent it', r.invited_by, v_owner);
  perform pg_temp.check_true('and it runs out in a fortnight',
    r.invite_expires_at between now() + interval '13 days'
                           and now() + interval '15 days');
  v_token := r.invite_token;

  -- ==================================================================
  -- Who may send one
  -- ==================================================================
  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform public.invite_member(v_org, 'anybody@example.test', 'viewer');
    raise exception 'FAIL: a clerk invited somebody into the company';
  exception when sqlstate '42501' then
    raise notice 'ok   only an owner or admin may invite';
  end;

  perform pg_temp.sign_in_as(v_owner);
  begin
    perform public.invite_member(v_org, 'someone@example.test', 'owner');
    v_took := true;
  exception when others then v_took := false;
  end;
  perform pg_temp.check_true('ownership is not something you invite somebody to',
    not v_took);

  begin
    perform public.invite_member(v_org, '   ', 'viewer');
    v_took := true;
  exception when others then v_took := false;
  end;
  perform pg_temp.check_true('an invitation needs an address', not v_took);

  -- ==================================================================
  -- The owner keeps the company
  -- ==================================================================
  perform pg_temp.sign_in_as(v_admin);
  begin
    perform public.invite_member(v_org, v_owner_em, 'viewer');
    raise exception 'FAIL: an admin demoted the owner through invite_member';
  exception when sqlstate '42501' then
    raise notice 'ok   an admin cannot demote the owner by re-inviting them';
  end;
  perform pg_temp.check_eq('and the owner is still the owner',
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_owner), 'owner');

  -- The same attempt without the function, which is the route the fix
  -- to invite_member alone would have left open. Under `authenticated`,
  -- because as the database owner there are no policies to disobey.
  begin
    set local role authenticated;
    v_role := current_user;
    begin
      update public.org_members set role = 'viewer'
       where org_id = v_org and user_id = v_owner;
      v_demoted := found;
    exception when others then v_demoted := false;
    end;
    begin
      update public.org_members set role = 'owner'
       where org_id = v_org and user_id = v_admin;
      v_promoted := found;
    exception when others then v_promoted := false;
    end;
    begin
      delete from public.org_members
       where org_id = v_org and user_id = v_owner;
      v_deleted := found;
    exception when others then v_deleted := false;
    end;
  end;
  reset role;

  perform pg_temp.check_eq('the policy test ran under row level security',
    v_role, 'authenticated');
  perform pg_temp.check_true('an admin cannot demote the owner by hand either',
    not v_demoted);
  perform pg_temp.check_true('nor promote themselves into the owner''s chair',
    not v_promoted);
  perform pg_temp.check_true('nor delete the owner outright', not v_deleted);
  perform pg_temp.check_eq('the owner is untouched by all three',
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_owner), 'owner');
  perform pg_temp.check_eq('and the admin is still an admin',
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_admin), 'admin');

  -- An admin still administers: a member who is not the owner can be
  -- re-roled, which is what the "already a member" branch is for.
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_eq('an admin may still change a member''s role',
    public.invite_member(v_org, 'clerk@example.test', 'viewer'),
    (select id from public.org_members
      where org_id = v_org and user_id = v_clerk));
  perform pg_temp.check_eq('and the role took', 
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_clerk), 'viewer');

  -- ==================================================================
  -- Accepting
  -- ==================================================================
  perform pg_temp.sign_out();
  begin
    perform public.accept_invitation(v_token);
    raise exception 'FAIL: an invitation was accepted by nobody at all';
  exception when sqlstate '42501' then
    raise notice 'ok   an invitation is accepted by somebody signed in';
  end;

  perform pg_temp.sign_in_as(v_joiner);
  begin
    perform public.accept_invitation('not-a-real-token');
    v_took := true;
  exception when others then v_took := false;
  end;
  perform pg_temp.check_true('a token that was never issued is refused',
    not v_took);

  perform pg_temp.check_eq('a valid token joins the company',
    public.accept_invitation(v_token), v_org);
  select * into r from public.org_members where id = v_id;
  perform pg_temp.check_eq('the invitation becomes a membership',
    r.status::text, 'active');
  perform pg_temp.check_eq('attached to whoever accepted it',
    r.user_id, v_joiner);
  perform pg_temp.check_true('with the date they joined',
    r.joined_at is not null);
  perform pg_temp.check_eq('at the role they were offered',
    r.role::text, 'sales');
  -- The token is spent. A link that keeps working is a link that gets
  -- forwarded.
  perform pg_temp.check_true('and the token is spent',
    r.invite_token is null);
  begin
    perform public.accept_invitation(v_token);
    v_took := true;
  exception when others then v_took := false;
  end;
  perform pg_temp.check_true('so it cannot be used twice', not v_took);

  -- An invitation that has run out is refused even though it is still
  -- sitting there unaccepted.
  perform pg_temp.sign_in_as(v_owner);
  v_id2 := public.invite_member(v_org, 'late@example.test', 'viewer');
  select invite_token into v_token from public.org_members where id = v_id2;
  update public.org_members
     set invite_expires_at = now() - interval '1 day' where id = v_id2;
  perform pg_temp.sign_in_as(pg_temp.another_user('late@example.test'));
  begin
    perform public.accept_invitation(v_token);
    v_took := true;
  exception when others then v_took := false;
  end;
  perform pg_temp.check_true('an expired invitation is refused', not v_took);
  -- And signing up at that address does not let it in either. This is
  -- the half that was missing: app.handle_new_user claims pending
  -- invitations on signup and never looked at the expiry, so an
  -- invitation could be years stale and still hand over its role the
  -- day somebody registered. The assertion above passed against the
  -- shipped code and this one did not.
  perform pg_temp.check_eq('and signing up does not claim it either',
    (select status::text from public.org_members where id = v_id2),
    'invited');
  perform pg_temp.check_true('nobody is attached to it',
    (select user_id is null from public.org_members where id = v_id2));

  -- An invitation still in date is claimed at signup, which is the
  -- behaviour worth keeping: somebody invited before they had an
  -- account is a member the moment they make one.
  perform pg_temp.sign_in_as(v_owner);
  v_id2 := public.invite_member(v_org, 'fresh@example.test', 'purchaser');
  perform pg_temp.another_user('fresh@example.test');
  select * into r from public.org_members where id = v_id2;
  perform pg_temp.check_eq('an invitation in date is claimed at signup',
    r.status::text, 'active');
  perform pg_temp.check_eq('at the role it was issued with',
    r.role::text, 'purchaser');
  -- And the token goes with it. A spent credential left in a column is
  -- one somebody has to explain later.
  perform pg_temp.check_true('and its token is cleared',
    r.invite_token is null);

  -- ==================================================================
  -- Known and left alone: inviting one address twice
  --
  -- The insert guards on (org_id, user_id), which is null for an
  -- invitation, and null is distinct from null in a unique index -- so
  -- a second invitation to the same address makes a second row with its
  -- own token rather than replacing the first. Recorded rather than
  -- changed: re-inviting is how somebody is sent a fresh link when the
  -- first has expired, and both links landing in the same inbox is not
  -- the same kind of problem as either of the two above.
  -- ==================================================================
  perform pg_temp.sign_in_as(v_owner);
  perform public.invite_member(v_org, 'twice@example.test', 'viewer');
  perform public.invite_member(v_org, 'twice@example.test', 'viewer');
  perform pg_temp.check_eq('a second invitation makes a second row',
    (select count(*) from public.org_members
      where org_id = v_org and invited_email = 'twice@example.test'), 2);

  perform pg_temp.sign_out();
end $$;

rollback;
