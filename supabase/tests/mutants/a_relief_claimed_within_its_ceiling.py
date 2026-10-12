# Mutants for 0836 -- app.a_relief_claimed_within_its_ceiling refuses a
# claim that takes a relief's total on a Form B or BE computation above
# its ceiling in the PCB schedule in force at the basis period's end.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0836_a_relief_claimed_within_its_ceiling.sql \
#       supabase/tests/relief_ceiling_on_form_b.sql \
#       supabase/tests/mutants/a_relief_claimed_within_its_ceiling.py
#
# RESULT, 12 October: 8 of 9 killed by relief_ceiling_on_form_b.sql,
# the control surviving.
#
# EQUIVALENT: "a relief without a ceiling is refused" drops the
# `max_amount is null` return. A total compared with a null ceiling is
# never greater than it, so a relief without one (the children's) is
# taken either way; the early return says so out loud rather than
# leaving it to three-valued logic.
#
# Not swept, because nothing here can tell: the schedule-missing
# return (a null schedule finds no relief, and that returns too) and
# the choice of the basis period's end over another day of 2026 (one
# PCB schedule covers the whole year).
#
# The first run's "alone" mutant dropped the sum and left a select with
# no aggregate, which found no row on an update and so let the claim
# through for a reason of its own. It sums nothing now, as it says.

m('the ceiling is never asked',
  'a_relief_claimed_within_its_ceiling',
  '  if v_total > v_relief.max_amount then',
  '  if false then  -- no ceiling',
  '-- no ceiling')

m('the ceiling itself is refused',
  'a_relief_claimed_within_its_ceiling',
  '  if v_total > v_relief.max_amount then',
  '  if v_total >= v_relief.max_amount then  -- ceiling refused',
  '-- ceiling refused')

m('each claim is asked alone, as 0408 does',
  'a_relief_claimed_within_its_ceiling',
  '  select coalesce(sum(rc.amount), 0) + NEW.amount into v_total',
  '  select NEW.amount + 0 * coalesce(sum(rc.amount), 0) into v_total  -- alone',
  '-- alone')

m('the claim being amended is counted twice',
  'a_relief_claimed_within_its_ceiling',
  '     and rc.id is distinct from NEW.id;',
  '     and true;  -- counted twice',
  '-- counted twice')

m('every relief is summed together',
  'a_relief_claimed_within_its_ceiling',
  '     and rc.relief_code = NEW.relief_code\n',
  '     and true  -- every relief\n',
  '-- every relief')

m('every computation is summed together',
  'a_relief_claimed_within_its_ceiling',
  '   where rc.computation_id = NEW.computation_id\n',
  '   where true  -- every computation\n',
  '-- every computation')

m('an uncoded claim is refused',
  'a_relief_claimed_within_its_ceiling',
  '  if NEW.relief_code is null then\n    return NEW;\n  end if;',
  "  if NEW.relief_code is null then\n    raise exception 'uncoded';  -- uncoded refused\n  end if;",
  '-- uncoded refused')

m('a relief without a ceiling is refused',
  'a_relief_claimed_within_its_ceiling',
  '  if v_relief.id is null or v_relief.max_amount is null then',
  '  if v_relief.id is null then  -- no ceiling, refused',
  '-- no ceiling, refused')

m('the shortfall is told without this claim',
  'a_relief_claimed_within_its_ceiling',
  "      to_char(v_total, 'FM999G999G990D00')",
  "      to_char(v_total - NEW.amount, 'FM999G999G990D00')  -- without it",
  '-- without it')

m('CONTROL: a comment inside a_relief_claimed_within_its_ceiling',
  'a_relief_claimed_within_its_ceiling',
  '  return NEW;\nend $$;',
  '  return NEW;  -- (control)\nend $$;',
  '(control)')
