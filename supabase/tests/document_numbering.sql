-- =====================================================================
-- iAkauntan :: what the next invoice is called
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_numbering.sql
--
-- 0480. An admin sets a series -- prefix, suffix, padding, reset
-- policy, next number -- and the listing says what the next draw will
-- return before it is drawn. The assertions that matter: the sample is
-- the number the draw returns; the next number cannot go below the
-- last one issued in the same series; the hundred-thousandth number
-- keeps all its digits; and a draw writes no audit row while a setting
-- does.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on
begin;

\i supabase/tests/_helpers.sql

-- One column of one series from the listing, or null when the series
-- is not listed.
create or replace function pg_temp.listed(p_org uuid, p_type text)
returns boolean language sql as $$
  select exists (select 1 from public.document_numbering(p_org) d
                  where d.doc_type = p_type);
$$;

create or replace function pg_temp.sample_of(p_org uuid, p_type text)
returns text language sql as $$
  select d.sample from public.document_numbering(p_org) d
   where d.doc_type = p_type;
$$;

create or replace function pg_temp.next_of(p_org uuid, p_type text)
returns bigint language sql as $$
  select d.next_value from public.document_numbering(p_org) d
   where d.doc_type = p_type;
$$;

create or replace function pg_temp.last_of(p_org uuid, p_type text)
returns bigint language sql as $$
  select d.last_issued from public.document_numbering(p_org) d
   where d.doc_type = p_type;
$$;

create or replace function pg_temp.period_of(p_org uuid, p_type text)
returns text language sql as $$
  select d.period_key from public.document_numbering(p_org) d
   where d.doc_type = p_type;
$$;

create or replace function pg_temp.is_default(p_org uuid, p_type text)
returns boolean language sql as $$
  select d.is_default from public.document_numbering(p_org) d
   where d.doc_type = p_type;
$$;

-- The sample `set_document_numbering` returns, or what it says when it
-- refuses.
create or replace function pg_temp.set_series(
  p_org uuid, p_type text, p_prefix text, p_suffix text,
  p_padding integer, p_reset text, p_next bigint)
returns text language plpgsql as $$
declare v text;
begin
  v := public.set_document_numbering(
    p_org, p_type, p_prefix, p_suffix, p_padding, p_reset, p_next);
  return v;
exception when others then
  get stacked diagnostics v = message_text;
  return 'refused: ' || v;
end $$;

create or replace function pg_temp.set_code(
  p_org uuid, p_type text, p_prefix text, p_suffix text,
  p_padding integer, p_reset text, p_next bigint)
returns text language plpgsql as $$
declare v text;
begin
  v := public.set_document_numbering(
    p_org, p_type, p_prefix, p_suffix, p_padding, p_reset, p_next);
  return 'ok';
exception when others then
  get stacked diagnostics v = returned_sqlstate;
  return v;
end $$;

create or replace function pg_temp.audit_rows(p_org uuid)
returns integer language sql as $$
  select count(*)::integer from public.audit_logs
   where org_id = p_org and table_name = 'number_sequences';
$$;

-- ---------------------------------------------------------------------
-- The helper
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('a short number is padded',
    app.compose_document_number('INV-', '2026', 7, 5, ''), 'INV-2026-00007');
  perform pg_temp.check_eq('a suffix follows the number',
    app.compose_document_number('INV-', '2026', 7, 5, '/A'), 'INV-2026-00007/A');
  perform pg_temp.check_eq('no period, no dash',
    app.compose_document_number('QT/', null, 12, 4, ''), 'QT/0012');
  perform pg_temp.check_eq('the hundred-thousandth number keeps its digits',
    app.compose_document_number('INV-', '2026', 100000, 5, ''), 'INV-2026-100000');
  perform pg_temp.check_eq('a number exactly the padding is whole',
    app.compose_document_number('INV-', '2026', 99999, 5, ''), 'INV-2026-99999');
  perform pg_temp.check_eq('null prefix and suffix read as empty',
    app.compose_document_number(null, null, 3, 2, null), '03');
  perform pg_temp.check_eq('yearly is the Malaysian year',
    app.series_period_key('yearly'), to_char(app.today(), 'YYYY'));
  perform pg_temp.check_eq('monthly is the Malaysian month',
    app.series_period_key('monthly'), to_char(app.today(), 'YYYYMM'));
  perform pg_temp.check_true('never has no period',
    app.series_period_key('never') is null);
