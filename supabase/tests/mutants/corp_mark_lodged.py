# Mutants for public.corp_mark_lodged (0378) -- recording that an SSM
# filing was lodged: by whom, when, under what reference, at what fee.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0378_saying_no_and_who_lodged_it.sql \
#       supabase/tests/decline_and_lodge.sql \
#       supabase/tests/mutants/corp_mark_lodged.py
#
# then again against `corp_deadlines.sql` and `corp_filing_shapes.sql`.
#
# RESULT: 12 mutants and a control. 12 killed: decline_and_lodge.sql
# takes ten, corp_filing_shapes.sql the reader and the missing date.
#
#   Two survived every file: a filing SSM has APPROVED lodged a second
#   time, and one lodged on the very day of its event refused as early.
#   "corp_mark_lodged, rule by rule" asks both.

m("a reader records a lodgement",
  "corp_mark_lodged",
  "  if not app.can_write(f.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a lodged filing is lodged again",
  "corp_mark_lodged",
  "  if f.status in ('lodged', 'approved') then",
  "  if f.status in ('approved') then  -- relodge",
  "-- relodge")

m("an approved filing is lodged again",
  "corp_mark_lodged",
  "  if f.status in ('lodged', 'approved') then",
  "  if f.status in ('lodged') then  -- approved relodge",
  "-- approved relodge")

m("a lodgement in the future is accepted",
  "corp_mark_lodged",
  "  if v_on > (now() at time zone 'Asia/Kuala_Lumpur')::date then",
  "  if false then  -- future fine",
  "-- future fine")

m("lodged today is the future",
  "corp_mark_lodged",
  "  if v_on > (now() at time zone 'Asia/Kuala_Lumpur')::date then",
  "  if v_on >= (now() at time zone 'Asia/Kuala_Lumpur')::date then  -- today future",
  "-- today future")

m("lodged before the event is accepted",
  "corp_mark_lodged",
  "  if v_on < f.trigger_date then",
  "  if false then  -- before event",
  "-- before event")

m("lodged on the day of the event is refused",
  "corp_mark_lodged",
  "  if v_on < f.trigger_date then",
  "  if v_on <= f.trigger_date then  -- same day",
  "-- same day")

m("a negative fee is accepted",
  "corp_mark_lodged",
  "  if p_fee_paid is not null and p_fee_paid < 0 then",
  "  if false then  -- negative fee",
  "-- negative fee")

m("no date given is no date",
  "corp_mark_lodged",
  "  v_on := coalesce(p_lodged_on,\n                   (now() at time zone 'Asia/Kuala_Lumpur')::date);",
  "  v_on := p_lodged_on;  -- no default",
  "-- no default")

m("the reference keeps its spaces",
  "corp_mark_lodged",
  "    ssm_reference = nullif(btrim(coalesce(p_reference, '')), ''),",
  "    ssm_reference = p_reference,  -- untrimmed",
  "-- untrimmed")

m("who lodged it is not recorded",
  "corp_mark_lodged",
  "    lodged_by     = auth.uid(),",
  "    lodged_by     = null,  -- nobody",
  "-- nobody")

m("the fee is not recorded",
  "corp_mark_lodged",
  "    fee_paid      = p_fee_paid,",
  "    fee_paid      = null,  -- no fee",
  "-- no fee")

m("CONTROL: a comment inside the block",
  "corp_mark_lodged",
  "  -- The guard the app was carrying on its own. A lodgement is a thing",
  "  -- CONTROL\n  -- The guard the app was carrying on its own. A lodgement is a thing",
  "-- CONTROL")
