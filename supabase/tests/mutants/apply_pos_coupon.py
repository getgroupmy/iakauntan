# Mutants for public.apply_pos_coupon (0256) -- a voucher typed at the
# till: the sale must exist, be the caller's to sell on and still be
# parked; the code is matched in this company, whatever its case or
# spacing; a voucher that cannot apply is refused at the door; entered
# again it refreshes its row (0788) rather than adding another; and the
# bill is recalculated.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0256_a_price_the_shop_decided_in_advance.sql \
#       supabase/tests/pos.sql \
#       supabase/tests/mutants/apply_pos_coupon.py
#
# RESULT: 16 mutants and a control. 14 killed by `pos.sql`; before its
# assertions, 5 -- the code's case and spacing, the minimum spend, the
# typed flag, the recalculation. The rest had nothing asking: a missing bill,
# an unknown code, another company's code, a stranger, a settled bill,
# who typed it, the row returned, the refresh's reason for a voucher
# nothing on the bill qualifies for -- and a second entry demoted to
# automatic, which the sweep's first run let through because the THIRD
# entry put back the row the second lost. It is asked after each entry
# now. Found here: `0788`, a voucher typed twice was taken off twice.
#
# Two are EQUIVALENT, for one reason: `app.refresh_pos_promotions` runs
# straight after the write and sets every typed voucher's amount and
# reason afresh -- so a second entry that kept the old amount, or the
# old reason, is corrected before anything reads it.

F = "apply_pos_coupon"

m("a sale that does not exist is not refused", F,
  "  if v_sale.id is null then\n    raise exception 'No such sale.'",
  "  if false then  -- no such sale\n    raise exception 'No such sale.'",
  "-- no such sale")

m("anybody may put a voucher on a bill", F,
  "  if not app.can_write_module(v_sale.org_id, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a settled bill takes a voucher", F,
  "  if v_sale.status <> 'parked' then",
  "  if false then  -- any status",
  "-- any status")

m("another company's voucher is found", F,
  "   where p.org_id = v_sale.org_id\n     and p.code is not null",
  "   where true  -- any company\n     and p.code is not null",
  "-- any company")

m("the code is matched case for case", F,
  "     and upper(p.code) = upper(btrim(coalesce(p_code, '')));",
  "     and p.code = btrim(coalesce(p_code, ''));  -- case kept",
  "-- case kept")

m("the code is matched with its spaces", F,
  "     and upper(p.code) = upper(btrim(coalesce(p_code, '')));",
  "     and upper(p.code) = upper(coalesce(p_code, ''));  -- spaces kept",
  "-- spaces kept")

m("an unknown code is not refused in words", F,
  "  if v_promo.id is null then\n    raise exception 'No voucher with that code.'",
  "  if false then  -- unknown passes\n    raise exception 'No voucher with that code.'",
  "-- unknown passes")

m("a voucher that cannot apply is attached anyway", F,
  "  if v_why is not null then\n    raise exception '%', v_why",
  "  if false then  -- blocked attached\n    raise exception '%', v_why",
  "-- blocked attached")

m("a typed voucher is written as automatic", F,
  "          app.pos_promo_amount(v_promo.id, p_sale), true, auth.uid())",
  "          app.pos_promo_amount(v_promo.id, p_sale), false, auth.uid())  -- automatic",
  "-- automatic")

m("entered again, it becomes automatic", F,
  "    set by_code = true,",
  "    set by_code = false,  -- demoted",
  "-- demoted")

m("entered again, its amount is not refreshed", F,
  "        amount = excluded.amount,",
  "        amount = public.pos_sale_promotions.amount,  -- stale",
  "-- stale")

m("entered again, its old reason stays", F,
  "        blocked_reason = null",
  "        blocked_reason = public.pos_sale_promotions.blocked_reason  -- old reason",
  "-- old reason")

m("nobody is recorded as applying it", F,
  "          app.pos_promo_amount(v_promo.id, p_sale), true, auth.uid())",
  "          app.pos_promo_amount(v_promo.id, p_sale), true, null)  -- nobody",
  "-- nobody")

m("the automatic promotions are not looked at again", F,
  "  perform app.refresh_pos_promotions(p_sale);\n  perform app.recalc_pos_sale(p_sale);\n  return v_id;",
  "  -- no refresh\n  perform app.recalc_pos_sale(p_sale);\n  return v_id;",
  "-- no refresh")

m("the bill is not recalculated", F,
  "  perform app.recalc_pos_sale(p_sale);\n  return v_id;",
  "  -- no recalc\n  return v_id;",
  "-- no recalc")

m("the row is not returned", F,
  "  return v_id;\nend;",
  "  return null;  -- no row\nend;",
  "-- no row")

m("CONTROL", F,
  "  insert into public.pos_sale_promotions\n    (org_id, sale_id, promotion_id, amount, by_code, applied_by)",
  "  insert into public.pos_sale_promotions  -- control\n    (org_id, sale_id, promotion_id, amount, by_code, applied_by)",
  "-- control")
