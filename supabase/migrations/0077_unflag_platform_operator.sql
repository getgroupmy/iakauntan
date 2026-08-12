-- The platform operator is no longer a demo account.
--
-- 0076 froze the credentials of every seeded login so a visitor could
-- not change a shared password and lock everyone else out. That was
-- right for the four accounts the sign-in page offers, all of which are
-- scoped to a demo company.
--
-- The operator account is not one of them any more: it was taken off the
-- picker because its console is scoped to nothing — it lists every tenant
-- on the deployment. Since it is no longer handed to visitors, the reason
-- to freeze it has gone, and the freeze is now in the way of the thing
-- that should happen to it instead: its password is published in the
-- README and needs rotating.
--
-- So the flag comes off, which is what makes the password changeable.
--
-- Written as a migration rather than done by hand on the hosted project,
-- because a change that exists only in the live database is exactly the
-- drift the numbered migrations are for. `db reset` and production have
-- to agree about which accounts are frozen.
--
-- NOTE: this widens what is possible on that account. Until a new
-- password is set, the published one both works and can now be changed by
-- anyone who uses it. Rotate it.

update auth.users
   set raw_app_meta_data = raw_app_meta_data - 'demo'
 where email = 'superadmin@iakauntan.my';
