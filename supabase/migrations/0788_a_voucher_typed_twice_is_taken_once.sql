-- =====================================================================
-- iAkauntan :: 0788 a voucher typed twice is taken off once
--
-- `apply_pos_coupon` (`0256`) writes the voucher onto the bill with
--
--     on conflict (sale_id, promotion_id, line_id) do update
--       set by_code = true, amount = excluded.amount, ...
--
-- so a code entered a second time was meant to land on the row it
-- already had. It never did. `pos_sale_promotions` keys on those three
-- columns, and a voucher for the whole bill has no line: `line_id` is
-- null, two nulls are never equal to a unique constraint, and the
-- conflict the function waits for cannot happen. Each entry added a
-- row, `recalc_pos_sale` sums the rows, and the discount was taken
-- once per entry. Measured on 9 October 2026, locally: a one-use RM5
-- voucher, entered three times on a RM60 bill, took RM15 off, and the
-- invoice settled at RM45. Nothing in the till stops a cashier typing a
-- code again -- the voucher dialog is always there -- and the minimum
-- spend and the use limit are both asked of the bill, not of the
-- rows already on it, so neither noticed.
--
-- Answered "one row per voucher". The key now treats a missing line as
-- a value (`nulls not distinct`, Postgres 15 onwards; production runs
-- 17), so the conflict both writers already name happens, and a second
-- entry refreshes the row instead of adding one -- what the function
-- was written to do. `refresh_pos_promotions` writes automatic
-- promotions under the same clause and is put right by the same key.
--
-- Production held no voucher and no promotion on any bill on 9 October,
-- so no row is in the way of the stricter key.
-- =====================================================================

alter table public.pos_sale_promotions
  drop constraint pos_sale_promotions_sale_id_promotion_id_line_id_key;

alter table public.pos_sale_promotions
  add constraint pos_sale_promotions_sale_id_promotion_id_line_id_key
  unique nulls not distinct (sale_id, promotion_id, line_id);

comment on constraint pos_sale_promotions_sale_id_promotion_id_line_id_key
  on public.pos_sale_promotions is
  'One row per promotion per line of a bill, and one per promotion for '
  'the whole bill: a missing line counts as a value, so a voucher '
  'entered twice refreshes its row rather than adding a second one '
  'that is taken off again. 0788.';
