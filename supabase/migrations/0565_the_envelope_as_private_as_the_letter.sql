-- =====================================================================
-- iAkauntan :: 0565 the envelope as private as the letter
--
-- `0560` let somebody answer mail that arrived at one of the company's
-- addresses, and the answer can only be words. A supplier sends a PDF
-- invoice, it lands in `aisyah@`, she reads it here -- and to send the
-- signed copy back she opens Gmail, which is the split `0560` existed
-- to close.
--
-- `email_outbox` has carried `attachment_path` and `attachment_name`
-- since `0109`, and `send-email` already uploads whatever they name.
-- What was missing was a way for a person to set them.
--
-- ---------------------------------------------------------------------
-- Where the file lives, and why the prefix matters
--
-- `0109`'s rule, applied to a mailbox: a path arrives from the client
-- and is a CLAIM about a file, so it is anchored to a prefix the caller
-- has already been proved to hold. There it was
-- `<org>/sales_documents/<document>/`; here it is
-- `<org>/mailbox/<mailbox>/`, and the caller has just passed
-- `app.may_read_mailbox` on that mailbox.
--
-- Without the anchor, a member could point a reply at any object in
-- their own company's bucket and mail it to anybody -- the storage
-- policy governs who may WRITE there, never what a queued message may
-- reference.
--
-- ---------------------------------------------------------------------
-- And the leak that anchoring alone would open
--
-- The bucket decides who may read an object by taking its name apart --
-- `org/table/record/file` since `0068` -- and asking
-- `app.can_read_attachment(org, table, record)`. A `mailbox` prefix it
-- has never heard of falls through to that function's ordinary answer,
-- which for anybody who can write the books is `true`. So a file
-- attached to a reply from `aisyah@` would be readable in storage by
-- every colleague, while the message it belongs to is not.
--
-- That is exactly what `personal_mailbox.sql` refuses to allow for
-- inbound mail, in the words it uses there: a policy that guarded the
-- message and not what was attached to it would be a door with the
-- letter behind it and the envelope open.
--
-- So the two guards learn one more table name, beside the
-- `feedback_reports` case each already carries. The three storage
-- policies are not touched: they have been asking the right question
-- since `0068` and `0118`, and the answer is what changes.
--
-- The module asked is `mailbox`, through `may_read_mailbox`, and not
-- `attachments`. A file on an email is part of having an email
-- address; a company that never bought the attachments module can
-- still answer its own mail.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Reading one
--
-- `0068`'s function with one case added at the top, beside `0460`'s.
-- `may_read_mailbox` is the whole answer: it asks membership, the
-- module, and whose mailbox it is, which is the same question the
-- message row is guarded by -- so the envelope and the letter cannot
-- come apart.
-- ---------------------------------------------------------------------

