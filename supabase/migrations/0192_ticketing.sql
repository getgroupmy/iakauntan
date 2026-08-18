-- A service desk: tickets, the teams that work them, and the SLAs they
-- are held to.
--
-- The product already carries most of what a helpdesk needs and none of
-- the thing itself. Contacts exist, employees exist, assets exist,
-- attachments exist, approvals exist, public holidays exist. What is
-- missing is the record that says somebody asked for help at a
-- particular moment and somebody else owes them an answer by another.
--
-- ## One table for four different jobs
--
-- The ITIL archetypes — incident, service request, problem, change —
-- are not four tables. They are the same record with different
-- expectations attached, and every product that split them into
-- separate tables ends up rebuilding the join. An incident that turns
-- out to be one of five with a common cause becomes a problem's child;
-- a service request that needs a change window becomes a change's
-- child. `parent_id` carries that, and `ticket_type` carries which kind
-- of expectation applies.
--
-- ## Who asked
--
-- A ticket is raised either by somebody with a login — staff, an
-- internal IT desk — or by a customer who has none, in which case the
-- requester is a `contacts` row. Both are nullable and exactly one must
-- be set, which is a check rather than a convention because a ticket
-- belonging to nobody cannot be answered and a ticket belonging to two
-- people cannot be reported on.
--
-- ## The SLA is a promise about time, so it is stored as one
--
-- `sla_targets` holds minutes per priority, not timestamps. The
-- deadlines land on the ticket when it is created, because a target
-- that is recomputed on read gives a different answer after somebody
-- edits the policy — and an SLA you can retroactively meet by editing
-- the policy is not a service level agreement. `0193` does the
-- arithmetic; this migration only makes somewhere to put it.
--
-- ## Status is small on purpose
--
-- Seven states, and the transitions between them are enforced in
-- `0194` rather than by a check constraint, because the legal moves
-- depend on who is asking and a constraint cannot see that. The states
-- that stop the SLA clock — pending on the requester, on hold — are
-- marked as such on the table rather than hardcoded in the sweep, since
-- which states pause a clock is a policy question and policies move.

-- ---------------------------------------------------------------------
-- The vocabulary
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'ticket_channel') then
    create type app.ticket_channel as enum
      ('web', 'email', 'chat', 'phone', 'api', 'monitoring');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'ticket_type') then
    create type app.ticket_type as enum
      ('incident', 'service_request', 'problem', 'change');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'ticket_priority') then
    -- P1 first, so `order by priority` is most urgent first without a
    -- case expression at every call site.
    create type app.ticket_priority as enum ('p1', 'p2', 'p3', 'p4');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'ticket_status') then
    create type app.ticket_status as enum
      ('new', 'open', 'pending', 'on_hold', 'resolved', 'closed', 'cancelled');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'ticket_escalation') then
    create type app.ticket_escalation as enum ('hierarchic', 'functional');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Is the module on?
-- ---------------------------------------------------------------------
create or replace function app.has_ticketing_module(p_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select app.has_module(p_org_id, 'ticketing');
$$;

grant execute on function app.has_ticketing_module(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Teams
-- ---------------------------------------------------------------------
create table if not exists public.ticket_teams (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id) on delete cascade,
  code          text not null,
  name          text not null,
  description   text,
  email         text,
  -- Where anything unrouted lands. Without one, a category nobody
  -- configured produces a ticket with no team, which is the queue
  -- everybody discovers three weeks later.
  is_default    boolean not null default false,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, code),
  unique (org_id, id)
);

create unique index if not exists ticket_teams_one_default
  on public.ticket_teams (org_id) where is_default;

