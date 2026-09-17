-- ---------------------------------------------------------------------
-- 0474  Nobody else may speak in the assistant's voice
-- ---------------------------------------------------------------------
-- Three places state who a conversation belongs to. Two of them agree:
--
--   * `ai_ask` refuses to add a question to somebody else's --
--     `'That is not your conversation'`;
--   * the read policy on `ai_messages` shows you your own, and an
--     administrator the company's.
--
-- `ai_answer` states it nowhere. It checked that the conversation
-- exists and that you belong to the company, and then wrote an
-- **assistant** message into it.
--
-- Measured, not reasoned about. A plain `viewer` in the same company:
--
--     ai_ask    into A's conversation: refused, 'That is not your
--                                      conversation'
--     ai_answer into A's conversation: accepted
--     A reads back: user: What do we owe?
--                 | assistant: Your books are perfectly in order.
--
-- That last line is the defect. It is not a leak -- the colleague
-- learns nothing -- it is a forgery. The screen draws assistant turns
-- as the assistant's words, and this module exists to be believed about
-- figures: an answer saying the books are in order, sitting under a
-- question the owner really asked, is worth more to somebody covering
-- something up than any read they could have done.
--
-- `ai_answer` now applies the same predicate as the other two, written
-- the same way, so the three cannot drift apart again.
--
-- ### Why the rule is `ai_ask`'s and not something stricter
--
-- `created_by = auth.uid()` alone was the tighter candidate and is
-- wrong: `ai_ask` deliberately lets an administrator add a question to
-- a conversation in their company, and the edge function answers under
-- whoever asked. A stricter rule here would refuse the answer to the
-- question the other rule had just allowed -- the two disagreeing
-- again, in the other direction.
--
-- ### What was already right
--
-- `ai_messages` grants `authenticated` nothing but `select`, and its
-- read policy already carries the correct rule, so there was no second
-- way in and there is one place to fix.
--
-- ### Mutants
--
-- Two, restated into a built database and run against
-- `supabase/tests/ai_assistant.sql`:
--
--   * the guard removed -- killed by "a colleague cannot put words in
--     the assistant's mouth";
--   * the guard weakened to `app.is_org_member(v_org)`, which is what
--     was effectively there before -- killed by the same assertion.
--     Kept as a separate mutant because it is the shape the defect
--     actually had, and a fix that only survives the deletion of the
--     whole clause is not evidence the clause says the right thing.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.ai_answer(p_conversation uuid, p_content text, p_tool_calls jsonb DEFAULT '[]'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org uuid;
  v_id  uuid;
  v_mine boolean;
begin
  select c.org_id,
         (c.created_by = auth.uid() or app.can_admin(c.org_id))
    into v_org, v_mine
    from public.ai_conversations c
   where c.id = p_conversation;
  if v_org is null or not app.is_org_member(v_org) then
    raise exception 'No such conversation' using errcode = 'P0002';
  end if;

  -- The same rule `ai_ask` applies, and the same one the read policy on
  -- `ai_messages` applies. It was stated in those two places and not in
  -- this one, so a colleague who could not add a *question* to your
  -- conversation could add an *answer* to it -- in the assistant's
  -- voice, indistinguishable from one, about your books. See 0474.
  if not v_mine then
    raise exception 'That is not your conversation' using errcode = '42501';
  end if;

  insert into public.ai_messages
    (conversation_id, org_id, role, content, tool_calls, created_by)
  values (p_conversation, v_org, 'assistant', p_content,
          coalesce(p_tool_calls, '[]'::jsonb), auth.uid())
  returning id into v_id;
  return v_id;
end $function$;

comment on function public.ai_answer(uuid, text, jsonb) is
  'Files the assistant''s reply in a conversation the caller may add '
  'to -- the same rule ai_ask applies and the same one the read policy '
  'on ai_messages applies. Called by the ask edge function under the '
  'asker''s own token. See 0474.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_ans text := pg_get_functiondef(
    to_regprocedure('public.ai_answer(uuid, text, jsonb)'));
  v_ask text := pg_get_functiondef(
    to_regprocedure('public.ai_ask(uuid, text, uuid)'));
begin
  if position('c.created_by = auth.uid() or app.can_admin(c.org_id)' in v_ans) = 0
  then
    raise exception
      '0474: ai_answer still does not ask whose conversation it is';
  end if;

  -- Both halves of the pair, so a later edit to one of them is a
  -- migration that fails rather than a rule that quietly splits.
  if position('That is not your conversation' in v_ans) = 0
     or position('That is not your conversation' in v_ask) = 0 then
    raise exception
      '0474: the two halves of this rule no longer refuse the same way';
  end if;
end
$do$;
