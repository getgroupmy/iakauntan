-- =====================================================================
-- iAkauntan :: an email is as it arrived (0852)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/inbound_email_kept.sql
--
-- Mail to a company's addresses is written by `receive_email`, as the
-- service role. Before `0852` the client's grant behind the policy meant
-- for marking a message read was the whole table: a supplier's payment
-- instruction could be rewritten, its sender and its date with it. Asked
-- as the owner with the role `authenticated`, as the inbox asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ie (org uuid, shared uuid, mine uuid, mail uuid);
grant select on t_ie to authenticated;

do $$
declare r t_ie;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Mel Asal Sdn Bhd', array['mailbox']);
  insert into public.org_mailboxes (org_id, local_part, status, decided_at, is_personal, owner_id)
  values (r.org, 'accounts', 'approved', now(), false, null) returning id into r.shared;
  insert into public.org_mailboxes (org_id, local_part, status, decided_at, is_personal, owner_id)
  values (r.org, 'aisyah', 'approved', now(), true, pg_temp.test_user()) returning id into r.mine;
  insert into public.inbound_emails
    (org_id, mailbox_id, message_id, from_email, to_email, subject, body_text, received_at)
  values (r.org, r.shared, '<m1@supplier.example>', 'billing@supplier.example',
          'accounts@iakauntan.com', 'Invoice 4471',
          'Please pay RM12,400 to Maybank 5123 4567 8901.', now() - interval '1 hour')
  returning id into r.mail;
  insert into t_ie select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ie; n int;
begin
  select * into d from t_ie;
  perform pg_temp.check_true('the owner, asking as a client who reads both mailboxes',
    current_user = 'authenticated' and app.can_write(d.org)
    and app.may_read_mailbox(d.shared) and app.may_read_mailbox(d.mine));

  -- What the inbox does: marks it read when it is opened.
  update public.inbound_emails set read_at = now() where id = d.mail;
  get diagnostics n = row_count;
  perform pg_temp.check_eq('opening a message still marks it read',
    n::text || ' / ' ||
    (select (read_at is not null)::text from public.inbound_emails where id = d.mail),
    '1 / true');

  -- What was measured, a column at a time.
  perform pg_temp.check_refused('what a supplier wrote is not rewritten',
    format($q$update public.inbound_emails
                 set body_text = 'Our bank account has changed: please pay RM12,400 to CIMB 8000 1111 2222.'
               where id = %L$q$, d.mail),
    'permission denied for table inbound_emails', '42501');
  perform pg_temp.check_refused('nor who sent it',
    format($q$update public.inbound_emails set from_email = 'ceo@supplier.example' where id = %L$q$, d.mail),
    'permission denied for table inbound_emails', '42501');
  perform pg_temp.check_refused('nor when it came',
    format($q$update public.inbound_emails set received_at = now() - interval '30 days' where id = %L$q$, d.mail),
    'permission denied for table inbound_emails', '42501');
  perform pg_temp.check_refused('nor what it was about',
    format($q$update public.inbound_emails set subject = 'Change of bank details' where id = %L$q$, d.mail),
    'permission denied for table inbound_emails', '42501');
  perform pg_temp.check_refused('nor the raw message behind it',
    format($q$update public.inbound_emails set raw_path = 'elsewhere.eml' where id = %L$q$, d.mail),
    'permission denied for table inbound_emails', '42501');
  perform pg_temp.check_refused('nor the mailbox it came to',
    format('update public.inbound_emails set mailbox_id = %L where id = %L', d.mine, d.mail),
    'permission denied for table inbound_emails', '42501');
  perform pg_temp.check_eq('so it reads as it arrived',
    (select from_email || ' / ' || subject || ' / ' || body_text || ' / ' ||
            (received_at > now() - interval '2 hours')::text
       from public.inbound_emails where id = d.mail),
    'billing@supplier.example / Invoice 4471 / Please pay RM12,400 to Maybank 5123 4567 8901. / true');
end $$;

reset role;

rollback;