create table if not exists public.ticket_team_members (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations(id) on delete cascade,
  team_id    uuid not null references public.ticket_teams(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  is_lead    boolean not null default false,
  created_at timestamptz not null default now(),
  unique (team_id, user_id)
);

-- ---------------------------------------------------------------------
-- SLA policies
-- ---------------------------------------------------------------------
create table if not exists public.sla_policies (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  code        text not null,
  name        text not null,
  -- Round-the-clock or only during the working day. A P1 raised at
  -- 23:50 on a Friday has a very different deadline under each, and
  -- which one applies is the single most argued line in any support
  -- contract.
  business_hours_only boolean not null default true,
  work_start  time not null default '09:00',
  work_end    time not null default '18:00',
  -- ISO weekdays that count: 1 = Monday. Malaysia is mostly Mon–Fri,
  -- but Johor, Kedah, Kelantan and Terengganu run Sun–Thu, so this is
  -- per policy rather than assumed.
  work_days   smallint[] not null default array[1,2,3,4,5],
  -- Which state's holidays pause the clock. Null means the company's
  -- own state.
  holiday_state_code text,
  is_default  boolean not null default false,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- Whose working day. The database runs in UTC and no other table
  -- carries a timezone, so without this a 09:00 start means 09:00 UTC —
  -- which is 5pm in Kuala Lumpur, and every deadline computed from it
  -- would be wrong by eight hours while looking entirely plausible.
  --
  -- Last, out of the grouping it belongs to, because that is where the
  -- hosted project has it: the table was created there first and this
  -- column added afterwards, so it is column 14 and no `create table`
  -- that declares it in the middle will ever reproduce that. The schema
  -- drift gate compares column order and is right to — moving it back
  -- up to sit beside `work_days` reads better and makes CI red.
  time_zone   text not null default 'Asia/Kuala_Lumpur',
  unique (org_id, code),
  unique (org_id, id),
  constraint sla_policies_work_window check (work_end > work_start),
  constraint sla_policies_work_days check (array_length(work_days, 1) between 1 and 7)
);

create unique index if not exists sla_policies_one_default
  on public.sla_policies (org_id) where is_default;

create table if not exists public.sla_targets (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id) on delete cascade,
  policy_id     uuid not null references public.sla_policies(id) on delete cascade,
  priority      app.ticket_priority not null,
  -- Minutes, not intervals: the clock they are counted against is not
  -- wall clock when the policy is business-hours only, so an interval
  -- would imply an arithmetic that does not apply.
  response_minutes   integer not null,
  resolution_minutes integer not null,
  created_at    timestamptz not null default now(),
  unique (policy_id, priority),
  constraint sla_targets_positive
    check (response_minutes > 0 and resolution_minutes > 0),
  -- A resolution deadline earlier than the response deadline is not a
  -- stricter promise, it is a typo.
  constraint sla_targets_ordered
    check (resolution_minutes >= response_minutes)
);

-- ---------------------------------------------------------------------
-- Categories, which are what routing actually keys off
-- ---------------------------------------------------------------------
create table if not exists public.ticket_categories (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id) on delete cascade,
  code           text not null,
  name           text not null,
  parent_id      uuid references public.ticket_categories(id) on delete set null,
  default_type   app.ticket_type not null default 'incident',
  default_priority app.ticket_priority not null default 'p3',
  team_id        uuid,
  sla_policy_id  uuid,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (org_id, code),
  unique (org_id, id),
  -- Composite so a category cannot route to another tenant's team or
  -- borrow another tenant's SLA.
  constraint ticket_categories_team_fk
    foreign key (org_id, team_id) references public.ticket_teams(org_id, id)
    on delete set null,
  constraint ticket_categories_sla_fk
    foreign key (org_id, sla_policy_id) references public.sla_policies(org_id, id)
    on delete set null
);

-- ---------------------------------------------------------------------
-- The composite key a ticket's asset link needs
--
-- Every table this schema points at org-scoped carries `unique (org_id,
-- id)` so the reference can be made composite and a row cannot borrow
-- another tenant's record. `fixed_assets` was the one that did not have
-- it — `id` is already unique, so this adds an index and forbids
-- nothing that was previously allowed.
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.fixed_assets'::regclass
       and contype = 'u'
       and conkey = array[
         (select attnum from pg_attribute
           where attrelid = 'public.fixed_assets'::regclass and attname = 'org_id'),
         (select attnum from pg_attribute
           where attrelid = 'public.fixed_assets'::regclass and attname = 'id')]
  ) then
    alter table public.fixed_assets add constraint fixed_assets_org_id_id_key
      unique (org_id, id);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- The ticket
