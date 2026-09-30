-- =====================================================================
-- iAkauntan :: 0726 two clients may share a year end
--
-- `fs_filings` was unique on `(org_id, fy_end)`. A practice is ONE
-- organization holding many client companies -- that is what
-- `corp_entities` is for, and `fs_filings.corp_entity_id` names which
-- client a set of accounts belongs to -- so that key says:
--
--     one organization may file one set of accounts per year end,
--     whichever client it is for.
--
-- Which is wrong for the only kind of customer the table was built for.
-- A great many Malaysian companies end on 31 December. A practice with
-- two such clients could record the first and not the second, and the
-- refusal it got was a duplicate-key error naming a constraint rather
-- than a sentence about clients.
--
-- ---------------------------------------------------------------------
-- Found three times before it was believed
--
-- Never as itself. Always as a test dying on a date:
--
--   * `supabase/tests/fs_deadlines.sql` carries a paragraph about
--     7 September 2026, when two fixtures a day apart both clamped to
--     28 February and "the file died on a duplicate key, on that day
--     only, with nothing wrong in the code it tests". The fixture was
--     rewritten so the collision could not happen.
--   * run 2177, 1 October in Kuala Lumpur, `app.demo_amanah_accounts`:
--     Kilang's year end is the last complete calendar year and Bayu's
--     is nine months back off the start of this month. In OCTOBER
--     those are the same 31 December, so `demo_rebuild()` failed and
--     took the whole assertion run with it. Every October.
--
-- Two workarounds and a third one waiting. The third is what turned
-- this from a fixture problem into a schema problem: the demo function
-- is not a test, it runs in production, and a demo rebuild that fails
-- for the whole of October is a product that is broken for a month.
--
-- ---------------------------------------------------------------------
-- Two partial indexes rather than one wider key
--
-- `corp_entity_id` is NULLABLE: a filing may be the practice's own
-- accounts rather than a client's. A plain `unique (org_id,
-- corp_entity_id, fy_end)` would treat every NULL as distinct -- that
-- is what `NULLS DISTINCT` means and it is the default -- so the
-- practice could file its own accounts twice for one year end, which
-- is the one duplicate the old key was right to refuse.
--
-- So the rule is said twice, once for each case:
--
--   * one filing per CLIENT per year end;
--   * one filing for the PRACTICE ITSELF per year end.
--
-- This is strictly WEAKER than what it replaces -- everything the old
-- key permitted, these permit -- so no existing row can violate them
-- and the change cannot fail on live data.
-- =====================================================================

alter table public.fs_filings
  drop constraint if exists fs_filings_org_id_fy_end_key;

create unique index if not exists fs_filings_one_per_client_year
  on public.fs_filings (org_id, corp_entity_id, fy_end)
  where corp_entity_id is not null;

create unique index if not exists fs_filings_one_per_own_year
  on public.fs_filings (org_id, fy_end)
  where corp_entity_id is null;

comment on index public.fs_filings_one_per_client_year is
  'One set of accounts per client company per year end. Replaces '
  'fs_filings_org_id_fy_end_key, which ignored corp_entity_id and so '
  'refused a practice its second client with a 31 December year end -- '
  'and a great many Malaysian companies have one. See 0726.';

comment on index public.fs_filings_one_per_own_year is
  'One set of the practice''s OWN accounts per year end. The other '
  'half of what fs_filings_org_id_fy_end_key used to say: a plain '
  'unique over (org_id, corp_entity_id, fy_end) would treat every null '
  'corp_entity_id as distinct and let the practice file its own '
  'accounts twice for one year, which is the duplicate the old key was '
  'right about. See 0726.';
