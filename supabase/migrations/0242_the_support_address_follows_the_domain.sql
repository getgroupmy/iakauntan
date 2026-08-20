-- ---------------------------------------------------------------------
-- 0242  The support address follows the domain
-- ---------------------------------------------------------------------
--
-- 0196 moved this project from iakauntan.my to iakauntan.com: the five
-- demo logins, and the platform operator, who moved separately and by
-- hand. It did not move the support contact, which 0018 seeds into
-- `platform_settings` under the key `support` and describes as the
-- "Support contact shown in the app".
--
-- So a database built from these migrations comes up telling customers
-- to write to support@iakauntan.my, on a domain the project left. The
-- hosted project was corrected through the console, which is where that
-- setting belongs; this is the same correction for every stack built
-- from scratch afterwards.
--
-- ## Why this is not `update ... set value = '{...}'`
--
-- Two reasons, and both are about not being the last word on a setting
-- that is somebody else's to hold.
--
-- The value carries a phone as well as an address, and on the hosted
-- project that phone was filled in long after the row was seeded.
-- Writing a whole object would blank it. `jsonb_set` moves the one key
-- and leaves the rest of the object as found, whatever it has grown.
--
-- And it moves the address only where it is still the seeded `.my`. An
-- operator who has since set something else -- a different mailbox, a
-- support desk at another domain -- has made a decision, and a
-- migration that overwrote it would be taking that decision back
-- silently on the next deploy. On the hosted project this already reads
-- `.com`, so this migration finds nothing to do there, which is the
-- correct outcome rather than a missed one.
-- ---------------------------------------------------------------------

do $do$
declare
  v_before jsonb;
  v_after  jsonb;
begin
  select value into v_before from public.platform_settings where key = 'support';

  -- No row at all is a real state: 0018 seeds with `on conflict do
  -- nothing`, and nothing guarantees this key exists on a database that
  -- predates it. Nothing to correct, and nothing to invent.
  if v_before is null then
    raise notice '0242: no support setting to correct';
    return;
  end if;

  if v_before->>'email' = 'support@iakauntan.my' then
    update public.platform_settings
       set value = jsonb_set(v_before, '{email}', '"support@iakauntan.com"'::jsonb),
           updated_at = now()
     where key = 'support';
    raise notice '0242: support address moved to iakauntan.com';
  else
    raise notice
      '0242: support address is already %, left alone', v_before->>'email';
  end if;

  select value into v_after from public.platform_settings where key = 'support';

  -- The old domain is gone from this key, whichever way we got here.
  if v_after->>'email' = 'support@iakauntan.my' then
    raise exception 'FAIL 0242: the support address is still on iakauntan.my';
  end if;

  -- And nothing else in the object moved. The positive control: an
  -- assertion that only checks the address is satisfied by a migration
  -- that replaced the whole value and lost the phone.
  if (v_after - 'email') is distinct from (v_before - 'email') then
    raise exception
      'FAIL 0242: something other than the address changed: % -> %',
      v_before::text, v_after::text;
  end if;
end
$do$;
