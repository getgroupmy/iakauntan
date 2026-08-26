-- =====================================================================
-- iAkauntan :: the front page will not publish copy that says it is not real
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/placeholder_copy.sql
--
-- Three testimonials reading "SAMPLE COPY, NOT A REAL CUSTOMER" were
-- live on the front page, attributed to three named people, beside two
-- figures reading "0 — Sample — replace me". Typed into the console to
-- see the shape of the band and never taken down.
--
-- No test could have caught that: the rows were production data and CI
-- runs against a throwaway database. What can be tested is the guard
-- `0330` puts in the way of the next one — and the two halves of it
-- that are easy to get wrong.
--
--   * it refuses *publishing*, not storing, so an operator can still
--     keep an example to work from;
--   * it judges the row as it will read after the save, not the text
--     that happened to be sent — because switching an existing sample
--     on sends no quote at all.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- What counts as copy that says it is not real
-- ---------------------------------------------------------------------
do $$
declare
  v_phrase text;
begin
  foreach v_phrase in array array[
    'SAMPLE COPY, NOT A REAL CUSTOMER. Replace it with a real one.',
    'sample copy',
    'Not A Real Customer',
    'replace me',
    'Replace this with something true',
    'Lorem ipsum dolor sit amet',
    'PLACEHOLDER',
    'Your text here',
    'TODO: ask Kevin for a quote'
  ] loop
    perform pg_temp.check_true(
      quote_literal(v_phrase) || ' is placeholder copy',
      app.is_placeholder_copy(v_phrase));
  end loop;

  -- And the other half, which matters more. A guard that refused half
  -- the real quotes on a marketing page would be taken out again.
  foreach v_phrase in array array[
    'We closed our books in a morning instead of a week.',
    -- "Sample" on its own is a word real businesses use. A laboratory,
    -- a surveyor, a company that posts samples to customers.
    'We send a sample to every new customer and iAkauntan bills it.',
    'The sample tracking alone paid for it.',
    'Our placeholder policy'  -- deliberately absurd, and still refused
  ] loop
    if v_phrase = 'Our placeholder policy' then
      -- Named as the one exception this list contains: "placeholder" is
      -- on the marker list, so this is refused. That is the trade, and
      -- it is the right way round — a quote that has to say
      -- "placeholder" can be reworded, and a placeholder that goes live
      -- cannot be taken back.
      perform pg_temp.check_true('and the one word that costs a false refusal',
        app.is_placeholder_copy(v_phrase));
    else
      perform pg_temp.check_true(
        quote_literal(v_phrase) || ' is somebody talking',
        not app.is_placeholder_copy(v_phrase));
    end if;
  end loop;

  perform pg_temp.check_true('and nothing at all is not placeholder copy',
    not app.is_placeholder_copy(null));
end $$;

-- ---------------------------------------------------------------------
-- Storing it is allowed; publishing it is not
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_id    uuid;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  -- Switched off, it is somebody's working draft and the platform has
  -- no business refusing it.
  v_id := public.platform_save_landing_testimonial(
    p_quote => 'SAMPLE COPY, NOT A REAL CUSTOMER. Shows the band.',
    p_author => 'A Name',
    p_is_active => false);
  perform pg_temp.check_true('a sample may be stored, switched off',
    v_id is not null);

  -- Switching that same row on sends no quote at all, which is the case
  -- a guard reading only its arguments would wave through.
  begin
    perform public.platform_save_landing_testimonial(
      p_id => v_id, p_is_active => true);
    raise exception 'FAIL: a stored sample was switched on';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('and may not then be switched on',
        sqlerrm like '%placeholder%');
  end;

  -- Nor may one be published in a single step.
  begin
    perform public.platform_save_landing_testimonial(
      p_quote => 'Lorem ipsum dolor sit amet.',
      p_author => 'Another Name',
      p_is_active => true);
    raise exception 'FAIL: a sample was published outright';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('nor published in one step',
        sqlerrm like '%placeholder%');
  end;

  -- A new testimonial defaults to published, so it is judged too.
  begin
    perform public.platform_save_landing_testimonial(
      p_quote => 'Replace me with something real.',
      p_author => 'A Third Name');
    raise exception 'FAIL: a sample was published by default';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('and a new one defaults to published, so is judged',
        sqlerrm like '%placeholder%');
  end;

  -- The name is judged as well as the quote. "Replace me" over a real
  -- sentence is the same defect wearing a different hat.
  begin
    perform public.platform_save_landing_testimonial(
      p_quote => 'We closed our books in a morning.',
      p_author => 'TODO name',
      p_is_active => true);
    raise exception 'FAIL: a sample byline was published';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('the byline is judged too',
        sqlerrm like '%placeholder%');
  end;

  -- And a real one still goes up, which is the point of all of it.
  v_id := public.platform_save_landing_testimonial(
    p_quote => 'We closed our books in a morning instead of a week.',
    p_author => 'Somebody Real',
    p_company => 'Their Company',
    p_is_active => true);
  perform pg_temp.check_true('and a real quote still goes up',
    (select is_active from public.landing_testimonials where id = v_id));
end $$;

-- ---------------------------------------------------------------------
-- The same for a figure
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_id    uuid;
begin
  perform pg_temp.sign_in_as(v_admin);

  v_id := public.platform_save_landing_stat(
    p_value => '0', p_label => 'Sample — replace me', p_is_active => false);
  perform pg_temp.check_true('a sample figure may be stored, switched off',
    v_id is not null);

  begin
    perform public.platform_save_landing_stat(p_id => v_id, p_is_active => true);
    raise exception 'FAIL: a stored sample figure was switched on';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('and may not then be switched on',
        sqlerrm like '%placeholder%');
  end;

  v_id := public.platform_save_landing_stat(
    p_value => '1,200', p_label => 'Companies keeping books here',
    p_is_active => true);
  perform pg_temp.check_true('and a real figure still goes up',
    (select is_active from public.landing_stats where id = v_id));
end $$;

-- ---------------------------------------------------------------------
-- The guard did not eat the rest of the function
-- ---------------------------------------------------------------------
-- `0330` recreates both save functions whole, so everything `0317` put
-- in them has to still be there. These are the three refusals it had
-- before this change, and a rewrite that dropped one would pass every
-- assertion above.
do $$
declare
  v_admin uuid := pg_temp.test_user();
begin
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_save_landing_testimonial(
      p_quote => 'A real sentence with nobody behind it.');
    raise exception 'FAIL: an unattributed quote got in';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('a quote still needs somebody''s name on it',
        sqlerrm like '%name against it%');
  end;

  begin
    perform public.platform_save_landing_stat(p_value => '12');
    raise exception 'FAIL: a figure with no label got in';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('a figure still needs what it counts',
        sqlerrm like '%what it counts%');
  end;

  -- And a tenant administrator is still not a platform one.
  delete from public.platform_admins where user_id = v_admin;
  perform pg_temp.sign_in_as(v_admin);
  begin
    perform public.platform_save_landing_stat(
      p_value => '9', p_label => 'Mine now');
    raise exception 'FAIL: a non-operator changed the front page';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('and only platform staff may change any of it',
        sqlerrm like '%platform administrator%');
  end;
end $$;

rollback;
