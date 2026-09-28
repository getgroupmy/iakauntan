-- =====================================================================
-- iAkauntan :: 0722 an expense adds up its own total
--
-- `expenses.total_amount` was the one money figure in this database
-- that the APP computed and the database merely stored.
-- `Repo.recordExpense` sends
--
--     'amount': amount,
--     'tax_amount': taxAmount,
--     'total_amount': amount + taxAmount,
--
-- and `expenses` carries no recalculation trigger -- only
-- `set_updated_at`. Every other document total in this schema is
-- derived by SQL: `app.recalc_sales_totals`, `app.recalc_purchase_totals`
-- and `app.recalc_pos_sale` own theirs, and `0706` went to some trouble
-- to make sure the rounding they apply is the document's own. The
-- expense was the exception, and nothing said so.
--
-- ---------------------------------------------------------------------
-- What was actually wrong with it, and what was not
--
-- NOT the arithmetic. `amount + taxAmount` is added as two IEEE 754
-- doubles in Dart, which is wrong by about 1e-13 -- and `total_amount`
-- is `numeric(18, 2)`, so Postgres rounds that away on the way in. Half
-- a sen is 5e-3. You would need figures in the tens of trillions of
-- ringgit before a double's error could survive the column's own scale.
-- No stored total is wrong today, and this migration changes no existing
-- row.
--
-- What was wrong is that the rule lived somewhere the database could not
-- see. Three migrations already write this column -- `0496`, `0639` and
-- `0692`, each one `set total_amount = s.base + s.tax` while rebuilding
-- a split -- so the rule was stated four times in three languages and
-- enforced nowhere. A fourth writer that forgot the line, or an import,
-- or a support session with `psql`, would leave an expense whose total
-- is not its parts, and the ledger would still balance against itself
-- because `gl_entries` is posted from `amount` and `tax_amount`
-- separately. It would be wrong only on the expense list, which is the
-- hardest place to notice and the place a person actually reads.
--
-- ---------------------------------------------------------------------
-- `0286` already knew, and guarded the wrong end
--
-- Worth reading before this one. `0286` says, in its own header:
--
--   `total_amount` is an ordinary column with a default of zero.
--   Nothing in the schema keeps it equal to `amount + tax_amount` --
--   the app computes it -- so an expense saved with a total that
--   disagrees with its own parts was until now refused by accident.
--
-- and it made that refusal deliberate: `public.post_expense` compares
-- the two and raises in the expense's own words before any arithmetic
-- happens. That was the right fix for what it could reach -- a guard at
-- the posting boundary -- and it left the cause alone, because the
-- cause was in Dart.
--
-- This removes the cause. `post_expense`'s check stays and is now
-- unreachable for any row written after this migration, which is the
-- state a guard should end up in. It still protects the rows written
-- before it, and that is why it is not removed.
--
-- ---------------------------------------------------------------------
-- Derived, not defended
--
-- A check constraint was the other option and is the worse one: it
-- would reject the writes that `0496`, `0639` and `0692` already make
-- in the wrong order, and it would turn a support typo into an error
-- somebody has to understand rather than a figure that is simply right.
-- A BEFORE trigger overwrites instead, so `total_amount` becomes a
-- derived column that cannot disagree with its parts no matter who
-- writes it or in what order.
--
-- The three existing `set total_amount = s.base + s.tax` statements
-- stay, and are now redundant rather than wrong -- the trigger computes
-- the same figure from the `amount` and `tax_amount` in the same SET
-- list. Migrations are append-only here; they are not edited to remove
-- a line that has become decoration.
--
-- ---------------------------------------------------------------------
-- The `round(..., 2)` below cannot currently fire, and is kept anyway
--
-- Worth stating plainly, because it looks like working code and is not.
-- `amount` and `tax_amount` are themselves `numeric(18, 2)`, and a
-- BEFORE trigger sees NEW already coerced to the table's rowtype -- so
-- both parts arrive rounded to the sen and their sum is exactly two
-- decimal places before `round` is reached. There is nothing for it to
-- do.
--
-- It stays as insurance against one of those scales changing, which is
-- a one-line migration somebody could write without thinking about this
-- one. What it must not do is mislead: `supabase/tests/expense_total.sql`
-- asserts the reachable behaviour -- that a sub-sen part is ROUNDED at
-- the column rather than truncated -- and says why the obvious
-- assertion about `round` was deleted. It was written, it failed
-- against a real Postgres, and the failure was the assertion's fault.
-- =====================================================================

create or replace function app.expense_total()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- `coalesce` on both: `amount` is `not null` and `tax_amount` defaults
  -- to 0, but a trigger that assumes its own table's constraints is a
  -- trigger that breaks the day one is relaxed.
  new.total_amount :=
    round(coalesce(new.amount, 0) + coalesce(new.tax_amount, 0), 2);
  return new;
end;
$$;

comment on function app.expense_total() is
  'Derives expenses.total_amount from amount + tax_amount. BEFORE, so the total cannot disagree with its parts whoever writes them.';

drop trigger if exists expense_total on public.expenses;
create trigger expense_total
  before insert or update of amount, tax_amount, total_amount
    on public.expenses
  for each row execute function app.expense_total();

comment on column public.expenses.total_amount is
  'DERIVED by app.expense_total() from amount + tax_amount. Writing it directly has no effect; change the parts.';

-- ---------------------------------------------------------------------
-- Nothing already recorded changes
--
-- No corrective UPDATE. Every writer of this column has always computed
-- `amount + tax_amount`, so the rows agree with the trigger already --
-- and restating stored figures in somebody's books is not something a
-- migration should do on a suspicion. If a row ever does disagree, the
-- assertion in `supabase/tests/expense_total.sql` is what will say so,
-- and putting it right is then a decision with a person behind it.
-- ---------------------------------------------------------------------
