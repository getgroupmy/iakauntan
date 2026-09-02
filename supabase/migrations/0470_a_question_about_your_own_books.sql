-- ---------------------------------------------------------------------
-- 0470  A question about your own books
-- ---------------------------------------------------------------------
-- Every figure in this product is already computed by a function that
-- knows the rules -- `report_general_ledger`, `report_ar_aging`,
-- `corp_upcoming_filings`, `report_statutory_due`. What is missing is
-- the ability to ask for one in a sentence. "Why is 6350 up RM3,412 this
-- month" is answerable from the general ledger in four lines, and
-- getting there today means knowing that the general ledger is where to
-- look, which account 6350 is, and which dates to type.
--
-- This is the database half of the AI module: what an assistant is
-- allowed to read, how it is allowed to read it, and where the
-- conversation is kept. The model call itself lives in the `ask` edge
-- function.
--
-- ### The whole design is the allow-list
--
-- An assistant that could call any RPC would be a hole with a chat box
-- in front of it. So `ai_tools` names, one row at a time, exactly which
-- functions may be reached, and three things are enforced about every
-- row **at the moment it is written**, by `app.guard_ai_tool`:
--
--   * the function exists, and is in `public`;
--   * it is `stable` or `immutable` -- **it cannot write**. Postgres
--     knows this, so nothing depends on anybody's judgement or on a
--     naming convention. That matters more than it sounds: `report_`
--     looks like a prefix that means "reads", and
--     `report_feedback(...)` and `report_denied(...)` are both
--     `volatile` functions that insert rows. A convention would have
--     let both in;
--   * every argument named in the row is a real parameter of that
--     function, so a tool cannot be registered that fails at the moment
--     somebody asks a question.
--
-- ### The company is not the model's to choose
--
-- Every one of these functions takes `p_org_id`, and none of them takes
-- it *from the model*. `ai_run_tool` supplies it from the conversation,
-- and a tool row with `injects_org` set cannot have `p_org_id` passed
-- in at all. It is not that a wrong company would be refused -- it
-- would be, by `app.is_org_member` inside each function -- it is that
-- there is nowhere for the model to say one.
--
-- ### An empty answer is not a refusal
--
-- Every report the assistant can reach guards itself already, and
-- guards itself *in the where clause*: `app.is_org_member(p_org_id)`
-- filters, so a stranger gets zero rows rather than an error. On a
-- screen that is exactly right — an empty table reads as empty. Handed
-- to a model it is the worst answer available, because `[]` does not
-- come back as "you may not see this", it comes back as "there is
-- nothing outstanding", said confidently about books nobody was shown.
-- `ai_run_tool` therefore refuses before it reads.
--
-- ### And it reads as the person asking
--
-- `ai_run_tool` is **security invoker**, deliberately and unusually for
-- this schema. Everything else here is `security definer` because it
-- has a guard of its own to apply. This one has the opposite job: it
-- must be incapable of seeing anything the person who asked cannot see,
-- so it runs as them and every policy and `app.can_read_*` guard
-- applies exactly as it does when they open the screen. An auditor gets
-- the auditor's answer; a salesperson does not get the payroll.
--
-- ### Mutants
--
-- Four, restated into a built database and run against
-- `supabase/tests/ai_assistant.sql`. All four die.
--
--   * the membership refusal taken out of `ai_run_tool` -- killed by
--     "an outsider cannot read another company's books through a tool".
--     Worth knowing what the failure looked like: not a leak of rows,
--     but `[]`, because the reports filter rather than refuse. The
--     assertion is about the refusal for that reason;
--   * the allow-list stopped being consulted, so the tool name becomes
--     the function name -- killed by "a tool that is not on the list is
--     refused", **after the assertion was rewritten**. It first used a
--     made-up tool name and the mutant died on "function
--     public.drop_everything does not exist": a pass proving the name
--     was fictional rather than that the list was read. It now asks for
--     `report_migration_progress`, which is real, stable, takes exactly
--     `p_org_id`, and would have run;
--   * the volatility check dropped from the registration guard --
--     killed by "a function that writes cannot be given to the
--     assistant", registering `report_feedback`;
--   * an undeclared argument dropped instead of refused -- killed by
--     "an argument the tool has not got is refused, not dropped". A
--     dropped argument answers a different question from the one asked,
--     and answers it confidently.
-- ---------------------------------------------------------------------

insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order, is_active)
values (
  'ai', 'AI Assistant',
  'Ask about this company''s own books in a sentence and get the figure '
  'with the entries behind it. Reads through the same reports the '
  'screens use, as the person asking, so it can see what they can see '
  'and nothing else. Charged per question against scanning credit.',
  false, 39.00, 30, true)
on conflict (code) do update
  set name = excluded.name, description = excluded.description,
      is_active = true;

-- ---------------------------------------------------------------------
-- What may be read, and how
-- ---------------------------------------------------------------------
create table public.ai_tools (
  name          text primary key,
  function_name text not null,
  description   text not null,
  -- [{name, type, required, description}]. `type` is one of the six in
  -- app.ai_arg_types(); anything else is refused, because these become
  -- a cast in generated SQL.
  arguments     jsonb not null default '[]'::jsonb,
  -- The company comes from the conversation, never from the model.
  injects_org   boolean not null default true,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

comment on table public.ai_tools is
  'The only functions the AI module may call. Every row is checked when '
  'it is written: the function must exist, live in public, be stable or '
  'immutable so it cannot write, and name only its own parameters. See '
  '0470.';

create or replace function app.ai_arg_types()
returns text[] language sql immutable
set search_path = public, app, pg_temp
as $$
  select array['uuid', 'date', 'integer', 'numeric', 'text', 'boolean'];
$$;

create or replace function app.guard_ai_tool()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_oid  oid;
  v_vol  "char";
  v_args text[];
  a      jsonb;
begin
  select p.oid, p.provolatile,
         string_to_array(pg_get_function_identity_arguments(p.oid), ', ')
    into v_oid, v_vol, v_args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = new.function_name
   order by p.pronargs desc
   limit 1;

  if v_oid is null then
    raise exception
      'There is no public.% to call, so % cannot be a tool.',
      new.function_name, new.name using errcode = 'P0002';
  end if;

  -- The one that matters. `volatile` means it may write, and Postgres
  -- is the authority on that -- not the name. `report_feedback` and
  -- `report_denied` both insert rows.
  if v_vol not in ('s', 'i') then
    raise exception
      'public.% is volatile, so it may write. Only a function Postgres '
      'knows to be stable or immutable may be read by the assistant.',
      new.function_name using errcode = '42501';
  end if;

  for a in select * from jsonb_array_elements(new.arguments)
  loop
    if not (a ->> 'type') = any (app.ai_arg_types()) then
      raise exception
        '% is not a type a tool argument may have. One of: %.',
        coalesce(a ->> 'type', 'null'),
        array_to_string(app.ai_arg_types(), ', ') using errcode = '23514';
    end if;

    -- The parameter has to be one the function actually has, or the
    -- tool is a question that fails the first time somebody asks it.
    if not exists (
      select 1 from unnest(v_args) g
       where split_part(btrim(g), ' ', 1) = (a ->> 'name')) then
      raise exception
        'public.% has no parameter called %.',
        new.function_name, a ->> 'name' using errcode = '23514';
    end if;

    if new.injects_org and (a ->> 'name') = 'p_org_id' then
      raise exception
        '% names p_org_id, but the company comes from the conversation. '
        'A tool cannot let the model choose whose books to read.',
        new.name using errcode = '42501';
    end if;
  end loop;

  return new;
end $$;

create trigger guard_ai_tool
  before insert or update on public.ai_tools
  for each row execute function app.guard_ai_tool();

alter table public.ai_tools enable row level security;

-- Readable by anybody signed in: it is a list of function names, and
-- the assistant's catalogue has to be built from it. Written by nobody
-- through the API — these rows arrive in migrations.
create policy ai_tools_read on public.ai_tools
  for select to authenticated using (true);

-- ---------------------------------------------------------------------
-- The conversation
-- ---------------------------------------------------------------------
create table public.ai_conversations (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  title      text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ai_messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null
                  references public.ai_conversations (id) on delete cascade,
  org_id          uuid not null references public.organizations (id) on delete cascade,
  role            text not null check (role in ('user', 'assistant', 'tool')),
  content         text,
  -- What was read to answer, kept so an answer can be checked rather
  -- than believed. A figure with no working shown is a rumour.
  tool_calls      jsonb not null default '[]'::jsonb,
  created_by      uuid references auth.users (id) on delete set null,
  created_at      timestamptz not null default now()
);

create index on public.ai_conversations (org_id, updated_at desc);
create index on public.ai_messages (conversation_id, created_at);

create trigger set_updated_at before update on public.ai_conversations
  for each row execute function app.set_updated_at();

alter table public.ai_conversations enable row level security;
alter table public.ai_messages enable row level security;

-- A conversation is the asker's own. It is not hidden from colleagues
-- out of secrecy -- everything in it came from the company's own books
-- -- but somebody else's half-finished question is noise on your screen.
create policy ai_conversations_read on public.ai_conversations
  for select to authenticated
  using (app.is_org_member(org_id)
         and (created_by = auth.uid() or app.can_admin(org_id)));

create policy ai_messages_read on public.ai_messages
  for select to authenticated
  using (exists (select 1 from public.ai_conversations c
                  where c.id = conversation_id
                    and app.is_org_member(c.org_id)
                    and (c.created_by = auth.uid() or app.can_admin(c.org_id))));

-- ---------------------------------------------------------------------
-- Reading one thing, as the person who asked
-- ---------------------------------------------------------------------
-- security INVOKER, and that is the point. See the header.
create or replace function public.ai_run_tool(
  p_org_id uuid,
  p_tool   text,
  p_args   jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable security invoker
set search_path = public, app, pg_temp
as $$
declare
  t        public.ai_tools;
  a        jsonb;
  v_parts  text[] := '{}';
  v_value  text;
  v_sql    text;
  v_out    jsonb;
begin
  -- Refused, rather than answered with nothing.
  --
  -- Every report this can reach already guards itself — they all carry
  -- `app.is_org_member(p_org_id)` — but they guard it *in the where
  -- clause*, so a stranger gets zero rows rather than an error. For a
  -- screen that is right: an empty table reads as empty. For an
  -- assistant it is the worst possible answer, because a model handed
  -- `[]` does not say "you may not see this", it says "there is nothing
  -- outstanding" — confidently, about books it was never shown. An
  -- empty answer and a refused one have to be different things here.
  if not app.is_org_member(p_org_id) then
    raise exception
      'Not a member of that company, so there is nothing here to read.'
      using errcode = '42501';
  end if;
  if not app.has_module(p_org_id, 'ai') then
    raise exception
      'The AI Assistant is not switched on for this company.'
      using errcode = '42501';
  end if;

  select * into t from public.ai_tools
   where name = p_tool and is_active;
  if t.name is null then
    raise exception
      'The assistant has no tool called %. It may only read what 0470''s '
      'list names.', p_tool using errcode = '42501';
  end if;

  if t.injects_org then
    v_parts := array_append(v_parts, format('p_org_id => %L::uuid', p_org_id));
  end if;

  for a in select * from jsonb_array_elements(t.arguments)
  loop
    v_value := p_args ->> (a ->> 'name');

    if v_value is null then
      if coalesce((a ->> 'required')::boolean, false) then
        raise exception '% needs %.', p_tool, a ->> 'name'
          using errcode = '23514';
      end if;
      continue;
    end if;

    -- `%I` on the parameter name and `%L` on the value; the type is one
    -- of six the guard allows. Nothing the model sends reaches the
    -- statement unquoted.
    v_parts := array_append(v_parts,
      format('%I => %L::%s', a ->> 'name', v_value, a ->> 'type'));
  end loop;

  -- An argument the tool does not declare is refused rather than
  -- dropped. Dropping it silently answers a different question from the
  -- one asked, confidently.
  for a in select jsonb_build_object('name', k)
             from jsonb_object_keys(p_args) k
  loop
    if not exists (select 1 from jsonb_array_elements(t.arguments) d
                    where d ->> 'name' = a ->> 'name') then
      raise exception '% has no argument called %.', p_tool, a ->> 'name'
        using errcode = '23514';
    end if;
  end loop;

  v_sql := format(
    'select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) '
    'from public.%I(%s) x',
    t.function_name, array_to_string(v_parts, ', '));

  execute v_sql into v_out;
  return coalesce(v_out, '[]'::jsonb);
end $$;

revoke all on function public.ai_run_tool(uuid, text, jsonb) from public, anon;
grant execute on function public.ai_run_tool(uuid, text, jsonb) to authenticated;
grant select on public.ai_tools to authenticated;
grant select on public.ai_conversations, public.ai_messages to authenticated;

comment on function public.ai_run_tool(uuid, text, jsonb) is
  'Runs one allow-listed read for the assistant, as the caller — '
  'security invoker on purpose, so it cannot see what the person '
  'asking cannot. The company comes from the argument, never from the '
  'model. See 0470.';

-- ---------------------------------------------------------------------
-- What the assistant is offered
-- ---------------------------------------------------------------------
create or replace function public.ai_tool_catalogue(p_org_id uuid)
returns jsonb
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', t.name,
           'description', t.description,
           'arguments', t.arguments) order by t.name), '[]'::jsonb)
    from public.ai_tools t
   where t.is_active
     and app.is_org_member(p_org_id)
     and app.has_module(p_org_id, 'ai');
