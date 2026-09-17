-- =====================================================================
-- iAkauntan :: what the paper actually is
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scan_document_kinds.sql
--
-- `0614` gave AI SmartScan a notion of what the PAPER IS, as a table an
-- administrator can add to rather than an enum that needs a migration.
--
-- Four things here are worth a test, and one of them is a fault this
-- file was written for:
--
--   * **An empty argument clears; an absent one does not.** Three of
--     the kinds this shipped with have no destination on purpose, so
--     the console offers "filed only" — and under the `coalesce` this
--     function was first written with, choosing it would have said
--     "Saved" and left the old destination standing. A screen that
--     reports a change it did not make is the fault worth asserting.
--   * **A built-in cannot be deleted, and one in use cannot either.**
--     Both refusals name what to do instead, because "switch it off"
--     is almost always what was meant.
--   * **A kind that IS removed leaves its scans.** `on delete set null`
--     rather than restrict, deliberately, and the opposite of what
--     `entity_types` does — so it is asserted rather than assumed.
--   * **Only a platform administrator writes the list.** It is the
--     whole platform's, not a company's.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.a_platform_admin(p_user uuid)
returns void language sql as $$
  insert into public.platform_admins (user_id) values (p_user)
  on conflict (user_id) do nothing;
$$;

-- =====================================================================
-- The list this shipped with
--
-- Not the labels -- those are an administrator's to change -- but the
-- two structural claims the app is written against: `other` sorts last
-- so "nothing matched" is the bottom of the dropdown rather than the
-- middle of it, and every kind with a destination names one the app
-- knows how to open.
-- =====================================================================
do $$
declare
  v_n       integer;
  v_last    text;
  v_unknown text;
begin
  select count(*) into v_n
    from public.scan_document_kinds where is_builtin;
  perform pg_temp.check_true(
    'the kinds this shipped with are all built in and there are several',
    v_n >= 9);

  select code into v_last from public.scan_document_kinds
   where is_active order by sort_order desc, code desc limit 1;
  perform pg_temp.check_eq(
    '"something else" is last, because it is the answer when nothing '
    'matched', v_last, 'other');

  -- The destinations are screens. `scan_kinds_repository.dart` holds
  -- the list of the ones this app can open, and a seeded row naming
  -- something else would be an option leading nowhere.
  select string_agg(destination, ', ') into v_unknown
    from public.scan_document_kinds
   where destination is not null
     and destination not in ('purchase_document', 'expense',
                             'goods_received', 'bank_import', 'contact');
  perform pg_temp.check_true(
    'and every destination is one the app knows how to open: '
    || coalesce(v_unknown, 'none unknown'),
    v_unknown is null);

  -- CONTROL. Three of them have no destination, so the assertion above
  -- is not passing because every row was skipped.
  select count(*) into v_n from public.scan_document_kinds
   where destination is not null;
  perform pg_temp.check_true(
    'with several rows actually carrying one', v_n >= 6);
end $$;

-- =====================================================================
-- Absent means leave it alone; empty means clear it
--
-- The fault this file was written for. Both halves, because either one
-- alone is satisfied by a function that ignores the argument entirely.
-- =====================================================================
do $$
declare
  v_me  uuid := pg_temp.test_user();
  v_dest text;
  v_hint text;
  v_label text;
