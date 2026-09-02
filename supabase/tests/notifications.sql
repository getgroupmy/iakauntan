-- =====================================================================
-- iAkauntan :: telling somebody
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/notifications.sql
--
-- Four things the system already records and never told anybody: an
-- e-Invoice LHDN refused, a ticket past its SLA, a claim waiting on a
-- named approver, and financial statements approaching the s.259
-- lodgement date. 0497 gathers them once a night.
--
-- Three things are asserted. That each source is read at all; that a
-- nightly job does not say the same thing every night; and that one
-- person's bell is theirs -- an approval addressed to the approver is
-- not on everybody's screen, and no company's notice is on another
-- company's.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create table pg_temp.fixture (
  org uuid, other_org uuid, boss uuid, clerk uuid, ticket uuid,
  claim uuid, filing uuid, einv uuid);

create or replace function pg_temp.titles(p_org uuid)
returns text language sql stable as $$
  select coalesce(string_agg(kind, ',' order by kind), '')
    from public.notifications
   where org_id = p_org and dismissed_at is null;
$$;

do $$
declare
  v_org    uuid := pg_temp.test_org('Bell Sdn Bhd');
  v_boss   uuid := pg_temp.test_user();
  v_clerk  uuid := pg_temp.another_user('clerk@example.test');
  v_other  uuid;
  v_them   uuid;
  v_doc    uuid;
  v_ticket uuid;
  v_claim  uuid;
  v_filing uuid;
  v_einv   uuid;
  v_emp    uuid;
  v_ent    uuid;
begin
  perform pg_temp.allow_many_companies();
  v_other := pg_temp.test_org('Somebody Else Sdn Bhd');
  perform pg_temp.sign_in_as(v_boss);

  -- The clerk works here too. Without a membership the policy would
  -- keep the claim from them for the wrong reason, and the assertion
  -- below would pass while saying nothing.
  insert into public.org_members
    (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'accountant', 'active', now());

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'buyer@example.test')
  returning id into v_them;

  -- 1. LHDN would not take it.
  insert into public.einvoice_documents
    (org_id, source_table, source_id, einvoice_type_code, internal_doc_no,
     issue_date, currency, supplier_name, supplier_tin, buyer_name,
     buyer_tin, total_excl_tax, total_incl_tax, payable_amount, status,
     rejection_reason)
  values (v_org, 'sales_documents', gen_random_uuid(), '01', 'INV-1',
          date '2026-01-15', 'MYR', 'Bell Sdn Bhd', 'C12345678900',
          'Buyer Bhd', 'C98765432100', 1000, 1000, 1000, 'rejected',
          'Buyer TIN not found')
  returning id into v_einv;

  -- The same thing, in the company next door. Nothing about it belongs
  -- on this company's bell.
  insert into public.einvoice_documents
    (org_id, source_table, source_id, einvoice_type_code, internal_doc_no,
     issue_date, currency, supplier_name, supplier_tin, buyer_name,
     buyer_tin, total_excl_tax, total_incl_tax, payable_amount, status,
     rejection_reason)
  values (v_other, 'sales_documents', gen_random_uuid(), '01', 'THEIRS-9',
          date '2026-01-15', 'MYR', 'Somebody Else Sdn Bhd', 'C11111111100',
          'Buyer Bhd', 'C98765432100', 50, 50, 50, 'rejected',
          'Their problem');

  -- 2. A ticket past the time the customer was promised.
  insert into public.tickets
    (org_id, ticket_no, subject, requester_contact_id, status, priority,
     resolution_due_at)
  values (v_org, 'T-1', 'Cannot log in', v_them, 'open', 'p1',
          now() - interval '2 hours')
  returning id into v_ticket;

  -- 3. A claim waiting on one person.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E-1', 'Siti binti Ahmad', date '2025-01-01', 'active')
  returning id into v_emp;
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status,
     total_amount, currency, submitted_at, approver_id)
  values (v_org, 'CLM-1', v_emp, date '2026-02-01', 'Client visit',
          'submitted', 250, 'MYR', now(), v_clerk)
  returning id into v_claim;

  -- 4. The statutory one.
  insert into public.corp_entities (org_id, name, entity_type)
  values (v_org, 'Bell Sdn Bhd', 'sdn_bhd')
  returning id into v_ent;
  -- Circulated early, which under s.259 brings the lodgement date
  -- forward with it: thirty days from the act, not from the
  -- entitlement. A filing that read the year end alone would put this
  -- deadline two months later than it is.
  insert into public.fs_filings
    (org_id, corp_entity_id, fy_start, fy_end, framework,
     directors_approval_date, circulated_on)
  values (v_org, v_ent, date '2025-01-01', date '2025-12-31', 'mpers',
          date '2026-04-20', date '2026-05-01')
  returning id into v_filing;

  insert into pg_temp.fixture
  values (v_org, v_other, v_boss, v_clerk, v_ticket, v_claim, v_filing,
          v_einv);

  -- ------------------------------------------------------------------
  -- The nightly pass
  --
  -- Run on a day inside the thirty days before the lodgement date:
  -- circulate by 30 Jun 2026, lodge by 30 Jul 2026.
  -- ------------------------------------------------------------------
  perform app.raise_notifications(v_org, date '2026-07-10');

  perform pg_temp.check_true('LHDN refusing an invoice is on the list',
    pg_temp.titles(v_org) like '%einvoice_rejected%');
  perform pg_temp.check_true('and a ticket past its SLA',
    pg_temp.titles(v_org) like '%ticket_overdue%');
  perform pg_temp.check_true('and a claim waiting to be approved',
    pg_temp.titles(v_org) like '%claim_to_approve%');
  perform pg_temp.check_true('and the lodgement date coming up',
    pg_temp.titles(v_org) like '%fs_lodgement_due%');

  perform pg_temp.check_eq('and nothing from another company',
    (select count(*)::integer from public.notifications
      where org_id = v_org
        and (title like '%THEIRS-9%' or body like '%Their problem%')), 0);

  -- The rule the statute gives, which `fs_deadlines` answers with for
  -- the same filing. Written in one place at 0497 precisely so these
  -- two cannot drift apart.
  perform pg_temp.check_true('the lodgement date is the one the statute gives',
    (select n.title like '%' || to_char(d.lodge_by, 'DD Mon YYYY') || '%'
       from public.notifications n,
            lateral public.fs_deadlines(v_filing) d
      where n.org_id = v_org and n.kind = 'fs_lodgement_due'));

  -- ------------------------------------------------------------------
  -- Saying it once
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('and running the job again does not say it twice',
    app.raise_notifications(v_org, date '2026-07-10'), 0);
  perform pg_temp.check_eq('so the list is still four',
    (select count(*)::integer from public.notifications
      where org_id = v_org and dismissed_at is null), 4);

  -- Dismissed is not silenced for ever: a ticket that goes overdue a
  -- second time is news a second time.
  perform public.dismiss_notification(
    (select id from public.notifications
      where org_id = v_org and kind = 'ticket_overdue'));
  perform pg_temp.check_eq(
    'but a ticket that goes overdue again is news again',
    app.raise_notifications(v_org, date '2026-07-10'), 1);
