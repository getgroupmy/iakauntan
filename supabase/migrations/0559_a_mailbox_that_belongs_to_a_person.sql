-- =====================================================================
-- iAkauntan :: 0559 a mailbox that belongs to a person
--
-- `0328` gave a company addresses on the platform's domain and made
-- them the COMPANY's: `inbound_emails_read` is `is_org_member(org_id)`,
-- so everything that arrives at any of them is readable by everybody
-- who works there. That is right for `sales@` and `support@`, which is
-- what it was built for, and it is the wrong answer for `aisyah@` --
-- the first thing anybody assumes about an address with their own name
-- on it is that their colleagues cannot read it.
--
-- So a mailbox now knows whether it belongs to a person, and who.
--
-- ---------------------------------------------------------------------
-- Three states, not two
--
--   shared    `is_personal` false. Any member of the company reads it,
--             which is exactly what happens today and what every
--             existing row becomes.
--
--   personal  `is_personal` true with an `owner_id`. That person reads
--             it and nobody else does -- not their manager, not the
--             company's owner. An administrator can reassign it or
--             close it; neither of those is reading it.
--
--   orphaned  `is_personal` true with no owner, which is what a
--             personal mailbox becomes when the account is deleted.
--             An administrator can read THAT one, because the
--             alternative is mail nobody can ever reach again: a
--             company whose bookkeeper leaves still needs the invoices
--             customers sent to them.
--
-- The constraint refuses the fourth combination -- a shared mailbox
-- with an owner -- because it would read as personal to anybody
-- looking at the row and behave as shared.
--
-- ---------------------------------------------------------------------
-- Why an administrator cannot read a colleague's mail
--
-- It would be easy to add `or app.can_admin(org_id)` to the policy and
-- it is not what the word personal means. Workspace administrators
-- elsewhere cannot read a mailbox either; they can take it over, which
-- is a visible act with a row to show for it. Reassignment is the door,
-- and it leaves `owner_id` changed where an audit can see it.
--
-- ---------------------------------------------------------------------
-- What this does not change
--
-- Every row that exists today becomes shared, which is what it already
-- was: the migration adds a column with `false` and nothing that could
-- read a message yesterday stops being able to.
-- =====================================================================

alter table public.org_mailboxes
  add column if not exists is_personal boolean not null default false,
  -- Set null rather than cascade. Deleting somebody's account must not
  -- delete the mail customers sent them, which is the company's record
  -- of what was agreed as much as it is the person's.
  add column if not exists owner_id uuid references auth.users (id)
    on delete set null;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'org_mailboxes_owner_is_personal') then
    alter table public.org_mailboxes
      add constraint org_mailboxes_owner_is_personal
      check (is_personal or owner_id is null);
  end if;
end $$;

comment on column public.org_mailboxes.is_personal is
  'Whether this address belongs to one person rather than to the '
  'company. Shared is the default and what every row before 0559 is.';

comment on column public.org_mailboxes.owner_id is
  'Whose mailbox it is, for a personal one. Null on a personal mailbox '
  'means the account was deleted, and only an administrator can reach '
  'what is in it. 0559.';

create index if not exists org_mailboxes_owner_idx
  on public.org_mailboxes (owner_id) where owner_id is not null;

-- `0524`'s rule, and this column is squarely inside it: a mailbox
-- handed to somebody who does not work here is an address its owner
-- cannot read. Both RPCs below check membership too; the trigger is
-- what closes the straight-through-PostgREST path, and
-- `a_colleague_not_a_stranger.sql` asserts that every column of this
-- shape has one.
drop trigger if exists names_a_colleague_owner_id on public.org_mailboxes;
create trigger names_a_colleague_owner_id
  before insert or update on public.org_mailboxes
  for each row execute function app.names_a_colleague('owner_id', 'That person');

-- ---------------------------------------------------------------------
-- Who may read what arrived at a mailbox
--
-- One function, because three policies ask the same question --
-- reading a message, reading its attachments, and marking it read --
-- and three copies of a rule about who may read somebody's mail is
-- three places for them to drift apart.
-- ---------------------------------------------------------------------
create or replace function app.may_read_mailbox(p_mailbox uuid)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select exists (
    select 1
      from public.org_mailboxes m
     where m.id = p_mailbox
       and app.is_org_member(m.org_id)
       and app.has_module(m.org_id, 'mailbox')
       and (
             -- The company's own address: sales@, support@, hello@.
             not m.is_personal
             -- Mine.
             or m.owner_id = auth.uid()
             -- Nobody's, because the account is gone. An administrator
             -- can reach it; the alternative is mail that is lost the
             -- day somebody leaves.
             or (m.owner_id is null and app.can_admin(m.org_id))
           )
  );
$$;

comment on function app.may_read_mailbox(uuid) is
  'Whether the caller may read what arrived at this mailbox: shared to '
  'the company, personal to its owner, orphaned to an administrator. '
  '0559.';

