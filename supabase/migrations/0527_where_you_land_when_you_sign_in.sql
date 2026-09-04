-- =====================================================================
-- Where you land when you sign in
--
-- Everybody has been landing on the dashboard because that is what the
-- router says, and the router says it once for everyone. A bookkeeper
-- who spends the day in the invoice list, a cashier who opens the till
-- and nothing else, and a director who wants the figures and nothing
-- else are all sent to the same screen and all navigate away from it
-- immediately.
--
-- So: the landing page is a PREFERENCE, and so is what is on it.
--
-- PER PERSON, NOT PER COMPANY. Somebody who keeps three companies'
-- books does the same job in all three, and asking them to set this
-- three times would be asking them to say the same thing repeatedly.
-- The row is keyed on the user alone.
--
-- THE ROUTE IS TEXT, NOT AN ENUM. The set of screens changes with every
-- release, and an enum would mean a migration each time somebody wanted
-- a new page on the list. What the database enforces is the SHAPE -- an
-- in-app path, one line, no scheme and no host -- and the client
-- falls back to the dashboard for any route this version does not
-- know. That fallback is the important half: a preference written by a
-- newer build, or pointing at a screen since withdrawn, must not leave
-- somebody staring at nothing after sign-in, which is a state they
-- cannot navigate out of if it is also where the app starts.
--
-- WHAT IT DOES NOT OVERRIDE is confinement. A device pinned to the till
-- goes to the till whatever its user prefers: that is a property of the
-- ADDRESS, chosen by whoever set the device up, and a preference is a
-- property of the person. The router keeps them in that order.
-- =====================================================================

create table if not exists public.user_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,

  -- An in-app route. Shape only: begins with a slash, no whitespace, no
  -- scheme, and short enough that it is a path rather than a payload.
  -- '//host/x' is excluded on purpose -- a protocol-relative URL is not
  -- an in-app route, and this column is read into a navigator.
  landing_route text not null default '/dashboard'
    check (landing_route ~ '^/[A-Za-z0-9/_-]{0,120}$'
           and landing_route !~ '^//'),

  -- Which panels this person wants on the dashboard, in the order they
  -- want them. Empty means the defaults: an empty array here is a
  -- person who has turned everything off, which is a thing somebody may
  -- legitimately do, so the DEFAULT carries the defaults rather than
  -- the client reading emptiness as "unset".
  dashboard_cards text[] not null
    default array['todos', 'ticker', 'metrics', 'trend', 'receivables'],

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.user_preferences is
  'Where a person lands when they sign in, and what they want on the '
  'dashboard. One row per user, not per company. The route is validated '
  'for SHAPE only; the client falls back to /dashboard for anything it '
  'does not recognise. See 0527.';

comment on column public.user_preferences.landing_route is
  'An in-app path such as /dashboard or /sales/invoice. Never a URL: '
  'the check refuses a scheme, whitespace and a protocol-relative '
  'prefix, because this is read straight into the navigator.';

drop trigger if exists set_updated_at on public.user_preferences;
create trigger set_updated_at
  before update on public.user_preferences
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- Row level security
--
-- Yours alone. There is no company in this table and no reason for one
-- person to read another's: where somebody chooses to start their day
-- is nobody else's business, and a policy scoped to the company would
-- make it everybody's.
-- ---------------------------------------------------------------------
alter table public.user_preferences enable row level security;

create policy user_preferences_select on public.user_preferences
  for select to authenticated using (user_id = auth.uid());

create policy user_preferences_insert on public.user_preferences
  for insert to authenticated with check (user_id = auth.uid());

create policy user_preferences_update on public.user_preferences
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- No delete policy. Clearing the preference is setting it back to the
-- default, which is an update; a row that can vanish is one the client
-- has to handle the absence of on every read, for no gain.

-- Supabase hands `anon` every new table in `public`. See 0497.
revoke all on public.user_preferences from anon, authenticated, public;
grant select, insert, update on public.user_preferences to authenticated;