-- ---------------------------------------------------------------------
create table if not exists public.tickets (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id) on delete cascade,
  ticket_no     text not null,
  subject       text not null,
  description   text,
  ticket_type   app.ticket_type not null default 'incident',
  priority      app.ticket_priority not null default 'p3',
  status        app.ticket_status not null default 'new',
  channel       app.ticket_channel not null default 'web',

  category_id   uuid,
  team_id       uuid,
  assignee_id   uuid references auth.users(id),

  -- Exactly one of these. See the header.
  requester_user_id    uuid references auth.users(id),
  requester_contact_id uuid,

  -- What it is about, when it is about a thing the company owns.
  asset_id      uuid,
  -- An incident's parent problem, or a request's parent change.
  parent_id     uuid references public.tickets(id) on delete set null,

  sla_policy_id uuid,
  opened_at     timestamptz not null default now(),
  response_due_at   timestamptz,
  resolution_due_at timestamptz,
  first_response_at timestamptz,
  resolved_at   timestamptz,
  closed_at     timestamptz,
  -- Stamped by the sweep rather than derived on read, so a report of
  -- what was breached last month does not change when somebody edits
  -- the policy this month.
  response_breached   boolean not null default false,
  resolution_breached boolean not null default false,
  -- How long the clock has been stopped, in minutes, accumulated as the
  -- ticket moves in and out of the paused states.
  paused_minutes integer not null default 0,
  paused_at     timestamptz,

  escalation_level smallint not null default 0,
  reopened_count   smallint not null default 0,
  resolution_note  text,
  tags          text[] not null default '{}',
  custom_fields jsonb not null default '{}'::jsonb,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,

  unique (org_id, ticket_no),
  unique (org_id, id),

  constraint tickets_one_requester check (
    (requester_user_id is not null)::int + (requester_contact_id is not null)::int = 1),

  constraint tickets_category_fk
    foreign key (org_id, category_id) references public.ticket_categories(org_id, id)
    on delete set null,
  constraint tickets_team_fk
    foreign key (org_id, team_id) references public.ticket_teams(org_id, id)
    on delete set null,
  constraint tickets_sla_fk
    foreign key (org_id, sla_policy_id) references public.sla_policies(org_id, id)
    on delete set null,
  constraint tickets_contact_fk
    foreign key (org_id, requester_contact_id) references public.contacts(org_id, id)
    on delete restrict,
  constraint tickets_asset_fk
    foreign key (org_id, asset_id) references public.fixed_assets(org_id, id)
    on delete set null
);

create index if not exists tickets_org_status  on public.tickets (org_id, status);
create index if not exists tickets_org_team    on public.tickets (org_id, team_id);
create index if not exists tickets_assignee    on public.tickets (assignee_id)
  where assignee_id is not null;
-- The sweep's query: anything still running against a deadline.
create index if not exists tickets_open_deadlines on public.tickets (org_id, resolution_due_at)
  where status not in ('resolved', 'closed', 'cancelled');

-- ---------------------------------------------------------------------
-- Conversation and history
-- ---------------------------------------------------------------------
create table if not exists public.ticket_comments (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  ticket_id   uuid not null references public.tickets(id) on delete cascade,
  body        text not null,
  -- An internal note is invisible to the requester. It is the single
  -- most dangerous boolean in a helpdesk, so it defaults to the safe
  -- value: visible notes have to be asked for.
  is_internal boolean not null default true,
  author_user_id    uuid references auth.users(id),
  author_contact_id uuid,
  channel     app.ticket_channel not null default 'web',
  created_at  timestamptz not null default now(),
  constraint ticket_comments_one_author check (
    (author_user_id is not null)::int + (author_contact_id is not null)::int = 1),
  constraint ticket_comments_contact_fk
    foreign key (org_id, author_contact_id) references public.contacts(org_id, id)
    on delete restrict
);

create index if not exists ticket_comments_ticket
  on public.ticket_comments (ticket_id, created_at);

create table if not exists public.ticket_events (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  ticket_id   uuid not null references public.tickets(id) on delete cascade,
  event_type  text not null,
  from_value  text,
  to_value    text,
  note        text,
  actor_id    uuid references auth.users(id),
  created_at  timestamptz not null default now()
);