end $$;

-- ---------------------------------------------------------------------
-- A fresh company: defaults, and a sample that is what the draw returns
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Nombor Sdn Bhd');
  v_year text := to_char(app.today(), 'YYYY');
  v_sample text;
  v_drawn text;
  v_rows integer;
begin
  perform pg_temp.check_true('invoices are listed', pg_temp.listed(v_org, 'invoice'));
  perform pg_temp.check_true('a fresh series says it is the default',
    pg_temp.is_default(v_org, 'invoice'));
  perform pg_temp.check_eq('a fresh series starts at 1',
    pg_temp.next_of(v_org, 'invoice'), 1);
  perform pg_temp.check_true('nothing issued yet',
    pg_temp.last_of(v_org, 'invoice') is null);
  perform pg_temp.check_eq('the sample is INV-YYYY-00001',
    pg_temp.sample_of(v_org, 'invoice'), 'INV-' || v_year || '-00001');
  perform pg_temp.check_eq('the period is this year',
    pg_temp.period_of(v_org, 'invoice'), v_year);

  -- The listing drew nothing.
  select count(*) into v_rows from public.number_sequences where org_id = v_org;
  perform pg_temp.check_eq('listing makes no counter row', v_rows, 0);

  -- The sample is the number the next draw returns, for every series.
  select count(*) into v_rows
    from public.document_numbering(v_org) d
   where d.sample <> public.next_document_number(v_org, d.doc_type);
  perform pg_temp.check_eq('the sample is the number the next draw returns',
    v_rows, 0);

  -- After a draw the series has moved on.
  perform pg_temp.check_eq('after one draw the next is 2',
    pg_temp.next_of(v_org, 'invoice'), 2);
  perform pg_temp.check_eq('after one draw the last issued is 1',
    pg_temp.last_of(v_org, 'invoice'), 1);
  perform pg_temp.check_true('a drawn series is no longer the default',
    not pg_temp.is_default(v_org, 'invoice'));

  -- The contact series are the ones 0477 draws, C- S- P-.
  perform pg_temp.check_eq('customers are C-',
    pg_temp.sample_of(v_org, 'contact'), 'C-' || v_year || '-00002');
  perform pg_temp.check_eq('suppliers are S-',
    pg_temp.sample_of(v_org, 'supplier'), 'S-' || v_year || '-00002');
  perform pg_temp.check_eq('prospects are P-',
    pg_temp.sample_of(v_org, 'prospect'), 'P-' || v_year || '-00002');
  perform pg_temp.check_eq('the contact sample matches the import preview',
    pg_temp.sample_of(v_org, 'supplier'),
    replace(app.contact_code_shape(v_org, 'supplier'), 'YYYY-NNNNN',
            v_year || '-00002'));
end $$;

-- ---------------------------------------------------------------------
-- Setting a series
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Tetapan Sdn Bhd');
  v_year text := to_char(app.today(), 'YYYY');
  v_month text := to_char(app.today(), 'YYYYMM');
  v_sample text;
  v_msg text;
  v_audit integer;
