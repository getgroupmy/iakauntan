-- ---------------------------------------------------------------------
-- 0235  Who got in, and what they took out
-- ---------------------------------------------------------------------
--
-- `audit_logs` answers one question -- what changed -- for thirteen
-- tables. It cannot answer any of the others an auditor asks, because
-- none of them is a row changing:
--
--   * who signed in, from where, and on what;
--   * who took a copy of something out of the building;
--   * who was told no.
--
-- None of those writes to a table, so no trigger can see them. This
-- migration adds `security_events` for the three, alongside `audit_logs`
-- rather than instead of it. The split is the honest one: `audit_logs`
-- is what the data did, `security_events` is what the people did.
--
-- ## Sign-ins come from `auth.sessions`, not from the app
--
-- The obvious way is an RPC the client calls after signing in. It is
-- also the wrong way: a record of sign-ins that depends on the client
-- choosing to report one is a record of the sign-ins that were happy to
-- be recorded. GoTrue writes a row to `auth.sessions` on every
-- successful sign-in, with the IP and the user agent already on it, and
-- deletes it when the session ends. A trigger there cannot be skipped by
-- anything short of a different database.
--
-- `auth.audit_log_entries` would have been the natural source and is
-- not usable: it is empty on this project -- checked, not assumed --
-- so nothing can be built on it.
--
-- One row per company the person belongs to. A bookkeeper who keeps the
-- books of four companies signing in at midnight from an unfamiliar
-- address is a fact all four auditors are entitled to, and an event
-- filed under one of them is an event the other three cannot see.
--
-- ## Failed sign-ins are best-effort, and say so
--
-- There is no server-side record of a rejected password. GoTrue does not
-- write one to the database, and this project's `auth.audit_log_entries`
-- is empty, so the only thing that knows a sign-in failed is the browser
-- that was refused. `report_failed_sign_in` lets it say so.
--
-- That is worth having and worth being honest about: it catches a
-- colleague locked out of their own account and a password sprayer using
-- the app, and it does not catch somebody hitting the auth endpoint
-- directly, because nothing in this database can. The function is
-- therefore built to be safe rather than trusted -- it records nothing
-- for an address that is not a user, it stores no password or attempt,
-- it returns the same void either way so it cannot be used to find out
-- which addresses exist, and it writes at most one row a minute per
-- address so it cannot be used to bury a real event under noise.
--
-- ## Seven years
--
-- Section 245(5) of the Companies Act 2016 requires accounting records
-- to be kept for seven years from the end of the year they relate to,
-- and an audit trail of who changed those records is part of them.
-- Neither log had any retention at all before this: `audit_logs` has
-- grown without bound since 0055 and would have gone on doing so.

-- ---------------------------------------------------------------------
-- What kind of thing happened
-- ---------------------------------------------------------------------
do $do$
begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'security_event') then
    create type app.security_event as enum (
      'sign_in',       -- a session began
      'session_ended', -- and ended: signed out, expired, or revoked
      'export',         -- a copy of something left the building
      'sensitive_read', -- somebody looked at something worth noticing
      'denied');        -- somebody was told no
  end if;
end
$do$;

create table if not exists public.security_events (
  id          bigserial primary key,
  org_id      uuid references public.organizations (id) on delete cascade,
  user_id     uuid references auth.users (id) on delete set null,

  -- Kept beside `user_id` on purpose. The foreign key nulls on delete,
  -- and a security log that forgets who did something the moment their
  -- account is removed is a log that cannot be read after the one event
  -- most worth reading about.
  email       text,

  kind        app.security_event not null,

  -- What was reached for -- a function name, a report, a payroll run --
  -- and anything worth saying about it. Never a payload: this table is
  -- readable by every admin of the company and must not become a second
  -- copy of the salaries.
  target      text,
  detail      text,

  outcome     text not null default 'ok'
              check (outcome in ('ok', 'refused')),

  ip_address  inet,
  user_agent  text,
  session_id  uuid,
  created_at  timestamptz not null default now()
);

create index if not exists security_events_org_idx
  on public.security_events (org_id, created_at desc);
create index if not exists security_events_kind_idx
  on public.security_events (org_id, kind, created_at desc);
create index if not exists security_events_user_idx
  on public.security_events (user_id, created_at desc);

alter table public.security_events enable row level security;

-- Read-only, and only for the people who run the company. The rows
-- carry IP addresses and the shape of everybody's working day, which is
-- exactly the material this log exists to protect. There is deliberately
-- no insert, update or delete policy: everything that writes here is
-- SECURITY DEFINER, so nobody edits their own trail afterwards.
drop policy if exists security_events_select on public.security_events;
create policy security_events_select on public.security_events
  for select using (
    app.can_admin(org_id)
    or (org_id is null and app.is_platform_admin()));

