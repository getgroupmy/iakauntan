-- =====================================================================
-- iAkauntan :: 0683 the five columns a statement line has
--
-- `0682` gave `accounting.bank_statement` the ability to repeat, and
-- ticked nothing. `scan_extraction_targets` only offers a target that
-- has at least one field, so as it stands the reader is never asked for
-- statement lines at all: photograph a statement today and the answer
-- comes back with `rows` empty, correctly, because nobody asked.
--
-- The console can tick them. But a platform administrator opening
-- `/#/admin/scan-kinds` is shown every column of `bank_transactions` --
-- `id`, `org_id`, `import_batch_id`, `transaction_type`, `raw_data`,
-- `created_by` among them -- and has to know which five are printed on
-- a statement and which five are bookkeeping this system does for
-- itself. That is the kind of question the answer to which does not
-- vary by installation, so it should not be asked once per
-- installation.
--
-- ---------------------------------------------------------------------
-- The five, and why not the sixth
--
-- `transaction_date`, `description`, `reference`, `amount` and
-- `running_balance`. Those are the columns on the paper. The last is
-- the one that matters most and would be the first a person left off:
-- `import_bank_transactions` checks each line against the one before it
-- and refuses a statement whose balances do not bridge, which is the
-- only defence there is against a reader that dropped a line. A reading
-- with no balances imports and is never checked.
--
-- `value_date` is deliberately not ticked, and `0369` already wrote
-- down why the column exists and stays unwritten. The reader is told
-- about it in `transaction_date`'s own sentence instead -- a statement
-- that prints only a value date should answer with it rather than
-- leave the line dateless -- which is exactly what `scannedStatement`
-- falls back to on the way in.
--
-- ---------------------------------------------------------------------
-- The sentences
--
-- A field with no description is a field the model guesses at. The one
-- these have to carry is the sign: a statement prints two money
-- columns, or one column with `DR`/`CR` beside it, and neither of
-- those is a negative number. The amount wanted here is signed the way
-- the account moves, and a reader left to itself returns the figure as
-- printed -- which makes every withdrawal a deposit.
--
-- The other thing a reader gets wrong is the order, and that one is
-- already said: `targetPrompt` adds "Every line, in the order printed"
-- to any target that repeats. It matters because
-- `import_bank_transactions` reads the statement's direction off its
-- own dates and walks the balance chain the way the statement runs, so
-- a reader that helpfully sorts newest-first into oldest-first breaks
-- the check that is the whole reason for taking the balance.
--
-- `on conflict do nothing`, so an installation that has already ticked
-- its own set keeps it.
-- =====================================================================

insert into public.scan_target_fields
  (module_code, action, column_name, description, sort_order)
values
  ('accounting', 'bank_statement', 'transaction_date',
   'The date printed on the line. Give it exactly as printed. Where '
   'the statement prints only a value date, give that rather than '
   'leaving the line without a date.',
   10),
  ('accounting', 'bank_statement', 'description',
   'What the bank calls the entry, in the bank''s own words. Where it '
   'runs onto a second line, join them.',
   20),
  ('accounting', 'bank_statement', 'reference',
   'The cheque number, transaction reference or narrative code beside '
   'the entry, where the statement prints one. Leave it out rather '
   'than repeating the description.',
   30),
  ('accounting', 'bank_statement', 'amount',
   'How much the account moved, signed: money in is positive, money '
   'out is negative. A statement prints two columns, or one column '
   'with DR or CR beside it; a withdrawal or a debit is negative '
   'either way. Give the figure only, without the currency.',
   40),
  ('accounting', 'bank_statement', 'running_balance',
   'The balance printed beside the line, after it. This is the figure '
   'that proves the rest: give it for every line that has one, and '
   'leave it out only where the statement prints none.',
   50)
on conflict (module_code, action, column_name) do nothing;
