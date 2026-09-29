-- =====================================================================
-- iAkauntan :: two accounts that can ring each other
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/demo_calling_pair.sql
--
-- `0724`. App Review asked for a recording of the VoIP feature, and
-- recording a call needs two accounts that can call each other. The
-- wiring is four things and the third is the one everybody forgets:
-- members of a company, the company entitled to `chat`, EACH PERSON
-- switched on in `chat_access`, and a direct conversation with exactly
-- those two in it.
--
-- What has to be true:
--
--   * ALL FOUR ARE DONE, and `app.chat_enabled` -- the gate the app
--     itself asks -- answers true for both people afterwards. Asserting
--     the gate rather than the rows is the point: the rows are how it
--     is true today.
--   * IT IS IDEMPOTENT. Run twice, one conversation. A second one
--     beside it would split the history and leave a reviewer looking at
--     the empty one.
--   * AN ACCOUNT THAT DOES NOT EXIST IS NAMED, not conjured. Creating
--     one needs the Admin API and the service role key, which is what
--     `platform-users` is for.
--   * ONLY A PLATFORM ADMIN MAY CALL IT. It writes an entitlement.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_admin  uuid := pg_temp.test_user();
  v_a      uuid;
  v_b      uuid;
  v_id     uuid;
  v_again  uuid;
  v_org    uuid;
begin
  v_a := pg_temp.another_user('review-one@iakauntan.test');
  v_b := pg_temp.another_user('review-two@iakauntan.test');

  -- -------------------------------------------------------------------
  -- Only a platform administrator
  -- -------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_a);
  begin
    perform public.demo_calling_pair(
      'review-one@iakauntan.test', 'review-two@iakauntan.test');
    raise exception 'FAIL: an ordinary member granted a chat entitlement';
  exception when sqlstate '42501' then
    raise notice 'ok   only a platform administrator may wire a pair';
  end;

  insert into public.platform_admins (user_id) values (v_admin)
  on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  -- -------------------------------------------------------------------
  -- An account that does not exist is named
  -- -------------------------------------------------------------------
  begin
    perform public.demo_calling_pair(
      'review-one@iakauntan.test', 'nobody@iakauntan.test');
    raise exception 'FAIL: wired a pair against an account that is not there';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a missing account is named rather than conjured';
  end;

  -- And two of the same person is not a pair.
  begin
    perform public.demo_calling_pair(
      'review-one@iakauntan.test', 'review-one@iakauntan.test');
    raise exception 'FAIL: wired somebody to themselves';
  exception when sqlstate '22023' then
    raise notice 'ok   a call needs two people';
  end;

  -- -------------------------------------------------------------------
  -- The four things, asserted through the gate the app asks
  -- -------------------------------------------------------------------
  v_id := public.demo_calling_pair(
    'review-one@iakauntan.test', 'review-two@iakauntan.test',
    'Apple Review Demo');
  if v_id is null then
    raise exception 'FAIL: no conversation came back';
  end if;

  select p.org_id into v_org from public.chat_participants p
   where p.conversation_id = v_id and p.user_id = v_a;

  -- `app.chat_enabled` is what `chat_start_direct` and the screens ask,
  -- and it is true only when the module, the per-person switch and the
  -- membership are all there. One assertion, three of the four things.
  perform pg_temp.check_true('the caller may chat',
    app.chat_enabled(v_org, v_a));
  perform pg_temp.check_true('and so may the person being called',
    app.chat_enabled(v_org, v_b));

  -- The fourth: exactly these two in the conversation, and no third.
  perform pg_temp.check_eq('two people in the conversation',
    (select count(*) from public.chat_participants
      where conversation_id = v_id), 2);

  -- The per-person switch specifically. It is the one that is easy to
  -- miss, and losing it would leave the three above passing on a pair
  -- who cannot see each other.
  perform pg_temp.check_eq('each person is switched on individually',
    (select count(*) from public.chat_access
      where org_id = v_org and user_id in (v_a, v_b) and is_enabled), 2);

  -- -------------------------------------------------------------------
  -- Run it again: the same conversation
  -- -------------------------------------------------------------------
  v_again := public.demo_calling_pair(
    'review-one@iakauntan.test', 'review-two@iakauntan.test',
    'Apple Review Demo');
  if v_again is distinct from v_id then
    raise exception
      'FAIL: a second call made conversation % beside %. The history '
      'would be split in half and a reviewer would open the empty one.',
      v_again, v_id;
  end if;
  perform pg_temp.check_eq('and still one company',
    (select count(*) from public.organizations
      where slug = 'apple-review-demo'), 1);

  -- The name is matched by slug, so the same company typed differently
  -- is still the same company.
  v_again := public.demo_calling_pair(
    'review-one@iakauntan.test', 'review-two@iakauntan.test',
    '  Apple   Review   Demo  ');
  if v_again is distinct from v_id then
    raise exception
      'FAIL: the same company spelled differently made a second one';
  end if;

  raise notice 'ok   two accounts can ring each other';
end;
$$;

rollback;
