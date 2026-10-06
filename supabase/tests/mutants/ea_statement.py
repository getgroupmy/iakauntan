# Mutants for public.ea_statement (0608) -- the EA form an employer
# gives every employee by the end of February, which the employee files
# from: remuneration by EA box, the PCB, CP38 and zakat deducted, the
# EPF/SOCSO/EIS paid, the period employed, a previous employer's
# figures, and who may read it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0608_what_the_ea_form_has_boxes_for.sql \
#       supabase/tests/ea_form.sql \
#       supabase/tests/mutants/ea_statement.py

m("anybody in the company may read anybody's EA form",
  "ea_statement",
  "         or p_employee_id = app.my_employee_id(v_emp.org_id),",
  "         or true,  -- anyone's",
  "-- anyone's")

m("an employee may not read their OWN EA form",
  "ea_statement",
  "         or p_employee_id = app.my_employee_id(v_emp.org_id),",
  "         or false,  -- own refused",
  "-- own refused")

m("the payroll module being off does not stop it",
  "ea_statement",
  "  if not app.can_read_module(v_emp.org_id, 'payroll') then",
  "  if false then  -- module unchecked",
  "-- module unchecked")

m("pay from a run never posted is put in the boxes",
  "ea_statement",
  "     where p.employee_id = p_employee_id\n"
  "       and r.posted_at is not null\n"
  "       and extract(year from coalesce(p.pay_date, pp.pay_date)) = p_tax_year\n"
  "  ), lines as (",
  "     where p.employee_id = p_employee_id\n"
  "       and extract(year from coalesce(p.pay_date, pp.pay_date)) = p_tax_year  -- unposted boxed\n"
  "  ), lines as (",
  "-- unposted boxed")

m("the year is decided by the pay period, not the day it was paid",
  "ea_statement",
  "    select p.id, coalesce(p.pay_date, pp.pay_date) as pay_date",
  "    select p.id, coalesce(pp.pay_date, p.pay_date) as pay_date  -- period first",
  "-- period first")

m("non-taxable earnings are put in the boxes",
  "ea_statement",
  "     where l.kind = 'earning'\n       and l.is_taxable",
  "     where l.kind = 'earning'  -- exempt included",
  "-- exempt included")

m("deductions are put in the boxes as income",
  "ea_statement",
  "     where l.kind = 'earning'\n       and l.is_taxable",
  "     where l.is_taxable  -- any kind",
  "-- any kind")

m("a bonus is filed as salary",
  "ea_statement",
  "        case when l.is_additional_remuneration then 'fees_bonus'\n"
  "             else 'salary' end) as box,",
  "        'salary') as box,  -- bonus as salary",
  "-- bonus as salary")

m("a component's own EA box is ignored",
  "ea_statement",
  "        sc.ea_category,\n",
  "        null::text,  -- component box ignored\n",
  "-- component box ignored")

m("the totals include runs never posted",
  "ea_statement",
  "     and r.posted_at is not null\n"
  "     and extract(year from coalesce(p.pay_date, pp.pay_date)) = p_tax_year;",
  "     and extract(year from coalesce(p.pay_date, pp.pay_date)) = p_tax_year;  -- unposted totalled",
  "-- unposted totalled")

m("the MTD deducted is reported as CP38",
  "ea_statement",
  "      'mtd', round(coalesce(v_totals.pcb, 0), 2),",
  "      'mtd', round(coalesce(v_totals.cp38, 0), 2),  -- mtd from cp38",
  "-- mtd from cp38")

m("the employer's EPF is reported as the employee's",
  "ea_statement",
  "      'epf_employee', round(coalesce(v_totals.epf_employee, 0), 2),\n"
  "      'epf_employer',",
  "      'epf_employee', round(coalesce(v_totals.epf_employer, 0), 2),  -- employer as employee\n"
  "      'epf_employer',",
  "-- employer as employee")

m("zakat deducted is left off",
  "ea_statement",
  "      'zakat', round(coalesce(v_totals.zakat, 0), 2)),",
  "      'zakat', 0),  -- zakat dropped",
  "-- zakat dropped")

m("someone hired in an earlier year is employed from their hire date",
  "ea_statement",
  "  v_first := greatest(coalesce(v_emp.hire_date, make_date(p_tax_year, 1, 1)),\n"
  "                      make_date(p_tax_year, 1, 1));",
  "  v_first := coalesce(v_emp.hire_date, make_date(p_tax_year, 1, 1));  -- year floor dropped",
  "-- year floor dropped")

m("someone who left in a LATER year is shown as leaving then",
  "ea_statement",
  "  v_last  := least(coalesce(v_emp.last_working_date,\n"
  "                            make_date(p_tax_year, 12, 31)),\n"
  "                   make_date(p_tax_year, 12, 31));",
  "  v_last  := coalesce(v_emp.last_working_date,\n"
  "                            make_date(p_tax_year, 12, 31));  -- year ceiling dropped",
  "-- year ceiling dropped")

m("an employee with only a TIN shows no income tax number",
  "ea_statement",
  "      'income_tax_no', coalesce(v_emp.income_tax_no, v_emp.tin),",
  "      'income_tax_no', v_emp.income_tax_no,  -- tin fallback dropped",
  "-- tin fallback dropped")

m("a previous employer's figures are never shown",
  "ea_statement",
  "    'previous_employer', case when v_open.employee_id is null then null",
  "    'previous_employer', case when true then null  -- previous employer dropped",
  "-- previous employer dropped")

m("a previous employer's PCB is shown as nothing",
  "ea_statement",
  "        'pcb_paid', round(coalesce(v_open.pcb_paid, 0), 2),",
  "        'pcb_paid', 0,  -- previous pcb dropped",
  "-- previous pcb dropped")

m("CONTROL -- a comment inside the function block",
  "ea_statement",
  "  select * into v_org from public.organizations where id = v_emp.org_id;",
  "  select * into v_org from public.organizations where id = v_emp.org_id;  -- CONTROL: this cannot change a box.",
  "-- CONTROL: this cannot change a box.")