$$;

revoke all on function public.ai_tool_catalogue(uuid) from public, anon;
grant execute on function public.ai_tool_catalogue(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Asking, and what it costs
-- ---------------------------------------------------------------------
create or replace function public.ai_ask(
  p_org_id      uuid,
  p_question    text,
  p_conversation uuid default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id    uuid := p_conversation;
  v_price numeric(18, 2) := 0.20;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of that company' using errcode = '42501';
  end if;
  if not app.has_module(p_org_id, 'ai') then
    raise exception
      'The AI Assistant is not switched on for this company.'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_question, '')), '') is null then
    raise exception 'Ask something.' using errcode = '23514';
  end if;

  if v_id is null then
    insert into public.ai_conversations (org_id, title, created_by)
    values (p_org_id, left(btrim(p_question), 80), auth.uid())
    returning id into v_id;
  else
    -- Somebody else's conversation is not one you may add to, and a
    -- conversation belongs to the company it was started in.
    if not exists (select 1 from public.ai_conversations c
                    where c.id = v_id and c.org_id = p_org_id
                      and (c.created_by = auth.uid()
                           or app.can_admin(p_org_id))) then
      raise exception 'That is not your conversation' using errcode = '42501';
    end if;
    update public.ai_conversations set updated_at = now() where id = v_id;
  end if;

  -- Charged before the answer, and refused when the credit is not
  -- there: the model bills for the attempt, so charging afterwards
  -- would mean a company at nil could ask for ever.
  perform app.move_credit(
    p_org_id, 'usage', -v_price, 'AI question', null, null, true);

  insert into public.ai_messages
    (conversation_id, org_id, role, content, created_by)
  values (v_id, p_org_id, 'user', btrim(p_question), auth.uid());

  return v_id;
