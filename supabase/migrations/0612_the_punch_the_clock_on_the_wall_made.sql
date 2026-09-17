-- =====================================================================
-- iAkauntan :: 0612 the punch the clock on the wall made
--
-- README: "Biometric terminal integration: attendance records carry a
-- terminal identifier, but nothing pushes punches in from a device
-- yet."
--
-- Both halves are true. `attendance_records.clock_in_terminal` and
-- `clock_out_terminal` have been there since `0027`, `app.clock_method`
-- has had `biometric` since then, and `clock_in` and `clock_out` both
-- take a `p_terminal` -- so a punch from a device is a first-class
-- thing this schema already understands. What has never existed is a
-- way for the device to send one.
--
-- ---------------------------------------------------------------------
-- Why `clock_in` cannot be the answer
--
-- Three reasons, and the third is the one that matters:
--
--   1. It authenticates a SESSION. `app.my_employee_id(org)` reads
--      `auth.uid()`, and a clock on a wall has no login.
--   2. It resolves an employee by UUID. A terminal knows "enrolment
--      0042" -- the number somebody's fingerprint was registered
--      against -- and nothing else.
--   3. **It stamps `now()`.** A terminal that lost its network at
--      08:55 and reconnected at 17:30 sends the morning's punches when
--      it reconnects, and `now()` files every one of them at half past
--      five. The punch carries its own time or the whole exercise is
--      theatre.
--
-- ---------------------------------------------------------------------
-- The enrolment number is per terminal
--
-- Two terminals number their users independently -- the device at the
-- front door and the one in the warehouse both have a user 1, and they
-- are not the same person. A single `employees.biometric_id` column
-- would be the obvious shape and would silently file the warehouse's
-- attendance against the receptionist.
--
-- So `terminal_enrolments` is keyed on the terminal.
--
-- ---------------------------------------------------------------------
-- Every punch is kept, raw
--
-- `terminal_punches` holds what the device said, before anybody decided
-- what it meant. Same argument as `import_rows` in `0610`: when
-- somebody disputes their hours a year later, what settles it is what
-- the clock recorded, not what this schema concluded from it.
--
-- It is also the idempotency. A terminal that reconnects re-sends
-- everything it has, so `(terminal_id, enrolment_no, punched_at)` is
-- unique and a replay writes nothing.
--
-- ---------------------------------------------------------------------
-- In or out, where the device does not say
--
-- Many terminals send a bare timestamp. The rule is the one a person
-- would apply: if the day has no clock-in yet, this is one; otherwise
-- it is a clock-out. That is wrong for somebody who punches four times
-- because they went out for lunch, and it is wrong in the direction
-- that leaves the LAST punch as the clock-out -- which is the answer
-- that matches what the payroll engine already does with a single pair.
--
-- A device that does say is believed.
--
-- ---------------------------------------------------------------------
-- Out of order
--
-- A replay arrives in whatever order the device kept it in, so the
-- earliest in and the latest out win -- `least` and `greatest` rather
-- than "first write wins", which is what `clock_in` does and is right
-- for a person pressing a button in real time.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Something to hold a same-company key against
--
-- `tenant_foreign_keys.sql` requires every single-column key between
-- two tables that both have an `org_id` to be backed by a composite
-- one, and it is right to: without it, one company's punch could name
-- another company's attendance record. `attendance_records` has no
-- `(org_id, id)` key to point at, so it gets one.
-- ---------------------------------------------------------------------
alter table public.attendance_records
  add constraint attendance_records_org_id_id_key unique (org_id, id);

-- ---------------------------------------------------------------------
-- The device
--
-- The secret is hashed, never stored. A terminal proves itself by
-- sending it; nothing ever needs to read it back, so keeping it in a
-- form that could be read back is a liability with no purpose.
-- ---------------------------------------------------------------------
create table public.time_terminals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,

  -- What a person calls it. "Front door", "Warehouse gate".
  name text not null,

  -- Where it is, for a company with more than one.
  branch_id uuid references public.branches (id) on delete set null,
  constraint time_terminals_branch_same_org
    foreign key (org_id, branch_id)
    references public.branches (org_id, id),

  -- What the device says it is, if it says anything. A serial number,
  -- a MAC address. Recorded rather than trusted: the secret is what
  -- authenticates.
  device_ref text,

  -- bcrypt, through pgcrypto. Never the secret itself.
  secret_hash text not null,

  is_active boolean not null default true,

  last_seen_at timestamptz,
  last_punch_at timestamptz,

  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (org_id, name),

  -- So a row that names a terminal can say which company's. Same
  -- reason `tenant_foreign_keys.sql` gives everywhere else.
  unique (org_id, id)
);