begin
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.a_platform_admin(v_me);

  perform public.platform_save_scan_kind(
    'penyata_gaji', 'Payslip', null, 'expense',
    'Becomes an expense claim.', 45, true);

  -- Correcting the NAME must not clear the hint or the destination.
  perform public.platform_save_scan_kind('penyata_gaji', 'Payslip (EA)');
  select destination, hint into v_dest, v_hint
    from public.scan_document_kinds where code = 'penyata_gaji';
  perform pg_temp.check_eq(
    'correcting a name leaves the destination alone', v_dest, 'expense');
  perform pg_temp.check_eq(
    'and leaves the hint alone', v_hint, 'Becomes an expense claim.');

  select label into v_label
    from public.scan_document_kinds where code = 'penyata_gaji';
  perform pg_temp.check_eq(
    'and does change the name', v_label, 'Payslip (EA)');

  -- "Filed only": the destination is taken away, and nothing else
  -- moves. Under the `coalesce` this was first written with, this
  -- assertion is the one that failed.
  perform public.platform_save_scan_kind(
    'penyata_gaji', 'Payslip (EA)', p_destination => '');
  select destination, hint into v_dest, v_hint
    from public.scan_document_kinds where code = 'penyata_gaji';
  perform pg_temp.check_true(
    'choosing "filed only" actually takes the destination away',
    v_dest is null);
  perform pg_temp.check_eq(
    'and takes nothing else with it', v_hint, 'Becomes an expense claim.');

  -- And the hint on its own, so the rule is the argument's and not one
  -- column's.
  perform public.platform_save_scan_kind(
    'penyata_gaji', 'Payslip (EA)', p_hint => '   ');
  select hint into v_hint
    from public.scan_document_kinds where code = 'penyata_gaji';
  perform pg_temp.check_true(
    'a hint of nothing but spaces clears the hint', v_hint is null);
end $$;

-- =====================================================================
-- What the list refuses
-- =====================================================================
do $$
declare
  v_me uuid := pg_temp.test_user();
begin
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.a_platform_admin(v_me);

  perform pg_temp.check_refused(
    'a code with a space in it is refused, and says what a code is',
    $q$select public.platform_save_scan_kind('bank statement', 'Bank statement')$q$,
    '%lower-case letters%');

  perform pg_temp.check_refused(
    'a kind with no name is refused',
    $q$select public.platform_save_scan_kind('resit_kecil', '   ')$q$,
    '%needs a name%');

  perform pg_temp.check_refused(
    'and one of the kinds this shipped with cannot be deleted',
    $q$select public.platform_delete_scan_kind('bill')$q$,
    '%switched off%');

  perform pg_temp.check_refused(
    'nor can a kind that does not exist be deleted',
    $q$select public.platform_delete_scan_kind('tiada')$q$,
    '%No such kind%');
end $$;

-- =====================================================================
-- A kind in use is named rather than silently unfiled
--
-- And a kind that is NOT in use goes, leaving the list tidy-able. The
-- two together are what makes the foreign key's `on delete set null`
-- safe: nothing reaches it by accident.
-- =====================================================================
do $$
declare
  v_me   uuid := pg_temp.test_user();
  v_org  uuid;
  v_scan uuid;
  v_kind text;
  v_n    integer;
begin
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.a_platform_admin(v_me);
  v_org := pg_temp.test_org('Kertas Sdn Bhd');

  perform public.platform_save_scan_kind(
    'nota_kredit', 'Supplier''s credit note', null, 'purchase_document',
    'Becomes a purchase credit note.', 35, true);

  insert into public.ocr_scans
    (org_id, storage_path, provider, key_source, status, document_kind)
  values (v_org, 'scans/one.pdf', 'stub', 'platform', 'ok', 'nota_kredit')
  returning id into v_scan;

  perform pg_temp.check_refused(
    'a kind a scan is filed under is not removed, and the refusal '
    'counts them',
    $q$select public.platform_delete_scan_kind('nota_kredit')$q$,
    '%1 scan(s)%');

  -- Switched off instead, which is what the refusal said to do. The
  -- scan keeps its kind.
  perform public.platform_save_scan_kind(
    'nota_kredit', 'Supplier''s credit note', p_is_active => false);
  select document_kind into v_kind from public.ocr_scans where id = v_scan;
  perform pg_temp.check_eq(
    'switching it off leaves the scan filed under it',
    v_kind, 'nota_kredit');

  -- The scan goes; the kind can now go too.
  delete from public.ocr_scans where id = v_scan;
  perform pg_temp.check_true(
    'and with nothing filed under it, a kind an administrator added '
    'can be removed',
    public.platform_delete_scan_kind('nota_kredit'));

  select count(*) into v_n from public.scan_document_kinds
   where code = 'nota_kredit';
  perform pg_temp.check_eq('really removed', v_n, 0);
