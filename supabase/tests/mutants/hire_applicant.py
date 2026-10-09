# Mutants for public.hire_applicant (0381, restated in 0784) -- an
# applicant becomes an
# employee once, by somebody who manages HR, carrying name, email,
# phone and NRIC across; not while rejected or withdrawn; with a start
# date and an employee number; inside their notice period only with a
# note; not against a cancelled requisition (since 0784), nor past the
# requisition's headcount, which is marked filled on the day its last
# place is taken.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0784_a_cancelled_vacancy_is_not_hired_into.sql \
#       supabase/tests/hiring.sql \
#       supabase/tests/mutants/hire_applicant.py
#
# RESULT: 25 mutants and a control. 24 killed by `hiring.sql`. Swept
# first against 0381: 19 of 24 -- no rejected applicant, nobody started
# on the last day of notice, no number with spaces, no reading of who
# the history names, and no cancelled requisition; the last of those
# was raised and built as `0784`.
#
# One is EQUIVALENT since `0784`: "a cancelled requisition is marked
# filled". The function now refuses a cancelled requisition before it
# reaches the paragraph that fills one, so `status <> 'cancelled'`
# there can no longer be false.

F = "hire_applicant"

m("no such applicant is not said so", F,
  "  if v_a.id is null then\n    raise exception 'No such applicant.'",
  "  if false then  -- any id\n    raise exception 'No such applicant.'",
  "-- any id")

m("anybody hires", F,
  "  if not app.can_manage_hr(v_a.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an applicant is hired twice", F,
  "  if v_a.hired_employee_id is not null then",
  "  if false then  -- twice",
  "-- twice")

m("a rejected applicant is hired", F,
  "  if v_a.status in ('rejected', 'withdrawn') then",
  "  if v_a.status in ('withdrawn') then  -- rejected hired",
  "-- rejected hired")

m("a withdrawn applicant is hired", F,
  "  if v_a.status in ('rejected', 'withdrawn') then",
  "  if v_a.status in ('rejected') then  -- withdrawn hired",
  "-- withdrawn hired")

m("no start date is needed", F,
  "  if p_hire_date is null then",
  "  if false then  -- no date",
  "-- no date")

m("no employee number is needed", F,
  "  if btrim(coalesce(p_employee_no, '')) = '' then",
  "  if false then  -- no number",
  "-- no number")

m("notice is ignored", F,
  "  if coalesce(v_a.notice_period_days, 0) > 0 then",
  "  if false then  -- no notice",
  "-- no notice")

m("the last day of notice is too early", F,
  "    if p_hire_date < v_earliest",
  "    if p_hire_date <= v_earliest  -- the day itself",
  "-- the day itself")

m("a note does not let an early start through", F,
  "       and btrim(coalesce(p_early_start_note, '')) = '' then",
  "       then  -- note ignored",
  "-- note ignored")

m("the headcount is not asked", F,
  "    if v_hired >= v_req.headcount then",
  "    if false then  -- any number",
  "-- any number")

m("the last place cannot be filled", F,
  "    if v_hired >= v_req.headcount then",
  "    if v_hired + 1 >= v_req.headcount then  -- one short",
  "-- one short")

m("the number keeps its spaces", F,
  "  values (v_a.org_id, btrim(p_employee_no), v_a.full_name, v_a.email,",
  "  values (v_a.org_id, p_employee_no, v_a.full_name, v_a.email,  -- untrimmed",
  "-- untrimmed")

m("the NRIC is not carried", F,
  "          v_a.phone, v_a.nric, p_hire_date, p_basic_salary,",
  "          v_a.phone, null, p_hire_date, p_basic_salary,  -- no nric",
  "-- no nric")

m("the phone is not carried", F,
  "          v_a.phone, v_a.nric, p_hire_date, p_basic_salary,",
  "          null, v_a.nric, p_hire_date, p_basic_salary,  -- no phone",
  "-- no phone")

m("the requisition's employment type is not carried", F,
  "          coalesce(v_req.employment_type, 'full_time'), 'probation')",
  "          'full_time', 'probation')  -- always full time",
  "-- always full time")

m("a new hire starts confirmed", F,
  "          coalesce(v_req.employment_type, 'full_time'), 'probation')",
  "          coalesce(v_req.employment_type, 'full_time'), 'active')  -- confirmed",
  "-- confirmed")

m("the applicant is not marked hired", F,
  "    status            = 'hired',",
  "    status            = status,  -- status kept",
  "-- status kept")

m("the history does not record the note", F,
  "          nullif(btrim(coalesce(p_early_start_note, '')), ''), auth.uid());",
  "          null, auth.uid());  -- no note",
  "-- no note")

m("the history records nobody", F,
  "          nullif(btrim(coalesce(p_early_start_note, '')), ''), auth.uid());",
  "          nullif(btrim(coalesce(p_early_start_note, '')), ''), null);  -- nobody",
  "-- nobody")

m("the requisition is filled a place early", F,
  "  if v_req.id is not null and v_hired + 1 >= v_req.headcount then",
  "  if v_req.id is not null and v_hired + 2 >= v_req.headcount then  -- early",
  "-- early")

m("the requisition is never filled", F,
  "  if v_req.id is not null and v_hired + 1 >= v_req.headcount then",
  "  if false then  -- never filled",
  "-- never filled")

m("a cancelled requisition is marked filled", F,
  "     where id = v_req.id and status <> 'cancelled';",
  "     where id = v_req.id;  -- cancelled filled",
  "-- cancelled filled")

m("the requisition is closed undated", F,
  "       set status = 'filled', closed_date = v_today, updated_at = now()",
  "       set status = 'filled', closed_date = null, updated_at = now()  -- undated",
  "-- undated")

m("a cancelled requisition is hired into (as before 0784)", F,
  "    if v_req.status = 'cancelled' then",
  "    if false then  -- cancelled taken",
  "-- cancelled taken")

m("CONTROL: a comment inside the block", F,
  "  if p_hire_date is null then",
  "  if p_hire_date is null then  -- (control)",
  "(control)")
