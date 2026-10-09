# Mutants for app.closed_matter_takes_no_money (0776) -- no change to the
# client ledger may raise what a closed or archived matter holds: a
# receipt, a transfer in, an amount raised, a payment out voided or
# deleted; a change that moves nothing (posting a drafted payment) and
# money going OUT are allowed; void rows count for nothing.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0776_a_closed_file_takes_no_money.sql \
#       supabase/tests/matter_closing.sql \
#       supabase/tests/mutants/closed_matter_takes_no_money.py
#
# RESULT: 6 mutants and a control, all killed by `matter_closing.sql`.
# The void, the raised amount and the delete each need a closed file
# that already has rows: one paid in and out before it closed, with
# the payment still a draft -- whose posting moves nothing and is let
# through, which is what kills "money going out is refused too".

m("a closed file takes money",
  "closed_matter_takes_no_money",
  "  if v_status in ('closed', 'archived') then",
  "  if false then  -- takes money",
  "-- takes money")

m("an archived file takes money",
  "closed_matter_takes_no_money",
  "  if v_status in ('closed', 'archived') then",
  "  if v_status = 'closed' then  -- archived unguarded",
  "-- archived unguarded")

m("deleting a payment out is not asked",
  "closed_matter_takes_no_money",
  "    v_gain := case when old.status <> 'void' then -old.amount else 0 end;",
  "    v_gain := 0;  -- delete unasked",
  "-- delete unasked")

m("an update is judged by its new amount alone",
  "closed_matter_takes_no_money",
  "      v_gain := v_gain - old.amount;",
  "      v_gain := v_gain;  -- old ignored",
  "-- old ignored")

m("voiding a row is not seen as taking it off",
  "closed_matter_takes_no_money",
  "    v_gain := case when new.status <> 'void' then new.amount else 0 end;",
  "    v_gain := new.amount;  -- void counted",
  "-- void counted")

m("money going out of a closed file is refused too",
  "closed_matter_takes_no_money",
  "  if v_matter is null or v_gain <= 0 then",
  "  if v_matter is null or v_gain < 0 then  -- nothing moved is asked",
  "-- nothing moved is asked")

m("CONTROL: a comment inside the block",
  "closed_matter_takes_no_money",
  "  if v_status in ('closed', 'archived') then",
  "  if v_status in ('closed', 'archived') then  -- (control)",
  "(control)")
