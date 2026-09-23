-- =====================================================================
-- iAkauntan :: 0687 which matter this line belongs to
--
-- A law firm keeps two sets of books at once. The firm's own, and one
-- per matter — and the second is not a report over the first, it is a
-- statutory obligation with its own arithmetic.
--
-- `0021` built the client side: `matters`, `client_account_transactions`
-- with its four movements, and `app.assert_client_funds()`, which is the
-- rule that matters most — a matter may not spend money it does not
-- hold, because the alternative is one client's money paying for
-- another's.
--
-- What it did not do is put the matter anywhere the REST of the ledger
-- could see it.
--
-- ---------------------------------------------------------------------
-- Four tables knew, and the ledger did not
--
-- `matter_id` reaches exactly four tables: `client_account_transactions`,
-- `disbursements`, `sales_documents` and `time_entries`. Everything
-- else in this product posts through `gl_lines`, and `gl_lines` carries
-- `contact_id`, `item_id`, `project_code` and `department_code` —
-- every dimension except the one a solicitor actually files by.
--
-- So a bill from a searcher, an expense for a courier, a journal
-- correcting last month, a bank charge: none of them can be told which
-- matter it belongs to. They land in the firm's ledger and stop.
--
-- And because `report_trial_balance` is built on `gl_lines`, a trial
-- balance for one matter cannot be written at all. There is nothing on
-- the line to filter by.
--
-- ---------------------------------------------------------------------
-- Nullable, and it stays nullable
--
-- Most of what a firm posts belongs to no matter: the rent, the
-- salaries, the firm's own bank charges. A mandatory matter would put a
-- fictitious one on every such line, and a dimension everybody has to
-- defeat is worse than no dimension -- it makes the matter reports
-- wrong rather than empty.
--
-- `on delete set null` for the same reason a `sales_documents.matter_id`
-- is: a matter that is deleted must not take posted ledger lines with
-- it. The line is still a real movement of money; it simply stops being
-- filed against anything.
--
-- ---------------------------------------------------------------------
-- The composite foreign key, not the simple one
--
-- `0160` is the migration to read here. RLS scopes a row by its own
-- `org_id` and says NOTHING about the ids it carries in its foreign key
-- columns, so a simple `references public.matters (id)` would accept
-- another firm's matter id on this firm's ledger line -- and a matter
-- trial balance would then quietly include, or omit, somebody else's
-- work.
--
-- `0160` closed exactly this on `gl_lines.account_id`, and said why the
-- ledger is the one that closes every posting path at once: several
-- callers build their lines as jsonb and hand them to `create_gl_entry`,
-- where no amount of reading the callers would have caught the next one.
-- The same argument applies here and the same shape answers it.
-- =====================================================================

-- The parent key the composite reference needs. A later migration than
-- `0160` already added it for another reference, so this is written to
-- find it rather than to assume either way -- `add constraint` has no
-- `if not exists`, and a migration that raises on an already-correct
-- database is a migration that cannot be applied twice.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.matters'::regclass
       and conname = 'matters_org_id_id_key')
  then
    alter table public.matters
      add constraint matters_org_id_id_key unique (org_id, id);
  end if;
end $$;

alter table public.gl_lines
  add column if not exists matter_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.gl_lines'::regclass
       and conname = 'gl_lines_matter_same_org')
  then
    alter table public.gl_lines
      add constraint gl_lines_matter_same_org
      foreign key (org_id, matter_id)
      references public.matters (org_id, id)
      -- NAMING THE COLUMN. A bare `on delete set null` on a composite
      -- key nulls EVERY column in it, and `org_id` is NOT NULL -- so
      -- deleting a matter would not detach the line, it would raise.
      -- `tenant_foreign_keys.sql` refuses the bare form, and `0681` hit
      -- exactly this on its own composite key.
      on delete set null (matter_id);
  end if;
end $$;

