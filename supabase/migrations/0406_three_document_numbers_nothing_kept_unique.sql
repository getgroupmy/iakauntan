-- =====================================================================
-- iAkauntan :: 0406 three document numbers nothing kept unique
--
-- Every generated document number in this schema comes from one place:
--
--     select * into v_seq from public.number_sequences
--      where org_id = p_org_id and doc_type = p_doc_type for update;
--
-- `app.next_document_number_internal` takes a row lock and holds it for
-- the rest of the transaction, so two callers asking at the same moment
-- serialise on that row and cannot be handed the same number. The
-- function is right, and this migration is not about the function.
--
-- It is about what happens when something writes one of these columns
-- without going through it, and that is not a hypothetical.
-- `contact_numbering.sql` opens by saying so:
--
--     `app.next_document_number_internal` counts; it does not check. A
--     code can reach `contacts` without ever passing through it -- the
--     CSV importer writes whatever the file said [...] That is not
--     hypothetical: it is what a live organization did the first time a
--     supplier was created from a scanned bill.
--
-- What saved `contacts` was `contacts_org_id_code_key`. The duplicate
-- was refused at the moment it was attempted, loudly, by a constraint,
-- and `0116` was written to re-sync the counter. On a table with no
-- such index the same importer, the same seed, the same scanned bill
-- would have written the duplicate and said nothing.
--
-- So: asked of the catalogue. Every org-scoped
-- column ending in `_no`, against the unique indexes on its table.
-- `sales_documents` and `purchase_documents` are covered —
-- `UNIQUE (org_id, doc_type, doc_no)` — and so are `gl_entries`,
-- `receipts`, `bank_transfers`, `contra_notes`, `deposit_notes`,
-- `client_account_transactions`, `employees` and a dozen more.
--
-- Three are not:
--
--     stock_movements.movement_no
--     rent_runs.run_no
--     strata_charge_runs.run_no
--
-- all `text not null`, all generated, none constrained.
--
-- ---------------------------------------------------------------------
-- No duplicate exists, and that is what makes this safe rather than
-- what makes it unnecessary
--
-- Counted on the hosted project before writing this, because a unique
-- index that cannot be built is a migration that breaks a deployment:
--
--     stock_movements       44 rows, 0 duplicates
--     rent_runs              0 rows, 0 duplicates
--     strata_charge_runs     0 rows, 0 duplicates
--     gl_entries           149 rows, 0 duplicates
--     receipts              24 rows, 0 duplicates
--
-- So nothing is being repaired. What changes is where the guarantee
-- lives: today these three rest entirely on one function being right
-- forever and on every future writer remembering to call it, and the
-- other twenty rest on that *and* on the database refusing anything
-- else -- which is the layer that actually caught the one real
-- occurrence. `0401` made the same argument about a privilege RLS
-- already refused, and `0405` about a cast that only mattered if
-- something else went wrong first.
--
-- ---------------------------------------------------------------------
-- What is deliberately left alone
--
-- The sweep's first list was longer, and most of it was noise worth
-- writing down so nobody re-runs it:
--
--   * **Numbers that are somebody else's.** `registration_no`,
--     `passport_no`, `licence_no`, `bank_account_no`, `eis_no`,
--     `supplier_doc_no`, `internal_doc_no`. Two suppliers may perfectly
--     well send invoices numbered `INV-1`, and a unique index there
--     would refuse the second one.
--   * **Line numbers.** `payslip_lines.line_no`,
--     `expense_claim_lines.line_no` and friends are unique within their
--     parent, not within the company, and are constrained there where
--     it matters.
--   * **`pos_sales.order_no`**, which is the number called across the
--     room and *restarts every day, per outlet*, exactly as `0220`
--     intended: "short enough to read across a room, which is the whole
--     job it has". A unique index on it would be wrong, not missing.
--     `app.next_kiosk_order_no` is a single upsert taking the row lock,
--     with `0220`'s own comment explaining why it is one statement.
-- =====================================================================

create unique index if not exists stock_movements_org_id_movement_no_key
  on public.stock_movements (org_id, movement_no);

create unique index if not exists rent_runs_org_id_run_no_key
  on public.rent_runs (org_id, run_no);

create unique index if not exists strata_charge_runs_org_id_run_no_key
  on public.strata_charge_runs (org_id, run_no);

-- ---------------------------------------------------------------------
-- And the ones that were already covered still are
-- ---------------------------------------------------------------------
-- Named rather than swept, because the sweep's own output showed that
-- "every `_no` column should be unique" is false — most of them should
-- not be. This is the list of numbers this application *issues*, and
-- the assertion is that the database, not a function, is what stops two
-- of them being the same.
do $do$
declare
  r record;
  v_missing text := null;
  c_issued constant text[][] := array[
    ['gl_entries',                  'entry_no'],
    ['receipts',                    'receipt_no'],
    ['bank_transfers',              'transfer_no'],
    ['contra_notes',                'contra_no'],
    ['deposit_notes',               'deposit_no'],
    ['client_account_transactions', 'transaction_no'],
    ['employees',                   'employee_no'],
    ['stock_movements',             'movement_no'],
    ['rent_runs',                   'run_no'],
    ['strata_charge_runs',          'run_no']];
  i int;
begin
  for i in 1 .. array_length(c_issued, 1) loop
    if not exists (
      select 1
        from pg_index x
        join pg_class c on c.oid = x.indrelid
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = c_issued[i][1]
         and x.indisunique
         and c_issued[i][2] = any (
           select a.attname from pg_attribute a
            where a.attrelid = c.oid and a.attnum = any (x.indkey))
         and 'org_id' = any (
           select a.attname from pg_attribute a
            where a.attrelid = c.oid and a.attnum = any (x.indkey)))
    then
      v_missing := coalesce(v_missing || ', ', '')
                || c_issued[i][1] || '.' || c_issued[i][2];
    end if;
  end loop;

  if v_missing is not null then
    raise exception
      'FAIL 0406: % is a number this application issues and nothing but '
      '`app.next_document_number_internal` stops two of them being the '
      'same. Add a unique index over (org_id, the column).', v_missing;
  end if;
  raise notice
    '0406: every number this application issues is unique per company '
    'in the database, not only in the function that hands it out';
end
$do$;
