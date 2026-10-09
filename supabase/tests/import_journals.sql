-- =====================================================================
-- iAkauntan :: the journals that came before
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/import_journals.sql
--
-- `0633`. The last part of G6, and the one that breaks the rule the
-- other three importers keep: it POSTS. A journal has no draft state
-- the rest of this database understands -- the reports filter on
-- `posted` but `app.apply_account_balance` moves
-- `accounts.current_balance` whatever the status is -- so a draft
-- journal would be absent from the trial balance and present on the
-- chart of accounts.
--
-- Four things have to hold:
--
--   * **each entry balances**, reported with both totals and the
--     difference. `app.assert_gl_balanced` is deferred to commit and
--     would say one thing about one entry and nothing about the other
--     four hundred.
--   * **a line is a debit or a credit**, never both. A line carrying
--     both is two lines merged, and netting them hides whichever is
--     smaller from every report that looks at turnover.
--   * **a heading is not an account.** Posting to a group account puts
--     money where no report adds it up.
--   * **the dry run writes nothing**, which is what replaces the draft.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.j_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.j_line(
  p_no text, p_date text, p_account text, p_desc text,
  p_debit text default null, p_credit text default null)
returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'entry_no', p_no, 'entry_date', p_date, 'account_code', p_account,
    'description', p_desc, 'debit', p_debit, 'credit', p_credit));
$$;

-- ---------------------------------------------------------------------
-- 1. A balanced file posts, and the old number is kept
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.j_org('Jurnal Lama Sdn Bhd');
  v_out jsonb;
  v_before numeric;
begin
  select current_balance into v_before from public.accounts
   where org_id = v_org and code = '6900';

  v_out := public.import_journals(v_org, jsonb_build_array(
    pg_temp.j_line('JV-0088', '2026-02-01', '6900', 'Sundry', '400', null),
    pg_temp.j_line('JV-0088', '2026-02-01', '1110', 'Sundry', null, '400'),
    pg_temp.j_line('JV-0089', '2026-02-02', '6900', 'More', '150', null),
    pg_temp.j_line('JV-0089', '2026-02-02', '1110', 'More', null, '150')
  ), true);

  perform pg_temp.check_eq('two entries came out of four rows',
    (v_out ->> 'documents')::integer, 2);
  perform pg_temp.check_eq('and nothing was wrong with the file',
    (v_out ->> 'errors')::integer, 0);

  -- It POSTS. That is the departure, and it is asserted rather than
  -- described.
  perform pg_temp.check_eq('and they are posted, not drafts',
    (select count(*) from public.gl_entries
      where org_id = v_org and import_source = 'journals'
        and status <> 'posted'), 0);
  perform pg_temp.check_eq('the ledger moved by what the file said',
    (select current_balance from public.accounts
      where org_id = v_org and code = '6900'), v_before + 550);

  -- `entry_no` is this ledger's own sequence: the numbers it issues
  -- must not have another system's holes in them.
  perform pg_temp.check_true('the entry gets this ledger''s own number',
    (select entry_no not in ('JV-0088', 'JV-0089') from public.gl_entries
      where org_id = v_org and import_ref = 'JV-0088'));
  -- And the old one is where somebody looking for it will find it.
  perform pg_temp.check_eq('and the old number is on the reference',
    (select reference from public.gl_entries
      where org_id = v_org and import_ref = 'JV-0088'), 'JV-0088');
end $$;

-- ---------------------------------------------------------------------
-- 2. An entry that does not balance
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.j_org('Tidak Seimbang Sdn Bhd');
  v_out jsonb;
  v_msg text;