comment on table public.time_terminals is
  'A clock on a wall. It has no login, so it proves itself with a '
  'secret this table holds the hash of. 0612.';

create index time_terminals_org_idx on public.time_terminals (org_id, name);

create trigger set_updated_at before update on public.time_terminals
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- Who the device thinks its users are
--
-- Per terminal, because the front door's user 1 and the warehouse's
-- user 1 are two different people. See the header.
-- ---------------------------------------------------------------------
create table public.terminal_enrolments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  terminal_id uuid not null
    references public.time_terminals (id) on delete cascade,
  constraint terminal_enrolments_terminal_same_org
    foreign key (org_id, terminal_id)
    references public.time_terminals (org_id, id) on delete cascade,

  employee_id uuid not null
    references public.employees (id) on delete cascade,
  constraint terminal_enrolments_employee_same_org
    foreign key (org_id, employee_id)
    references public.employees (org_id, id) on delete cascade,

  -- The number the device registered the fingerprint against. Text
  -- rather than integer: devices pad, and "0042" and "42" arriving from
  -- the same terminal are the same person.
  enrolment_no text not null
    check (btrim(enrolment_no) <> ''),

  created_at timestamptz not null default now(),

  -- One person per number on a terminal, and one number per person on
  -- a terminal. Both directions: a number pointing at two people files
  -- one person's hours against the other, and a person with two numbers
  -- on one device gets two half-days.
  unique (terminal_id, enrolment_no),
  unique (terminal_id, employee_id)
);

comment on table public.terminal_enrolments is
  'Which employee a terminal''s user number is. Per terminal, because '
  'two devices number their users independently and the front door''s '
  'user 1 is not the warehouse''s. 0612.';

create index terminal_enrolments_employee_idx
  on public.terminal_enrolments (employee_id);

-- ---------------------------------------------------------------------
-- What the device said
--
-- Raw, and kept. When somebody disputes their hours a year later, what
-- settles it is what the clock recorded, not what this schema concluded
-- from it.
-- ---------------------------------------------------------------------
create table public.terminal_punches (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  terminal_id uuid not null
    references public.time_terminals (id) on delete cascade,
  constraint terminal_punches_terminal_same_org
    foreign key (org_id, terminal_id)
    references public.time_terminals (org_id, id) on delete cascade,

  -- The device's own number, not ours. Kept even where it matches
  -- nobody: a punch from an unenrolled finger is a thing that happened
  -- and somebody has to be able to see it.
  enrolment_no text not null,

  -- WHEN THE DEVICE SAYS IT HAPPENED. Not when it arrived. A terminal
  -- that lost its network at 08:55 and reconnected at 17:30 sends the
  -- morning's punches when it reconnects.
  punched_at timestamptz not null,

  -- 'in', 'out', or null where the device does not say -- which many
  -- do not.
  direction text check (direction in ('in', 'out')),

  -- Where it landed, once it landed.
  employee_id uuid references public.employees (id) on delete set null,
  constraint terminal_punches_employee_same_org
    foreign key (org_id, employee_id)
    references public.employees (org_id, id),
  attendance_id uuid references public.attendance_records (id) on delete set null,
  constraint terminal_punches_attendance_same_org
    foreign key (org_id, attendance_id)
    references public.attendance_records (org_id, id),

  -- Why it did not, where it did not.
  problem text,

  received_at timestamptz not null default now(),

  -- A terminal that reconnects re-sends everything it has. The same
  -- finger on the same device at the same instant is one punch.
  unique (terminal_id, enrolment_no, punched_at)
);

comment on table public.terminal_punches is
  'Every punch a terminal reported, as it reported it. The unique key '
  'is what makes a reconnecting device''s replay a no-op. 0612.';

create index terminal_punches_org_idx
  on public.terminal_punches (org_id, punched_at desc);
create index terminal_punches_unmatched_idx
  on public.terminal_punches (org_id, punched_at desc)
  where employee_id is null;

-- ---------------------------------------------------------------------
-- Reading and writing them
--
-- HR's, all three. Attendance decides what people are paid.
-- ---------------------------------------------------------------------
alter table public.time_terminals enable row level security;
alter table public.terminal_enrolments enable row level security;
alter table public.terminal_punches enable row level security;

create policy time_terminals_select on public.time_terminals
  for select to authenticated using (app.can_manage_hr(org_id));
create policy time_terminals_write on public.time_terminals
  for all to authenticated
  using (app.can_manage_hr(org_id)) with check (app.can_manage_hr(org_id));

create policy terminal_enrolments_select on public.terminal_enrolments
  for select to authenticated using (app.can_manage_hr(org_id));