end $$;

-- ---------------------------------------------------------------------
-- Whose bell it is
--
-- Under `authenticated`, because the policy is what answers this and a
-- superuser session goes straight past it.
-- ---------------------------------------------------------------------
do $$
declare f pg_temp.fixture;
begin
  select * into f from pg_temp.fixture;

  -- The boss: everything addressed to the company, and not the claim
  -- that is waiting on the clerk.
  perform pg_temp.sign_in_as(f.boss);
  set local role authenticated;
  perform pg_temp.check_eq('the company''s notices reach a member',
    (select count(*)::integer from public.my_notifications(f.org)
      where kind in ('einvoice_rejected', 'fs_lodgement_due')), 2);
  perform pg_temp.check_eq('and not somebody else''s',
    (select count(*)::integer from public.my_notifications(f.org)
      where kind = 'claim_to_approve'), 0);
  reset role;

  -- The clerk: the claim, because it is addressed to them.
  perform pg_temp.sign_in_as(f.clerk);
  set local role authenticated;
  perform pg_temp.check_eq(
    'a claim waiting on one person is that person''s',
    (select count(*)::integer from public.my_notifications(f.org)
      where kind = 'claim_to_approve'), 1);
  reset role;

  perform pg_temp.sign_in_as(f.boss);
end $$;

-- ---------------------------------------------------------------------
-- Marking it read
-- ---------------------------------------------------------------------
do $$
declare
  f      pg_temp.fixture;
  v_id   uuid;
  v_mine uuid;
begin
  select * into f from pg_temp.fixture;

  select id into v_id from public.notifications
   where org_id = f.org and kind = 'claim_to_approve';
  select id into v_mine from public.notifications
   where org_id = f.org and kind = 'einvoice_rejected';

  -- The boss is signed in, and the claim belongs to the clerk.
  perform pg_temp.check_true('a person can only mark their own as read',
    not public.mark_notification_read(v_id));
  perform pg_temp.check_true('and the company''s are theirs to mark',
    public.mark_notification_read(v_mine));
  perform pg_temp.check_true('which is what read means',
    (select read_at is not null from public.notifications
      where id = v_mine));

  -- Marking everything read leaves the dismissed ones alone and the
  -- clerk's alone.
  perform pg_temp.check_true('marking all read clears what is left',
    public.mark_all_notifications_read(f.org) >= 1);
  perform pg_temp.check_eq('and the claim is still unread for the clerk',
    (select count(*)::integer from public.notifications
      where org_id = f.org and kind = 'claim_to_approve'
        and read_at is null), 1);
end $$;

rollback;