create index if not exists ticket_events_ticket
  on public.ticket_events (ticket_id, created_at);

-- ---------------------------------------------------------------------
-- Canned responses
-- ---------------------------------------------------------------------
create table if not exists public.canned_responses (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations(id) on delete cascade,
  code       text not null,
  title      text not null,
  body       text not null,
  category_id uuid,
  is_active  boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, code),
  constraint canned_responses_category_fk
    foreign key (org_id, category_id) references public.ticket_categories(org_id, id)
    on delete set null
);

-- ---------------------------------------------------------------------
-- Keeping updated_at honest, and a history of what changed
-- ---------------------------------------------------------------------
drop trigger if exists set_updated_at on public.tickets;
create trigger set_updated_at before update on public.tickets
  for each row execute function app.set_updated_at();

drop trigger if exists set_updated_at on public.ticket_teams;
create trigger set_updated_at before update on public.ticket_teams
  for each row execute function app.set_updated_at();

drop trigger if exists set_updated_at on public.ticket_categories;
create trigger set_updated_at before update on public.ticket_categories
  for each row execute function app.set_updated_at();

drop trigger if exists set_updated_at on public.sla_policies;
create trigger set_updated_at before update on public.sla_policies
  for each row execute function app.set_updated_at();

drop trigger if exists set_updated_at on public.canned_responses;
create trigger set_updated_at before update on public.canned_responses
  for each row execute function app.set_updated_at();

-- The SLA policy is the promise; who changed it and when is the kind of
-- question that gets asked precisely once, in an argument about whether
-- a breach was real.
drop trigger if exists audit_changes on public.sla_policies;
create trigger audit_changes after insert or update or delete on public.sla_policies
  for each row execute function app.write_audit_log();

drop trigger if exists audit_changes on public.sla_targets;
create trigger audit_changes after insert or update or delete on public.sla_targets
  for each row execute function app.write_audit_log();

-- ---------------------------------------------------------------------
-- Row level security
--
-- Configuration — teams, categories, policies, targets, canned text —
-- is administrative. Tickets themselves are readable by anyone the
-- module is on for, plus the requester, who may have no other rights in
-- the company at all: a self-service portal where the person who raised
-- the ticket cannot read it is not a portal.
-- ---------------------------------------------------------------------
alter table public.ticket_teams        enable row level security;
alter table public.ticket_team_members enable row level security;
alter table public.sla_policies        enable row level security;
alter table public.sla_targets         enable row level security;
alter table public.ticket_categories   enable row level security;
alter table public.tickets             enable row level security;
alter table public.ticket_comments     enable row level security;
alter table public.ticket_events       enable row level security;
alter table public.canned_responses    enable row level security;

drop policy if exists ticket_teams_select on public.ticket_teams;
create policy ticket_teams_select on public.ticket_teams for select
  using (app.can_read_module(org_id, 'ticketing'));
drop policy if exists ticket_teams_write on public.ticket_teams;
create policy ticket_teams_write on public.ticket_teams for all
  using (app.can_admin(org_id) and app.has_ticketing_module(org_id))
  with check (app.can_admin(org_id) and app.has_ticketing_module(org_id));

drop policy if exists ticket_team_members_select on public.ticket_team_members;
create policy ticket_team_members_select on public.ticket_team_members for select
  using (app.can_read_module(org_id, 'ticketing'));
drop policy if exists ticket_team_members_write on public.ticket_team_members;
create policy ticket_team_members_write on public.ticket_team_members for all
  using (app.can_admin(org_id) and app.has_ticketing_module(org_id))
  with check (app.can_admin(org_id) and app.has_ticketing_module(org_id));

drop policy if exists sla_policies_select on public.sla_policies;
create policy sla_policies_select on public.sla_policies for select
  using (app.can_read_module(org_id, 'ticketing'));
drop policy if exists sla_policies_write on public.sla_policies;
create policy sla_policies_write on public.sla_policies for all
  using (app.can_admin(org_id) and app.has_ticketing_module(org_id))
  with check (app.can_admin(org_id) and app.has_ticketing_module(org_id));