end $$;

-- =====================================================================
-- A removed kind leaves its scans standing
--
-- `on delete set null`, and the opposite of what `entity_types` does: a
-- contact's kind is part of the contact, and a scan's kind is a note
-- about a reading. Asserted against the foreign key itself, because the
-- refusal above means no ordinary path reaches this.
-- =====================================================================
do $$
declare
  v_rule "char";
begin
  select confdeltype into v_rule
    from pg_constraint
   where conrelid = 'public.ocr_scans'::regclass
     and confrelid = 'public.scan_document_kinds'::regclass;
  perform pg_temp.check_eq(
    'a kind that is removed leaves its scans, saying nothing rather '
    'than taking them with it',
    v_rule::text, 'n');

  select confupdtype into v_rule
    from pg_constraint
   where conrelid = 'public.ocr_scans'::regclass
     and confrelid = 'public.scan_document_kinds'::regclass;
  perform pg_temp.check_eq(
    'and a code that is renamed follows onto them', v_rule::text, 'c');
end $$;

-- =====================================================================
-- Whose list it is
--
-- The whole platform's. A company's owner is not a platform
-- administrator and gets the sentence that says so.
-- =====================================================================
do $$
declare
  v_them uuid := pg_temp.another_user('not.the.platform@example.test');
begin
  perform pg_temp.sign_in_as(v_them);

  perform pg_temp.check_refused(
    'an ordinary signed-in user cannot add a kind of document',
    $q$select public.platform_save_scan_kind('resit_tol', 'Toll receipt')$q$,
    '%platform administrator%', '42501');

  perform pg_temp.check_refused(
    'nor remove one',
    $q$select public.platform_delete_scan_kind('other')$q$,
    '%platform administrator%', '42501');

  -- And can read it, because it is a dropdown on their own scan
  -- result. The refusals above are about writing only.
  perform pg_temp.check_true(
    'and can read it, because it is a dropdown on their own scan',
    exists (select 1 from public.scan_document_kinds where code = 'bill'));
end $$;

-- =====================================================================
-- What the person holding the paper said it was
--
-- The kind is chosen after the reading, so it is written by its own
-- call. Four claims: it reaches the LATEST scan of the attachment and
-- not an older one, it takes a kind that has since been switched off,
-- it refuses one that does not exist, and it answers null rather than
-- raising where there is no scan to write on.
-- =====================================================================
do $$
declare
  v_me    uuid := pg_temp.test_user();
  v_org   uuid;
  v_att   uuid;
  v_old   uuid;
  v_new   uuid;
  v_wrote uuid;
  v_kind  text;