create or replace function app.can_read_attachment(
  p_org_id uuid, p_entity_table text, p_entity_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_employee uuid;
begin
  -- 0565. A file on a message, guarded by the same question the
  -- message is: shared to the company, personal to its owner, orphaned
  -- to an administrator. Before everything below, because none of what
  -- follows knows that a mailbox can be one person's.
  if p_entity_table = 'mailbox' then
    return p_entity_id is not null
       and app.may_read_mailbox(p_entity_id)
       -- And the path has to name the mailbox's own company, or the
       -- first segment is decoration.
       and exists (select 1 from public.org_mailboxes m
                    where m.id = p_entity_id and m.org_id = p_org_id);
  end if;

  -- A screenshot on a bug report, before anything else is asked.
  --
  -- Everything below this line is about a company's own records and
  -- asks `can_write` or `can_read_ledger` first; a bug report is not
  -- one of those. Whoever may read the report may see the picture on
  -- it, and nobody else. See 0460.
  if p_entity_table = 'feedback_reports' then
    return exists (
      select 1 from public.feedback_reports f
       where f.id = p_entity_id
         and (f.reported_by = auth.uid()
              or app.is_platform_admin()
              or (f.org_id is not null and app.can_admin(f.org_id))));
  end if;

  if p_org_id is null then return false; end if;

  if app.can_write(p_org_id) or app.can_read_ledger(p_org_id) then
    -- …except the personnel records, which the ledger audience has no
    -- business in. An accounts clerk does not get to read a passport.
    if p_entity_table in ('employees', 'employee_documents', 'payslips',
                          'corp_persons') then
      return app.can_manage_hr(p_org_id) or app.can_admin(p_org_id)
          or app.can_run_payroll(p_org_id);
    end if;
    return true;
  end if;

  if app.can_manage_hr(p_org_id) then return true; end if;

  -- Otherwise: the person it is about, and nobody else.
  select e.id into v_employee
    from public.employees e
   where e.org_id = p_org_id and e.user_id = auth.uid();
  if v_employee is null then return false; end if;

  return case p_entity_table
    when 'employees' then p_entity_id = v_employee
    when 'employee_documents' then exists (
      select 1 from public.employee_documents d
       where d.id = p_entity_id and d.employee_id = v_employee)
    when 'expense_claims' then exists (
      select 1 from public.expense_claims c
       where c.id = p_entity_id and c.employee_id = v_employee)
    when 'leave_requests' then exists (
      select 1 from public.leave_requests r
       where r.id = p_entity_id and r.employee_id = v_employee)
    when 'payslips' then exists (
      select 1 from public.payslips p
       where p.id = p_entity_id and p.employee_id = v_employee)
    else false
  end;
end;
$$;

-- ---------------------------------------------------------------------
-- Putting one there
--
-- `0118`'s function, the same case added. Writing asks `can_write` on
-- top of `may_read_mailbox`: a read-only member may read the mailbox
-- and does not send from it, which is the line `send_from_mailbox`
-- draws one layer up.
--
-- Placed before the `attachments` module check on purpose. A file on
-- an email is part of having an email address.
-- ---------------------------------------------------------------------
create or replace function app.can_attach_to(
  p_org_id uuid, p_entity_table text, p_entity_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_employee uuid;
begin
  if p_org_id is null or p_entity_id is null then return false; end if;

  -- 0565. And nobody drops a file into a colleague's mailbox folder:
  -- it would be unreadable to them afterwards, which is the shape of a
  -- thing that looks like it worked.
  if p_entity_table = 'mailbox' then
    return app.may_read_mailbox(p_entity_id)
       and app.can_write(p_org_id)
       and exists (select 1 from public.org_mailboxes m
                    where m.id = p_entity_id and m.org_id = p_org_id);
  end if;

  -- 0323. The module. Reading is decided by
  -- `app.can_read_attachment`, which does not ask this and is
  -- deliberately left open: a company that stops paying keeps its
  -- documents, it just cannot add more.
  -- A picture on your own bug report, before the module is asked
  -- about. Reporting a fault in the product is not a feature a company
  -- buys, and the person most likely to have a screenshot is the
  -- employee who hit the fault -- who may hold no write permission at
  -- all. See 0460.
  if p_entity_table = 'feedback_reports' then
    return exists (
      select 1 from public.feedback_reports f
       where f.id = p_entity_id and f.reported_by = auth.uid());
  end if;

  if not app.has_module(p_org_id, 'attachments') then return false; end if;

  -- Everybody who could before.
  if app.can_write(p_org_id) then return true; end if;
  if app.can_manage_hr(p_org_id) then return true; end if;

  -- Otherwise: the person the record is about, on the records that are
  -- theirs to support.
  select e.id into v_employee
    from public.employees e
   where e.org_id = p_org_id and e.user_id = auth.uid();
  if v_employee is null then return false; end if;

  return case p_entity_table
    -- While it can still matter. Once a claim is in the ledger the
    -- paperwork behind it is the accountant's record, not a document
    -- the claimant can still add to.
    when 'expense_claims' then exists (
      select 1 from public.expense_claims c
       where c.id = p_entity_id
         and c.employee_id = v_employee
         and c.posted_at is null)
    when 'leave_requests' then exists (
      select 1 from public.leave_requests r
       where r.id = p_entity_id
         and r.employee_id = v_employee)
    else false
  end;
end;
$$;

-- ---------------------------------------------------------------------
-- Sending one
--
-- Dropped and recreated rather than replaced, for the reason `0559`
-- wrote down and `0492` learned before it: extra arguments with
-- defaults ADD an overload beside the old function, and PostgREST then
-- answers "function is not unique" rather than choosing.
-- ---------------------------------------------------------------------
drop function if exists public.send_from_mailbox(uuid, text, text, text, uuid);

create or replace function public.send_from_mailbox(
  p_mailbox_id uuid,
  p_to text,
  p_subject text,
  p_body text,
  p_in_reply_to uuid default null,
  p_attachment_path text default null,
  p_attachment_name text default null
)
returns public.email_outbox
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_box    public.org_mailboxes;
  v_parent public.inbound_emails;
  v_to     text := lower(btrim(coalesce(p_to, '')));
  v_path   text := nullif(btrim(coalesce(p_attachment_path, '')), '');
  v_row    public.email_outbox;
begin
  select * into v_box from public.org_mailboxes where id = p_mailbox_id;
  if not found then
    raise exception 'There is no such mailbox' using errcode = 'P0002';
  end if;

  -- The same question `0559` asks of the inbox. Sending as an address
  -- is a stronger thing than reading it, and there is no case where
  -- somebody may send as a mailbox they may not read: what the
  -- recipient sees is that address's name over words they did not
  -- write.
  if not app.may_read_mailbox(p_mailbox_id) then
    raise exception 'That is not your mailbox' using errcode = '42501';
  end if;

  -- And read-only members read. `can_write` is the ordinary line
  -- between somebody looking at the books and somebody changing them,
  -- and mail leaving the company over its own name is on the far side
  -- of it.
  if not app.can_write(v_box.org_id) then
    raise exception 'You do not have permission to send from here'
      using errcode = '42501';
  end if;

  if v_box.status <> 'approved' then
    raise exception 'That address has not been approved yet'
      using errcode = '22023';
  end if;

  -- Deliberately loose. Address syntax is wider than anything worth
  -- writing here, and the provider will refuse what it will refuse; the
  -- point of this check is to catch the empty box and the name typed
  -- without a domain before the row is queued and a person is told it
  -- was sent.
  if v_to !~ '^[^@[:space:],]+@[^@[:space:],]+\.[^@[:space:],]+$' then
    raise exception 'That is not an email address we can send to'
      using errcode = '22023';
  end if;

  if btrim(coalesce(p_body, '')) = '' then
    raise exception 'A message needs something in it'
      using errcode = '22023';
  end if;

  -- `0109`'s rule on a mailbox. The path is a claim from the client,
  -- and it is anchored to the one prefix this caller has just been
  -- proved to hold -- otherwise a member could point a reply at any
  -- object in the company's bucket and mail it out.
  -- `0109`'s check, in `0068`'s vocabulary: the bucket has read an
  -- object's name as `org/table/record/file` since then, and
  -- `uuid_or_null` is how it reads a segment that may be rubbish
  -- without raising.
  if v_path is not null
     and (split_part(v_path, '/', 1) <> v_box.org_id::text
          or split_part(v_path, '/', 2) <> 'mailbox'
          or app.uuid_or_null(split_part(v_path, '/', 3))
             is distinct from p_mailbox_id
          or split_part(v_path, '/', 4) = '') then
    raise exception 'An attachment must live under %/mailbox/%/',
      v_box.org_id, p_mailbox_id using errcode = '42501';
  end if;

  if p_in_reply_to is not null then
    select * into v_parent from public.inbound_emails
     where id = p_in_reply_to;
    -- Not `may_read_mailbox(v_parent.mailbox_id)`: a reply must go back
    -- to the conversation it came from, so the parent has to be in THIS
    -- mailbox and not merely in one the sender can read.
    if not found or v_parent.mailbox_id <> p_mailbox_id then
      raise exception 'That message did not arrive at this address'
        using errcode = '22023';
    end if;
  end if;

  insert into public.email_outbox (
    org_id, mailbox_id, to_email, subject, body,
    from_email, from_name, in_reply_to, thread_refs, created_by,
    attachment_path, attachment_name)
  values (
    v_box.org_id,
    v_box.id,
    v_to,
    -- An empty subject is an empty subject, not a missing one: "(no
    -- subject)" in the box is what the recipient would see typed out.
    coalesce(nullif(btrim(coalesce(p_subject, '')), ''), '(no subject)'),
    p_body,
    -- Rebuilt here rather than taken from the caller. `0328`'s trigger
    -- would refuse a mismatch anyway; building it means there is
    -- nothing to refuse.
    v_box.local_part || '@' || app.mail_domain(),
    (select nullif(btrim(coalesce(p.full_name, '')), '')
       from public.profiles p where p.id = auth.uid()),
    v_parent.message_id,
    v_parent.message_id,
    auth.uid(),
    v_path,
    -- The name the recipient sees. Falls back to the last path segment
    -- rather than to nothing, because a mail client with no filename
    -- shows "attachment" and the person opening it has to guess.
    coalesce(nullif(btrim(coalesce(p_attachment_name, '')), ''),
             nullif(regexp_replace(coalesce(v_path, ''), '^.*/', ''), '')))
  returning * into v_row;

  return v_row;
end;
$$;

comment on function public.send_from_mailbox(
  uuid, text, text, text, uuid, text, text) is
  'Queues a message from one of the company''s addresses, optionally '
  'as a reply and optionally with one file. Queued, never sent: '
  'send-email drains the outbox. 0560, attachment 0565.';

revoke all on function public.send_from_mailbox(
  uuid, text, text, text, uuid, text, text) from public, anon;
grant execute on function public.send_from_mailbox(
  uuid, text, text, text, uuid, text, text) to authenticated;
