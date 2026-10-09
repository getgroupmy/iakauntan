# Mutants for public.reissue_terminal_secret (0612) -- a wall clock's
# secret replaced: the terminal must exist; only somebody who manages
# HR (attendance decides pay); a fresh 32-byte secret, handed back once
# and stored only as a bcrypt hash; THIS terminal's, not every
# terminal's in the company.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0612_the_punch_the_clock_on_the_wall_made.sql \
#       supabase/tests/terminal_punches.sql \
#       supabase/tests/mutants/reissue_terminal_secret.py
#
# RESULT: 5 mutants and a control, all killed by `terminal_punches.sql`;
# one before its rule-by-rule block (a plain secret fails the bcrypt
# check). The file reissued the only terminal of a company, as its
# owner, and never measured the secret: resetting every terminal, a
# one-byte secret, anybody reissuing, and a missing terminal all passed.

m("a terminal that does not exist is not said so",
  "reissue_terminal_secret",
  "  if v_org is null then\n    raise exception 'No such terminal'",
  "  if false then  -- no such terminal\n    raise exception 'No such terminal'",
  "-- no such terminal")

m("anybody reissues a terminal's secret",
  "reissue_terminal_secret",
  "  if not app.can_manage_hr(v_org) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("the new secret is one byte",
  "reissue_terminal_secret",
  "  v_secret := encode(gen_random_bytes(32), 'hex');",
  "  v_secret := encode(gen_random_bytes(1), 'hex');  -- one byte",
  "-- one byte")

m("every terminal in the company is reissued",
  "reissue_terminal_secret",
  "     set secret_hash = crypt(v_secret, gen_salt('bf'))\n   where id = p_terminal_id;",
  "     set secret_hash = crypt(v_secret, gen_salt('bf'))\n   where org_id = v_org;  -- every terminal",
  "-- every terminal")

m("the secret is stored as it is",
  "reissue_terminal_secret",
  "     set secret_hash = crypt(v_secret, gen_salt('bf'))",
  "     set secret_hash = v_secret  -- plain",
  "-- plain")

m("CONTROL: a comment inside the block",
  "reissue_terminal_secret",
  "  if not app.can_manage_hr(v_org) then",
  "  if not app.can_manage_hr(v_org) then  -- (control)",
  "(control)")
