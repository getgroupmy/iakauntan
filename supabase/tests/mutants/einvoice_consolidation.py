# Mutants for app.roll_einvoice_consolidation (0392) -- the month's
# consumer sales gathered into one consolidated e-Invoice -- and
# public.einvoice_consolidations_due (0616), the scheduler's list of
# consolidations coming due within LHDN's seven days.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0392_the_consolidated_einvoice_that_never_ran.sql \
#       supabase/tests/monthly_jobs.sql \
#       supabase/tests/mutants/einvoice_consolidation.py
#
# (einvoice_consolidations_due is 0616's, and has its own run below the
# RESULT.)
#
# RESULT: (pending)

m("a month is gathered twice",
  "roll_einvoice_consolidation",
  "  if exists (select 1 from public.einvoice_consolidations c\n              where c.org_id = p_org_id and c.period_start = p_month_start) then",
  "  if false then  -- again",
  "-- again")

m("another company's month blocks this one",
  "roll_einvoice_consolidation",
  "              where c.org_id = p_org_id and c.period_start = p_month_start) then",
  "              where c.period_start = p_month_start) then  -- any org",
  "-- any org")

m("a credit note is gathered as a sale",
  "roll_einvoice_consolidation",
  "   where d.org_id = p_org_id\n     and d.doc_type = 'invoice'\n     and d.status in ('posted', 'partial', 'completed')\n     and d.doc_date between p_month_start and v_end\n     and not coalesce(d.is_consolidated, false)\n     and not exists (select 1 from public.einvoice_documents e\n                      where e.source_id = d.id)\n     -- A consumer",
  "   where d.org_id = p_org_id\n     and true  -- any type\n     and d.status in ('posted', 'partial', 'completed')\n     and d.doc_date between p_month_start and v_end\n     and not coalesce(d.is_consolidated, false)\n     and not exists (select 1 from public.einvoice_documents e\n                      where e.source_id = d.id)\n     -- A consumer",
  "-- any type")

m("a draft is counted",
  "roll_einvoice_consolidation",
  "     and d.status in ('posted', 'partial', 'completed')\n     and d.doc_date between p_month_start and v_end\n     and not coalesce(d.is_consolidated, false)\n     and not exists (select 1 from public.einvoice_documents e\n                      where e.source_id = d.id)\n     -- A consumer",
  "     and true  -- any status\n     and d.doc_date between p_month_start and v_end\n     and not coalesce(d.is_consolidated, false)\n     and not exists (select 1 from public.einvoice_documents e\n                      where e.source_id = d.id)\n     -- A consumer",
  "-- any status")

m("the month's last day is left out",
  "roll_einvoice_consolidation",
  "  v_end date := (p_month_start + interval '1 month' - interval '1 day')::date;",
  "  v_end date := (p_month_start + interval '1 month' - interval '2 days')::date;  -- short",
  "-- short")

m("a sale already consolidated is counted again",
  "roll_einvoice_consolidation",
  "     and not coalesce(d.is_consolidated, false)\n     and not exists (select 1 from public.einvoice_documents e\n                      where e.source_id = d.id)\n     -- A consumer",
  "     and true  -- again\n     and not exists (select 1 from public.einvoice_documents e\n                      where e.source_id = d.id)\n     -- A consumer",
  "-- again")

m("a sale with its own e-Invoice is counted",
  "roll_einvoice_consolidation",
  "     and not exists (select 1 from public.einvoice_documents e\n                      where e.source_id = d.id)\n     -- A consumer",
  "     and true  -- own einvoice\n     -- A consumer",
  "-- own einvoice")

m("a buyer with a TIN is consolidated",
  "roll_einvoice_consolidation",
  "     -- A consumer: no TIN to issue an individual e-Invoice against.\n     and coalesce(nullif(btrim(c.tin), ''), '') = '';",
  "     -- A consumer: no TIN to issue an individual e-Invoice against.\n     and true;  -- any buyer",
  "-- any buyer")

m("an empty month is written",
  "roll_einvoice_consolidation",
  "  if v_count = 0 then return null; end if;",
  "  null;  -- empty",
  "-- empty")

m("the items list a buyer with a TIN",
  "roll_einvoice_consolidation",
  "     and not exists (select 1 from public.einvoice_documents e\n                      where e.source_id = d.id)\n     and coalesce(nullif(btrim(c.tin), ''), '') = '';\n\n  return v_id;",
  "     and not exists (select 1 from public.einvoice_documents e\n                      where e.source_id = d.id)\n     and true;  -- items any buyer\n\n  return v_id;",
  "-- items any buyer")

m("the total is the count",
  "roll_einvoice_consolidation",
  "  select count(*), coalesce(sum(d.total_amount), 0) into v_count, v_total",
  "  select count(*), count(*) into v_count, v_total  -- count",
  "-- count")

m("CONTROL: a comment inside the block",
  "roll_einvoice_consolidation",
  "  if v_count = 0 then return null; end if;",
  "  -- CONTROL\n  if v_count = 0 then return null; end if;",
  "-- CONTROL")
