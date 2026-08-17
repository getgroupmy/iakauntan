-- Two comments the migrations and the hosted project disagree about,
-- and they disagree in opposite directions.
--
-- These are the last two findings from the drift check that are not
-- function bodies. `0176`, `0177` and `0178` reconciled the three
-- functions; a comment is schema too, and `supabase db dump` emits it,
-- so the check compares it like anything else.
--
-- What makes this pair worth a header rather than a one-line fix is that
-- **neither side is uniformly right**. Every finding before this one
-- resolved in production's favour, which was starting to look like a
-- rule. It is not a rule. It was a pattern produced by one cause —
-- changes applied to the hosted project by hand and never written into a
-- file — and that cause can leave either side stale depending on which
-- way the hand-editing went.
--
-- ## `payroll_payment_instruction`: the hosted project has it
--
-- The function has carried a comment on the hosted project for as long
-- as the drift check has been able to see it. No migration writes one.
-- It is accurate — it is a fair one-line summary of what `0051`'s own
-- header says at length — so it is kept and written down here rather
-- than dropped:
--
--     The rows a bank needs to pay a posted run, with anything that
--     would be rejected flagged rather than silently omitted.
--
-- The second clause is the part worth having. `0051` is emphatic that an
-- employee with no bank account is returned *flagged* rather than
-- dropped, because a payment file that silently loses a person is far
-- more dangerous than one that shows the problem. A reader running `\df+`
-- should meet that fact without opening the migration.
--
-- ## `organizations.default_sales_tax_code_id`: the repository has it
--
-- Here it is the other way round, and it is the first finding in the set
-- where the repository is the newer side. `0145_sst_registration.sql`
-- writes a five-line comment. The hosted project has the first two lines
-- of it and stops mid-thought, at `tax_codes.is_default.`
--
-- The hosted text is an exact **prefix** of the file's, which is the
-- shape of a partial application rather than an edit: somebody ran an
-- earlier draft of `0145` against the project by hand, the file grew two
-- more literal-continuation lines before it was committed, and nothing
-- ever went back to reconcile them. `git log` on `0145` shows a single
-- commit, so the file was never edited after the fact — the divergence
-- was there from the day it was applied.
--
-- The truncated version loses the answer to the obvious next question.
-- "Dead since 0001, read by nothing" invites somebody to drop the
-- column; the missing sentences are the ones explaining why not.
--
-- Restating it is a no-op on a stack built from these files, where
-- `0145` already set the full text, and corrective on the hosted
-- project. Same shape as `0174`.
--
-- Still true after `0176`: that migration rewrote `create_organization`
-- but kept the `update ... set default_sales_tax_code_id = ...`, so the
-- comment's claim that the function still writes the column holds.

comment on function public.payroll_payment_instruction(uuid) is
  'The rows a bank needs to pay a posted run, with anything that would '
  'be rejected flagged rather than silently omitted.';

comment on column public.organizations.default_sales_tax_code_id is
  'Dead since 0001: written by create_organization and read by nothing. '
  'The tax code a line actually defaults to is the one carrying '
  'tax_codes.is_default. Kept rather than dropped because '
  'create_organization still writes it, and a migration that removed the '
  'column would have to rewrite that function to no purpose.';
