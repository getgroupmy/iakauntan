# Mutants for public.close_pos_shift (0206) -- a till's shift closed on a
# counted drawer: by somebody who may write POS, never twice, never
# without a figure or with a negative one, never over a parked sale,
# and more than the tolerance out only by a manager; the expected cash,
# the count, the variance (counted less expected), who and when recorded.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0206_pos_outlets_registers_and_shifts.sql \
#       supabase/tests/pos_drawer_shapes.sql \
#       supabase/tests/mutants/close_pos_shift.py
#
# RESULT: 20 mutants and a control, all killed by `pos_drawer_shapes.sql`.
# Two only after it asserted them -- who closed the shift, and a note
# given at the close replacing the morning's; `pos_counting.sql`,
# `pos.sql` and `pos_offline.sql` asserted neither.

m("a shift that does not exist is not said so",
  "close_pos_shift",
  "  if v_org is null then\n    raise exception 'No such shift.'",
  "  if false then  -- no such shift\n    raise exception 'No such shift.'",
  "-- no such shift")

m("anybody closes a till",
  "close_pos_shift",
  "  if not app.can_write_module(v_org, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a closed shift is closed again",
  "close_pos_shift",
  "  if v_status = 'closed' then",
  "  if false then  -- twice",
  "-- twice")

m("a shift is closed with no count",
  "close_pos_shift",
  "  if p_declared is null or p_declared < 0 then",
  "  if p_declared < 0 then  -- no count",
  "-- no count")

m("a shift is closed on a negative count",
  "close_pos_shift",
  "  if p_declared is null or p_declared < 0 then",
  "  if p_declared is null then  -- negative count",
  "-- negative count")

m("a shift is closed over a parked sale",
  "close_pos_shift",
  "    if coalesce(v_open, 0) > 0 then",
  "    if false then  -- parked ignored",
  "-- parked ignored")

m("the tolerance is crossed AT it, not past it",
  "close_pos_shift",
  "  if v_tolerance is not null and abs(v_variance) > v_tolerance",
  "  if v_tolerance is not null and abs(v_variance) >= v_tolerance  -- at the line",
  "-- at the line")

m("a manager is held to the tolerance too",
  "close_pos_shift",
  "     and not app.can_admin(v_org) then",
  "     and true then  -- managers too",
  "-- managers too")

m("nobody is held to the tolerance",
  "close_pos_shift",
  "  if v_tolerance is not null and abs(v_variance) > v_tolerance",
  "  if false and abs(v_variance) > v_tolerance  -- no tolerance",
  "-- no tolerance")

m("only a shortage is held to the tolerance",
  "close_pos_shift",
  "  if v_tolerance is not null and abs(v_variance) > v_tolerance",
  "  if v_tolerance is not null and -v_variance > v_tolerance  -- shortage only",
  "-- shortage only")

m("the variance is expected less counted",
  "close_pos_shift",
  "  v_variance := round(p_declared - v_expected, 2);",
  "  v_variance := round(v_expected - p_declared, 2);  -- sign flipped",
  "-- sign flipped")

m("the shift is not marked closed",
  "close_pos_shift",
  "     set status = 'closed',",
  "     set status = s.status,  -- still open",
  "-- still open")

m("who closed it is not recorded",
  "close_pos_shift",
  "         closed_by = auth.uid(),",
  "         closed_by = null,  -- nobody",
  "-- nobody")

m("when it closed is not recorded",
  "close_pos_shift",
  "         closed_at = now(),",
  "         closed_at = null,  -- never",
  "-- never")

m("the count is not kept",
  "close_pos_shift",
  "         declared_cash = p_declared,",
  "         declared_cash = null,  -- no count kept",
  "-- no count kept")

m("what was expected is not kept",
  "close_pos_shift",
  "         expected_cash = v_expected,",
  "         expected_cash = null,  -- no expectation kept",
  "-- no expectation kept")

m("the variance is not kept",
  "close_pos_shift",
  "         variance = v_variance,",
  "         variance = null,  -- no variance kept",
  "-- no variance kept")

m("closing without a note wipes the one already there",
  "close_pos_shift",
  "         notes = coalesce(p_notes, s.notes)",
  "         notes = p_notes  -- wipes",
  "-- wipes")

m("closing with a note keeps the old one instead",
  "close_pos_shift",
  "         notes = coalesce(p_notes, s.notes)",
  "         notes = coalesce(s.notes, p_notes)  -- old wins",
  "-- old wins")

m("what is returned is not what was recorded",
  "close_pos_shift",
  "  variance := v_variance;\n  return next;",
  "  variance := 0;  -- returns no variance\n  return next;",
  "-- returns no variance")

m("CONTROL: a comment inside the block",
  "close_pos_shift",
  "  if v_status = 'closed' then",
  "  if v_status = 'closed' then  -- (control)",
  "(control)")
