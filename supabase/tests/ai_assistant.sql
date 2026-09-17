-- =====================================================================
-- iAkauntan :: a question about your own books
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ai_assistant.sql
--
-- The AI module is an allow-list with a chat box in front of it, so the
-- allow-list is what this file is about. Four properties, and none of
-- them is about the model:
--
--   * it can only call what `ai_tools` names;
--   * nothing that writes can be named — checked by Postgres, not by
--     the prefix on the function;
--   * the company comes from the conversation, never from the question;
--   * it reads **as the person asking**, so an answer cannot contain a
--     figure they could not have opened a screen and seen.
--
-- The last one is the one that would matter on the day it was wrong.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ai_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  perform app.demo_modules(v_org, array['ai', 'accounting']);
  -- Something to pay for the questions with.
  perform app.move_credit(v_org, 'topup', 100, 'For the test', null, null, false);
  return v_org;
end $$;

-- ---------------------------------------------------------------------
-- What may be registered at all
-- ---------------------------------------------------------------------
do $$
declare
  v_took boolean;
  v_msg  text;
begin
  perform pg_temp.check_true('the module is on the platform''s list',
    exists (select 1 from public.platform_modules
             where code = 'ai' and is_active));

  perform pg_temp.check_true('and the assistant has things to read',
    (select count(*) from public.ai_tools where is_active) >= 5);

  -- The guard that matters most about registration. `report_feedback`
  -- is named like a report and inserts a row; Postgres knows it is
  -- volatile, and that is the authority rather than the prefix.
  perform pg_temp.check_eq('report_feedback really is a writer',
    (select p.provolatile::text from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'report_feedback'), 'v');

  begin
    insert into public.ai_tools (name, function_name, description)
    values ('sneaky', 'report_feedback', 'Looks like a report');
    v_took := true;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a function that writes cannot be given to the assistant', not v_took);
  perform pg_temp.check_true('and the refusal says why',
    v_msg like '%volatile%');

  -- A function that is not there at all.
  begin
    insert into public.ai_tools (name, function_name, description)
    values ('ghost', 'report_the_moon', 'Nothing');
    v_took := true;
  exception when sqlstate 'P0002' then v_took := false;
  end;
  perform pg_temp.check_true('nor one that does not exist', not v_took);

  -- An argument the function has not got: a tool that would fail the
  -- first time somebody asked.
  begin
    insert into public.ai_tools (name, function_name, description, arguments)
    values ('wrong_arg', 'report_ar_aging', 'Ageing',
      '[{"name":"p_colour","type":"text","required":false}]'::jsonb);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true(
    'nor an argument the function has not got', not v_took);

  -- And the company can never be one of the model's arguments.
  begin
    insert into public.ai_tools (name, function_name, description, arguments)
    values ('pick_a_company', 'report_ar_aging', 'Ageing',
      '[{"name":"p_org_id","type":"uuid","required":true}]'::jsonb);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true(
    'and the model cannot be given a company to choose', not v_took);
end $$;

-- ---------------------------------------------------------------------
-- Asking, and reading
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_conv uuid;
  v_out  jsonb;
  v_took boolean;
  v_msg  text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.ai_org('Tanya Sdn Bhd');

  v_conv := public.ai_ask(v_org, 'Why is 6350 what it is?');
  perform pg_temp.check_true('a question starts a conversation',
    v_conv is not null);
  perform pg_temp.check_eq('with the question in it',
    (select content from public.ai_messages
      where conversation_id = v_conv and role = 'user'),
    'Why is 6350 what it is?');
  perform pg_temp.check_eq('and it was charged for',
    (select amount from public.credit_ledger
      where org_id = v_org and description = 'AI question'),
    -0.20::numeric);

  -- The catalogue is what the model is offered.
  perform pg_temp.check_true('the catalogue names the ledger',
    public.ai_tool_catalogue(v_org)::text like '%general_ledger%');

  -- And a tool runs.
  v_out := public.ai_run_tool(v_org, 'who_owes_us', '{}'::jsonb);
  perform pg_temp.check_true('a tool returns json', v_out is not null);

  -- Anything not on the list is refused by name.
  --
  -- Asked with `report_migration_progress`, which is a real public
  -- function, stable, and takes exactly `p_org_id` — so if the
  -- allow-list stopped being consulted it would run perfectly. The
  -- first draft of this used a made-up name, and the mutant that
  -- removed the allow-list died on "function does not exist" instead:
  -- a pass that proved the name was fictional rather than that the list
  -- was consulted.
  perform pg_temp.check_true('the function it names really is there',
    exists (select 1 from pg_proc p join pg_namespace n
                       on n.oid = p.pronamespace
             where n.nspname = 'public'
               and p.proname = 'report_migration_progress'));
  perform pg_temp.check_true('and really is not on the list',
    not exists (select 1 from public.ai_tools
                 where function_name = 'report_migration_progress'));

  begin
    perform public.ai_run_tool(v_org, 'report_migration_progress',
                               '{}'::jsonb);
    v_took := true;
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true('a tool that is not on the list is refused',
    not v_took);
  perform pg_temp.check_true('and told it may only read the list',
    v_msg like '%may only read%');

  -- An argument the tool does not declare is refused rather than
  -- quietly dropped: dropping it answers a different question.
  begin
    perform public.ai_run_tool(v_org, 'who_owes_us',
      '{"p_secret": "x"}'::jsonb);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true(
    'an argument the tool has not got is refused, not dropped', not v_took);

  -- A required one that is missing.
  begin
    perform public.ai_run_tool(v_org, 'profit_and_loss', '{}'::jsonb);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('a missing required argument is refused',
    not v_took);