revoke all on function app.may_read_mailbox(uuid) from public, anon;
grant execute on function app.may_read_mailbox(uuid) to authenticated;

drop policy if exists inbound_emails_read on public.inbound_emails;
create policy inbound_emails_read on public.inbound_emails
  for select to authenticated
  using (app.may_read_mailbox(mailbox_id));

drop policy if exists inbound_emails_mark on public.inbound_emails;
create policy inbound_emails_mark on public.inbound_emails
  for update to authenticated
  using (app.may_read_mailbox(mailbox_id) and app.can_write(org_id))
  with check (app.may_read_mailbox(mailbox_id) and app.can_write(org_id));

drop policy if exists inbound_email_attachments_read
  on public.inbound_email_attachments;
create policy inbound_email_attachments_read
  on public.inbound_email_attachments
  for select to authenticated
  using (exists (
    select 1 from public.inbound_emails e
     where e.id = inbound_email_attachments.email_id
       and app.may_read_mailbox(e.mailbox_id)));

-- ---------------------------------------------------------------------
-- Asking for one
--
-- Restated with a third argument. `request_mailbox` is `0328`'s and is
-- otherwise unchanged: still an administrator's call, still refused
-- without the module, still folded through `normalize_host_label` and
-- still checked against the same blocklist a subdomain is.
--
-- A personal address is asked for WITH its owner, rather than claimed
-- afterwards, because an approved mailbox with no owner is one anybody
-- in the company can read until somebody remembers to assign it.
-- ---------------------------------------------------------------------
-- Dropped and recreated rather than replaced. A third argument with a
-- default does not replace the two-argument function, it adds a second
-- one beside it -- and `request_mailbox(uuid, text)` then has two
-- candidates, which PostgREST refuses to choose between and answers
-- "function is not unique" to. `0492` learned this the same way.
drop function if exists public.request_mailbox(uuid, text);

create or replace function public.request_mailbox(
  p_org_id uuid,
  p_local_part text,
  p_owner_id uuid default null)
returns public.org_mailboxes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name    text := app.normalize_host_label(p_local_part);
  v_problem text;
  v_row     public.org_mailboxes;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or administrator can ask for an address';
  end if;

  if not app.has_module(p_org_id, 'mailbox') then
    raise exception 'This company does not have the email address module';
  end if;

  v_problem := app.check_host_label(v_name, 'mailbox');
  if v_problem is not null then
    raise exception '%', v_problem;
  end if;

  -- An address for somebody who does not work here would be an address
  -- its owner could not read, which is a mailbox that exists and does
  -- nothing.
  if p_owner_id is not null
     and not exists (select 1 from public.org_members m
                      where m.org_id = p_org_id
                        and m.user_id = p_owner_id
                        and m.status = 'active') then
    raise exception 'That person is not in this company'
      using errcode = '22023';
  end if;

  insert into public.org_mailboxes
    (org_id, local_part, requested_by, is_personal, owner_id)
  values (p_org_id, v_name, auth.uid(), p_owner_id is not null, p_owner_id)
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'That address is already taken.';
end;
$$;

-- ---------------------------------------------------------------------
-- Handing one over
--
-- The door an administrator has instead of reading somebody's mail.
-- Moving a mailbox to a new owner leaves `owner_id` changed where the
-- audit trail can see it; reading it would leave nothing at all.
--
-- Null takes it back to the company, which is how a departed person's
-- address becomes `accounts@` again -- and is a decision somebody makes
-- deliberately, because it makes every message in it readable by every
-- member.
-- ---------------------------------------------------------------------
create or replace function public.assign_mailbox(
  p_mailbox_id uuid,
  p_owner_id uuid)
returns public.org_mailboxes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.org_mailboxes;
begin
  select * into v_row from public.org_mailboxes where id = p_mailbox_id;
  if v_row.id is null then
    raise exception 'There is no such mailbox' using errcode = 'P0002';
  end if;

  if not app.can_admin(v_row.org_id) then
    raise exception 'Only an owner or administrator can move a mailbox'
      using errcode = '42501';
  end if;

  if p_owner_id is not null
     and not exists (select 1 from public.org_members m
                      where m.org_id = v_row.org_id
                        and m.user_id = p_owner_id
                        and m.status = 'active') then
    raise exception 'That person is not in this company'
      using errcode = '22023';
  end if;

  update public.org_mailboxes
     set owner_id    = p_owner_id,
         is_personal = p_owner_id is not null
   where id = p_mailbox_id
  returning * into v_row;

  return v_row;
end;
$$;

comment on function public.assign_mailbox(uuid, uuid) is
  'Moves a mailbox to a person, or back to the company with null. The '
  'door an administrator has instead of reading it. 0559.';

revoke all on function public.assign_mailbox(uuid, uuid) from public, anon;
grant execute on function public.assign_mailbox(uuid, uuid) to authenticated;

revoke all on function public.request_mailbox(uuid, text, uuid)
  from public, anon;
grant execute on function public.request_mailbox(uuid, text, uuid)
  to authenticated;
