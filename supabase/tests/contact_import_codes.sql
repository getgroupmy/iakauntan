-- =====================================================================
-- iAkauntan :: a contact file with no code column
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/contact_import_codes.sql
--
-- 0479. A row with no code is coded on import from the series of its
-- type -- C-, S- or P-YYYY-NNNNN -- and the preview says so without
-- drawing one. The assertion that matters is the one about the typed
-- code that sits where the counter lands next: the typed row keeps its
-- number and the drawn row goes past it, instead of the whole file
-- failing on the unique index.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on
begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.contact_count(p_org uuid)
returns integer language sql as $$
  select count(*)::integer from public.contacts
   where org_id = p_org and deleted_at is null;
$$;

-- The message the preview gives one row, or the code the import gave it.
create or replace function pg_temp.answer(
  p_org uuid, p_rows jsonb, p_row integer, p_field text, p_commit boolean default false)
returns text language plpgsql as $$
declare
  v text;
begin
  select case p_field when 'code' then code when 'status' then status else message end
    into v
    from public.import_contacts(p_org, p_rows, p_commit) where row_no = p_row;
  return v;
end $$;

-- What `import_contacts` says when it refuses the file.
create or replace function pg_temp.refusal(p_org uuid, p_rows jsonb)
returns text language plpgsql as $$
declare
  v_msg text;
begin
  perform public.import_contacts(p_org, p_rows, true);
  return null;
exception when others then
  get stacked diagnostics v_msg = message_text;
  return v_msg;
end $$;

-- ---------------------------------------------------------------------
-- The preview says what a blank code gets, and draws nothing
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('No Codes Sdn Bhd');
  v_rows jsonb := jsonb_build_array(
    jsonb_build_object('name', 'Al Hardware Sdn Bhd', 'contact_type', 'supplier'),
    jsonb_build_object('name', 'Beta Ventures Sdn Bhd', 'contact_type', 'prospect'),
    jsonb_build_object('name', 'Gamma Trading Sdn Bhd', 'contact_type', 'customer'),
    jsonb_build_object('name', 'Delta Both Sdn Bhd', 'contact_type', 'both'),
    jsonb_build_object('code', 'X-9', 'name', 'Typed Sdn Bhd', 'contact_type', 'customer'));
  v_year text := to_char(app.today(), 'YYYY');