begin
  v_out := public.import_journals(v_org, jsonb_build_array(
    pg_temp.j_line('JV-1', '2026-02-01', '6900', 'One', '400', null),
    pg_temp.j_line('JV-1', '2026-02-01', '1110', 'One', null, '350')
  ), false);

  perform pg_temp.check_eq('it is reported', (v_out ->> 'errors')::integer, 1);

  v_msg := (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
             where (x ->> 'row')::integer = 1);
  -- Both totals and the difference. "Does not balance" sends somebody
  -- to add up a column by hand.
  perform pg_temp.check_true('with both totals and the difference',
    v_msg = 'JV-1 does not balance: 400.00 in debits against 350.00 in credits, 50.00 out.');
  -- Against the FIRST row of the entry, which is the line somebody
  -- scrolls to.
  perform pg_temp.check_true('and against the first row of the entry',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 2) is null);

  perform pg_temp.check_refused(
    'and the file is refused rather than half posted',
    format('select public.import_journals(%L, %L::jsonb, true)',
           v_org, jsonb_build_array(
             pg_temp.j_line('JV-1', '2026-02-01', '6900', 'One', '400', null),
             pg_temp.j_line('JV-1', '2026-02-01', '1110', 'One', null, '350')
           )::text),
    '%Nothing was imported%', '22023');
  perform pg_temp.check_eq('so nothing reached the ledger',
    (select count(*) from public.gl_entries
      where org_id = v_org and import_source = 'journals'), 0);

  -- A balanced entry in the same file as an unbalanced one goes
  -- nowhere either: all or nothing.
  perform pg_temp.check_refused(
    'and a good entry beside a bad one goes with it',
    format('select public.import_journals(%L, %L::jsonb, true)',
           v_org, jsonb_build_array(
             pg_temp.j_line('JV-2', '2026-02-01', '6900', 'Good', '100', null),
             pg_temp.j_line('JV-2', '2026-02-01', '1110', 'Good', null, '100'),
             pg_temp.j_line('JV-3', '2026-02-01', '6900', 'Bad', '100', null)
           )::text),
    '%Nothing was imported%', '22023');
  perform pg_temp.check_eq('nothing at all',
    (select count(*) from public.gl_entries
      where org_id = v_org and import_source = 'journals'), 0);
end $$;

-- ---------------------------------------------------------------------
-- 3. What a line may carry
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.j_org('Baris Jurnal Sdn Bhd');
  v_out jsonb;
  v_group text;
begin
  -- A heading, which every seeded chart has.
  select code into v_group from public.accounts
   where org_id = v_org and is_group limit 1;

  v_out := public.import_journals(v_org, jsonb_build_array(
    pg_temp.j_line(null, '2026-02-01', '6900', 'No number', '100', null),
    pg_temp.j_line('JV-4', 'not a date', '6900', 'Bad date', '100', null),
    pg_temp.j_line('JV-5', '2026-02-01', 'NOSUCH', 'No account', '100', null),
    pg_temp.j_line('JV-6', '2026-02-01', v_group, 'A heading', '100', null),
    pg_temp.j_line('JV-7', '2026-02-01', '6900', 'Both', '100', '100'),
    pg_temp.j_line('JV-8', '2026-02-01', '6900', 'Neither', null, null),
    pg_temp.j_line('JV-9', '2026-02-01', '6900', 'Negative', '-100', null)
  ), false);

  perform pg_temp.check_eq('every one of them is a problem',
    (v_out ->> 'errors')::integer, 7);
  perform pg_temp.check_true('a missing number says what it is for',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 1) like '%groups the lines%');
  perform pg_temp.check_true('an unreadable date names the entry',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 2) like 'JV-4 has no date%');
  perform pg_temp.check_true('an unknown account says to import the chart',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 3) like '%Import the chart first.');
  -- The one that would otherwise post money where no report adds it up.
  perform pg_temp.check_true('a heading is not an account you can post to',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 4) like '% is a heading, not an account you can post to.%');
  perform pg_temp.check_true('a line is a debit or a credit, not both',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 5) = 'This line has both a debit and a credit. A line is one or the other.');
  perform pg_temp.check_true('and not neither',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 6) = 'This line is for nothing.');
  perform pg_temp.check_true('a negative debit is a credit',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 7) like 'A negative debit is a credit.%');
end $$;