create policy terminal_enrolments_write on public.terminal_enrolments
  for all to authenticated
  using (app.can_manage_hr(org_id)) with check (app.can_manage_hr(org_id));

-- Punches are read by HR and by the person they are about: somebody
-- querying their own attendance is entitled to see the punches behind
-- it, which is the same rule `payslips` uses.
create policy terminal_punches_select on public.terminal_punches
  for select to authenticated
  using (app.can_manage_hr(org_id)
         or employee_id = app.my_employee_id(org_id));

grant select, insert, update, delete
  on public.time_terminals, public.terminal_enrolments to authenticated;
grant select on public.terminal_punches to authenticated;

-- ---------------------------------------------------------------------
-- Registering one
--
-- Returns the secret ONCE. It is hashed on the way in and there is no
-- way to read it back, which is the point: a secret a support call can
-- recover is a secret anybody who can impersonate a support call can
-- recover.
-- ---------------------------------------------------------------------
create or replace function public.register_time_terminal(
  p_org_id uuid,
  p_name text,
  p_branch_id uuid default null,
  p_device_ref text default null)
returns table (terminal_id uuid, secret text)
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'extensions', 'pg_temp'
as $function$
declare
  v_secret text;
  v_id uuid;
begin
  if not app.can_manage_hr(p_org_id) then
    raise exception 'Attendance decides what people are paid, and a '
                    'terminal is HR''s to add'
      using errcode = '42501';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'A terminal needs a name — "Front door", "Warehouse '
                    'gate"'
      using errcode = '23514';
  end if;

  -- 32 bytes of randomness, hex. Long enough that guessing is not a
  -- strategy and short enough to type into a device's web form, which
  -- is how most of these are configured.
  v_secret := encode(gen_random_bytes(32), 'hex');

  insert into public.time_terminals
    (org_id, name, branch_id, device_ref, secret_hash, created_by)
  values (p_org_id, btrim(p_name), p_branch_id,
          nullif(btrim(p_device_ref), ''),
          crypt(v_secret, gen_salt('bf')), auth.uid())
  returning id into v_id;

  terminal_id := v_id;
  secret := v_secret;
  return next;
end;
$function$;

comment on function public.register_time_terminal(uuid, text, uuid, text) is
  'Adds a clock and returns its secret, once. The secret is stored '
  'hashed and cannot be read back — losing it means issuing a new one. '
  '0612.';

revoke all on function public.register_time_terminal(uuid, text, uuid, text)
  from public, anon;
grant execute on function public.register_time_terminal(uuid, text, uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Issuing a new one
--
-- A device that was replaced, a secret that reached somebody it should
-- not have. The old one stops working the moment this returns.
-- ---------------------------------------------------------------------
create or replace function public.reissue_terminal_secret(p_terminal_id uuid)
returns text
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'extensions', 'pg_temp'
as $function$
declare
  v_org uuid;
  v_secret text;
begin
  select org_id into v_org from public.time_terminals where id = p_terminal_id;
  if v_org is null then
    raise exception 'No such terminal' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_org) then
    raise exception 'Attendance decides what people are paid, and a '
                    'terminal is HR''s to change'
      using errcode = '42501';
  end if;

  v_secret := encode(gen_random_bytes(32), 'hex');
  update public.time_terminals
     set secret_hash = crypt(v_secret, gen_salt('bf'))
   where id = p_terminal_id;
  return v_secret;
end;
$function$;

comment on function public.reissue_terminal_secret(uuid) is
  'Replaces a terminal''s secret and returns the new one, once. The '
  'old one stops working immediately. 0612.';