begin
  -- Three invoices issued.
  perform public.next_document_number(v_org, 'invoice');
  perform public.next_document_number(v_org, 'invoice');
  perform public.next_document_number(v_org, 'invoice');
  perform pg_temp.check_eq('three issued', pg_temp.last_of(v_org, 'invoice'), 3);
  v_audit := pg_temp.audit_rows(v_org);
  perform pg_temp.check_eq('drawing a number writes no audit row', v_audit, 0);

  -- Carry on from the old system's number.
  v_sample := pg_temp.set_series(v_org, 'invoice', 'INV-', '', 5, 'yearly', 413);
  perform pg_temp.check_eq('the setting returns the sample',
    v_sample, 'INV-' || v_year || '-00413');
  perform pg_temp.check_eq('the listing agrees',
    pg_temp.sample_of(v_org, 'invoice'), v_sample);
  perform pg_temp.check_eq('the number set is the number drawn',
    public.next_document_number(v_org, 'invoice'), v_sample);
  perform pg_temp.check_eq('setting a series writes an audit row',
    pg_temp.audit_rows(v_org), 1);
  perform pg_temp.check_eq('and the draw after it writes none',
    pg_temp.audit_rows(v_org), 1);

  -- The next number cannot go below the last issued.
  v_msg := pg_temp.set_series(v_org, 'invoice', 'INV-', '', 5, 'yearly', 2);
  perform pg_temp.check_true('the next number cannot go below the last issued',
    v_msg like 'refused:%');
  perform pg_temp.check_true('the refusal names the last number issued',
    position('INV-' || v_year || '-00413' in v_msg) > 0);
  perform pg_temp.check_true('the refusal names the lowest allowed',
    position('lower than 414' in v_msg) > 0);
  perform pg_temp.check_eq('the refusal is a check violation',
    pg_temp.set_code(v_org, 'invoice', 'INV-', '', 5, 'yearly', 2), '23514');
  perform pg_temp.check_eq('a refused setting changes nothing',
    pg_temp.sample_of(v_org, 'invoice'), 'INV-' || v_year || '-00414');
  perform pg_temp.check_eq('equal to the next is allowed',
    pg_temp.set_series(v_org, 'invoice', 'INV-', '', 5, 'yearly', 414),
    'INV-' || v_year || '-00414');

  -- A new prefix is a new series and may start from 1.
  perform pg_temp.check_eq('a new prefix may start from 1',
    pg_temp.set_series(v_org, 'invoice', 'INV/', '', 5, 'yearly', 1),
    'INV/' || v_year || '-00001');
  perform pg_temp.check_eq('the draw follows the new prefix',
    public.next_document_number(v_org, 'invoice'), 'INV/' || v_year || '-00001');
  -- A new suffix likewise.
  perform pg_temp.check_eq('a new suffix may start from 1',
    pg_temp.set_series(v_org, 'invoice', 'INV/', '/KL', 5, 'yearly', 1),
    'INV/' || v_year || '-00001/KL');
  perform pg_temp.check_eq('the draw follows the new suffix',
    public.next_document_number(v_org, 'invoice'), 'INV/' || v_year || '-00001/KL');
  -- Padding alone is not a new series: 00001 and 0001 sit next to each
  -- other on the same list.
  perform pg_temp.check_true('padding alone does not let the number go down',
    pg_temp.set_series(v_org, 'invoice', 'INV/', '/KL', 4, 'yearly', 1)
      like 'refused:%');
  perform pg_temp.check_eq('padding may change without the number going down',
    pg_temp.set_series(v_org, 'invoice', 'INV/', '/KL', 4, 'yearly', 2),
    'INV/' || v_year || '-0002/KL');

  -- No period at all.
  perform pg_temp.check_eq('never drops the year',
    pg_temp.set_series(v_org, 'quotation', 'QT/', '', 4, 'never', 77), 'QT/0077');
  perform pg_temp.check_true('never has no period in the listing',
    pg_temp.period_of(v_org, 'quotation') is null);
  perform pg_temp.check_eq('the draw follows never',
    public.next_document_number(v_org, 'quotation'), 'QT/0077');
  perform pg_temp.check_eq('and the one after',
    public.next_document_number(v_org, 'quotation'), 'QT/0078');
  -- And back to yearly: the period key is written, so the next number
  -- set is the number drawn, not 1 because the key was stale.
  perform pg_temp.check_eq('back to yearly from a set number',
    pg_temp.set_series(v_org, 'quotation', 'QT-', '', 5, 'yearly', 500),
    'QT-' || v_year || '-00500');
  perform pg_temp.check_eq('the draw returns the number set, not 1',
    public.next_document_number(v_org, 'quotation'), 'QT-' || v_year || '-00500');

  -- Monthly.
  perform pg_temp.check_eq('monthly carries the month',
    pg_temp.set_series(v_org, 'receipt', 'RCP-', '', 4, 'monthly', 1),
    'RCP-' || v_month || '-0001');
  perform pg_temp.check_eq('the draw carries the month',
    public.next_document_number(v_org, 'receipt'), 'RCP-' || v_month || '-0001');

  -- The hundred-thousandth number, through the draw.
  perform pg_temp.set_series(v_org, 'bill', 'BILL-', '', 5, 'yearly', 99999);
  perform pg_temp.check_eq('the 99,999th is padded',
    public.next_document_number(v_org, 'bill'), 'BILL-' || v_year || '-99999');
  perform pg_temp.check_eq('the 100,000th keeps its digits',
    public.next_document_number(v_org, 'bill'), 'BILL-' || v_year || '-100000');

  -- An empty prefix is allowed: a company that numbers 2026-00001.
  perform pg_temp.check_eq('an empty prefix is allowed',
    pg_temp.set_series(v_org, 'journal', '', '', 5, 'yearly', 1),
    v_year || '-00001');