begin
  perform pg_temp.check_eq('a file with no code column validates',
    (select count(*) from public.import_contacts(v_org, v_rows, false)
      where status = 'ok'), 5);

  perform pg_temp.check_true('a supplier is told the S- shape',
    pg_temp.answer(v_org, v_rows, 1, 'message') like '%S-YYYY-NNNNN%');
  perform pg_temp.check_true('a prospect the P- shape',
    pg_temp.answer(v_org, v_rows, 2, 'message') like '%P-YYYY-NNNNN%');
  perform pg_temp.check_true('a customer the C- shape',
    pg_temp.answer(v_org, v_rows, 3, 'message') like '%C-YYYY-NNNNN%');
  perform pg_temp.check_true('and both is coded with the customers',
    pg_temp.answer(v_org, v_rows, 4, 'message') like '%C-YYYY-NNNNN%');
  perform pg_temp.check_true('the sentence says when it is drawn',
    pg_temp.answer(v_org, v_rows, 2, 'message') like '%when the file is imported%');
  perform pg_temp.check_eq('a row that brought a code is told nothing',
    pg_temp.answer(v_org, v_rows, 5, 'message'), '');
  perform pg_temp.check_eq('and the preview shows it blank',
    pg_temp.answer(v_org, v_rows, 1, 'code'), '');

  perform pg_temp.check_eq('the preview wrote nothing',
    pg_temp.contact_count(v_org), 0);
  perform pg_temp.check_eq('and the preview drew nothing',
    (select count(*) from public.number_sequences
      where org_id = v_org and doc_type in ('supplier', 'prospect')), 0);

  -- The organization's own shape, not the default: a counter that
  -- numbers suppliers SUP/00001 without a year says so.
  insert into public.number_sequences (org_id, doc_type, prefix, padding, reset_policy)
  values (v_org, 'supplier', 'SUP/', 4, 'never');
  perform pg_temp.check_true('the shape is the organization''s own counter''s',
    pg_temp.answer(v_org, v_rows, 1, 'message') like '%SUP/NNNN %');
  delete from public.number_sequences where org_id = v_org and doc_type = 'supplier';

  -- Then the file goes in.
  perform public.import_contacts(v_org, v_rows, true);
  perform pg_temp.check_eq('all five arrive', pg_temp.contact_count(v_org), 5);
  perform pg_temp.check_true('a supplier is coded in the S- series',
    exists (select 1 from public.contacts
             where org_id = v_org and name = 'Al Hardware Sdn Bhd'
               and code = 'S-' || v_year || '-00001'
               and contact_type = 'supplier'));
  perform pg_temp.check_true('a prospect in the P- series',
    exists (select 1 from public.contacts
             where org_id = v_org and name = 'Beta Ventures Sdn Bhd'
               and code = 'P-' || v_year || '-00001'));
  perform pg_temp.check_true('a customer and a both in the C- series, in file order',
    exists (select 1 from public.contacts
             where org_id = v_org and name = 'Gamma Trading Sdn Bhd'
               and code = 'C-' || v_year || '-00001')
    and exists (select 1 from public.contacts
             where org_id = v_org and name = 'Delta Both Sdn Bhd'
               and code = 'C-' || v_year || '-00002'));
  perform pg_temp.check_true('and the typed code is kept as typed',
    exists (select 1 from public.contacts
             where org_id = v_org and name = 'Typed Sdn Bhd' and code = 'X-9'));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The answer carries the code drawn
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Answered Sdn Bhd');
  v_rows jsonb := jsonb_build_array(
    jsonb_build_object('code', 'K-1', 'name', 'Keyed Sdn Bhd'),
    jsonb_build_object('name', 'Drawn Sdn Bhd', 'contact_type', 'prospect'));
  v_year text := to_char(app.today(), 'YYYY');
  v_keyed record;
  v_drawn record;
begin
  -- One call, kept: the import's answer, not a preview run afterwards.
  create temp table pg_temp.answered on commit drop as
    select * from public.import_contacts(v_org, v_rows, true);
  select * into v_keyed from pg_temp.answered where row_no = 1;
  select * into v_drawn from pg_temp.answered where row_no = 2;

  perform pg_temp.check_eq('the answer carries the code drawn',
    v_drawn.code, 'P-' || v_year || '-00001');
  perform pg_temp.check_eq('and says it was drawn',
    v_drawn.message, 'No code in the file; this one was drawn.');
  perform pg_temp.check_eq('as imported', v_drawn.status, 'imported');
  perform pg_temp.check_eq('the keyed row keeps its code in the answer',
    v_keyed.code, 'K-1');
  perform pg_temp.check_eq('and its silence', v_keyed.message, '');
  perform pg_temp.check_true('and the code in the answer is the code in the table',
    exists (select 1 from public.contacts
             where org_id = v_org and name = 'Drawn Sdn Bhd' and code = v_drawn.code));
  drop table pg_temp.answered;
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A typed code where the counter lands next
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Collision Sdn Bhd');
  v_year text := to_char(app.today(), 'YYYY');
  -- The blank row comes first in the file, and would draw P-YYYY-00001
  -- -- which the second row typed.
  v_rows jsonb := jsonb_build_array(
    jsonb_build_object('name', 'Blank First Sdn Bhd', 'contact_type', 'prospect'),
    jsonb_build_object('code', 'P-' || v_year || '-00001',
                       'name', 'Typed Second Sdn Bhd', 'contact_type', 'prospect'));