end $$;

revoke all on function public.ai_ask(uuid, text, uuid) from public, anon;
grant execute on function public.ai_ask(uuid, text, uuid) to authenticated;

create or replace function public.ai_answer(
  p_conversation uuid,
  p_content      text,
  p_tool_calls   jsonb default '[]'::jsonb)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
  v_id  uuid;
begin
  select org_id into v_org from public.ai_conversations
   where id = p_conversation;
  if v_org is null or not app.is_org_member(v_org) then
    raise exception 'No such conversation' using errcode = 'P0002';
  end if;

  insert into public.ai_messages
    (conversation_id, org_id, role, content, tool_calls, created_by)
  values (p_conversation, v_org, 'assistant', p_content,
          coalesce(p_tool_calls, '[]'::jsonb), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

revoke all on function public.ai_answer(uuid, text, jsonb) from public, anon;
grant execute on function public.ai_answer(uuid, text, jsonb) to authenticated;

create or replace function public.ai_conversation(p_id uuid)
returns jsonb
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select jsonb_build_object(
    'id', c.id, 'title', c.title, 'org_id', c.org_id,
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
               'role', m.role, 'content', m.content,
               'tool_calls', m.tool_calls, 'created_at', m.created_at)
             order by m.created_at)
        from public.ai_messages m where m.conversation_id = c.id), '[]'::jsonb))
    from public.ai_conversations c
   where c.id = p_id
     and app.is_org_member(c.org_id)
     and (c.created_by = auth.uid() or app.can_admin(c.org_id));
