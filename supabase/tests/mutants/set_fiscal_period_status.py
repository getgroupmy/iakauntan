# Mutants for public.set_fiscal_period_status (0053) -- a period opened,
# closed or locked: by an owner or admin only, to one of the three
# statuses, never out of `locked`, and that period alone.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0053_fiscal_year_rollover.sql \
#       supabase/tests/ledger.sql \
#       supabase/tests/mutants/set_fiscal_period_status.py
#
# RESULT: 8 mutants and a control, all killed -- seven by `ledger.sql`,
# three of those only after its rule-by-rule block (the period that does
# not exist, a status none of the three, locked set back to closed), and
# "somebody who may post" by `year_end_close.sql`'s accountant, which
# `ledger.sql` has none of.

m("a period that does not exist is not said so",
  "set_fiscal_period_status",
  "  if v_period.id is null then\n    raise exception 'Fiscal period not found'",
  "  if false then  -- no such period\n    raise exception 'Fiscal period not found'",
  "-- no such period")

m("anybody opens and closes periods",
  "set_fiscal_period_status",
  "  if not app.can_admin(v_period.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("somebody who may post, not only an admin, opens and closes periods",
  "set_fiscal_period_status",
  "  if not app.can_admin(v_period.org_id) then",
  "  if not app.can_post(v_period.org_id) then  -- poster",
  "-- poster")

m("any status is accepted",
  "set_fiscal_period_status",
  "  if p_status not in ('open', 'closed', 'locked') then",
  "  if false then  -- any status",
  "-- any status")

m("a locked period is reopened",
  "set_fiscal_period_status",
  "  if v_period.status = 'locked' and p_status <> 'locked' then",
  "  if false then  -- locked opens",
  "-- locked opens")

m("a locked period may be set back to closed",
  "set_fiscal_period_status",
  "  if v_period.status = 'locked' and p_status <> 'locked' then",
  "  if v_period.status = 'locked' and p_status = 'open' then  -- locked to closed",
  "-- locked to closed")

m("the status is not changed",
  "set_fiscal_period_status",
  "  update public.fiscal_periods set status = p_status where id = p_period_id;",
  "  perform 1;  -- unchanged",
  "-- unchanged")

m("every period of the company is changed, not this one",
  "set_fiscal_period_status",
  "  update public.fiscal_periods set status = p_status where id = p_period_id;",
  "  update public.fiscal_periods set status = p_status where org_id = v_period.org_id;  -- every period",
  "-- every period")

m("CONTROL: a comment inside the block",
  "set_fiscal_period_status",
  "  if p_status not in ('open', 'closed', 'locked') then",
  "  if p_status not in ('open', 'closed', 'locked') then  -- (control)",
  "(control)")