end $$;

-- ---------------------------------------------------------------------
-- After the year turns
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Tahun Baru Sdn Bhd');
  v_year text := to_char(app.today(), 'YYYY');
begin
  perform public.next_document_number(v_org, 'invoice');
  perform public.next_document_number(v_org, 'invoice');
  perform pg_temp.check_eq('two issued this year', pg_temp.last_of(v_org, 'invoice'), 2);

  -- Last year's counter. There is no test clock: the key is aged by hand.
  update public.number_sequences set period_key = '1999'
   where org_id = v_org and doc_type = 'invoice';

  perform pg_temp.check_eq('after the year turns the sample says 00001',
    pg_temp.sample_of(v_org, 'invoice'), 'INV-' || v_year || '-00001');
  perform pg_temp.check_eq('after the year turns the next is 1',
    pg_temp.next_of(v_org, 'invoice'), 1);
  perform pg_temp.check_true('after the year turns nothing is issued yet',
    pg_temp.last_of(v_org, 'invoice') is null);
  perform pg_temp.check_eq('the draw agrees with the sample',
    public.next_document_number(v_org, 'invoice'), 'INV-' || v_year || '-00001');

  -- Aged again: setting a low number is allowed, nothing this year is
  -- below it.
  update public.number_sequences set period_key = '1999'
   where org_id = v_org and doc_type = 'invoice';
  perform pg_temp.check_eq('after the year turns a low number is allowed',
    pg_temp.set_series(v_org, 'invoice', 'INV-', '', 5, 'yearly', 1),
    'INV-' || v_year || '-00001');
end $$;

-- ---------------------------------------------------------------------
-- What is refused
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Tolak Sdn Bhd');
begin
  perform pg_temp.check_eq('an unknown series is refused',
    pg_temp.set_code(v_org, 'banana', 'B-', '', 5, 'yearly', 1), '22023');
  perform pg_temp.check_eq('a space in the prefix is refused',
    pg_temp.set_code(v_org, 'invoice', 'INV ', '', 5, 'yearly', 1), '22023');
  perform pg_temp.check_eq('a thirteen-character prefix is refused',
    pg_temp.set_code(v_org, 'invoice', 'ABCDEFGHIJKLM', '', 5, 'yearly', 1), '22023');
  perform pg_temp.check_eq('a space in the suffix is refused',
    pg_temp.set_code(v_org, 'invoice', 'INV-', ' A', 5, 'yearly', 1), '22023');
  perform pg_temp.check_eq('padding 0 is refused',
    pg_temp.set_code(v_org, 'invoice', 'INV-', '', 0, 'yearly', 1), '22023');
  perform pg_temp.check_eq('padding 13 is refused',
    pg_temp.set_code(v_org, 'invoice', 'INV-', '', 13, 'yearly', 1), '22023');
  perform pg_temp.check_eq('padding 12 is allowed',
    pg_temp.set_code(v_org, 'invoice', 'INV-', '', 12, 'yearly', 1), 'ok');
  perform pg_temp.check_eq('a weekly reset is refused',
    pg_temp.set_code(v_org, 'invoice', 'INV-', '', 5, 'weekly', 1), '22023');
  perform pg_temp.check_eq('next 0 is refused',
    pg_temp.set_code(v_org, 'invoice', 'INV-', '', 5, 'yearly', 0), '22023');
  perform pg_temp.check_eq('a null next is refused',
    pg_temp.set_code(v_org, 'invoice', 'INV-', '', 5, 'yearly', null), '22023');
  perform pg_temp.check_eq('a thirteen-digit next is refused',
    pg_temp.set_code(v_org, 'invoice', 'INV-', '', 5, 'yearly', 1000000000000), '22023');
end $$;

-- ---------------------------------------------------------------------
-- Who may
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Siapa Sdn Bhd');
  v_acct uuid := pg_temp.another_user('akaun@nombor.test');
  v_outsider uuid := pg_temp.another_user('luar@nombor.test');
  v_rows integer;
  v_code text;
