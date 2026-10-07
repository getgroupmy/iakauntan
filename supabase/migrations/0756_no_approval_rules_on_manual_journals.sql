-- =====================================================================
-- 0756 :: no approval rules on manual journals
--
-- Answered on 7 October: "stop offering it".
--
-- An approval rule on manual journals can never be satisfied. A journal
-- has no draft state -- `0633` explains why, deliberately: a draft
-- `gl_entry` would be off the trial balance and on the chart of accounts
-- at once -- so it posts the moment it is saved. `refuse_unapproved_
-- posting` (0167) checks it at that commit, finds it unapproved, and
-- refuses it; and it cannot be sent for approval first, because until it
-- posts it does not exist. Reproduced locally: with "journals over
-- RM1,000 need an admin", a RM5,000 journal could never be posted by
-- anyone, approved or not.
--
-- So a journal rule did not add an approval. It removed the ability to
-- post a large journal at all, and the rule editor offered it to every
-- company. Production had no journal rules when this was written.
--
-- A rule on journals is now refused where every rule is written -- the
-- table, which the editor writes to directly -- with the reason. The
-- editor stops offering it. Everything that READS a journal rule or
-- request is left alone: there are none, and if journal approval comes
-- back it will come back with a pending state of its own.
-- =====================================================================

create or replace function app.refuse_journal_approval_rule()
returns trigger
language plpgsql
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if new.entity_kind = 'journal' then
    raise exception
      'Manual journals cannot need approval yet. A journal posts the '
      'moment it is saved, so there is nothing to approve before it '
      'posts and the rule would stop every journal it covers from '
      'posting at all.'
      using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists approval_rules_no_journal on public.approval_rules;
create trigger approval_rules_no_journal
  before insert or update of entity_kind on public.approval_rules
  for each row execute function app.refuse_journal_approval_rule();

revoke all on function app.refuse_journal_approval_rule()
  from public, anon, authenticated;

comment on function app.refuse_journal_approval_rule() is
  'Refuses an approval rule on manual journals (0756). A journal has no '
  'draft state and posts on save, so a rule on it can never be '
  'satisfied: the posting gate refuses it unapproved, and it cannot be '
  'submitted for approval before it exists.';