begin
  perform pg_temp.check_eq('the file validates: nothing is known to clash yet',
    (select count(*) from public.import_contacts(v_org, v_rows, false)
      where status = 'error'), 0);
  perform pg_temp.check_true('and imports',
    pg_temp.refusal(v_org, v_rows) is null);
  perform pg_temp.check_eq('both rows arrive', pg_temp.contact_count(v_org), 2);
  perform pg_temp.check_true('the typed code keeps its number and the drawn row goes past it',
    exists (select 1 from public.contacts
             where org_id = v_org and name = 'Typed Second Sdn Bhd'
               and code = 'P-' || v_year || '-00001')
    and exists (select 1 from public.contacts
             where org_id = v_org and name = 'Blank First Sdn Bhd'
               and code = 'P-' || v_year || '-00002'));
  perform pg_temp.check_eq('and the counter is past both',
    (select next_value from public.number_sequences
      where org_id = v_org and doc_type = 'prospect'), 3);
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What is still refused, and what is refused sooner
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Refused Sdn Bhd');
  v_dead uuid;
  v_rows jsonb;
begin
  -- A contact that was deleted keeps its code: the index is over
  -- deleted rows too.
  insert into public.contacts (org_id, code, name, contact_type, deleted_at)
  values (v_org, 'C-OLD', 'Gone Sdn Bhd', 'customer', now())
  returning id into v_dead;

  v_rows := jsonb_build_array(
    -- No name, and no code either: it is the name that is missing.
    jsonb_build_object('contact_type', 'prospect'),
    -- The deleted contact's code.
    jsonb_build_object('code', 'C-OLD', 'name', 'Reused Sdn Bhd'),
    -- Two blank rows are not duplicates of each other.
    jsonb_build_object('name', 'One Sdn Bhd'),
    jsonb_build_object('name', 'Two Sdn Bhd'),
    -- A code typed twice still is.
    jsonb_build_object('code', 'T-1', 'name', 'First T Sdn Bhd'),
    jsonb_build_object('code', 't-1', 'name', 'Second T Sdn Bhd'),
    -- A blank code does not excuse a bad type.
    jsonb_build_object('name', 'Odd Sdn Bhd', 'contact_type', 'visitor'));

  perform pg_temp.check_true('a row with no name says so, not "no code"',
    pg_temp.answer(v_org, v_rows, 1, 'message') like 'No name%');
  perform pg_temp.check_true('a code a deleted contact still holds is refused at preview',
    pg_temp.answer(v_org, v_rows, 2, 'status') = 'error'
    and pg_temp.answer(v_org, v_rows, 2, 'message') like '%Gone Sdn Bhd%'
    and pg_temp.answer(v_org, v_rows, 2, 'message') like '%deleted%');
  perform pg_temp.check_true('two blank rows are not duplicates of each other',
    pg_temp.answer(v_org, v_rows, 3, 'status') = 'ok'
    and pg_temp.answer(v_org, v_rows, 4, 'status') = 'ok');
  perform pg_temp.check_true('a code typed twice still is',
    pg_temp.answer(v_org, v_rows, 6, 'message') like '%more than once%');
  perform pg_temp.check_true('and a blank code does not excuse a bad type',
    pg_temp.answer(v_org, v_rows, 7, 'message') like '%not a contact type%');

  perform pg_temp.check_true('the file is refused whole',
    pg_temp.refusal(v_org, v_rows) like 'Nothing was imported: 4 of 7 rows%');
  perform pg_temp.check_eq('nothing was written', pg_temp.contact_count(v_org), 0);
  perform pg_temp.check_eq('and nothing was drawn',
    (select count(*) from public.number_sequences
      where org_id = v_org and doc_type in ('contact', 'prospect')), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who may ask what the shape is
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('anon cannot call contact_code_shape',
    not has_function_privilege('anon',
      'app.contact_code_shape(uuid, app.contact_type)', 'execute'));
  perform pg_temp.check_true('and authenticated still imports',
    has_function_privilege('authenticated',
      'public.import_contacts(uuid, jsonb, boolean)', 'execute'));
end $$;

rollback;
