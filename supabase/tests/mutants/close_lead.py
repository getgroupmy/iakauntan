# Mutants for public.close_lead and public.reopen_lead (0373) -- a lead
# that came to nothing, closed with a reason: it must exist and not be
# deleted; somebody who can write; never one that became a customer;
# never without a reason, trimmed; marked lost with the reason. Reopened
# only when lost, to CONTACTED (somebody spoke to them), the reason
# cleared.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0373_a_deal_died_and_nobody_asked_why.sql \
#       supabase/tests/win_loss.sql \
#       supabase/tests/mutants/close_lead.py
#
# RESULT: 12 mutants and a control, all killed by `win_loss.sql`; four
# before its rule-by-rule block. One lead, the owner's, live, never
# converted, closed with a clean reason and reopened from lost: every
# refusal but the missing reason, and the trim, were unasked.

m("a lead that does not exist is not said so",
  "close_lead",
  "  if v_l.id is null then\n    raise exception 'No such lead.' using errcode = 'P0002';\n  end if;\n  if not app.can_write(v_l.org_id) then\n    raise exception 'not permitted to close a lead'",
  "  if false then  -- no such lead\n    raise exception 'No such lead.' using errcode = 'P0002';\n  end if;\n  if not app.can_write(v_l.org_id) then\n    raise exception 'not permitted to close a lead'",
  "-- no such lead")

m("a deleted lead is closed",
  "close_lead",
  "   where id = p_lead and deleted_at is null;\n  if v_l.id is null then\n    raise exception 'No such lead.' using errcode = 'P0002';\n  end if;\n  if not app.can_write(v_l.org_id) then\n    raise exception 'not permitted to close a lead'",
  "   where id = p_lead;  -- deleted too\n  if v_l.id is null then\n    raise exception 'No such lead.' using errcode = 'P0002';\n  end if;\n  if not app.can_write(v_l.org_id) then\n    raise exception 'not permitted to close a lead'",
  "-- deleted too")

m("anybody closes a lead",
  "close_lead",
  "  if not app.can_write(v_l.org_id) then\n    raise exception 'not permitted to close a lead'",
  "  if false then  -- whoever asks\n    raise exception 'not permitted to close a lead'",
  "-- whoever asks")

m("a lead that became a customer is lost too",
  "close_lead",
  "  if v_l.converted_contact_id is not null then",
  "  if false then  -- converted too",
  "-- converted too")

m("a lead is lost for no reason",
  "close_lead",
  "  if v_reason is null then\n    raise exception\n      'Say why the lead came to nothing.",
  "  if false then  -- no reason\n    raise exception\n      'Say why the lead came to nothing.",
  "-- no reason")

m("the reason is kept untrimmed",
  "close_lead",
  "    lost_reason = v_reason,",
  "    lost_reason = p_reason,  -- untrimmed",
  "-- untrimmed")

m("the lead is not marked lost",
  "close_lead",
  "    status      = 'lost',",
  "    status      = status,  -- not lost",
  "-- not lost")

m("a lead that does not exist is not said so, reopening",
  "reopen_lead",
  "  if v_l.id is null then\n    raise exception 'No such lead.' using errcode = 'P0002';\n  end if;\n  if not app.can_write(v_l.org_id) then\n    raise exception 'not permitted to reopen a lead'",
  "  if false then  -- no such lead\n    raise exception 'No such lead.' using errcode = 'P0002';\n  end if;\n  if not app.can_write(v_l.org_id) then\n    raise exception 'not permitted to reopen a lead'",
  "-- no such lead")

m("anybody reopens a lead",
  "reopen_lead",
  "  if not app.can_write(v_l.org_id) then\n    raise exception 'not permitted to reopen a lead'",
  "  if false then  -- whoever asks\n    raise exception 'not permitted to reopen a lead'",
  "-- whoever asks")

m("a lead that is not lost is reopened",
  "reopen_lead",
  "  if v_l.status <> 'lost' then",
  "  if false then  -- any status",
  "-- any status")

m("a reopened lead goes back to new",
  "reopen_lead",
  "    status = 'contacted', lost_reason = null, updated_at = now()",
  "    status = 'new', lost_reason = null, updated_at = now()  -- back to new",
  "-- back to new")

m("a reopened lead keeps its lost reason",
  "reopen_lead",
  "    status = 'contacted', lost_reason = null, updated_at = now()",
  "    status = 'contacted', updated_at = now()  -- reason kept",
  "-- reason kept")

m("CONTROL: a comment inside the block",
  "close_lead",
  "  if v_l.converted_contact_id is not null then",
  "  if v_l.converted_contact_id is not null then  -- (control)",
  "(control)")