drop policy if exists sla_targets_select on public.sla_targets;
create policy sla_targets_select on public.sla_targets for select
  using (app.can_read_module(org_id, 'ticketing'));
drop policy if exists sla_targets_write on public.sla_targets;
create policy sla_targets_write on public.sla_targets for all
  using (app.can_admin(org_id) and app.has_ticketing_module(org_id))
  with check (app.can_admin(org_id) and app.has_ticketing_module(org_id));

drop policy if exists ticket_categories_select on public.ticket_categories;
create policy ticket_categories_select on public.ticket_categories for select
  using (app.can_read_module(org_id, 'ticketing'));
drop policy if exists ticket_categories_write on public.ticket_categories;
create policy ticket_categories_write on public.ticket_categories for all
  using (app.can_admin(org_id) and app.has_ticketing_module(org_id))
  with check (app.can_admin(org_id) and app.has_ticketing_module(org_id));

drop policy if exists tickets_select on public.tickets;
create policy tickets_select on public.tickets for select
  using (app.can_read_module(org_id, 'ticketing')
         or (requester_user_id = auth.uid() and app.has_ticketing_module(org_id)));
drop policy if exists tickets_write on public.tickets;
create policy tickets_write on public.tickets for all
  using (app.can_write_module(org_id, 'ticketing'))
  with check (app.can_write_module(org_id, 'ticketing'));

-- A requester reads the replies to their own ticket, but never the
-- internal notes — that is the whole point of the flag.
drop policy if exists ticket_comments_select on public.ticket_comments;
create policy ticket_comments_select on public.ticket_comments for select
  using (app.can_read_module(org_id, 'ticketing')
         or (not is_internal and app.has_ticketing_module(org_id)
             and exists (select 1 from public.tickets t
                          where t.id = ticket_id and t.requester_user_id = auth.uid())));
drop policy if exists ticket_comments_write on public.ticket_comments;
create policy ticket_comments_write on public.ticket_comments for all
  using (app.can_write_module(org_id, 'ticketing'))
  with check (app.can_write_module(org_id, 'ticketing'));

-- History is written by the workflow functions, which are security
-- definer. Nobody edits it by hand.
drop policy if exists ticket_events_select on public.ticket_events;
create policy ticket_events_select on public.ticket_events for select
  using (app.can_read_module(org_id, 'ticketing'));

drop policy if exists canned_responses_select on public.canned_responses;
create policy canned_responses_select on public.canned_responses for select
  using (app.can_read_module(org_id, 'ticketing'));
drop policy if exists canned_responses_write on public.canned_responses;
create policy canned_responses_write on public.canned_responses for all
  using (app.can_write_module(org_id, 'ticketing'))
  with check (app.can_write_module(org_id, 'ticketing'));

grant select, insert, update, delete on public.ticket_teams        to authenticated;
grant select, insert, update, delete on public.ticket_team_members to authenticated;
grant select, insert, update, delete on public.sla_policies        to authenticated;
grant select, insert, update, delete on public.sla_targets         to authenticated;
grant select, insert, update, delete on public.ticket_categories   to authenticated;
grant select, insert, update, delete on public.tickets             to authenticated;
grant select, insert, update, delete on public.ticket_comments     to authenticated;
grant select                         on public.ticket_events       to authenticated;
grant select, insert, update, delete on public.canned_responses    to authenticated;

-- ---------------------------------------------------------------------
-- The module itself
-- ---------------------------------------------------------------------
insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order) values
  ('ticketing', 'Service Desk',
   'Tickets from email, web, chat and monitoring: routing by category, '
   'SLA deadlines over business hours and public holidays, escalation, '
   'and a history of every state a ticket passed through',
   false, 59, 18)
on conflict (code) do nothing;

comment on table public.tickets is
  'A request for help. One table for all four ITIL archetypes, because '
  'an incident that turns out to share a cause with four others becomes '
  'a problem''s child rather than a different kind of row.';

comment on table public.sla_targets is
  'Response and resolution promises in minutes per priority. Minutes '
  'rather than intervals because a business-hours policy does not count '
  'them against the wall clock.';
