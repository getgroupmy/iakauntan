# Mutants for public.close_requisition (0394) -- a vacancy cancelled or
# put on hold: it must exist; only somebody who manages HR; only those
# two (filling is hire_applicant's); never one already filled or
# cancelled; dated the day given, else today in Kuala Lumpur, never in
# the future (today itself is fine), never before it opened (the
# opening day is fine); a cancellation gets a closing date and on hold
# does not, because on hold is still a vacancy.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0394_the_vacancy_nobody_could_open.sql \
#       supabase/tests/vacancies.sql \
#       supabase/tests/mutants/close_requisition.py
#
# RESULT: 13 mutants and a control, all killed by `vacancies.sql`; nine
# before its rule-by-rule block. The closes were by the owner, of an
# open vacancy opened twenty days back -- so a missing vacancy,
# somebody who is not HR, a FILLED one, and a cancellation on the day
# it opened were unasked.

m("a requisition that does not exist is not said so",
  "close_requisition",
  "  if r.id is null then\n    raise exception 'No such requisition.'",
  "  if false then  -- no such requisition\n    raise exception 'No such requisition.'",
  "-- no such requisition")

m("anybody closes a vacancy",
  "close_requisition",
  "  if not app.can_manage_hr(r.org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a vacancy is closed as filled",
  "close_requisition",
  "  if p_status not in ('cancelled', 'on_hold') then",
  "  if false then  -- any status",
  "-- any status")

m("a filled vacancy is closed",
  "close_requisition",
  "  if r.status in ('filled', 'cancelled') then",
  "  if r.status = 'cancelled' then  -- filled too",
  "-- filled too")

m("a cancelled vacancy is cancelled again",
  "close_requisition",
  "  if r.status in ('filled', 'cancelled') then",
  "  if r.status = 'filled' then  -- cancelled again",
  "-- cancelled again")

m("a vacancy closes in the future",
  "close_requisition",
  "  if v_on > (now() at time zone 'Asia/Kuala_Lumpur')::date then",
  "  if false then  -- future",
  "-- future")

m("a vacancy cannot close today",
  "close_requisition",
  "  if v_on > (now() at time zone 'Asia/Kuala_Lumpur')::date then",
  "  if v_on >= (now() at time zone 'Asia/Kuala_Lumpur')::date then  -- not today",
  "-- not today")

m("a vacancy closes before it opened",
  "close_requisition",
  "  if r.opened_date is not null and v_on < r.opened_date then",
  "  if false then  -- before it opened",
  "-- before it opened")

m("a vacancy cannot close on the day it opened",
  "close_requisition",
  "  if r.opened_date is not null and v_on < r.opened_date then",
  "  if r.opened_date is not null and v_on <= r.opened_date then  -- not the same day",
  "-- not the same day")

m("a date given is not used",
  "close_requisition",
  "  v_on := coalesce(p_closed_on, (now() at time zone 'Asia/Kuala_Lumpur')::date);",
  "  v_on := (now() at time zone 'Asia/Kuala_Lumpur')::date;  -- date ignored",
  "-- date ignored")

m("a vacancy on hold gets a closing date",
  "close_requisition",
  "         closed_date = case when p_status = 'cancelled' then v_on end,",
  "         closed_date = v_on,  -- hold closed too",
  "-- hold closed too")

m("a cancelled vacancy gets no closing date",
  "close_requisition",
  "         closed_date = case when p_status = 'cancelled' then v_on end,",
  "         closed_date = null,  -- no date",
  "-- no date")

m("the status is not changed",
  "close_requisition",
  "     set status = p_status,",
  "     set status = status,  -- unchanged",
  "-- unchanged")

m("CONTROL: a comment inside the block",
  "close_requisition",
  "  if r.status in ('filled', 'cancelled') then",
  "  if r.status in ('filled', 'cancelled') then  -- (control)",
  "(control)")