-- A retired account is refused too: it is off the chart screen, and
-- posting to it puts a balance somewhere nobody is looking.
do $$
declare
  v_org uuid := pg_temp.j_org('Akaun Bersara Sdn Bhd');
  v_out jsonb;
begin
  update public.accounts set is_active = false
   where org_id = v_org and code = '6900';

  v_out := public.import_journals(v_org, jsonb_build_array(
    pg_temp.j_line('JV-10', '2026-02-01', '6900', 'Retired', '100', null),
    pg_temp.j_line('JV-10', '2026-02-01', '1110', 'Retired', null, '100')
  ), false);
  perform pg_temp.check_true('a retired account is refused',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 1) like '6900 has been retired.');
end $$;

-- ---------------------------------------------------------------------
-- 4. The dry run is what replaces the draft
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.j_org('Cuba Jurnal Sdn Bhd');
  v_out jsonb;
  v_before numeric;
begin
  select current_balance into v_before from public.accounts
   where org_id = v_org and code = '6900';

  v_out := public.import_journals(v_org, jsonb_build_array(
    pg_temp.j_line('JV-11', '2026-02-01', '6900', 'Trial', '900', null),
    pg_temp.j_line('JV-11', '2026-02-01', '1110', 'Trial', null, '900')
  ), false);

  perform pg_temp.check_eq('a dry run reports every row',
    jsonb_array_length(v_out -> 'rows'), 2);
  perform pg_temp.check_eq('and creates nothing',
    (select count(*) from public.gl_entries
      where org_id = v_org and import_source = 'journals'), 0);
  -- The assertion that matters for THIS importer, because it posts:
  -- a dry run must not move the ledger by a sen.
  perform pg_temp.check_eq('and moves nothing in the ledger',
    (select current_balance from public.accounts
      where org_id = v_org and code = '6900'), v_before);
end $$;

-- ---------------------------------------------------------------------
-- 5. Run it twice and nothing happens twice
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.j_org('Sekali Jurnal Sdn Bhd');
  v_file jsonb := jsonb_build_array(
    pg_temp.j_line('JV-12', '2026-02-01', '6900', 'Once', '200', null),
    pg_temp.j_line('JV-12', '2026-02-01', '1110', 'Once', null, '200'));
  v_out  jsonb;
begin
  perform public.import_journals(v_org, v_file, true);
  perform pg_temp.check_eq('the first run lands',
    (select count(*) from public.gl_entries
      where org_id = v_org and import_source = 'journals'), 1);

  v_out := public.import_journals(v_org, v_file, false);
  perform pg_temp.check_true('and the second is refused by name',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 1) like 'JV-12 was imported before.%');

  perform pg_temp.check_refused(
    'and committing it changes nothing',
    format('select public.import_journals(%L, %L::jsonb, true)',
           v_org, v_file::text),
    '%Nothing was imported%', '22023');
  perform pg_temp.check_eq('there is still one of it',
    (select count(*) from public.gl_entries
      where org_id = v_org and import_source = 'journals'), 1);
end $$;

-- ---------------------------------------------------------------------
-- 6. One date per entry, and posting permission
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.j_org('Kebenaran Jurnal Sdn Bhd');
  v_out   jsonb;
  v_clerk uuid := pg_temp.another_user('clerk2@iakauntan.test');
