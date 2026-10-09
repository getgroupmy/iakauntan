# Mutants for public.void_pos_sale (0247) -- a parked bill written off:
# by somebody who may sell AND has been given the void permission, only
# while it is parked, never for "other" without a word; the lines that
# reached the kitchen recorded as voids with their reason, the open
# tickets cancelled, and the bill marked voided with why, who and when.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0247_writing_off_a_bill_always_needs_the_grant.sql \
#       supabase/tests/pos_void_permission.sql \
#       supabase/tests/mutants/void_pos_sale.py
#
# RESULT: 16 mutants and a control, all killed by `pos_void_permission.sql`.
# Four only after it asserted them: the bill that does not exist,
# somebody who may not sell, the reason on each lost line (every cooked
# bill had been written off as 'other', the value a mutant writing 'other'
# produces), and a served ticket staying served. None of the other six
# files that call it killed any of the four.

m("a bill that does not exist is not said so",
  "void_pos_sale",
  "  if v_sale.id is null then\n    raise exception 'No such bill.'",
  "  if false then  -- no such bill\n    raise exception 'No such bill.'",
  "-- no such bill")

m("anybody voids a bill",
  "void_pos_sale",
  "  if not app.can_write_module(v_sale.org_id, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a seller without the void grant writes a bill off",
  "void_pos_sale",
  "  if not app.can_void_pos(v_sale.org_id) then",
  "  if false then  -- no grant needed",
  "-- no grant needed")

m("a paid bill is voided",
  "void_pos_sale",
  "  if v_sale.status <> 'parked' then",
  "  if false then  -- any status",
  "-- any status")

m("'other' needs no word",
  "void_pos_sale",
  "  if p_reason = 'other' and coalesce(btrim(p_note), '') = '' then",
  "  if false then  -- other unexplained",
  "-- other unexplained")

m("'other' with only spaces is a word",
  "void_pos_sale",
  "  if p_reason = 'other' and coalesce(btrim(p_note), '') = '' then",
  "  if p_reason = 'other' and coalesce(p_note, '') = '' then  -- spaces count",
  "-- spaces count")

m("lines nobody cooked are counted as voided food",
  "void_pos_sale",
  "   where l.sale_id = p_sale\n     and l.sent_to_kitchen_at is not null;",
  "   where l.sale_id = p_sale;  -- uncooked too",
  "-- uncooked too")

m("no food is recorded as voided",
  "void_pos_sale",
  "   where l.sale_id = p_sale\n     and l.sent_to_kitchen_at is not null;",
  "   where false;  -- nothing recorded",
  "-- nothing recorded")

m("the void line forgets the reason",
  "void_pos_sale",
  "         p_reason, nullif(btrim(p_note), ''), auth.uid()",
  "         'other', nullif(btrim(p_note), ''), auth.uid()  -- reason lost",
  "-- reason lost")

m("the kitchen keeps cooking",
  "void_pos_sale",
  "     set status = 'cancelled'\n   where t.sale_id = p_sale",
  "     set status = t.status  -- keeps cooking\n   where t.sale_id = p_sale",
  "-- keeps cooking")

m("served tickets are cancelled too",
  "void_pos_sale",
  "     and t.status in ('new', 'cooking', 'ready');",
  "     and true;  -- served too",
  "-- served too")

m("the bill is not marked voided",
  "void_pos_sale",
  "     set status     = 'voided',",
  "     set status     = s.status,  -- still parked",
  "-- still parked")

m("the bill does not say why",
  "void_pos_sale",
  "         void_reason = p_reason::text,",
  "         void_reason = null,  -- no reason",
  "-- no reason")

m("the note is kept with its spaces",
  "void_pos_sale",
  "         void_note  = nullif(btrim(p_note), ''),",
  "         void_note  = p_note,  -- untrimmed",
  "-- untrimmed")

m("who voided it is not recorded",
  "void_pos_sale",
  "         voided_by  = auth.uid()\n   where s.id = p_sale;",
  "         voided_by  = null  -- nobody\n   where s.id = p_sale;",
  "-- nobody")

m("the count answered is nothing",
  "void_pos_sale",
  "  return v_done;",
  "  return 0;  -- none",
  "-- none")

m("CONTROL: a comment inside the block",
  "void_pos_sale",
  "  if v_sale.status <> 'parked' then",
  "  if v_sale.status <> 'parked' then  -- (control)",
  "(control)")