$$;

create or replace function public.ai_conversations_for(p_org_id uuid)
returns setof public.ai_conversations
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select c.* from public.ai_conversations c
   where c.org_id = p_org_id
     and app.is_org_member(p_org_id)
     and (c.created_by = auth.uid() or app.can_admin(p_org_id))
   order by c.updated_at desc
   limit 50;
$$;

revoke all on function public.ai_conversation(uuid) from public, anon;
revoke all on function public.ai_conversations_for(uuid) from public, anon;
grant execute on function public.ai_conversation(uuid) to authenticated;
grant execute on function public.ai_conversations_for(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The opening set
-- ---------------------------------------------------------------------
-- Chosen for the questions an accountant actually asks out loud. Every
-- one of these is a function a screen already calls.
insert into public.ai_tools (name, function_name, description, arguments)
values
  ('general_ledger', 'report_general_ledger',
   'Every posted line on an account, in date order, with the balance '
   'brought forward and carried down. The report to answer "why is this '
   'account what it is".',
   '[{"name":"p_from","type":"date","required":false,
      "description":"Start of the period. Leave out for everything."},
     {"name":"p_to","type":"date","required":false,
      "description":"End of the period. Defaults to today."},
     {"name":"p_account_id","type":"uuid","required":false,
      "description":"One account. Leave out for all of them."}]'::jsonb),
  ('trial_balance', 'report_trial_balance',
   'Every account with its opening balance, movement and closing '
   'balance for a period.',
   '[{"name":"p_from","type":"date","required":false,"description":"Start."},
     {"name":"p_to","type":"date","required":false,"description":"End."}]'::jsonb),
  ('profit_and_loss', 'report_profit_loss',
   'Revenue and expenses for a period, and what is left.',
   '[{"name":"p_from","type":"date","required":true,"description":"Start."},
     {"name":"p_to","type":"date","required":true,"description":"End."}]'::jsonb),
  ('balance_sheet', 'report_balance_sheet',
   'What the company owns and owes on a day.',
   '[{"name":"p_as_at","type":"date","required":false,
      "description":"The day. Defaults to today."}]'::jsonb),
  ('who_owes_us', 'report_ar_aging',
   'Unpaid customer invoices by age, with money received and not yet '
   'set against anything.',
   '[{"name":"p_as_at","type":"date","required":false,
      "description":"The day to age against. Defaults to today."}]'::jsonb),
  ('who_we_owe', 'report_ap_aging',
   'Unpaid supplier bills by age.',
   '[{"name":"p_as_at","type":"date","required":false,
      "description":"The day to age against. Defaults to today."}]'::jsonb),
  ('statutory_filings_due', 'corp_upcoming_filings',
   'Annual returns and financial statements coming due for the '
   'companies whose registers this company keeps, with the SSM '
   'deadline for each.',
   '[{"name":"p_within_days","type":"integer","required":false,
      "description":"How far ahead to look. Defaults to the usual window."}]'::jsonb),
  ('cash_flow', 'report_cash_flow',
   'Money in and money out over a period.',
   '[{"name":"p_from","type":"date","required":true,"description":"Start."},
     {"name":"p_to","type":"date","required":true,"description":"End."}]'::jsonb);

-- ---------------------------------------------------------------------
-- Somewhere to see it
-- ---------------------------------------------------------------------
-- `demo_rebuild.sql` asserts that no active module is left without a
-- demo tenant to show it in, and it is right to: a module on the price
-- list that opens an empty screen is worse than one that is not sold
-- yet.
--
-- The AI module has no rows of its own until somebody asks something,
-- which is the same shape as attachments and the mailbox two lines
-- above it in this function — a capability that hangs off books that
-- already exist. Restated from the live definition; the change is the
-- one `union all`.

