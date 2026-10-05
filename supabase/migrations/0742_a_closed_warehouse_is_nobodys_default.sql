-- A retired warehouse must not still be somebody's default.
--
-- `0741` gave eight tables `(org_id) where is_default and is_active`,
-- and said in its own header what it was leaving open: thirteen
-- functions pick a default WAREHOUSE or PIPELINE with
--
--   where org_id = ... and is_default limit 1
--
-- and no `is_active` at all -- most of them with no `order by` either,
-- so not even a stable arbitrary answer. For those thirteen, 0741's
-- index guarantees one row only while nothing leaves a stale flag
-- behind: a warehouse that is closed but still flagged default is a
-- second matching row, and whichever one the plan reaches first is where
-- a sale is depleted from.
--
-- The obvious fix is to add `and is_active` to the thirteen. It is the
-- wrong fix. They are `app.post_sales_document_internal` (10,902
-- characters), `public.complete_pos_sale` (27,407) and eleven more, and
-- re-emitting a 27KB function body to change one line is precisely how,
-- earlier in the same week, re-applying `0029` to restore one function
-- reverted `0404`'s `calc_statutory`. Thirteen of those is thirteen
-- chances at the same accident, for a one-word edit each.
--
-- So fix the premise instead. If a row cannot be default while inactive,
-- then `where is_default` and `where is_default and is_active` select
-- the same rows, every one of the thirteen becomes correct as written,
-- and no function is touched. That is a CHECK constraint, and the app
-- has always behaved as though it were there: `retireWarehouse` writes
-- `is_active = false, is_default = false` together, because a closed
-- warehouse being the default is not a state anybody wants.
--
-- Checked read-only against live before writing: zero stale defaults in
-- warehouses, pipelines, or any of the other six. The repair below is
-- therefore expected to update nothing, and is here because a CHECK
-- validates existing rows as it is added and a constraint that fails to
-- add leaves the migration half-applied.
--
-- `bank_accounts` is deliberately NOT given this constraint, and the
-- reason is a test. `money_names_the_account.sql` builds a closed
-- account that still carries `is_default`, on purpose, beside an open
-- one -- because all seven `bank_accounts` readers DO filter
-- `is_active`, and what the fixture tests is that they skip it. There
-- the stale row is the contract being defended, not a defect. The same
-- argument covers branches, tax_codes, price_levels, payment_terms and
-- work_shifts: their readers all filter `is_active`, so the constraint
-- would buy them nothing and could only forbid a fixture.

update public.warehouses set is_default = false
 where is_default and not is_active;
update public.pipelines set is_default = false
 where is_default and not is_active;

alter table public.warehouses
  add constraint warehouses_default_is_active
  check (not (is_default and not is_active));

alter table public.pipelines
  add constraint pipelines_default_is_active
  check (not (is_default and not is_active));
