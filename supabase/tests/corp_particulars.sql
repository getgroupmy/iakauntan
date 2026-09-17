-- =====================================================================
-- iAkauntan :: the changes SSM has to be told about
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/corp_particulars.sql
--
-- `corp_entities.former_names`, `registered_office_changed_on` and
-- `constitution_adopted_on` have been columns since `0061` and none was
-- ever written. `0063` already knew the deadlines — s.28 and s.46(3),
-- fourteen days each — and had `corp_open_filing` to freeze them. What
-- was missing was the event: the entity editor writes `name` and
-- `registered_office` as ordinary form fields, so a company could be
-- renamed by typing over it and no clock started.
--
-- The claim that carries this file is s.28(4). For twelve months from a
-- change of name, the former name must appear beside the new one on the
-- company's documents — so losing the old name and losing the date are
-- each enough to make every document defective, and typing over the
-- field lost both.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org  uuid;
  v_e    uuid;
  v_f    uuid;
  v_said text;
  r      record;
  v_e2   uuid;
begin
  v_org := pg_temp.test_org('Setiausaha Nama Sdn Bhd', array['secretarial']);

  insert into public.corp_entities
    (org_id, name, entity_type, incorporated_on, registered_office)
  values (v_org, 'Lama Sdn Bhd', 'sdn_bhd', date '2020-01-15',
          'No 1, Jalan Lama, 50000 Kuala Lumpur')
  returning id into v_e;

  -- ------------------------------------------------------------------
  -- The refusal: a name is not a text field
  -- ------------------------------------------------------------------
  begin
    update public.corp_entities set name = 'Baru Sdn Bhd' where id = v_e;
    raise exception 'FAIL: a company was renamed by typing over it';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('typing over the name is refused',
    v_said like '%not a text field%');
  perform pg_temp.check_true('and the message names both doors',
    v_said like '%change_company_name%'
    and v_said like '%correct_company_name%');
  perform pg_temp.check_eq('the name is untouched',
    (select name from public.corp_entities where id = v_e), 'Lama Sdn Bhd');

  -- An edit about something else is not this trigger's business.
  update public.corp_entities set phone = '03-1234 5678' where id = v_e;
  perform pg_temp.check_eq('an unrelated edit still saves',
    (select phone from public.corp_entities where id = v_e), '03-1234 5678');

  -- ------------------------------------------------------------------
  -- Changing it properly
  -- ------------------------------------------------------------------
  v_f := public.change_company_name(v_e, 'Baru Sdn Bhd', date '2026-03-01');
  perform pg_temp.check_eq('the company is renamed',
    (select name from public.corp_entities where id = v_e), 'Baru Sdn Bhd');
  perform pg_temp.check_eq('the former name is kept',
    (select former_names[1] from public.corp_entities where id = v_e),
    'Lama Sdn Bhd');
  perform pg_temp.check_eq('with the date twelve months is counted from',
    (select name_changed_on from public.corp_entities where id = v_e)::text,
    '2026-03-01');

  -- The filing 0063 already knew how to compute, now actually opened.
  select * into r from public.corp_filings f where f.id = v_f;
  perform pg_temp.check_eq('and the s.28 filing is opened',
    r.filing_type, 'change_of_name');
  perform pg_temp.check_eq('dated the resolution', r.trigger_date::text,
    '2026-03-01');
  perform pg_temp.check_eq('due fourteen days later', r.due_date::text,
    '2026-03-15');

  -- ------------------------------------------------------------------
  -- s.28(4): twelve months of saying both
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('on the day, both names',
    public.corp_display_name(v_e, date '2026-03-01'),
    'Baru Sdn Bhd (formerly Lama Sdn Bhd)');
  perform pg_temp.check_eq('eleven months later, still both',
    public.corp_display_name(v_e, date '2027-02-01'),
    'Baru Sdn Bhd (formerly Lama Sdn Bhd)');
  -- Twelve months from 1 March 2026 is 1 March 2027, and the obligation
  -- is *for* twelve months — so the day itself is out.
  perform pg_temp.check_eq('and after twelve months, the new one alone',
    public.corp_display_name(v_e, date '2027-03-01'), 'Baru Sdn Bhd');
  -- A document dated before the change carries the name the company had
  -- then. Putting today's name on last year's paper is a different lie.
  perform pg_temp.check_eq('paper dated before the change says the old name',
    public.corp_display_name(v_e, date '2026-01-01'), 'Lama Sdn Bhd');

  -- ------------------------------------------------------------------
  -- And the documents actually carry it
  -- ------------------------------------------------------------------
  -- The four assertions above were true from the day `0377` landed and
  -- nothing was calling the function they assert. `{{company_name}}` --
  -- the first line of every template `0066` ships, above the
  -- registration number -- was `e.name`, the bare new name, for the
  -- twelve months in which s.28(4) requires both.
  --
  -- So this asserts the merge field rather than the function: not "does
  -- corp_display_name still work" but "does the document reach it".
  --
  -- `2026-03-01` is inside the twelve months at the time this runs.
  -- Should that stop being true -- somebody reads this in 2028 -- the
  -- control below goes red first and says the fixture date is what needs
  -- moving, not the code.
  perform pg_temp.check_true(
    'the rename is still inside the twelve months this asserts',
    (now() at time zone 'Asia/Kuala_Lumpur')::date < date '2027-03-01');
  perform pg_temp.check_eq(
    'a generated document carries both names, as s.28(4) requires',
    app.corp_merge_context(v_e) ->> 'company_name',
    'Baru Sdn Bhd (formerly Lama Sdn Bhd)');

  -- The control. Without it the assertion above could be satisfied by a
  -- merge context that appends "(formerly ...)" to everything.
  insert into public.corp_entities
    (org_id, name, entity_type, incorporated_on, registered_office)
  values (v_org, 'Tetap Sdn Bhd', 'sdn_bhd', date '2019-05-05',
          'No 2, Jalan Tetap, 50000 Kuala Lumpur')
  returning id into v_e2;
  perform pg_temp.check_eq(
    'and a company that never renamed carries its name alone',
    app.corp_merge_context(v_e2) ->> 'company_name', 'Tetap Sdn Bhd');

  -- ------------------------------------------------------------------
  -- The other door
  -- ------------------------------------------------------------------
  perform public.correct_company_name(v_e, 'Baru Sendirian Berhad');
  perform pg_temp.check_eq('a correction changes the name',
    (select name from public.corp_entities where id = v_e),
    'Baru Sendirian Berhad');
  perform pg_temp.check_eq('and adds no former name',
    (select array_length(former_names, 1) from public.corp_entities
      where id = v_e), 1);
  perform pg_temp.check_eq('nor opens a second filing',
    (select count(*) from public.corp_filings f
      where f.entity_id = v_e and f.filing_type = 'change_of_name'), 1);

  -- The correction's permission lasts one statement. Without the reset
  -- inside the function the marker would stand for the rest of the
  -- transaction, and the next bare update would ride through on it —
  -- which in an RPC that does two things is a rename nobody authorised.
  begin
    update public.corp_entities set name = 'Ketiga Sdn Bhd' where id = v_e;
    raise exception 'FAIL: a bare rename rode in on the correction';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and the permission does not outlive it',
    v_said like '%not a text field%');

  -- Renaming to what it is already called is not a change.
  begin
    perform public.change_company_name(v_e, 'Baru Sendirian Berhad');
    raise exception 'FAIL: a company was renamed to its own name';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('renaming to the same name is refused',
    v_said like '%already its name%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The registered office, and the constitution
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_e    uuid;
  v_f    uuid;
  v_said text;
  r      record;
begin
  v_org := pg_temp.test_org('Setiausaha Alamat Sdn Bhd', array['secretarial']);
  insert into public.corp_entities
    (org_id, name, entity_type, incorporated_on, registered_office)
  values (v_org, 'Pindah Sdn Bhd', 'sdn_bhd', date '2020-01-15',
          'No 1, Jalan Lama, 50000 Kuala Lumpur')
  returning id into v_e;

  begin
    update public.corp_entities
       set registered_office = 'No 9, Jalan Baru, 50100 Kuala Lumpur'
     where id = v_e;
    raise exception 'FAIL: the registered office moved with no filing';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('moving the office by hand is refused',
    v_said like '%s.46(3)%');

  v_f := public.change_registered_office(
    v_e, 'No 9, Jalan Baru, 50100 Kuala Lumpur', date '2026-04-10');
  perform pg_temp.check_eq('the office moves',
    (select registered_office from public.corp_entities where id = v_e),
    'No 9, Jalan Baru, 50100 Kuala Lumpur');
  perform pg_temp.check_eq('and the date is recorded',
    (select registered_office_changed_on from public.corp_entities
      where id = v_e)::text, '2026-04-10');
  select * into r from public.corp_filings f where f.id = v_f;
  perform pg_temp.check_eq('with the s.46(3) filing opened',
    r.filing_type, 'change_registered_office');
  perform pg_temp.check_eq('due in fourteen days', r.due_date::text,
    '2026-04-24');

  -- A blank registered office is not an address, it is nowhere for the
  -- Registrar to send anything.
  begin
    perform public.change_registered_office(v_e, '   ');
    raise exception 'FAIL: the registered office was blanked';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and it cannot be blank',
    v_said like '%cannot be blank%');

  -- ------------------------------------------------------------------
  -- s.32(3): thirty days from adoption
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('no constitution to begin with',
    (select not has_constitution from public.corp_entities where id = v_e));

  v_f := public.adopt_constitution(v_e, date '2026-05-05');
  perform pg_temp.check_true('the company has one now',
    (select has_constitution from public.corp_entities where id = v_e));
  perform pg_temp.check_eq('dated', (select constitution_adopted_on
    from public.corp_entities where id = v_e)::text, '2026-05-05');
  select * into r from public.corp_filings f where f.id = v_f;
  perform pg_temp.check_eq('and the s.32(3) filing is opened',
    r.filing_type, 'adopt_constitution');
  -- Thirty days, not fourteen: this one is its own section.
  perform pg_temp.check_eq('due thirty days later', r.due_date::text,
    '2026-06-04');

  -- Adopting twice is an alteration under s.36, which is a different
  -- thing with a different form.
  begin
    perform public.adopt_constitution(v_e, date '2026-08-01');
    raise exception 'FAIL: a second constitution was adopted';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a second adoption is an alteration, not this',
    v_said like '%s.36%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('renaming a company is closed to anon',
    not has_function_privilege('anon',
      'public.change_company_name(uuid, text, date)', 'execute'));
  perform pg_temp.check_true('and moving its office',
    not has_function_privilege('anon',
      'public.change_registered_office(uuid, text, date)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may read the name',
    has_function_privilege('authenticated',
      'public.corp_display_name(uuid, date)', 'execute'));
  -- The filing type is the statutory claim; assert it says what it says.
  perform pg_temp.check_eq('the constitution filing is thirty days',
    (select days_allowed from public.corp_filing_types
      where code = 'adopt_constitution'), 30);
  perform pg_temp.check_eq('under s.32(3)',
    (select statute_ref from public.corp_filing_types
      where code = 'adopt_constitution'), 'CA 2016 s.32(3)');
end $$;

rollback;
