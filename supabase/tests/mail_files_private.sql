-- =====================================================================
-- iAkauntan :: an attachment as private as its letter (0853)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/mail_files_private.sql
--
-- A file attached to incoming mail is stored as
-- `<company>/<email>/<n>-<file>` in the `mail` bucket. Before `0853` any
-- member of the company could list and read every one of them, though
-- the email and its attachment row were private to whoever may read the
-- mailbox it came to. Asked with the role `authenticated`, as the
-- Storage API asks, by four readers.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_mf (org uuid, clerk uuid, staff uuid, shared uuid, theirs uuid,
  shared_file text, personal_file text, foreign_file text, ghost_file text);
grant select on t_mf to authenticated;

insert into storage.buckets (id, name) values ('mail', 'mail') on conflict do nothing;

do $$
declare r t_mf; v_other uuid; v_other_box uuid; v_mail uuid; v_foreign uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Surat Peribadi Sdn Bhd', array['mailbox']);
  r.clerk := pg_temp.another_user('clerk@suratperibadi.test');
  r.staff := pg_temp.another_user('staff@suratperibadi.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.clerk, 'accounts_clerk', 'active'), (r.org, r.staff, 'employee', 'active');

  -- The company's own address, and the clerk's.
  insert into public.org_mailboxes (org_id, local_part, status, decided_at, is_personal)
  values (r.org, 'accounts', 'approved', now(), false) returning id into r.shared;
  insert into public.org_mailboxes (org_id, local_part, status, decided_at, is_personal, owner_id)
  values (r.org, 'meiling', 'approved', now(), true, r.clerk) returning id into r.theirs;

  insert into public.inbound_emails (org_id, mailbox_id, message_id, from_email, to_email, subject)
  values (r.org, r.shared, '<s1@supplier.example>', 'billing@supplier.example',
          'accounts@iakauntan.com', 'Invoice 4471') returning id into v_mail;
  r.shared_file := r.org || '/' || v_mail || '/1-invoice-4471.pdf';
  insert into public.inbound_emails (org_id, mailbox_id, message_id, from_email, to_email, subject)
  values (r.org, r.theirs, '<p1@clinic.example>', 'doctor@clinic.example',
          'meiling@iakauntan.com', 'Your results') returning id into v_mail;
  r.personal_file := r.org || '/' || v_mail || '/1-medical-report.pdf';

  -- An email the owner may read in a second company, and a file named as
  -- if it were this company's; and a file under an email that never was.
  v_other := pg_temp.test_org('Syarikat Kedua Sdn Bhd', array['mailbox']);
  insert into public.org_mailboxes (org_id, local_part, status, decided_at, is_personal)
  values (v_other, 'hello', 'approved', now(), false) returning id into v_other_box;
  insert into public.inbound_emails (org_id, mailbox_id, message_id, from_email, to_email, subject)
  values (v_other, v_other_box, '<o1@elsewhere.example>', 'a@elsewhere.example',
          'hello@iakauntan.com', 'Hello') returning id into v_foreign;
  r.foreign_file := r.org || '/' || v_foreign || '/1-elsewhere.pdf';
  r.ghost_file := r.org || '/' || gen_random_uuid() || '/1-ghost.pdf';

  insert into storage.objects (bucket_id, name)
  select 'mail', f from unnest(array[r.shared_file, r.personal_file, r.foreign_file, r.ghost_file]) f;
  insert into t_mf select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_mf;
begin
  select * into d from t_mf;
  perform pg_temp.check_eq('the premise: the owner reads the company''s address, not the clerk''s',
    app.may_read_mailbox(d.shared)::text || ' / ' || app.may_read_mailbox(d.theirs)::text,
    'true / false');

  -- What was measured.
  perform pg_temp.check_eq('the owner does not read the file on the clerk''s personal mail',
    (select count(*)::text from storage.objects where bucket_id = 'mail' and name = d.personal_file), '0');
  perform pg_temp.check_eq('nor one filed under another company''s email',
    (select count(*)::text from storage.objects where bucket_id = 'mail' and name = d.foreign_file), '0');
  perform pg_temp.check_eq('nor one under an email that never was',
    (select count(*)::text from storage.objects where bucket_id = 'mail' and name = d.ghost_file), '0');
  perform pg_temp.check_eq('so listing the bucket shows the company address''s file and nothing else',
    (select string_agg(name, ', ') from storage.objects where bucket_id = 'mail'), d.shared_file);
end $$;

reset role;

-- The clerk reads their own, and the company's.
select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_mf), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_mf;
begin
  select * into d from t_mf;
  perform pg_temp.check_eq('the clerk reads the file on their own mail, and the company''s',
    (select count(*)::text from storage.objects
      where bucket_id = 'mail' and name in (d.personal_file, d.shared_file)), '2');
end $$;

reset role;

-- A plain employee reads what came to the company's address, as they
-- read the message itself, and nobody's personal mail.
select set_config('request.jwt.claims',
  json_build_object('sub', (select staff from t_mf), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_mf;
begin
  select * into d from t_mf;
  perform pg_temp.check_eq('an employee reads the company address''s file and not the clerk''s',
    (select string_agg(name, ', ') from storage.objects where bucket_id = 'mail'), d.shared_file);
end $$;

reset role;

rollback;
