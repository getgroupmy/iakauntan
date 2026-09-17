-- =====================================================================
-- The list you keep beside the books
--
-- Every bookkeeper here already keeps one, on paper or in their head:
-- chase the Ramli invoice, file the SST return, ask the client for the
-- April statements. None of it is a document, none of it posts, and so
-- none of it has ever been anywhere this system could show it. The work
-- that keeps a set of books straight is mostly work that has no row.
--
-- WHOSE LIST IT IS is the decision this migration makes, and it makes
-- the narrow one deliberately: a to-do belongs to ONE PERSON at ONE
-- COMPANY. Not shared, not assigned, not delegated. A shared list is a
-- different feature -- it needs an assignment, a notion of who may
-- assign to whom, and a rule for what happens to somebody's items when
-- they leave -- and building the narrow one first costs nothing that
-- the wider one would need to undo. `user_id` is therefore never
-- chosen: the policies below only ever let you write your own.
--
-- That is also why there is no trigger of the 0524 kind here. 0524
-- guards the columns where A PERSON CHOOSES somebody else; nobody
-- chooses anybody in this table, and row level security saying
-- `user_id = auth.uid()` is the whole guard. There is no path -- RPC or
-- straight through PostgREST -- by which a row can name anybody else.
--
-- A to-do may carry a `link`: the address inside this app of whatever
-- it is about, so "chase INV-2026-00031" can be one tap from the list
-- rather than a search. It is a route, not a foreign key, on purpose --
-- the thing a person wants to come back to is as often a screen as a
-- row, and a key would have to be to one table.
-- =====================================================================

create table if not exists public.todos (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,

  -- Whose it is. Written from auth.uid() and never chosen; see the
  -- header and the policies below.
  user_id uuid not null references auth.users(id) on delete cascade,

  -- Not merely NOT NULL: an empty string is not null and an item with
  -- no words on it is a row nobody can act on and nobody can find
  -- again. The form can be typed into by accident; this cannot.
  title text not null check (btrim(title) <> ''),
  notes text,
  due_date date,

  -- What rises to the top of the list. Three is as many as anybody
  -- actually sorts by; more and the field stops meaning anything.
  priority text not null default 'normal'
    check (priority in ('low', 'normal', 'high')),

  -- Done is a TIME, not a flag: "what did I clear yesterday" is a
  -- question somebody asks, and a boolean cannot answer it.
  done_at timestamptz,

  -- Where in the app this is about, if anywhere. A route such as
  -- '/sales/invoice/<id>'.
  link text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- The one read the screens make: my open items at this company, the
-- soonest first.
create index if not exists todos_mine_idx
  on public.todos (org_id, user_id, due_date nulls last, created_at)
  where done_at is null;

comment on table public.todos is
  'A personal to-do list, scoped to one company. One row belongs to one '
  'person: user_id is written from auth.uid() and can never name '
  'anybody else. See 0526.';

drop trigger if exists set_updated_at on public.todos;
create trigger set_updated_at
  before update on public.todos
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- Row level security
--
-- Yours, at a company you belong to. Both halves are on every policy,
-- including the WITH CHECK of the write ones: without the check on
-- insert, a member of two companies could file an item against a
-- company they are in, naming a user they are not -- and without
-- `user_id = auth.uid()` on select, a to-do is a private note anybody
-- at the company can read.
-- ---------------------------------------------------------------------
alter table public.todos enable row level security;

create policy todos_select on public.todos
  for select to authenticated
  using (app.is_org_member(org_id) and user_id = auth.uid());

create policy todos_insert on public.todos
  for insert to authenticated
  with check (app.is_org_member(org_id) and user_id = auth.uid());

create policy todos_update on public.todos
  for update to authenticated
  using (app.is_org_member(org_id) and user_id = auth.uid())
  with check (app.is_org_member(org_id) and user_id = auth.uid());

create policy todos_delete on public.todos
  for delete to authenticated
  using (app.is_org_member(org_id) and user_id = auth.uid());

-- Supabase hands `anon` every new table in `public`; 0165's event
-- trigger strips that from functions and not from tables. Taken away
-- before anything is granted. See 0497.
revoke all on public.todos from anon, authenticated, public;
grant select, insert, update, delete on public.todos to authenticated;
