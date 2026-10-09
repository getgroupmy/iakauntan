# Mutants for public.clock_in and public.clock_out (0789) -- HR punches
# for somebody else only in its own company, and an HR manager who is
# not on the payroll can do it in both directions.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0789_a_company_clocks_its_own_people.sql \
#       supabase/tests/clock_out.sql \
#       supabase/tests/mutants/a_company_clocks_its_own_people.py
#
# RESULT: 6 mutants and a control, all 6 killed by `clock_out.sql`'s
# `0789` block -- after one more assertion: nothing had ever asked
# that a member who is not HR cannot clock somebody else IN (the file
# asked it of clocking out). Worth knowing from the run: with the
# company check removed, `clock_in` naming another company's employee
# who was already in that morning is not refused at all -- the upsert
# meets their day on `(employee_id, work_date)`, changes nothing, and
# hands back the id of the other company's attendance record.

I = "clock_in"
O = "clock_out"

m("clock_in: another company's employee is clocked in", I,
  "    if not exists (select 1 from public.employees e\n                    where e.id = p_employee_id and e.org_id = p_org_id) then\n      raise exception 'No such employee in this company.'",
  "    if false then  -- any company\n      raise exception 'No such employee in this company.'",
  "-- any company")

m("clock_in: the employee is looked for in any company", I,
  "                    where e.id = p_employee_id and e.org_id = p_org_id) then",
  "                    where e.id = p_employee_id) then  -- no company",
  "-- no company")

m("clock_in: `<>` again, so HR off the payroll never branches", I,
  "  if p_employee_id is not null and p_employee_id is distinct from v_me then",
  "  if p_employee_id is not null and p_employee_id <> v_me then  -- three-valued",
  "-- three-valued")

m("clock_in: anybody may punch for somebody else", I,
  "    if not app.can_manage_hr(p_org_id) then\n      raise exception 'Only HR may clock in",
  "    if false then  -- anybody\n      raise exception 'Only HR may clock in",
  "-- anybody")

m("clock_out: another company's employee's day is closed", O,
  "    if not exists (select 1 from public.employees e\n                    where e.id = p_employee_id and e.org_id = p_org_id) then\n      raise exception 'No such employee in this company.'",
  "    if false then  -- any company\n      raise exception 'No such employee in this company.'",
  "-- any company")

m("clock_out: the employee is looked for in any company", O,
  "                    where e.id = p_employee_id and e.org_id = p_org_id) then",
  "                    where e.id = p_employee_id) then  -- no company",
  "-- no company")

m("CONTROL", O,
  "  update public.attendance_records set\n    clock_out = now(),",
  "  update public.attendance_records set  -- control\n    clock_out = now(),",
  "-- control")
