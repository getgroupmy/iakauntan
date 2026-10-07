# Mutants for public.upsert_pos_tender_type and delete_pos_tender_type
# (0732) -- the editor behind the till's payment buttons: a name and a
# code, the code unique and upper-cased, a real LHDN payment mode, this
# company's bank account, none at all for a kind that takes no money,
# and a tender that has taken money kept on the books.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0732_a_shop_can_say_where_its_money_goes.sql \
#       supabase/tests/pos_tender_types.sql \
#       supabase/tests/mutants/pos_tender_types.py
#
# RESULT: 25 mutants and a control, all killed by `pos_tender_types.sql`.
# Eight only after the "What an amendment leaves alone, and whose tender
# it is" block there. Two were guards: amending ANOTHER company's tender
# by passing its id with this company's `p_org`, and a stranger deleting
# one. The rest were the "say nothing, keep it" rule of an amendment:
# every amendment had kept the DEFAULT account, which the trigger refills
# anyway, so clearing it passed; nothing amended a drawer-counted cheque
# tender or a switched-off one.
#
# Noted, not raised: `p_active` defaults to TRUE, unlike every other
# optional argument, so a caller that leaves it out of an amendment
# switches a disabled tender back on. The app always sends it, so the
# screen is unaffected; an explicit null keeps the old value, and that is
# what is asserted.

m("anybody edits the till's tenders",
  "upsert_pos_tender_type",
  "  if not app.can_write_module(p_org, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a tender with no name is saved",
  "upsert_pos_tender_type",
  "  if v_name = '' then",
  "  if false then  -- nameless",
  "-- nameless")

m("a tender with no code is saved",
  "upsert_pos_tender_type",
  "  if v_code = '' then",
  "  if false then  -- codeless",
  "-- codeless")

m("the code is kept as typed",
  "upsert_pos_tender_type",
  "  v_code   text := upper(btrim(coalesce(p_code, '')));",
  "  v_code   text := btrim(coalesce(p_code, ''));  -- as typed",
  "-- as typed")

m("a code already taken is refused by the index, not by name",
  "upsert_pos_tender_type",
  "  if v_taken is not null then",
  "  if false then  -- index says",
  "-- index says")

m("a tender clashes with itself on save",
  "upsert_pos_tender_type",
  "     and (v_id is null or t.id <> v_id);",
  "     and true;  -- clashes with itself",
  "-- clashes with itself")

m("another company's code counts as taken",
  "upsert_pos_tender_type",
  "   where t.org_id = p_org and t.code = v_code\n",
  "   where t.code = v_code  -- any company\n",
  "-- any company")

m("a payment mode LHDN does not publish is saved",
  "upsert_pos_tender_type",
  "  if p_payment_mode is not null\n     and not exists (select 1 from public.ref_payment_modes m",
  "  if false\n     and not exists (select 1 from public.ref_payment_modes m  -- any mode",
  "-- any mode")

m("another company's bank account is banked to",
  "upsert_pos_tender_type",
  "                      where b.id = p_bank_account and b.org_id = p_org) then",
  "                      where b.id = p_bank_account) then  -- stranger's bank",
  "-- stranger's bank")

m("a tender that takes no money is given a bank",
  "upsert_pos_tender_type",
  "  if p_bank_account is not null and p_kind in ('on_account', 'loyalty') then\n    raise",
  "  if false then  -- banked\n    raise",
  "-- banked")

m("cash does not count in the drawer by default",
  "upsert_pos_tender_type",
  "  v_drawer := coalesce(p_counts_in_drawer, p_kind = 'cash');",
  "  v_drawer := coalesce(p_counts_in_drawer, false);  -- not counted",
  "-- not counted")

m("what was asked about the drawer is ignored",
  "upsert_pos_tender_type",
  "  v_drawer := coalesce(p_counts_in_drawer, p_kind = 'cash');",
  "  v_drawer := p_kind = 'cash';  -- default only",
  "-- default only")

m("cash gives no change by default",
  "upsert_pos_tender_type",
  "      coalesce(p_gives_change, p_kind = 'cash'),",
  "      coalesce(p_gives_change, false),  -- no change",
  "-- no change")

m("cash does not open the drawer by default",
  "upsert_pos_tender_type",
  "      coalesce(p_opens_drawer, p_kind = 'cash'),",
  "      coalesce(p_opens_drawer, false),  -- stays shut",
  "-- stays shut")

m("a new tender goes first, not last",
  "upsert_pos_tender_type",
  "      coalesce(p_sort, (select coalesce(max(sort_order), 0) + 10",
  "      coalesce(p_sort, (select 0 + 0 * coalesce(max(sort_order), 0)  -- first",
  "-- first")

m("a new tender starts switched off",
  "upsert_pos_tender_type",
  "      coalesce(p_active, true))",
  "      coalesce(p_active, false))  -- off",
  "-- off")

m("an edit that leaves the account blank clears it",
  "upsert_pos_tender_type",
  "           bank_account_id = coalesce(p_bank_account, t.bank_account_id),",
  "           bank_account_id = p_bank_account,  -- cleared",
  "-- cleared")

m("an edit that says nothing of the drawer resets it",
  "upsert_pos_tender_type",
  "           counts_in_drawer = coalesce(p_counts_in_drawer, t.counts_in_drawer),",
  "           counts_in_drawer = coalesce(p_counts_in_drawer, false),  -- reset",
  "-- reset")

m("an edit that says nothing of switching off switches it on",
  "upsert_pos_tender_type",
  "           is_active = coalesce(p_active, t.is_active),",
  "           is_active = coalesce(p_active, true),  -- on again",
  "-- on again")

m("another company's tender is edited",
  "upsert_pos_tender_type",
  "     where t.id = v_id and t.org_id = p_org;",
  "     where t.id = v_id;  -- any company",
  "-- any company")

m("an edit of nothing says nothing",
  "upsert_pos_tender_type",
  "    if not found then\n      raise exception 'No such tender in this company.'",
  "    if false then  -- silent\n      raise exception 'No such tender in this company.'",
  "-- silent")

m("a kind that takes no money keeps a stale account",
  "upsert_pos_tender_type",
  "  if p_bank_account is null and p_kind in ('on_account', 'loyalty') then\n    update",
  "  if false then  -- stale\n    update",
  "-- stale")

m("deleting a tender that is not there is an error",
  "delete_pos_tender_type",
  "  if v_org is null then\n    return false;",
  "  if v_org is null then\n    raise exception 'gone';  -- loud",
  "-- loud")

m("anybody deletes a tender",
  "delete_pos_tender_type",
  "  if not app.can_write_module(v_org, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a tender that has taken money is deleted",
  "delete_pos_tender_type",
  "  if v_used > 0 then",
  "  if false then  -- history lost",
  "-- history lost")

m("CONTROL: a comment inside the block",
  "upsert_pos_tender_type",
  "  if v_name = '' then",
  "  if v_name = '' then  -- (control)",
  "(control)")