end $$;

-- ---------------------------------------------------------------------
-- It reads as the person asking
-- ---------------------------------------------------------------------
--
-- The assertion this module lives or dies on. `ai_run_tool` is security
-- invoker, so every guard inside every report applies to whoever asked.
-- Somebody at another company gets nothing — not an empty list they
-- might mistake for "nothing outstanding", but a refusal.
do $$
declare
  v_org     uuid;
  v_outside uuid;
  v_took    boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.ai_org('Rahsia Sdn Bhd');

  -- Somebody with an account, at no company of ours.
  v_outside := pg_temp.another_user('outsider-0470@iakauntan.test');
  perform pg_temp.sign_in_as(v_outside);

  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_outside, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.ai_run_tool(v_org, 'who_owes_us', '{}'::jsonb);
    execute 'reset role';
    v_took := true;
  exception when others then
    execute 'reset role';
    v_took := false;
  end;
  perform pg_temp.check_true(
    'an outsider cannot read another company''s books through a tool',
    not v_took);

  -- And cannot even see what is on offer.
  perform pg_temp.check_eq('nor be offered the catalogue',
    public.ai_tool_catalogue(v_org)::text, '[]');

  -- Nor ask a question against it.
  begin
    perform public.ai_ask(v_org, 'Show me everything');
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('nor ask against it at all', not v_took);
end $$;

-- ---------------------------------------------------------------------
-- The module has to be switched on
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  -- Named modules only. `pg_temp.test_org` with no list switches on
  -- every module there is, which would make this whole block vacuous.
  v_org := pg_temp.test_org('Tiada AI Sdn Bhd', array['accounting']);
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  perform app.move_credit(v_org, 'topup', 100, 'For the test', null, null, false);

  perform pg_temp.check_true('and it really has not got the module',
    not app.has_module(v_org, 'ai'));

  begin
    perform public.ai_ask(v_org, 'Anything');
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true(
    'a company that has not bought the module cannot ask', not v_took);
  perform pg_temp.check_eq('and is not charged for being refused',
    (select count(*)::integer from public.credit_ledger
      where org_id = v_org and description = 'AI question'), 0);
end $$;

-- ---------------------------------------------------------------------
-- And it is paid for
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_took boolean;
  v_msg  text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kosong Sdn Bhd', array['accounting', 'ai']);
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  perform pg_temp.check_true('this one has the module',
    app.has_module(v_org, 'ai'));

  -- No credit at all. Charged before the answer on purpose: the model
  -- bills for the attempt, so a company at nil could otherwise ask for
  -- ever.
  begin
    perform public.ai_ask(v_org, 'Anything');
    v_took := true;
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true('with no credit there is no question',
    not v_took);
  perform pg_temp.check_eq('and nothing was recorded',
    (select count(*)::integer from public.ai_messages m
       join public.ai_conversations c on c.id = m.conversation_id
      where c.org_id = v_org), 0);
end $$;

-- ---------------------------------------------------------------------
-- Nobody else may speak in the assistant's voice
-- ---------------------------------------------------------------------
--
-- Not a leak -- a forgery. A colleague learns nothing by doing this;
-- they plant something. The screen draws assistant turns as the
-- assistant's words, and this module exists to be believed about
-- figures, so an answer saying the books are in order under a question
-- somebody really asked is worth more to a person covering something up
-- than any read they could have done.
--
-- `ai_ask` refused this from the start. `ai_answer` did not, until 0474.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_owner uuid;
  v_other uuid;
  v_conv  uuid;
  v_took  boolean;
  v_msg   text;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Suara Palsu Sdn Bhd', array['accounting', 'ai']);
  perform app.move_credit(v_org, 'topup', 100, 'For the test',
                          null, null, false);

  -- A colleague in the same company, with the smallest role there is.
  -- The point is that belonging to the company was the entire check.
  v_other := pg_temp.another_user('rakan@ai.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_other, 'viewer', 'active', now());

  perform pg_temp.sign_in_as(v_owner);
  v_conv := public.ai_ask(v_org, 'What do we owe?');

  perform pg_temp.sign_in_as(v_other);

  -- The half that was already right, asserted first so that a run where
  -- both halves broke says which one it noticed.
  begin
    perform public.ai_ask(v_org, 'sneaky', v_conv);
    v_took := true;
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a colleague cannot add a question to your conversation', not v_took);
  perform pg_temp.check_eq('and is told why', v_msg,
    'That is not your conversation');

  begin
    perform public.ai_answer(v_conv, 'Your books are perfectly in order.');
    v_took := true;
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a colleague cannot put words in the assistant''s mouth', not v_took);
  perform pg_temp.check_eq('and is refused the same way', v_msg,
    'That is not your conversation');

  -- What the owner reads back. The assertion above would pass on a
  -- refusal that had already written the row, which is the shape of
  -- half-fix worth being explicit about.
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('so nothing was planted',
    (select count(*)::integer from public.ai_messages m
      where m.conversation_id = v_conv and m.role = 'assistant'), 0);

  -- And the legitimate path still works, or the fix is just a wall.
  perform pg_temp.check_true('while the person who asked can be answered',
    public.ai_answer(v_conv, 'You owe RM 4,000.') is not null);
  perform pg_temp.check_eq('and it is there to read',
    (select m.content from public.ai_messages m
      where m.conversation_id = v_conv and m.role = 'assistant'),
    'You owe RM 4,000.');
end $$;

rollback;