CREATE OR REPLACE FUNCTION app.demo_modules_in_use()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r   record;
  v_n integer := 0;
begin
  for r in
    select distinct x.org_id, x.module_code
      from (
        select org_id, 'pos'          as module_code from public.pos_outlets
        union all
        select org_id, 'loyalty'      from public.loyalty_programs
        union all
        select org_id, 'memberships'  from public.pos_memberships
        union all
        select org_id, 'ticketing'    from public.tickets
        union all
        select org_id, 'hr'           from public.employees
        union all
        select org_id, 'fixed_assets' from public.fixed_assets
        union all
        select org_id, 'inventory'    from public.warehouses
        union all
        select org_id, 'purchases'    from public.purchase_documents
        union all
        -- 0324. Not detected from rows, unlike every line above it.
        -- Attachments hang off records that already exist rather than
        -- having a subject of their own, so a tenant that happens not
        -- to have uploaded a file yet would show nothing about a
        -- feature it can perfectly well demonstrate.
        select id, 'attachments' from public.organizations where is_demo
        union all
        -- 0329, and for the same reason twice over. A name on our
        -- domain exists only once somebody has asked for one and an
        -- operator has agreed; mail arrives only once somebody has
        -- written to the address. A tenant rebuilt this morning has
        -- neither and never will by itself.
        select id, 'workspace_address'
          from public.organizations where is_demo
        union all
        select id, 'mailbox' from public.organizations where is_demo
        union all
        -- 0470, and the same reason a third time. Asking a question is
        -- something a visitor does; a tenant rebuilt this morning has
        -- asked nothing and never will by itself. What the module
        -- demonstrates is the books it reads, and those are there.
        select id, 'ai' from public.organizations where is_demo
      ) x
      join public.organizations g on g.id = x.org_id and g.is_demo
     where not exists (
       select 1 from public.org_modules om
        where om.org_id = x.org_id and om.module_code = x.module_code
          and om.is_enabled)
  loop
    insert into public.org_modules (org_id, module_code, is_enabled, enabled_at, notes)
    values (r.org_id, r.module_code, true, now(),
            'Enabled by app.demo_modules_in_use: the tenant has data for it.')
    on conflict (org_id, module_code) do update
      set is_enabled = true, expires_at = null;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$function$;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_bad text;
begin
  -- The property the whole module rests on, read from the catalogue
  -- rather than from the printed definition.
  --
  -- The first draft of this check looked for the words "security
  -- invoker" in `pg_get_functiondef`, and failed on a function that was
  -- correct: Postgres prints SECURITY DEFINER when it is set and prints
  -- nothing when it is not, because invoker is the default. `prosecdef`
  -- is the fact. The absence of a phrase in generated text is not
  -- evidence of anything.
  if (select p.prosecdef from pg_proc p
       where p.oid = 'public.ai_run_tool(uuid, text, jsonb)'::regprocedure)
  then
    raise exception
      '0470: the tool runner is security definer, so the assistant can '
      'read what the person asking cannot';
  end if;

  -- Nothing volatile got in. Belt and braces beside the trigger: this
  -- catches a row inserted before the trigger existed, and it is the
  -- statement that would have caught report_feedback.
  select string_agg(t.function_name, ', ') into v_bad
    from public.ai_tools t
    join pg_proc p on p.proname = t.function_name
    join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
   where p.provolatile not in ('s', 'i');
  if v_bad is not null then
    raise exception '0470: a tool can write: %', v_bad;
  end if;

  if (select count(*) from public.ai_tools) < 5 then
    raise exception '0470: the assistant has almost nothing to read';
  end if;

  -- The refusal, not the filter. See the header.
  if position('Not a member of that company' in
              pg_get_functiondef(to_regprocedure(
                'public.ai_run_tool(uuid, text, jsonb)'))) = 0 then
    raise exception
      '0470: a stranger gets an empty answer instead of a refusal, and a '
      'model reads empty as "there is nothing there"';
  end if;
end
$do$;