begin
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.a_platform_admin(v_me);
  v_org := pg_temp.test_org('Resit Sdn Bhd');

  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path)
  values (v_org, 'expenses', v_org, 'resit.pdf',
          v_org || '/expenses/' || v_org || '/resit.pdf')
  returning id into v_att;

  -- Two readings of the same paper: the first was rejected and read
  -- again, which is the ordinary case for a faded receipt.
  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     created_at)
  values (v_org, v_att, 'resit.pdf', 'stub', 'platform', 'ok',
          now() - interval '5 minutes')
  returning id into v_old;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status)
  values (v_org, v_att, 'resit.pdf', 'stub', 'platform', 'ok')
  returning id into v_new;

  v_wrote := public.set_scan_document_kind(v_org, v_att, 'receipt');
  perform pg_temp.check_eq(
    'the answer lands on the reading somebody was looking at, which is '
    'the latest one', v_wrote::text, v_new::text);

  select document_kind into v_kind from public.ocr_scans where id = v_new;
  perform pg_temp.check_eq('and says what it was', v_kind, 'receipt');

  -- CONTROL. The earlier reading is untouched, so the assertion above
  -- is not passing because every scan of the attachment was written.
  select document_kind into v_kind from public.ocr_scans where id = v_old;
  perform pg_temp.check_true(
    'and the reading it replaced still says nothing', v_kind is null);

  -- A kind switched off between the dialog loading and the button
  -- being pressed. Refusing here would lose the answer to a race
  -- nobody can see.
  perform public.platform_save_scan_kind(
    'quotation', 'Quotation from a supplier', p_is_active => false);
  v_wrote := public.set_scan_document_kind(v_org, v_att, 'quotation');
  select document_kind into v_kind from public.ocr_scans where id = v_new;
  perform pg_temp.check_eq(
    'a kind switched off while somebody was looking at it is still '
    'taken', v_kind, 'quotation');
  perform public.platform_save_scan_kind(
    'quotation', 'Quotation from a supplier', p_is_active => true);

  -- Cleared, which is what "I do not know" looks like.
  perform public.set_scan_document_kind(v_org, v_att, null);
  select document_kind into v_kind from public.ocr_scans where id = v_new;
  perform pg_temp.check_true(
    'and an empty answer takes it back off', v_kind is null);

  perform pg_temp.check_refused(
    'a kind that is not on the list at all is refused',
    format($q$select public.set_scan_document_kind(%L, %L, 'kertas_hantu')$q$,
           v_org, v_att),
    '%No such kind%');

  -- An attachment nobody read. The form still has a kind on it, and
  -- there is simply nothing to write it on.
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path)
  values (v_org, 'expenses', v_org, 'unread.pdf',
          v_org || '/expenses/' || v_org || '/unread.pdf')
  returning id into v_att;
  v_wrote := public.set_scan_document_kind(v_org, v_att, 'receipt');
  perform pg_temp.check_true(
    'a capture nobody read answers null rather than raising',
    v_wrote is null);
end $$;

-- =====================================================================
-- And only somebody who can write to the company
--
-- `ocr_scans` has a read policy and no write policy at all: its rows
-- are written by the functions that charge for them. This is the one
-- field on the row that is a person's opinion, and it is still not
-- everybody's.
-- =====================================================================
do $$
declare
  v_me   uuid := pg_temp.test_user();
  v_them uuid := pg_temp.another_user('outsider.scan@example.test');
  v_org  uuid;
  v_att  uuid;
begin
  perform pg_temp.sign_in_as(v_me);
  v_org := pg_temp.test_org('Kertas Rahsia Sdn Bhd');
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path)
  values (v_org, 'expenses', v_org, 'rahsia.pdf',
          v_org || '/expenses/' || v_org || '/rahsia.pdf')
  returning id into v_att;

  perform pg_temp.sign_in_as(v_them);
  perform pg_temp.check_refused(
    'somebody outside the company cannot file its scans',
    format($q$select public.set_scan_document_kind(%L, %L, 'receipt')$q$,
           v_org, v_att),
    '%Insufficient privileges%', '42501');
end $$;

-- =====================================================================
-- On the platform's live channel
--
-- `platform_live_test.dart` asserts the client's half. This is the
-- database's: a table listened for that is not published subscribes to
-- nothing, and nothing raises.
-- =====================================================================
do $$
begin
  perform pg_temp.check_true(
    'the list is published, so an administrator adding a kind reaches '
    'the person holding the paper',
    exists (
      select 1
        from pg_publication_rel pr
        join pg_publication p on p.oid = pr.prpubid
        join pg_class c on c.oid = pr.prrelid
        join pg_namespace n on n.oid = c.relnamespace
       where p.pubname = 'supabase_realtime'
         and n.nspname = 'public'
         and c.relname = 'scan_document_kinds'));
end $$;

rollback;