comment on column public.gl_lines.matter_id is
  'Which matter this line belongs to, or null for the firm''s own. '
  'Nullable and staying that way: most of what a firm posts -- rent, '
  'salaries, its own bank charges -- belongs to no matter, and a '
  'mandatory one would put a fictitious matter on every such line. '
  'The composite foreign key is deliberate; see `0160`. 0687.';

-- Every read of this filters by matter within an org, which is the
-- index the trial balance below wants and the only shape asked for.
create index if not exists gl_lines_matter_idx
  on public.gl_lines (org_id, matter_id)
  where matter_id is not null;

-- ---------------------------------------------------------------------
-- The trial balance for one matter
--
-- `report_trial_balance` from `0016`, with one more predicate and two
-- deliberate differences.
--
-- NO OPENING BALANCE OFF THE ACCOUNT. `report_trial_balance` adds
-- `accounts.opening_balance` into its figures, which is the balance the
-- FIRM brought forward when the books were opened. It belongs to no
-- matter, and adding it here would put the firm's entire opening
-- position onto whichever matter was asked for. That is the one
-- arithmetic error in this function that would look plausible.
--
-- AND A MATTER HAS NO UNTAGGED LINES. `matter_id is not null` is
-- implied by the equality, but stated, because the failure it prevents
-- is a null-matter query returning the firm's whole ledger under the
-- heading of a matter trial balance.
--
-- What this answers is "everything filed against this matter, and
-- nothing else" -- which is what was asked for. It is NOT a client
-- account reconciliation: a matter carries office-side costs too, a
-- disbursement paid out of office money and not yet billed among them,
-- and those are the matter's without being client money. A report
-- restricted to the designated client bank accounts is a different
-- question and is not this one.
-- ---------------------------------------------------------------------
create or replace function public.report_matter_trial_balance(
  p_org_id uuid,
  p_matter_id uuid,
  p_from date default null,
  -- `app.today()`, not `current_date`. A Malaysian business day starts
  -- eight hours before UTC does, so a report run at 7am local would
  -- otherwise stop at yesterday and silently omit this morning's
  -- postings. `utc_is_not_today.sql` refuses the latter.
  p_to date default app.today())
returns table (
  account_id uuid, code text, name text,
  account_type app.account_type, account_subtype app.account_subtype,
  opening_balance numeric, debit numeric, credit numeric,
  closing_balance numeric)
language sql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
  with movements as (
    select l.account_id,
           sum(case when p_from is not null and e.entry_date < p_from
                    then l.debit - l.credit else 0 end) as opening,
           sum(case when p_from is null or e.entry_date >= p_from
                    then l.debit else 0 end) as dr,
           sum(case when p_from is null or e.entry_date >= p_from
                    then l.credit else 0 end) as cr
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
     where l.org_id = p_org_id
       and app.can_read_ledger(p_org_id)
       and l.matter_id is not null
       and l.matter_id = p_matter_id
       and e.status = 'posted'
       and e.entry_date <= p_to
     group by l.account_id)
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(coalesce(m.opening, 0), 2),
         round(coalesce(m.dr, 0), 2),
         round(coalesce(m.cr, 0), 2),
         round(coalesce(m.opening, 0) + coalesce(m.dr, 0)
               - coalesce(m.cr, 0), 2)
    from public.accounts a
    join movements m on m.account_id = a.id
   where a.org_id = p_org_id
     and a.deleted_at is null
   order by a.code;
$$;

comment on function public.report_matter_trial_balance(uuid, uuid, date, date) is
  'A trial balance for ONE matter: every posted line filed against it, '
  'and nothing else -- not other matters, and not the firm''s own. '
  'Carries no opening balance off `accounts`, because that figure is '
  'the firm''s and belongs to no matter. Only accounts this matter has '
  'moved appear. Not a client account reconciliation: a matter holds '
  'office-side costs too. 0687.';

revoke all on function public.report_matter_trial_balance(uuid, uuid, date, date)
  from public, anon;
grant execute on function public.report_matter_trial_balance(uuid, uuid, date, date)
  to authenticated;

