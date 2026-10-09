# Mutants for public.void_strata_charge_run (0585) -- the strata twin
# of `void_rent_run`, mutated the same way: a charge run undone by
# somebody who may post, never twice, never without a reason, never
# while any of ITS invoices is paid or accepted by LHDN, voiding each of
# its invoices and no other run's, saying how many, and marking the run
# voided with who, when and why.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0585_the_way_back_from_a_billing_run.sql \
#       supabase/tests/property.sql \
#       supabase/tests/mutants/void_strata_charge_run.py
#
# RESULT: 16 mutants and a control, all killed by `property.sql` -- and
# all but two only after its rule-by-rule assertions. One call stood
# behind this function, undoing a quarter so it could be raised again,
# which killed only "the run is not marked voided" and "every run's
# invoices are voided".

m("a run that does not exist is not said so",
  "void_strata_charge_run",
  "  if v_run.id is null then\n    raise exception 'No such charge run.'",
  "  if false then  -- no such run\n    raise exception 'No such charge run.'",
  "-- no such run")

m("anybody undoes a charge run",
  "void_strata_charge_run",
  "  if not app.can_post(v_run.org_id) then\n    raise exception 'Insufficient privileges to void a charge run'",
  "  if false then  -- anybody\n    raise exception 'Insufficient privileges to void a charge run'",
  "-- anybody")

m("a run already voided is undone again",
  "void_strata_charge_run",
  "  if v_run.voided_at is not null then",
  "  if false then  -- twice",
  "-- twice")

m("a run is undone without a reason",
  "void_strata_charge_run",
  "  if nullif(btrim(coalesce(p_reason, '')), '') is null then",
  "  if false then  -- no reason",
  "-- no reason")

m("a paid invoice does not hold the run",
  "void_strata_charge_run",
  "     and (d.paid_amount > 0 or d.einvoice_status = 'valid');",
  "     and (false or d.einvoice_status = 'valid');  -- paid ignored",
  "-- paid ignored")

m("an invoice LHDN accepted does not hold the run",
  "void_strata_charge_run",
  "     and (d.paid_amount > 0 or d.einvoice_status = 'valid');",
  "     and (d.paid_amount > 0 or false);  -- valid ignored",
  "-- valid ignored")

m("another run's paid invoice holds this one",
  "void_strata_charge_run",
  "   where l.run_id = p_run\n     and (d.paid_amount > 0",
  "   where true  -- any run\n     and (d.paid_amount > 0",
  "-- any run")

m("nothing holds the run at all",
  "void_strata_charge_run",
  "  if v_paid > 0 then",
  "  if false then  -- nothing holds it",
  "-- nothing holds it")

m("the invoices are not voided",
  "void_strata_charge_run",
  "    perform public.void_sales_document(\n      v_line.invoice_id,\n      format('Charge run %s voided: %s', v_run.run_no, btrim(p_reason)));",
  "    perform 1;  -- invoices kept",
  "-- invoices kept")

m("every run's invoices are voided, not this one's",
  "void_strata_charge_run",
  "     where l.run_id = p_run and l.invoice_id is not null",
  "     where l.invoice_id is not null  -- every run",
  "-- every run")

m("the invoices are voided without saying which run or why",
  "void_strata_charge_run",
  "      format('Charge run %s voided: %s', v_run.run_no, btrim(p_reason)));",
  "      null);  -- no invoice reason",
  "-- no invoice reason")

m("the count says nothing was voided",
  "void_strata_charge_run",
  "    v_n := v_n + 1;",
  "    v_n := v_n;  -- not counted",
  "-- not counted")

m("the run is not marked voided",
  "void_strata_charge_run",
  "     set voided_at = now(), voided_by = auth.uid(),\n         void_reason = btrim(p_reason)\n   where id = p_run;\n\n  return v_n;",
  "     set void_reason = btrim(p_reason)  -- not marked\n   where id = p_run;\n\n  return v_n;",
  "-- not marked")

m("who undid it is not recorded",
  "void_strata_charge_run",
  "     set voided_at = now(), voided_by = auth.uid(),\n         void_reason = btrim(p_reason)\n   where id = p_run;\n\n  return v_n;",
  "     set voided_at = now(), voided_by = null,  -- nobody\n         void_reason = btrim(p_reason)\n   where id = p_run;\n\n  return v_n;",
  "-- nobody")

m("why is not recorded",
  "void_strata_charge_run",
  "     set voided_at = now(), voided_by = auth.uid(),\n         void_reason = btrim(p_reason)\n   where id = p_run;\n\n  return v_n;",
  "     set voided_at = now(), voided_by = auth.uid(),\n         void_reason = null  -- no why\n   where id = p_run;\n\n  return v_n;",
  "-- no why")

m("why is kept with its spaces",
  "void_strata_charge_run",
  "     set voided_at = now(), voided_by = auth.uid(),\n         void_reason = btrim(p_reason)\n   where id = p_run;\n\n  return v_n;",
  "     set voided_at = now(), voided_by = auth.uid(),\n         void_reason = p_reason  -- untrimmed\n   where id = p_run;\n\n  return v_n;",
  "-- untrimmed")

m("CONTROL: a comment inside the block",
  "void_strata_charge_run",
  "  if v_run.voided_at is not null then",
  "  if v_run.voided_at is not null then  -- (control)",
  "(control)")
