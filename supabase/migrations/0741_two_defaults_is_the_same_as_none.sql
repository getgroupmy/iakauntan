-- Eight tables where "the default" was whichever row came back first.
--
-- `0092_one_default_per_contact.sql` already found this bug, named it
-- exactly right -- "Two defaults is the same as none. Whichever row the
-- query happens to return first wins, the answer can change between two
-- runs of the same query" -- and closed it with a partial unique index,
-- for `contact_addresses` and `contact_persons`. Six more tables have
-- been given the same index since, one at a time, as each was built.
--
-- Eight were never given it: bank_accounts, branches, payment_terms,
-- pipelines, price_levels, tax_codes, warehouses and work_shifts.
-- Nothing in 740 migrations enforces one default on any of them, and
-- twenty-three functions pick a single row out of them with
--
--   where org_id = ... and is_default [and is_active]
--   order by created_at limit 1
--
-- which decides, among other things, where a group payment's money
-- lands (`record_group_payment`) and which warehouse a POS sale depletes
-- (`app.default_warehouse`). That `order by created_at` is not a
-- tiebreak: `created_at` defaults to `now()`, which is the TRANSACTION
-- timestamp, so two rows written by one transaction carry the same value
-- and the limit picks by physical order. Demonstrated on a scratch
-- cluster: one org, two active warehouses inserted together, the first
-- call returned W1; rewriting W1's name -- which changes only where the
-- row sits, not the ORDER BY -- made the next call return W2.
--
-- The app is not the hole. `setDefaultTaxCode`, `setDefaultBranch` and
-- `setDefaultWarehouse` each clear the flag on the other rows before
-- setting it, and their retire paths clear it too; the other five have
-- no setter at all, and get their one default from the organisation
-- seeder or, for a bank account, from `0529`'s "the first ACTIVE one".
-- The hole is that nothing STOPS a second default: two people editing
-- the same company at once both clear, both set, and both succeed. As
-- 0092 put it, a partial unique index makes the second one fail instead,
-- which is the outcome anybody would choose if asked.

-- `and is_active`, not `is_default` alone.
--
-- The stronger index was written first, on the reasoning that no path
-- retires a row without clearing the flag, so a retired row holding a
-- stale default could not arise. The suite refuted it:
-- `money_names_the_account.sql` builds that row ON PURPOSE -- a closed
-- account still flagged default, beside an open one -- because the thing
-- it is testing is that the readers skip it. All seven `bank_accounts`
-- readers do filter `is_active`, so that fixture is describing the
-- contract rather than abusing it, and an index that forbids the state
-- would forbid testing the defence against it.
--
-- The cost is named rather than hidden: thirteen readers pick a default
-- WAREHOUSE or PIPELINE without filtering `is_active`
-- (`app.pos_deplete_recipes`, `app.post_sales_document_internal`,
-- `public.complete_pos_sale` and ten more), and for those this index
-- guarantees one row only so long as nothing leaves a stale flag behind.
-- The app upholds that -- `retireWarehouse` clears `is_default` -- but it
-- is upheld by convention, not by the schema. Closing it properly means
-- adding `and is_active` to those thirteen, which is thirteen function
-- redefinitions and belongs in its own migration.

-- `pos_modifiers` is deliberately NOT here, and the suite is why.
--
-- It was in the first version of this migration, indexed on `(group_id)`
-- -- one pre-selected option per modifier group, which sounds right and
-- is wrong. `pos_fnb.sql` has asserted since `0250` that "a group that
-- takes two takes two defaults, and not a third": the limit is the
-- group's own `max_select`, already enforced where that column can be
-- read. A partial unique index cannot express a rule that lives in
-- another table, and `(group_id)` would have capped every multi-select
-- group at one default.

-- Demote duplicates first, or an index that fails to build leaves the
-- migration half-applied. The live database has none in any of the
-- eight -- checked, read-only, before writing this -- so this is a door
-- being closed rather than a mess being cleaned up, and the rule is
-- 0092's: the oldest row keeps the flag, because it is the one other
-- people's habits are built around. `id` breaks the tie that
-- `created_at` cannot, since rows written by one transaction share it.
do $$
declare
  t text;
begin
  foreach t in array array['bank_accounts', 'branches', 'payment_terms',
                           'pipelines', 'price_levels', 'tax_codes',
                           'warehouses', 'work_shifts']
  loop
    execute format($f$
      with ranked as (
        select id, row_number() over (
                 partition by org_id order by created_at, id) as rn
          from public.%I where is_default and is_active)
      update public.%I x set is_default = false
        from ranked r where r.id = x.id and r.rn > 1
    $f$, t, t);
  end loop;
end $$;

create unique index if not exists bank_accounts_one_default
  on public.bank_accounts (org_id) where is_default and is_active;
create unique index if not exists branches_one_default
  on public.branches (org_id) where is_default and is_active;
create unique index if not exists payment_terms_one_default
  on public.payment_terms (org_id) where is_default and is_active;
create unique index if not exists pipelines_one_default
  on public.pipelines (org_id) where is_default and is_active;
create unique index if not exists price_levels_one_default
  on public.price_levels (org_id) where is_default and is_active;
create unique index if not exists tax_codes_one_default
  on public.tax_codes (org_id) where is_default and is_active;
create unique index if not exists warehouses_one_default
  on public.warehouses (org_id) where is_default and is_active;
create unique index if not exists work_shifts_one_default
  on public.work_shifts (org_id) where is_default and is_active;
