-- =====================================================================
-- iAkauntan :: 0017 additional access types
--
-- Postgres will not let a new enum value be used in the same transaction
-- that adds it, so these arrive on their own and are wired into the
-- permission functions by the next migration.
-- =====================================================================

alter type app.member_role add value if not exists 'accounts_clerk' after 'accountant';
alter type app.member_role add value if not exists 'auditor' after 'accounts_clerk';
