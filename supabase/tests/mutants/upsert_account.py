# Mutants for public.upsert_account (0766) -- a rename leaves the chart
# as it was: no account with a figure behind it becomes a heading, no
# heading with accounts under it starts posting, and a parent the
# account already has is not examined again.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0766_a_rename_leaves_the_chart_as_it_was.sql \
#       supabase/tests/chart_of_accounts.sql \
#       supabase/tests/mutants/upsert_account.py
#
# RESULT: 10 mutants and a control, all killed by `chart_of_accounts.sql`'s
# 0766 block. That block failed against the function as `0459` left it,
# at its first refusal. Building it found an older block renaming 1200
# -- a heading -- without `p_is_group`, which demoted it as a side
# effect, and whose renumbering assertion 0766's demotion guard would
# then have satisfied by itself under the same SQLSTATE; it now passes
# `p_is_group => true` and asserts the heading stays one.

m("an account with postings becomes a heading anyway",
  "upsert_account",
  "    if v_refusal is not null then",
  "    if false then  -- promoted anyway",
  "-- promoted anyway")

m("a promotion is never asked about",
  "upsert_account",
  "     and not v_old.is_group then",
  "     and false then  -- never asked",
  "-- never asked")

m("the promotion reads the old flag, not the new one",
  "upsert_account",
  "  if p_id is not null and coalesce(p_is_group, v_old.is_group)",
  "  if p_id is not null and v_old.is_group  -- old flag",
  "-- old flag")

m("the refusal is said and not raised",
  "upsert_account",
  "      raise exception '%', v_refusal using errcode = '23514';",
  "      raise notice '%', v_refusal;  -- said only",
  "-- said only")

m("a heading with accounts under it starts posting",
  "upsert_account",
  "                  where a.parent_id = p_id and a.deleted_at is null) then",
  "                  where false) then  -- demoted anyway",
  "-- demoted anyway")

m("a retired child holds its parent a heading",
  "upsert_account",
  "                  where a.parent_id = p_id and a.deleted_at is null) then",
  "                  where a.parent_id = p_id) then  -- retired count",
  "-- retired count")

m("a demotion is never asked about",
  "upsert_account",
  "  if p_id is not null and v_old.is_group",
  "  if false and v_old.is_group  -- never demoted",
  "-- never demoted")

m("every heading is refused a demotion",
  "upsert_account",
  "     and not coalesce(p_is_group, v_old.is_group)",
  "     and true  -- any save",
  "-- any save")

m("a parent the account already has is examined again",
  "upsert_account",
  "    if (p_id is null or p_parent_id is distinct from v_old.parent_id)",
  "    if (true)  -- examined again",
  "-- examined again")

m("a new parent is never examined",
  "upsert_account",
  "    if (p_id is null or p_parent_id is distinct from v_old.parent_id)",
  "    if (false)  -- never examined",
  "-- never examined")

m("CONTROL: a comment inside the block",
  "upsert_account",
  "    if v_refusal is not null then",
  "    if v_refusal is not null then  -- (control)",
  "(control)")