grant select on public.security_events to authenticated;

-- ---------------------------------------------------------------------
-- The one writer
-- ---------------------------------------------------------------------
create or replace function app.record_security_event(
  p_org_id     uuid,
  p_user_id    uuid,
  p_kind       app.security_event,
  p_target     text default null,
  p_detail     text default null,
  p_outcome    text default 'ok',
  p_ip         inet default null,
  p_user_agent text default null,
  p_session    uuid default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  insert into public.security_events
    (org_id, user_id, email, kind, target, detail, outcome,
     ip_address, user_agent, session_id)
  values (
    p_org_id,
    p_user_id,
    (select u.email from auth.users u where u.id = p_user_id),
    p_kind,
    p_target,
    p_detail,
    p_outcome,
    coalesce(p_ip, nullif(split_part(
      coalesce(app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet),
    coalesce(p_user_agent, app.request_header('user-agent')),
    p_session);
end;
$$;

revoke all on function app.record_security_event(
  uuid, uuid, app.security_event, text, text, text, inet, text, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Sign in, and sign out
-- ---------------------------------------------------------------------
create or replace function app.record_sign_in()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  insert into public.security_events
    (org_id, user_id, email, kind, ip_address, user_agent, session_id)
  select m.org_id, NEW.user_id, u.email, 'sign_in',
         NEW.ip, NEW.user_agent, NEW.id
    from public.org_members m
    join auth.users u on u.id = NEW.user_id
   where m.user_id = NEW.user_id;

  -- Somebody who belongs to no company yet: a sign-up that has not
  -- created one, or platform staff. Filed under no organization, where
  -- only platform staff can read it -- rather than dropped, because
  -- "nobody was watching this account" is the interesting case.
  if not found then
    insert into public.security_events
      (org_id, user_id, email, kind, ip_address, user_agent, session_id)
    select null, NEW.user_id, u.email, 'sign_in',
           NEW.ip, NEW.user_agent, NEW.id
      from auth.users u where u.id = NEW.user_id;
  end if;

  return null;
end;
$$;

-- A session row is deleted when somebody signs out and also when one
-- expires or is revoked. The name says what is actually known.
create or replace function app.record_session_end()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  insert into public.security_events
    (org_id, user_id, email, kind, ip_address, user_agent, session_id)
  select m.org_id, OLD.user_id, u.email, 'session_ended',
         OLD.ip, OLD.user_agent, OLD.id
    from public.org_members m
    join auth.users u on u.id = OLD.user_id
   where m.user_id = OLD.user_id;
  return null;
end;
$$;

-- GoTrue connects as `supabase_auth_admin`, and it is that role whose
-- insert fires these. The functions are SECURITY DEFINER and run as
-- their owner regardless, but the role still has to be allowed to reach
-- them -- and guarded, because a stack that has not got the role yet
-- must not fail the migration.
do $do$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant usage on schema app to supabase_auth_admin;
    grant execute on function app.record_sign_in() to supabase_auth_admin;
    grant execute on function app.record_session_end() to supabase_auth_admin;
  end if;
end
$do$;

drop trigger if exists record_sign_in on auth.sessions;
create trigger record_sign_in after insert on auth.sessions
  for each row execute function app.record_sign_in();

drop trigger if exists record_session_end on auth.sessions;
create trigger record_session_end after delete on auth.sessions
  for each row execute function app.record_session_end();

-- ---------------------------------------------------------------------
-- A sign-in that was refused, as reported by the browser it refused
-- ---------------------------------------------------------------------
create or replace function public.report_failed_sign_in(p_email text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_user  uuid;
  v_last  timestamptz;
begin
  -- Nothing is returned in any branch, including this one. A function
  -- that behaved differently for an address that exists would be a way
  -- to find out which addresses exist.
  select u.id into v_user from auth.users u
   where lower(u.email) = lower(trim(coalesce(p_email, '')));
  if v_user is null then return; end if;

  -- At most one a minute for the same account, so a stranger cannot
  -- push the events that matter off the end of the auditor's screen.
  select max(e.created_at) into v_last
    from public.security_events e
   where e.user_id = v_user
     and e.kind = 'sign_in'
     and e.outcome = 'refused';
  if v_last is not null and v_last > now() - interval '1 minute' then
    return;
  end if;

  insert into public.security_events
    (org_id, user_id, email, kind, outcome, detail, ip_address, user_agent)
  select m.org_id, v_user, lower(trim(p_email)), 'sign_in', 'refused',
         'password rejected (reported by the browser)',
         nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,
         app.request_header('user-agent')
    from public.org_members m
   where m.user_id = v_user;
end;
$$;

-- Callable before anybody has signed in, which is the only moment it is
-- ever useful.
grant execute on function public.report_failed_sign_in(text)
  to anon, authenticated;

-- ---------------------------------------------------------------------
-- A copy of something leaving the building
-- ---------------------------------------------------------------------
create or replace function public.record_export(
  p_org_id uuid,
  p_what   text,
  p_detail text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if p_org_id is null or not app.is_org_member(p_org_id) then
    raise exception 'Not a member of this organization'
      using errcode = '42501';
  end if;

  perform app.record_security_event(
    p_org_id, auth.uid(), 'export', p_what, p_detail);
end;
$$;

grant execute on function public.record_export(uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Somebody looked at something worth noticing
-- ---------------------------------------------------------------------
--
-- A successful read, which is the half of "who did what" that a change
-- log cannot show. An account somebody else is using does not usually
-- start by changing things; it starts by reading them.
create or replace function app.note_read(p_org_id uuid, p_what text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  perform app.record_security_event(
    p_org_id, auth.uid(), 'sensitive_read', p_what);
end;
$$;

revoke all on function app.note_read(uuid, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Told no
-- ---------------------------------------------------------------------
--
-- This one is reported by the client, and that is not laziness. The
-- obvious design -- a function that writes the refusal and then raises
-- it -- cannot work in Postgres, and the production probe for this
-- migration is what showed it rather than an argument:
--
--     perform app.record_security_event(..., 'denied', ...);
--     raise exception '...' using errcode = '42501';
--
-- The raise unwinds the transaction the insert was made in, so the row
-- goes with it. Measured: a clerk was correctly refused, the exception
-- carried the right message, and `select count(*) ... where kind =
-- 'denied'` returned **0**. There is no arrangement of that function
-- that survives, because Postgres has no autonomous transactions --
-- only an out-of-band connection would do it, and that means a database
-- password stored in the database, which this project does not do.
--
-- So the refusal is recorded by the request that follows it. The app
-- catches a 42501 and calls this; the row says so in as many words. Be
-- clear about what that is worth: it catches a colleague reaching for a
-- screen they should not have, and an account somebody else is using
-- through the app. It does not catch a script that talks to the API
-- directly and simply declines to report itself -- nothing in this
-- database can, and a log that implied otherwise would be worse than
-- one that admits it.
--
-- What *is* recorded server-side and cannot be skipped: every sign-in
-- and session end, every sensitive read, and every export -- because
-- each of those happens in a transaction that goes on to commit.
create or replace function public.report_denied(
  p_org_id uuid,
  p_action text,
  p_message text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_last timestamptz;
begin
  -- Only for a company this person is actually in. A refusal that hit
  -- somebody with no business here is not that company's event to hold,
  -- and taking their word for the org_id would let anybody write into
  -- anybody's log.
  if p_org_id is null or not app.is_org_member(p_org_id) then
    return;
  end if;

  -- One a minute per person, so a loop cannot bury the rest of the log.
  select max(e.created_at) into v_last
    from public.security_events e
   where e.org_id = p_org_id
     and e.user_id = auth.uid()
     and e.kind = 'denied';
  if v_last is not null and v_last > now() - interval '1 minute' then
    return;
  end if;

  perform app.record_security_event(
    p_org_id, auth.uid(), 'denied', p_action,
    coalesce(p_message, 'refused') || ' (reported by the app)',
    'refused');
end;
$$;

grant execute on function public.report_denied(uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Reading it
-- ---------------------------------------------------------------------
create or replace function public.security_log(
  p_org_id uuid,
  p_kind   app.security_event default null,
  p_since  timestamptz default null,
  p_limit  integer default 200)
returns table (
  id         bigint,
  at         timestamptz,
  actor      text,
  kind       text,
  outcome    text,
  target     text,
  detail     text,
  ip_address text,
  user_agent text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  -- The same bar as the audit trail, and for the same reason: this log
  -- says where everybody in the company was working from.
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may read the security log'
      using errcode = '42501';
  end if;

  -- Reading the log is itself an event. Deliberately not `stable`: a
  -- security log that does not record who read it is the one record an
  -- insider has no reason to avoid.
  perform app.note_read(p_org_id, 'security_log');

  return query
  select e.id,
         e.created_at,
         coalesce(p.full_name, p.email, e.email, 'unknown'),
         e.kind::text,
         e.outcome,
         e.target,
         e.detail,
         host(e.ip_address),
         e.user_agent
    from public.security_events e
    left join public.profiles p on p.id = e.user_id
   where e.org_id = p_org_id
     and (p_kind is null or e.kind = p_kind)
     and (p_since is null or e.created_at >= p_since)
   order by e.id desc
   limit least(coalesce(p_limit, 200), 1000);
end;
$$;

grant execute on function public.security_log(
  uuid, app.security_event, timestamptz, integer) to authenticated;

-- A shape for the top of the screen, so an auditor opening it is told
-- what to look at rather than handed a thousand rows in date order.
create or replace function public.security_summary(
  p_org_id uuid,
  p_days   integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_from timestamptz;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may read the security log'
      using errcode = '42501';
  end if;

  v_from := now() - make_interval(days => greatest(coalesce(p_days, 30), 1));

  return (
    select jsonb_build_object(
      'days',            greatest(coalesce(p_days, 30), 1),
      'sign_ins',        count(*) filter (
                           where kind = 'sign_in' and outcome = 'ok'),
      'failed_sign_ins', count(*) filter (
                           where kind = 'sign_in' and outcome = 'refused'),
      'people',          count(distinct user_id) filter (
                           where kind = 'sign_in' and outcome = 'ok'),
      'addresses',       count(distinct ip_address) filter (
                           where kind = 'sign_in' and outcome = 'ok'),
      'exports',         count(*) filter (where kind = 'export'),
      'reads',           count(*) filter (where kind = 'sensitive_read'),
      'denials',         count(*) filter (where kind = 'denied'),
      'changes',         (select count(*) from public.audit_logs l
                           where l.org_id = p_org_id and l.created_at >= v_from))
      from public.security_events
     where org_id = p_org_id and created_at >= v_from);
end;
$$;

grant execute on function public.security_summary(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------
-- The change log records who read it, too
-- ---------------------------------------------------------------------
--
-- Restated from 0055 with one line added and `stable` dropped. Same
-- guard, same query, same ordering: this is the only place in the system
-- where salary history, bank account numbers and everybody's access
-- changes can be read in one go, so a company is entitled to know who
-- did.
create or replace function public.audit_trail(
  p_org_id uuid, p_table text default null, p_record_id uuid default null,
  p_limit integer default 100)
returns table (
  id bigint, at timestamptz, actor text, action text,
  table_name text, record_id uuid, changes jsonb)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may read the audit trail'
      using errcode = '42501';
  end if;

  perform app.note_read(p_org_id, 'audit_trail');

  return query
  select l.id, l.created_at,
         coalesce(p.full_name, p.email, 'system'),
         l.action, l.table_name, l.record_id,
         jsonb_build_object('from', l.old_data, 'to', l.new_data)
    from public.audit_logs l
    left join public.profiles p on p.id = l.user_id
   where l.org_id = p_org_id
     and (p_table is null or l.table_name = p_table)
     and (p_record_id is null or l.record_id = p_record_id)
   order by l.id desc
   limit least(coalesce(p_limit, 100), 500);
end;
$$;

grant execute on function public.audit_trail(uuid, text, uuid, integer)
  to authenticated;

-- ---------------------------------------------------------------------
-- Seven years, and then gone
-- ---------------------------------------------------------------------
create or replace function app.purge_audit_history(
  p_years integer default 7)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_cutoff timestamptz := now() - make_interval(years => greatest(p_years, 1));
  v_gone   integer := 0;
  v_n      integer;
begin
  delete from public.security_events where created_at < v_cutoff;
  get diagnostics v_n = row_count;
  v_gone := v_gone + v_n;

  delete from public.audit_logs where created_at < v_cutoff;
  get diagnostics v_n = row_count;
  v_gone := v_gone + v_n;

  return v_gone;
end;
$$;

revoke all on function app.purge_audit_history(integer)
  from public, anon, authenticated;

-- Its own job rather than a line in `run_daily_jobs`, because a purge
-- that fails must not be able to take the recurring invoices with it,
-- and one that runs a day late costs nothing.
do $do$
begin
  if exists (select 1 from cron.job where jobname = 'iakauntan-purge-audit') then
    perform cron.unschedule('iakauntan-purge-audit');
  end if;
  perform cron.schedule(
    'iakauntan-purge-audit',
    '30 19 * * 0',
    $job$select app.purge_audit_history(7)$job$);
end
$do$;
