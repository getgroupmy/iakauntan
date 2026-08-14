-- =====================================================================
-- iAkauntan :: the tables the API is allowed to reach
--
-- `claim_attachments.sql` grew a positive control — an employee must be
-- able to attach a receipt to their own claim — and it failed on a
-- database built only from these migrations:
--
--   FAIL an employee cannot attach to their own claim:
--   42501 permission denied for table attachments
--
-- Read the message carefully, because two different failures wear the
-- same errcode. Row level security refusing a row says "new row violates
-- row-level security policy". "Permission denied for table" is the
-- coarser gate in front of it: the `authenticated` role has no INSERT
-- privilege on the table at all, so the policy is never consulted.
--
-- `public.attachments` is created in 0008 and never granted. It works on
-- the hosted project because that project carries Supabase's default
-- privileges, which grant every new table in `public` to `anon`,
-- `authenticated` and `service_role` as it is created. A stack built
-- from these files alone does not necessarily carry them, and a schema
-- that is only usable when something outside the schema happens to be
-- configured is not a schema anybody can redeploy. The later migrations
-- in this repository already grant explicitly for the tables they add
-- (0094, 0095, 0097, 0099, 0101, 0108); these three were missed.
--
-- What this does NOT do is hand out a blanket grant across the schema.
-- Several tables here are service-role-only on purpose — an
-- organization's LHDN credentials, its OCR provider keys — and a
-- convenient `grant all on all tables` would be exactly the wrong
-- instrument. Row level security is what decides *which* rows; these
-- grants only decide which tables the API may ask about at all.
--
-- Nothing here widens `anon`.
-- =====================================================================

-- The four verbs match the four policies on the table: select through
-- `can_read_attachment`, insert and delete through `can_attach_to`, and
-- update through `can_write`.
grant select, insert, update, delete on public.attachments to authenticated;

-- The approval chain is read by the claims screen so somebody can see
-- who a claim is waiting on. It is written only by the SECURITY DEFINER
-- functions in 0119, which is why there is no insert, update or delete
-- policy on it — and so no grant for those either. The absence is the
-- design, not an oversight.
grant select on public.claim_approvals to authenticated;

-- The threshold is read by everybody in the company and written by an
-- administrator, both of which the policies in 0119 already decide.
grant select, insert, update on public.claim_approval_settings
  to authenticated;
