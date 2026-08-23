-- ---------------------------------------------------------------------
-- The landing page's logo could not be uploaded at all
--
-- 0290's console screen puts the platform's own logo in the `logos`
-- bucket, which already exists and is already public. What it did not
-- check is the policy governing writes to it, set by 0010:
--
--     with check (bucket_id = 'logos'
--                 and app.can_admin(nullif(split_part(name,'/',1),'')::uuid))
--
-- The first path segment has to be an organization id, and the caller an
-- admin of it. The landing logo belongs to no organization — it is the
-- platform's — so it was written to `landing/…`, and `'landing'::uuid`
-- does not evaluate to false. It raises 22P02, invalid input syntax for
-- type uuid. The upload could never have worked, and what somebody saw
-- was a failure naming a cast rather than a permission.
--
-- ## Two things wrong, not one
--
-- The missing policy is the obvious half. The half worth fixing more
-- carefully is that the existing policy *raises* on a name it does not
-- recognise instead of returning false.
--
-- A policy that errors is not merely unhelpful. Permissive policies for
-- one command are OR-ed, and PostgreSQL does not promise an evaluation
-- order — so an exception thrown while testing one policy takes down the
-- statement regardless of whether another policy would have allowed it.
-- Adding a landing policy while leaving the cast unguarded would
-- therefore have fixed nothing reliably: it would have worked or not
-- depending on which policy the planner happened to check first.
--
-- So the cast is made safe first, and only then is the new policy of any
-- use. `app.uuid_or_null` matches the shape before casting rather than
-- catching the exception, because a plpgsql exception block inside an
-- RLS check is a subtransaction per row and these policies run on every
-- object in the bucket.
--
-- ## Where the platform's own marks live
--
-- Under `landing/`, writable by a platform administrator and nobody
-- else. The paths are fixed — `landing/logo` and `landing/logo-dark` —
-- rather than timestamped, for the reason 0073 gives about the company
-- logo: a bucket that keeps every logo anybody ever uploaded is a bucket
-- nobody ever tidies. A fixed path is an update on the second upload,
-- which is why the update policy matters as much as the insert one, and
-- the console busts the browser cache with a version parameter exactly
-- as the company logo does.
-- ---------------------------------------------------------------------

-- A cast that answers instead of raising.
create or replace function app.uuid_or_null(p_text text)
returns uuid
language sql
immutable
set search_path = pg_catalog, pg_temp as $$
  select case
    when p_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then p_text::uuid
  end;
$$;

-- The organization-scoped policies, unchanged in meaning and no longer
-- able to raise. `app.can_admin(null)` is already false.
drop policy if exists logos_write on storage.objects;
create policy logos_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'logos'
    and app.can_admin(app.uuid_or_null(split_part(name, '/', 1)))
  );

drop policy if exists logos_update on storage.objects;
create policy logos_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'logos'
    and app.can_admin(app.uuid_or_null(split_part(name, '/', 1)))
  )
  with check (
    bucket_id = 'logos'
    and app.can_admin(app.uuid_or_null(split_part(name, '/', 1)))
  );

drop policy if exists logos_delete on storage.objects;
create policy logos_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'logos'
    and app.can_admin(app.uuid_or_null(split_part(name, '/', 1)))
  );

-- And the platform's own, which no organization owns.
drop policy if exists logos_platform_write on storage.objects;
create policy logos_platform_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'logos'
    and split_part(name, '/', 1) = 'landing'
    and app.is_platform_admin()
  );

drop policy if exists logos_platform_update on storage.objects;
create policy logos_platform_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'logos'
    and split_part(name, '/', 1) = 'landing'
    and app.is_platform_admin()
  )
  with check (
    bucket_id = 'logos'
    and split_part(name, '/', 1) = 'landing'
    and app.is_platform_admin()
  );

drop policy if exists logos_platform_delete on storage.objects;
create policy logos_platform_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'logos'
    and split_part(name, '/', 1) = 'landing'
    and app.is_platform_admin()
  );
