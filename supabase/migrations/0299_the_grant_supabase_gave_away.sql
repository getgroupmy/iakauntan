-- ---------------------------------------------------------------------
-- The grant Supabase gave away
--
-- 0297 granted `select` on `platform_payments` to `authenticated` and
-- said, in as many words, that nobody writes it from a client. Checking
-- the deployed project showed that is not what arrived: Supabase ships
--
--   alter default privileges in schema public
--     grant all on tables to anon, authenticated, service_role
--
-- so every table created in `public` reaches production with insert,
-- update and delete already granted, whatever its migration asked for.
-- `platform_payments` carries all four there and only `select` in the
-- test harness, which is how an assertion written against the harness
-- came to describe a database nobody runs.
--
-- ## Nothing was open
--
-- The table has one policy and it is `for select`, so row level
-- security refuses every write — an update matches no rows and changes
-- nothing. Production was safe, by one mechanism.
--
-- One mechanism is enough right up until somebody adds a policy. This
-- table records money arriving against invoices, and the day a
-- well-meaning `for all using (app.is_org_member(org_id))` appears on
-- it, the missing grant is what would still be standing. So take the
-- grant away and let there be two.
--
-- Deliberately not done to every table in the schema. That is a sweep
-- across a hundred tables to change a convention this project has had
-- since 0010, and it is not something to do quietly inside a migration
-- about payments.
-- ---------------------------------------------------------------------

revoke insert, update, delete on public.platform_payments
  from authenticated, anon;

comment on table public.platform_payments is
  'One attempt to settle a platform invoice through a gateway. Written only by the edge functions under the service role; a company may read its own. Insert, update and delete are revoked from authenticated as well as refused by policy, because Supabase''s default privileges grant them on every new table in public.';
