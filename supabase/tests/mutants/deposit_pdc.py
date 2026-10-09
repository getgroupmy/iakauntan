# Mutants for public.deposit_pdc (0421) -- a post-dated cheque paid in:
# by somebody with write access to the side of the books it belongs to,
# only while it is still held, on the day given or today, and posting
# nothing until it clears.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0421_what_day_the_money_moved.sql \
#       supabase/tests/post_dated_cheques.sql \
#       supabase/tests/mutants/deposit_pdc.py
#
# RESULT: 7 mutants and a control, all killed by `post_dated_cheques.sql`.
# Six only after its rule-by-rule block: a cheque that does not exist,
# the permission and which side of the books it is asked of, a cheque
# paid in twice, and the day it was paid in, given and not given. Before
# it, only the cheque left held was seen.

m("a cheque that does not exist is not said so",
  "deposit_pdc",
  "  if v_c.id is null then\n    raise exception 'No such cheque.'",
  "  if false then  -- no such cheque\n    raise exception 'No such cheque.'",
  "-- no such cheque")

m("anybody pays a cheque in",
  "deposit_pdc",
  "  if not app.can_write_module(v_c.org_id,",
  "  if false and app.can_write_module(v_c.org_id,  -- anybody",
  "-- anybody")

m("a cheque received is paid in on the buying side's permission",
  "deposit_pdc",
  "        case when v_c.direction = 'incoming' then 'sales' else 'purchases' end) then",
  "        case when v_c.direction = 'incoming' then 'purchases' else 'sales' end) then  -- sides swapped",
  "-- sides swapped")

m("a cheque already deposited, cleared or bounced is paid in again",
  "deposit_pdc",
  "  if v_c.status <> 'held' then",
  "  if false then  -- any status",
  "-- any status")

m("the day it was paid in is ignored",
  "deposit_pdc",
  "     set status = 'deposited', deposited_on = coalesce(p_on, app.today())",
  "     set status = 'deposited', deposited_on = app.today()  -- today only",
  "-- today only")

m("with no day given, it is paid in on the cheque's own date",
  "deposit_pdc",
  "     set status = 'deposited', deposited_on = coalesce(p_on, app.today())",
  "     set status = 'deposited', deposited_on = coalesce(p_on, v_c.cheque_date)  -- cheque date",
  "-- cheque date")

m("the cheque is not marked deposited",
  "deposit_pdc",
  "     set status = 'deposited', deposited_on = coalesce(p_on, app.today())",
  "     set deposited_on = coalesce(p_on, app.today())  -- still held",
  "-- still held")

m("CONTROL: a comment inside the block",
  "deposit_pdc",
  "  if v_c.status <> 'held' then",
  "  if v_c.status <> 'held' then  -- (control)",
  "(control)")