begin
  v_out := public.import_journals(v_org, jsonb_build_array(
    pg_temp.j_line('JV-13', '2026-02-01', '6900', 'One', '100', null),
    pg_temp.j_line('JV-13', '2026-02-09', '1110', 'Two', null, '100')
  ), false);
  perform pg_temp.check_true('a second date for one entry is caught',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 2)
      = 'Row 1 dates JV-13 2026-02-01 and this row dates it 2026-02-09.');

  -- `can_post`, not `can_write`: this one puts entries in the ledger.
  -- A sales clerk may write a contact and may not post a journal.
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'sales');
  perform pg_temp.sign_in_as(v_clerk);

  perform pg_temp.check_refused(
    'somebody who may write but not post cannot import journals',
    format('select public.import_journals(%L, %L::jsonb, true)',
           v_org, jsonb_build_array(
             pg_temp.j_line('JV-14', '2026-02-01', '6900', 'x', '1', null),
             pg_temp.j_line('JV-14', '2026-02-01', '1110', 'x', null, '1')
           )::text),
    '%not permitted to import journals%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- What a committed line carries, rule by rule
--
-- Every file above names accounts by number, which has no case, names
-- no contact, gives every line its entry's description and every
-- entry a description, and has nothing below a sen. So an importer
-- that looked codes up case-sensitively, dropped a line's own
-- description, left an undescribed entry blank or posted a fraction of
-- a sen built the same ledger -- and nothing read the `committed`
-- flag the screen shows.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.j_org('Baris Demi Baris Sdn Bhd');
  v_sus  uuid;
  v_cust uuid;
  v_gone uuid;
  v_out  jsonb;
  v_e1   uuid;
  v_other uuid;
begin
  -- An account and a contact whose codes have letters in them, so
  -- their case can be wrong in the file.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, parent_id, sort_order)
  select a.org_id, 'SUS-A', 'Suspense, migration', a.account_type,
         a.account_subtype, false, a.parent_id, a.sort_order + 1
    from public.accounts a where a.org_id = v_org and a.code = '6900'
  returning id into v_sus;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST-A', 'Syarikat Lama', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type, deleted_at)
  values (v_org, 'GONE-1', 'Dahulu Sdn Bhd', 'customer', now()) returning id into v_gone;
  perform pg_temp.allow_many_companies();
  v_other := pg_temp.j_org('Syarikat Lain Sdn Bhd');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  v_out := public.import_journals(v_org, jsonb_build_array(
    jsonb_build_object('entry_no', 'JV-A1', 'entry_date', '2026-03-01',
      'account_code', 'sus-a', 'description', 'Alpha', 'debit', '100.004',
      'contact_code', 'cust-a'),
    jsonb_build_object('entry_no', 'JV-A1', 'entry_date', '2026-03-01',
      'account_code', '1110', 'description', 'Beta', 'credit', '100.00'),
    jsonb_build_object('entry_no', 'JV-A2', 'entry_date', '2026-03-02',
      'account_code', '6900', 'debit', '20.00'),
    jsonb_build_object('entry_no', 'JV-A2', 'entry_date', '2026-03-02',
      'account_code', '1110', 'credit', '19.996')
  ), false);
  perform pg_temp.check_true('a preview says it committed nothing',
    not (v_out ->> 'committed')::boolean);

  v_out := public.import_journals(v_org, jsonb_build_array(
    jsonb_build_object('entry_no', 'JV-A1', 'entry_date', '2026-03-01',
      'account_code', 'sus-a', 'description', 'Alpha', 'debit', '100.004',
      'contact_code', 'cust-a'),
    jsonb_build_object('entry_no', 'JV-A1', 'entry_date', '2026-03-01',
      'account_code', '1110', 'description', 'Beta', 'credit', '100.00'),
    jsonb_build_object('entry_no', 'JV-A2', 'entry_date', '2026-03-02',
      'account_code', '6900', 'debit', '20.00'),
    jsonb_build_object('entry_no', 'JV-A2', 'entry_date', '2026-03-02',
      'account_code', '1110', 'credit', '19.996')
  ), true);
  perform pg_temp.check_true('a commit says it committed',
    (v_out ->> 'committed')::boolean);
  select id into v_e1 from public.gl_entries
   where org_id = v_org and import_ref = 'JV-A1';

  perform pg_temp.check_eq('an account code in the wrong case finds the account',
    (select l.debit from public.gl_lines l
      where l.entry_id = v_e1 and l.account_id = v_sus), 100.00);
  perform pg_temp.check_true('and a contact code in the wrong case finds the contact',
    (select l.contact_id from public.gl_lines l
      where l.entry_id = v_e1 and l.account_id = v_sus) = v_cust);
  perform pg_temp.check_eq('each line keeps its own description',
    (select l.description from public.gl_lines l
      where l.entry_id = v_e1 and l.account_id <> v_sus), 'Beta');
  perform pg_temp.check_eq('an entry with no description is named for its old number',
    (select e.description from public.gl_entries e
      where e.org_id = v_org and e.import_ref = 'JV-A2'), 'Imported journal JV-A2');
  perform pg_temp.check_eq('and a credit below the sen is rounded to it',
    (select sum(l.credit) from public.gl_lines l
       join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_org and e.import_ref = 'JV-A2'), 20.00);

  -- `0774`. A contact code that is given has to be somebody: a typo, a
  -- contact since deleted, or another company's code is reported on
  -- the preview and refuses the commit, as the sales, purchase and
  -- opening-balance importers do. Before it, the code was dropped and
  -- the line posted with no customer on it.
  v_out := public.import_journals(v_org, jsonb_build_array(
    jsonb_build_object('entry_no', 'JV-A3', 'entry_date', '2026-03-03',
      'account_code', '6900', 'debit', '5.00', 'contact_code', 'CUST-Z'),
    jsonb_build_object('entry_no', 'JV-A3', 'entry_date', '2026-03-03',
      'account_code', '1110', 'credit', '5.00')), false);
  perform pg_temp.check_eq('a contact code that matches nobody is reported on its row',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 1),
    'There is no customer or supplier with the code CUST-Z. Import the '
    'contacts first, or leave the column empty.');
  perform pg_temp.check_refused('and the commit is refused',
    format('select public.import_journals(%L, %L::jsonb, true)', v_org,
      jsonb_build_array(
        jsonb_build_object('entry_no', 'JV-A3', 'entry_date', '2026-03-03',
          'account_code', '6900', 'debit', '5.00', 'contact_code', 'CUST-Z'),
        jsonb_build_object('entry_no', 'JV-A3', 'entry_date', '2026-03-03',
          'account_code', '1110', 'credit', '5.00'))::text),
    'Nothing was imported: 2 of 2 rows have a problem.%', '22023');

  v_out := public.import_journals(v_org, jsonb_build_array(
    jsonb_build_object('entry_no', 'JV-A4', 'entry_date', '2026-03-04',
      'account_code', '6900', 'debit', '5.00', 'contact_code', 'gone-1'),
    jsonb_build_object('entry_no', 'JV-A4', 'entry_date', '2026-03-04',
      'account_code', '1110', 'credit', '5.00')), false);
  perform pg_temp.check_eq('so is a contact that has been deleted',
    (select x ->> 'status' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 1), 'error');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_other, 'THEIRS-1', 'Pelanggan Mereka', 'customer');
  v_out := public.import_journals(v_org, jsonb_build_array(
    jsonb_build_object('entry_no', 'JV-A5', 'entry_date', '2026-03-05',
      'account_code', '6900', 'debit', '5.00', 'contact_code', 'THEIRS-1'),
    jsonb_build_object('entry_no', 'JV-A5', 'entry_date', '2026-03-05',
      'account_code', '1110', 'credit', '5.00')), false);
  perform pg_temp.check_eq('and so is another company''s customer',
    (select x ->> 'status' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 1), 'error');

  -- An empty column is still a line on an account nobody owes.
  v_out := public.import_journals(v_org, jsonb_build_array(
    jsonb_build_object('entry_no', 'JV-A6', 'entry_date', '2026-03-06',
      'account_code', '6900', 'debit', '5.00', 'contact_code', '   '),
    jsonb_build_object('entry_no', 'JV-A6', 'entry_date', '2026-03-06',
      'account_code', '1110', 'credit', '5.00')), false);
  perform pg_temp.check_eq('while a blank contact column is no problem at all',
    (v_out ->> 'errors')::integer, 0);
  perform pg_temp.check_eq('and nothing deleted was ever put on a line',
    (select count(*) from public.gl_lines l where l.contact_id = v_gone), 0);
end $$;

rollback;
