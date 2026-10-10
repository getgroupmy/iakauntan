# Mutants for public.set_membership_status (0420) -- a membership's
# status set by hand: one that exists, for somebody who may sell
# memberships; ending one (cancelled or expired) dates its end, keeping
# an end already set, and stops its recurring billing.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0420_what_day_a_sale_happened_on.sql \
#       supabase/tests/pos_service.sql \
#       supabase/tests/mutants/set_membership_status.py
#
# RESULT: 9 mutants and a control, all 9 killed by `pos_service.sql`,
# from 1: eight only after its rule-by-rule block -- a pause written,
# handed back, still billed and not ended; an expiry dated today and
# billed no more; an end already set kept; a missing membership and a
# stranger refused.

F = "set_membership_status"

m("a membership that is not there is set", F,
  "  if v_sub.id is null then\n    raise exception 'No such membership.'",
  "  if false then  -- ghost\n    raise exception 'No such membership.'",
  "-- ghost")
m("anybody may set it", F,
  "  if not app.can_write_module(v_sub.org_id, 'memberships') then",
  "  if false then  -- anybody",
  "-- anybody")
m("the status is not written", F,
  "     set status = p_status,",
  "     set status = s.status,  -- unwritten",
  "-- unwritten")
m("an ended membership is not dated", F,
  "         ends_on = case when p_status in ('cancelled', 'expired')\n                        then coalesce(s.ends_on, app.today()) else s.ends_on end",
  "         ends_on = s.ends_on  -- undated",
  "-- undated")
m("an end already set is moved to today", F,
  "                        then coalesce(s.ends_on, app.today()) else s.ends_on end",
  "                        then app.today() else s.ends_on end  -- moved",
  "-- moved")
m("an expired one keeps billing", F,
  "  if p_status in ('cancelled', 'expired') and v_sub.recurring_document_id is not null then",
  "  if p_status in ('cancelled') and v_sub.recurring_document_id is not null then  -- expired bills",
  "-- expired bills")
m("a cancelled one keeps billing", F,
  "       set is_active = false where r.id = v_sub.recurring_document_id;",
  "       set is_active = r.is_active where r.id = v_sub.recurring_document_id;  -- still billing",
  "-- still billing")
m("pausing it stops the billing too", F,
  "  if p_status in ('cancelled', 'expired') and v_sub.recurring_document_id is not null then",
  "  if v_sub.recurring_document_id is not null then  -- any status stops",
  "-- any status stops")
m("the status set is not handed back", F,
  "  return p_status;\nend;",
  "  return null;  -- nothing back\nend;",
  "-- nothing back")

m("CONTROL", F,
  "  v_sub public.pos_membership_subscriptions;\nbegin",
  "  v_sub public.pos_membership_subscriptions;  -- control\nbegin",
  "-- control")