revoke all on function public.reissue_terminal_secret(uuid) from public, anon;
grant execute on function public.reissue_terminal_secret(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Taking a punch
--
-- Service role only. The caller is the edge function, which has already
-- checked the terminal's secret; this one is deliberately not reachable
-- from a session, because a client that could call it could file
-- attendance for anybody.
--
-- Returns what happened rather than raising, because the caller is a
-- device replaying a batch: one unenrolled finger in a hundred punches
-- must not stop the other ninety-nine.
-- ---------------------------------------------------------------------
create or replace function app.record_terminal_punch(
  p_terminal_id uuid,
  p_enrolment_no text,
  p_punched_at timestamptz,
  p_direction text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_term  public.time_terminals;
  v_emp   uuid;
  v_no    text;
  v_date  date;
  v_dir   text;
  v_rec   public.attendance_records;
  v_shift public.work_shifts;
  v_late  integer := 0;
  v_punch uuid;
  v_att   uuid;
  v_prob  text;
begin
  select * into v_term from public.time_terminals where id = p_terminal_id;
  if v_term.id is null then
    return jsonb_build_object('ok', false, 'problem', 'No such terminal');
  end if;
  if not v_term.is_active then
    return jsonb_build_object('ok', false, 'problem', 'Terminal is switched off');
  end if;
  if p_punched_at is null then
    return jsonb_build_object('ok', false, 'problem', 'A punch needs a time');
  end if;

  -- Devices pad. "0042" and "42" from the same terminal are the same
  -- person, and treating them as two is how somebody gets two half
  -- days.
  v_no := btrim(coalesce(p_enrolment_no, ''));
  if v_no = '' then
    return jsonb_build_object('ok', false, 'problem', 'A punch needs a user number');
  end if;

  select e.employee_id into v_emp
    from public.terminal_enrolments e
   where e.terminal_id = p_terminal_id
     and ltrim(e.enrolment_no, '0') = ltrim(v_no, '0');

  if v_emp is null then
    v_prob := format('No employee is enrolled as %s on this terminal', v_no);
  end if;

  -- The punch is recorded whether or not it matched. A finger nobody
  -- enrolled is a thing that happened, and the person it belongs to
  -- will be asking about it.
  insert into public.terminal_punches
    (org_id, terminal_id, enrolment_no, punched_at, direction,
     employee_id, problem)
  values (v_term.org_id, p_terminal_id, v_no, p_punched_at,
          nullif(p_direction, ''), v_emp, v_prob)
  on conflict (terminal_id, enrolment_no, punched_at) do nothing
  returning id into v_punch;

  update public.time_terminals
     set last_seen_at = now(),
         last_punch_at = greatest(coalesce(last_punch_at, p_punched_at),
                                  p_punched_at)
   where id = p_terminal_id;

  -- A replay. The device sent this one before and it was dealt with
  -- then; saying so is not an error.
  if v_punch is null then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  if v_emp is null then
    return jsonb_build_object('ok', false, 'problem', v_prob);
  end if;

  v_date := (p_punched_at at time zone 'Asia/Kuala_Lumpur')::date;

  select * into v_rec from public.attendance_records
   where employee_id = v_emp and work_date = v_date;

  -- The device's word where it gives one. Where it does not: no
  -- clock-in yet means this is one, and anything after that is a
  -- clock-out -- which leaves the LAST punch of the day as the
  -- clock-out, matching what the payroll engine does with a pair.
  v_dir := nullif(p_direction, '');
  if v_dir is null then
    v_dir := case when v_rec.id is null or v_rec.clock_in is null
                  then 'in' else 'out' end;
  end if;

  if v_dir = 'in' then
    v_shift := app.shift_for(v_emp, v_date);
    if v_shift.id is not null then
      v_late := greatest(0, (extract(epoch from (
          (p_punched_at at time zone 'Asia/Kuala_Lumpur')::time
            - v_shift.start_time
        )) / 60)::integer - coalesce(v_shift.grace_minutes, 0));
    end if;

    insert into public.attendance_records as a (
      org_id, employee_id, work_date, shift_id, clock_in, clock_in_method,
      clock_in_terminal, status, late_minutes)
    values (
      v_term.org_id, v_emp, v_date, v_shift.id, p_punched_at, 'biometric',
      v_term.name,
      case when v_late > 0 then 'late'::app.attendance_status
           else 'present'::app.attendance_status end,
      v_late)
    -- `least`, not "first write wins". A device replaying a batch
    -- sends the punches in whatever order it kept them, so the
    -- EARLIEST clock-in has to win however late it arrives.
    on conflict (employee_id, work_date) do update
      set clock_in = least(coalesce(a.clock_in, excluded.clock_in),
                           excluded.clock_in),
          clock_in_method = case
            when excluded.clock_in < coalesce(a.clock_in, excluded.clock_in)
            then excluded.clock_in_method else a.clock_in_method end,
          clock_in_terminal = case
            when excluded.clock_in < coalesce(a.clock_in, excluded.clock_in)
            then excluded.clock_in_terminal else a.clock_in_terminal end,
          late_minutes = case
            when excluded.clock_in < coalesce(a.clock_in, excluded.clock_in)
            then excluded.late_minutes else a.late_minutes end
    returning id into v_att;
  else
    if v_rec.id is null then
      -- A clock-out with no clock-in. It happens: somebody's morning
      -- punch was on a terminal that has not uploaded yet. The record
      -- is opened with the out on it and the in filled in when the
      -- other device catches up, which `least` above will do.
      v_shift := app.shift_for(v_emp, v_date);
      insert into public.attendance_records
        (org_id, employee_id, work_date, shift_id, clock_out,
         clock_out_method, clock_out_terminal, status)
      values (v_term.org_id, v_emp, v_date, v_shift.id,
              p_punched_at, 'biometric', v_term.name, 'present')
      returning id into v_att;
    else
      -- `greatest`: the LATEST punch of the day is the clock-out, and a
      -- replay must not move it backwards.
      update public.attendance_records
         set clock_out = greatest(coalesce(clock_out, p_punched_at),
                                  p_punched_at),
             clock_out_method = 'biometric',
             clock_out_terminal = v_term.name
       where id = v_rec.id
      returning id into v_att;
    end if;
    perform app.recompute_attendance(v_att);
  end if;

  update public.terminal_punches
     set attendance_id = v_att, direction = v_dir
   where id = v_punch;

  return jsonb_build_object(
    'ok', true, 'direction', v_dir, 'attendance_id', v_att);
end;
$function$;

comment on function app.record_terminal_punch(uuid, text, timestamptz, text) is
  'Files one punch a terminal reported, at the time the DEVICE says it '
  'happened rather than now(). Service role only: a client that could '
  'call it could file attendance for anybody. Returns what happened '
  'instead of raising, because one unenrolled finger in a batch of a '
  'hundred must not stop the other ninety-nine. 0612.';

revoke all on function app.record_terminal_punch(uuid, text, timestamptz, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- On the live feed
--
-- `live_change_feed.sql` asks for a trigger on every table with an
-- `org_id`. These three earn it: a terminal being set up is watched by
-- whoever is standing at it, and punches arriving is the one thing an
-- HR screen is genuinely live about -- somebody testing a new clock
-- presses their finger to it and looks at a laptop.
-- ---------------------------------------------------------------------
do $do$
declare t text;
begin
  foreach t in array array['time_terminals', 'terminal_enrolments',
                           'terminal_punches'] loop
    execute format($f$
      create trigger live_change_insert after insert on public.%I
        referencing new table as new_rows
        for each statement execute function app.note_live_change()
    $f$, t);
    execute format($f$
      create trigger live_change_update after update on public.%I
        referencing old table as old_rows new table as new_rows
        for each statement execute function app.note_live_change()
    $f$, t);
    execute format($f$
      create trigger live_change_delete after delete on public.%I
        referencing old table as old_rows
        for each statement execute function app.note_live_change()
    $f$, t);
  end loop;
end $do$;

-- ---------------------------------------------------------------------
-- What the edge function can reach
--
-- PostgREST only exposes `public`, so `app.record_terminal_punch` above
-- is unreachable from an HTTP call however privileged the caller. These
-- two are its front door, and both are service-role only: EXECUTE is
-- revoked from `authenticated` as well as from `anon`, because a client
-- that could call either could file attendance for anybody or test
-- secrets against a terminal at its leisure.
-- ---------------------------------------------------------------------
create or replace function public.terminal_secret_matches(
  p_terminal_id uuid,
  p_secret text)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'extensions', 'pg_temp'
as $function$
  -- `crypt(offered, hash) = hash` is bcrypt's own comparison, and it
  -- is constant time in the only sense that matters here: the work
  -- factor dominates and it does not short-circuit on a prefix.
  --
  -- `coalesce(..., false)`: a terminal id that matches nothing returns
  -- no row, and `if not null` would let it through.
  select coalesce(
    (select t.secret_hash = extensions.crypt(p_secret, t.secret_hash)
       from public.time_terminals t
      where t.id = p_terminal_id
        and t.is_active
        and coalesce(t.secret_hash, '') <> ''
        and coalesce(p_secret, '') <> ''),
    false);
$function$;

comment on function public.terminal_secret_matches(uuid, text) is
  'Whether a terminal offered the right secret. Service role only: a '
  'client that could call it could test secrets at its leisure. 0612.';

revoke all on function public.terminal_secret_matches(uuid, text)
  from public, anon, authenticated;

create or replace function public.record_terminal_punch(
  p_terminal_id uuid,
  p_enrolment_no text,
  p_punched_at timestamptz,
  p_direction text default null)
returns jsonb
language sql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select app.record_terminal_punch(
    p_terminal_id, p_enrolment_no, p_punched_at, p_direction);
$function$;

comment on function public.record_terminal_punch(uuid, text, timestamptz, text) is
  'The edge function''s way in to app.record_terminal_punch, because '
  'PostgREST only exposes `public`. Service role only: a client that '
  'could call it could file attendance for anybody. 0612.';

revoke all on function public.record_terminal_punch(uuid, text, timestamptz, text)
  from public, anon, authenticated;
