-- =====================================================================
-- iAkauntan :: 0853 an attachment as private as its letter
--
-- Files attached to incoming mail are stored by `receive-email` in the
-- `mail` bucket as `<company>/<email>/<n>-<file>`. The email and its
-- attachment rows are private to whoever may read the mailbox it came
-- to -- `app.may_read_mailbox`: a company address to its members, a
-- personal one to its owner alone (`0559`, `0565`). The bucket's read
-- policy, `mail_files_read` (`0354`, restated by `0405`), asked only
-- whether the reader was a member of the company.
--
-- Measured on 13 October 2026, locally, as the company's OWNER with the
-- role `authenticated`: a clerk's personal email and its attachment row
-- were invisible, as `personal_mailbox.sql` asserts -- and listing the
-- `mail` bucket showed `0-medical-report.pdf` from that same email, and
-- reading it was allowed. Any member, a plain employee included, could
-- list and fetch every file that had come to any of the company's
-- mailboxes.
--
-- Answered "ask the mailbox": `app.may_read_mail_file` looks the email
-- up by the path's second segment and asks `may_read_mailbox` of the
-- mailbox it came to, in the company the first segment names; the
-- policy asks it, and the module as before. A definer, as
-- `can_read_attachment` is: whether a file may be read is not a
-- question to answer through the reader's own row level security, and
-- `0661` is what happens to a bucket whose policy calls something the
-- client cannot execute. A path that is not two uuids reads as nobody's,
-- through `app.uuid_or_null`, rather than raising (`0405`).
--
-- Production held no mailbox and no mail file on 13 October; the
-- mailbox feature is not yet live.
-- =====================================================================

create or replace function app.may_read_mail_file(p_org uuid, p_email uuid)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select exists (select 1 from public.inbound_emails e
                  where e.id = p_email
                    and e.org_id = p_org
                    and app.may_read_mailbox(e.mailbox_id));
$$;

comment on function app.may_read_mail_file(uuid, uuid) is
  'Whether a file in the mail bucket, <company>/<email>/<n>-<file>, may '
  'be read: the email is that company''s and its mailbox is one the '
  'reader may read (app.may_read_mailbox). For mail_files_read. 0853.';

revoke all on function app.may_read_mail_file(uuid, uuid) from public, anon;
grant execute on function app.may_read_mail_file(uuid, uuid)
  to authenticated, service_role;

drop policy if exists mail_files_read on storage.objects;
create policy mail_files_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'mail'
    and app.has_module(app.uuid_or_null(split_part(name, '/', 1)), 'mailbox')
    and app.may_read_mail_file(app.uuid_or_null(split_part(name, '/', 1)),
                               app.uuid_or_null(split_part(name, '/', 2)))
  );
