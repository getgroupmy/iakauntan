# Mutants for public.close_matter (0372) -- a legal file closed: it must
# exist and not be deleted, the legal module must be on, the caller
# must be able to post; not twice; not before it opened (the opening
# day itself will do); dated today in Kuala Lumpur unless told; REFUSED
# while the client account holds anything for THIS matter -- void
# transactions not counted, other matters' money not counted; unbilled
# billable time and disbursements (with their tax) reported, not
# refused; a closing note added under any notes already there.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0372_a_matter_that_could_never_be_closed.sql \
#       supabase/tests/matter_closing.sql \
#       supabase/tests/mutants/close_matter.py
#
# RESULT: 22 mutants and a control. 20 killed by `matter_closing.sql`,
# nine before its rule-by-rule block: every close was by the owner, in
# a company with the module, on a date given, beside no other matter
# holding money, with notes empty or already trimmed -- and the sweep
# found the money rule could be walked round entirely by an UPDATE on
# the table (`0775`).
#
# Two are EQUIVALENT since `0775`: "a matter holding client money is
# closed" and "a matter closes before it opened". Both were killed
# before it; now `app.matter_closes_only_when_empty` asks the same two
# questions on the same UPDATE, in the same words, so removing them
# here changes nothing anybody sees. They stay in the function, which
# says them first.

m("a matter that does not exist is not said so",
  "close_matter",
  "  if v_m.id is null then\n    raise exception 'No such matter.' using errcode = 'P0002';\n  end if;\n  if not app.has_module(v_m.org_id, 'legal') then\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to close a matter'",
  "  if false then  -- no such matter\n    raise exception 'No such matter.' using errcode = 'P0002';\n  end if;\n  if not app.has_module(v_m.org_id, 'legal') then\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to close a matter'",
  "-- no such matter")

m("a deleted matter is closed",
  "close_matter",
  "   where id = p_matter and deleted_at is null;\n  if v_m.id is null then\n    raise exception 'No such matter.' using errcode = 'P0002';\n  end if;\n  if not app.has_module(v_m.org_id, 'legal') then\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to close a matter'",
  "   where id = p_matter;  -- deleted too\n  if v_m.id is null then\n    raise exception 'No such matter.' using errcode = 'P0002';\n  end if;\n  if not app.has_module(v_m.org_id, 'legal') then\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to close a matter'",
  "-- deleted too")

m("a company without the legal module closes a matter",
  "close_matter",
  "  if not app.has_module(v_m.org_id, 'legal') then\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to close a matter'",
  "  if false then  -- no module needed\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to close a matter'",
  "-- no module needed")

m("anybody closes a matter",
  "close_matter",
  "  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to close a matter'",
  "  if false then  -- whoever asks\n    raise exception 'not permitted to close a matter'",
  "-- whoever asks")

m("a closed matter is closed again",
  "close_matter",
  "  if v_m.status = 'closed' then",
  "  if false then  -- twice",
  "-- twice")

m("a matter closes before it opened",
  "close_matter",
  "  if v_date < v_m.opened_date then",
  "  if false then  -- before it opened",
  "-- before it opened")

m("a matter cannot close on the day it opened",
  "close_matter",
  "  if v_date < v_m.opened_date then",
  "  if v_date <= v_m.opened_date then  -- not the same day",
  "-- not the same day")

m("a matter closed without a date is closed on the day it opened",
  "close_matter",
  "  v_date := coalesce(p_closed_date,\n                     (now() at time zone 'Asia/Kuala_Lumpur')::date);",
  "  v_date := coalesce(p_closed_date, v_m.opened_date);  -- opening day\n",
  "-- opening day")

m("a matter holding client money is closed",
  "close_matter",
  "  if round(v_funds, 2) <> 0 then",
  "  if false then  -- money left",
  "-- money left")

m("a voided receipt still counts as money held",
  "close_matter",
  "   where t.matter_id = p_matter and t.status <> 'void';",
  "   where t.matter_id = p_matter;  -- void counted",
  "-- void counted")

m("another matter's money holds this one open",
  "close_matter",
  "   where t.matter_id = p_matter and t.status <> 'void';",
  "   where t.org_id = v_m.org_id and t.status <> 'void';  -- any matter",
  "-- any matter")

m("billed time is reported as unbilled",
  "close_matter",
  "   where e.matter_id = p_matter and e.is_billable and not e.is_billed;",
  "   where e.matter_id = p_matter and e.is_billable;  -- billed too",
  "-- billed too")

m("time nobody may bill is reported as unbilled",
  "close_matter",
  "   where e.matter_id = p_matter and e.is_billable and not e.is_billed;",
  "   where e.matter_id = p_matter and not e.is_billed;  -- unbillable too",
  "-- unbillable too")

m("a disbursement is reported without its tax",
  "close_matter",
  "  select coalesce(sum(d.amount + d.tax_amount), 0) into v_disb",
  "  select coalesce(sum(d.amount), 0) into v_disb  -- no tax",
  "-- no tax")

m("a billed disbursement is reported as unbilled",
  "close_matter",
  "   where d.matter_id = p_matter and d.is_billable and not d.is_billed;",
  "   where d.matter_id = p_matter and d.is_billable;  -- billed too",
  "-- billed too")

m("the matter is not marked closed",
  "close_matter",
  "    status      = 'closed',",
  "    status      = status,  -- still open",
  "-- still open")

m("the closing date is not kept",
  "close_matter",
  "    closed_date = v_date,",
  "    closed_date = null,  -- no date",
  "-- no date")

m("closing without a note wipes the notes",
  "close_matter",
  "                    when nullif(trim(coalesce(p_note, '')), '') is null\n                      then notes",
  "                    when nullif(trim(coalesce(p_note, '')), '') is null\n                      then null  -- notes wiped",
  "-- notes wiped")

m("a first note is kept untrimmed",
  "close_matter",
  "                    when nullif(trim(coalesce(notes, '')), '') is null\n                      then trim(p_note)",
  "                    when nullif(trim(coalesce(notes, '')), '') is null\n                      then p_note  -- untrimmed",
  "-- untrimmed")

m("a closing note replaces the notes there",
  "close_matter",
  "                    else notes || E'\\n' || trim(p_note)",
  "                    else trim(p_note)  -- notes replaced",
  "-- notes replaced")

m("unbilled time is not reported",
  "close_matter",
  "    'unbilled_time', round(v_time, 2),",
  "    'unbilled_time', 0,  -- time unreported",
  "-- time unreported")

m("unbilled disbursements are not reported",
  "close_matter",
  "    'unbilled_disbursements', round(v_disb, 2));",
  "    'unbilled_disbursements', 0);  -- disbursements unreported",
  "-- disbursements unreported")

m("CONTROL: a comment inside the block",
  "close_matter",
  "  if v_m.status = 'closed' then",
  "  if v_m.status = 'closed' then  -- (control)",
  "(control)")