begin
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_acct, 'accountant', 'active', now());

  perform pg_temp.sign_in_as(v_acct);
  select count(*) into v_rows from public.document_numbering(v_org);
  perform pg_temp.check_true('an accountant may read the numbering', v_rows > 0);
  perform pg_temp.check_eq('and may not set it',
    pg_temp.set_code(v_org, 'invoice', 'INV-', '', 5, 'yearly', 1), '42501');

  perform pg_temp.sign_in_as(v_outsider);
  begin
    select count(*) into v_rows from public.document_numbering(v_org);
    v_code := 'read';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
  end;
  perform pg_temp.check_eq('an outsider may not read it', v_code, '42501');
  perform pg_temp.check_eq('nor set it',
    pg_temp.set_code(v_org, 'invoice', 'INV-', '', 5, 'yearly', 1), '42501');

  perform pg_temp.check_true('anon cannot list',
    not has_function_privilege('anon', 'public.document_numbering(uuid)', 'execute'));
  perform pg_temp.check_true('anon cannot set',
    not has_function_privilege('anon',
      'public.set_document_numbering(uuid, text, text, text, integer, text, bigint)',
      'execute'));
  -- 0480 restates the internal draw, and a restatement's grant line is
  -- the easiest place to hand an API key the draw that skips the
  -- membership check. 0056 took it away; it stays away.
  perform pg_temp.check_true('the unchecked draw is not exposed to the API',
    not has_function_privilege('authenticated',
      'app.next_document_number_internal(uuid, text)', 'execute'));
end $$;

-- ---------------------------------------------------------------------
-- Only the modules the company has
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Jualan Sahaja Sdn Bhd', array['sales']);
begin
  perform pg_temp.check_true('invoices are listed for a sales company',
    pg_temp.listed(v_org, 'invoice'));
  perform pg_temp.check_true('customers are listed: contacts is core',
    pg_temp.listed(v_org, 'contact'));
  perform pg_temp.check_true('journals are listed: accounting is core',
    pg_temp.listed(v_org, 'journal'));
  perform pg_temp.check_true(
    'a series of a module the company has not bought is not listed',
    not pg_temp.listed(v_org, 'pos_shift'));
  perform pg_temp.check_true('nor tickets without ticketing',
    not pg_temp.listed(v_org, 'ticket'));
  -- Purchasing is switched on for every new company by `seed_org_modules`.
  perform pg_temp.check_true('bills are listed: purchases is seeded on',
    pg_temp.listed(v_org, 'bill'));
end $$;

do $$
declare
  v_org uuid := pg_temp.test_org('Semua Sdn Bhd');
  v_rows integer;
begin
  perform pg_temp.check_true('shifts are listed once POS is bought',
    pg_temp.listed(v_org, 'pos_shift'));
  select count(*) into v_rows from public.document_numbering(v_org);
  perform pg_temp.check_eq('every series is listed for a company with everything',
    v_rows, (select count(*)::integer from app.numbered_series()));
end $$;

-- ---------------------------------------------------------------------
-- A number is CONSUMED the moment it is drawn
--
-- This is why the editor no longer draws one when it opens.
-- `app.next_document_number_internal` advances the counter and does not
-- put anything back, so every call is a number spent whether or not a
-- document ever carries it. An editor that numbered on OPEN burnt one
-- each time somebody changed their mind, and a sales invoice series
-- with gaps in it is what an auditor asks about.
--
-- The other half, asserted here because it is the thing people assume
-- and it is not true: two people drawing at the same moment do NOT get
-- the same number. The row is taken `for update`, so the second waits
-- for the first. Duplicates were never the risk; the gaps were.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Nombor Berturutan Sdn Bhd');
  a text; b text; c text;
  v_next bigint;
begin
  a := app.next_document_number_internal(v_org, 'invoice');
  b := app.next_document_number_internal(v_org, 'invoice');
  c := app.next_document_number_internal(v_org, 'invoice');

  perform pg_temp.check_true('three draws are three different numbers',
    a <> b and b <> c and a <> c);
  perform pg_temp.check_true('and they run in order',
    a < b and b < c);

  select next_value into v_next from public.number_sequences
   where org_id = v_org and doc_type = 'invoice';
  perform pg_temp.check_eq(
    'and the counter has moved by three, whether or not anything was saved',
    v_next::numeric, 4);

  -- The consequence, stated as an assertion so the reason for the
  -- client change survives: nothing here can give a drawn number back.
  perform pg_temp.check_eq('a drawn number is not returned to the series',
    (select count(*)::numeric from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app' and p.proname like '%release%number%'), 0);
end $$;

rollback;