-- ---------------------------------------------------------------------
-- And the pull an internal audit actually wants
--
-- The trial balance above is a summary: one row per account, which
-- answers "where does this matter stand". It does not answer the
-- question somebody auditing a matter is holding, which is "show me
-- everything, in order, and let me tick it against the file".
--
-- So: every posted line filed against this matter, oldest first, with
-- the entry that carried it, what moved, and a running balance. Only
-- this matter -- not the one beside it, and not the firm's own.
--
-- ## Why the running balance is computed here
--
-- A listing without one makes the reader add up a column by hand, and
-- the whole point of the pull is that somebody is checking arithmetic.
-- It runs over the ordering the report itself returns, so the figure
-- beside a row is the figure after that row as printed, rather than
-- after some other sort the caller might have applied.
--
-- ## What `source` is doing on it
--
-- `gl_entries.source` and `source_table` say what CREATED the entry --
-- a client account movement, an invoice, a manual journal. An audit of
-- client money cares about that more than about the narration: a
-- matter whose ledger is all manual journals is a different
-- conversation from one posted by the machinery, and the column is the
-- only place that distinction survives.
--
-- ## Not restricted to the client bank accounts
--
-- Deliberate, and the same choice the trial balance above makes. This
-- is the complete picture of a matter, office-side costs included --
-- the disbursement paid out of office money and not yet billed belongs
-- to the matter without being client money. A pull restricted to the
-- designated client accounts is a Rule 8 reconciliation, which is a
-- different report against a different question, and writing one
-- report that half-answers both would answer neither.
-- ---------------------------------------------------------------------
create or replace function public.report_matter_ledger(
  p_org_id uuid,
  p_matter_id uuid,
  p_from date default null,
  p_to date default app.today())
returns table (
  entry_date      date,
  entry_no        text,
  -- Returned, because the running balance below is only meaningful in
  -- the order this report emits, and without the line number a caller
  -- that re-sorts cannot get back to it. An audit pull whose running
  -- balance cannot be reproduced is a column of numbers to be taken on
  -- trust, which is the opposite of the point.
  line_no         integer,
  source          text,
  account_code    text,
  account_name    text,
  description     text,
  reference       text,
  debit           numeric,
  credit          numeric,
  running_balance numeric,
  entry_id        uuid,
  posted_at       timestamptz)
language sql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
  select e.entry_date,
         e.entry_no,
         l.line_no,
         e.source::text,
         a.code,
         a.name,
         -- The line's own narration where it has one, and the entry's
         -- otherwise. A line with neither is a line an auditor has to
         -- go and look up, and there is no third place to look.
         coalesce(nullif(btrim(l.description), ''), e.description),
         e.reference,
         round(l.debit, 2),
         round(l.credit, 2),
         round(sum(l.debit - l.credit) over (
           order by e.entry_date, e.entry_no, l.line_no
           rows between unbounded preceding and current row), 2),
         e.id,
         e.posted_at
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.accounts a on a.id = l.account_id
   where l.org_id = p_org_id
     and app.can_read_ledger(p_org_id)
     and l.matter_id is not null
     and l.matter_id = p_matter_id
     and e.status = 'posted'
     and e.entry_date <= p_to
     and (p_from is null or e.entry_date >= p_from)
   order by e.entry_date, e.entry_no, l.line_no;
$$;

comment on function public.report_matter_ledger(uuid, uuid, date, date) is
  'Every posted line filed against ONE matter, oldest first, with a '
  'running balance and what created each entry. The pull an internal '
  'audit of a matter wants, where the trial balance is the summary. '
  'Not restricted to the client bank accounts -- this is the complete '
  'picture of the matter, office-side costs included; a Rule 8 client '
  'account reconciliation is a different report. 0687.';

revoke all on function public.report_matter_ledger(uuid, uuid, date, date)
  from public, anon;
grant execute on function public.report_matter_ledger(uuid, uuid, date, date)
  to authenticated;
