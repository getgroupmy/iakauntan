# Mutants for app.record_terminal_punch (0612) -- one punch from a wall
# terminal: recorded once whatever happens, matched to whoever is
# enrolled under that number on that terminal, and turned into the
# day's clock-in or clock-out.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0612_the_punch_the_clock_on_the_wall_made.sql \
#       supabase/tests/terminal_punches.sql \
#       supabase/tests/mutants/record_terminal_punch.py
#
# RESULT: 24 mutants and a control. 24 killed by `terminal_punches.sql`,
# fourteen only after a rule-by-rule block there. The fixture's employee
# was on no roster, so lateness and its grace were never measured; every
# refused punch was an unknown number, so a missing terminal, time or
# number never arrived; the out-of-order test sent the later clock-in
# first, which earliest-wins and its opposite answer alike; and nothing
# read the terminal's last-seen and last-punch times, which day a punch
# before eight in the morning lands on, or the punch's link to its day.
#
# Recorded in the block's header, not asserted: a punch's lateness is
# measured on any day the roster names (as `clock_in`'s is), while a
# corrected morning re-read by `recompute_attendance` gives a rest day
# or a holiday none. Nothing that pays reads `late_minutes`.

m("a terminal that does not exist is answered",
  "record_terminal_punch",
  "  if v_term.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("a switched-off terminal is heard",
  "record_terminal_punch",
  "  if not v_term.is_active then",
  "  if false then  -- always on",
  "-- always on")

m("a punch needs no time",
  "record_terminal_punch",
  "  if p_punched_at is null then",
  "  if false then  -- whenever",
  "-- whenever")

m("a punch needs no user number",
  "record_terminal_punch",
  "  if v_no = '' then",
  "  if false then  -- anonymous",
  "-- anonymous")

m("the number is kept with its spaces",
  "record_terminal_punch",
  "  v_no := btrim(coalesce(p_enrolment_no, ''));",
  "  v_no := coalesce(p_enrolment_no, '');  -- as sent",
  "-- as sent")

m("another terminal's enrolment answers",
  "record_terminal_punch",
  "   where e.terminal_id = p_terminal_id\n     and ltrim(e.enrolment_no, '0') = ltrim(v_no, '0');",
  "   where true  -- any terminal\n     and ltrim(e.enrolment_no, '0') = ltrim(v_no, '0');",
  "-- any terminal")

m("leading zeros make a different number",
  "record_terminal_punch",
  "     and ltrim(e.enrolment_no, '0') = ltrim(v_no, '0');",
  "     and e.enrolment_no = v_no;  -- zero-padded differs",
  "-- zero-padded differs")

m("an unknown number says nothing of why",
  "record_terminal_punch",
  "    v_prob := format('No employee is enrolled as %s on this terminal', v_no);",
  "    v_prob := null;  -- unexplained",
  "-- unexplained")

m("the punch is filed under another company",
  "record_terminal_punch",
  "  values (v_term.org_id, p_terminal_id, v_no, p_punched_at,\n          nullif(p_direction, ''), v_emp, v_prob)",
  "  values ((select id from public.organizations limit 1), p_terminal_id, v_no, p_punched_at,  -- elsewhere\n          nullif(p_direction, ''), v_emp, v_prob)",
  "-- elsewhere")

m("the terminal is not seen",
  "record_terminal_punch",
  "     set last_seen_at = now(),",
  "     set last_seen_at = last_seen_at,  -- unseen",
  "-- unseen")

m("the latest punch is the one just sent, even an older one",
  "record_terminal_punch",
  "         last_punch_at = greatest(coalesce(last_punch_at, p_punched_at),\n                                  p_punched_at)",
  "         last_punch_at = p_punched_at  -- backwards too",
  "-- backwards too")

m("a repeated punch is not reported as one",
  "record_terminal_punch",
  "    return jsonb_build_object('ok', true, 'duplicate', true);",
  "    return jsonb_build_object('ok', true);  -- quietly",
  "-- quietly")

m("a repeated punch is applied again",
  "record_terminal_punch",
  "  if v_punch is null then\n    return jsonb_build_object('ok', true, 'duplicate', true);\n  end if;",
  "  if false then  -- again\n    return jsonb_build_object('ok', true, 'duplicate', true);\n  end if;",
  "-- again")

m("an unknown number is applied to nobody's day",
  "record_terminal_punch",
  "  if v_emp is null then\n    return jsonb_build_object('ok', false, 'problem', v_prob);",
  "  if false then  -- onwards\n    return jsonb_build_object('ok', false, 'problem', v_prob);",
  "-- onwards")

m("the day is the UTC day",
  "record_terminal_punch",
  "  v_date := (p_punched_at at time zone 'Asia/Kuala_Lumpur')::date;",
  "  v_date := (p_punched_at at time zone 'UTC')::date;  -- wrong clock",
  "-- wrong clock")

m("an undirected first punch is a clock-out",
  "record_terminal_punch",
  "    v_dir := case when v_rec.id is null or v_rec.clock_in is null\n                  then 'in' else 'out' end;",
  "    v_dir := 'out';  -- always out",
  "-- always out")

m("an undirected second punch is another clock-in",
  "record_terminal_punch",
  "    v_dir := case when v_rec.id is null or v_rec.clock_in is null\n                  then 'in' else 'out' end;",
  "    v_dir := 'in';  -- always in",
  "-- always in")

m("there is no grace",
  "record_terminal_punch",
  "        )) / 60)::integer - coalesce(v_shift.grace_minutes, 0));",
  "        )) / 60)::integer - 0);  -- no grace",
  "-- no grace")

m("nobody is late",
  "record_terminal_punch",
  "      case when v_late > 0 then 'late'::app.attendance_status",
  "      case when false then 'late'::app.attendance_status  -- punctual",
  "-- punctual")

m("a later clock-in replaces an earlier one",
  "record_terminal_punch",
  "      set clock_in = least(coalesce(a.clock_in, excluded.clock_in),\n                           excluded.clock_in),",
  "      set clock_in = excluded.clock_in,  -- the last one wins",
  "-- the last one wins")

m("a later clock-in's lateness replaces the earlier one's",
  "record_terminal_punch",
  "          late_minutes = case\n            when excluded.clock_in < coalesce(a.clock_in, excluded.clock_in)\n            then excluded.late_minutes else a.late_minutes end",
  "          late_minutes = excluded.late_minutes  -- the last one's",
  "-- the last one's")

m("an earlier clock-out replaces a later one",
  "record_terminal_punch",
  "         set clock_out = greatest(coalesce(clock_out, p_punched_at),\n                                  p_punched_at),",
  "         set clock_out = p_punched_at,  -- the last one sent",
  "-- the last one sent")

m("a clock-out is not measured",
  "record_terminal_punch",
  "    perform app.recompute_attendance(v_att);",
  "    null;  -- unmeasured",
  "-- unmeasured")

m("the punch is not tied to the day it made",
  "record_terminal_punch",
  "     set attendance_id = v_att, direction = v_dir",
  "     set attendance_id = null, direction = v_dir  -- loose",
  "-- loose")

m("CONTROL: a comment inside the block",
  "record_terminal_punch",
  "  v_date := (p_punched_at at time zone 'Asia/Kuala_Lumpur')::date;",
  "  v_date := (p_punched_at at time zone 'Asia/Kuala_Lumpur')::date;  -- (control)",
  "(control)")
