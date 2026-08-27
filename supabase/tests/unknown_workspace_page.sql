-- =====================================================================
-- iAkauntan :: what a visitor gets at a name nobody holds
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/unknown_workspace_page.sql
--
-- `0327` gave a company a door with its name on it. Every other label
-- under the wildcard resolves too, so `nosuchcompany.iakauntan.com`
-- reaches the app exactly as `sinar` does. `0331` gives that visitor a
-- page of their own and lets an operator write it.
--
-- Three things here are easy to get wrong and silent when they are:
--
--   * the copy is gated on publication, so a platform whose marketing
--     site is still a draft tells the visitor nothing at all;
--   * the saver does not know the columns, so the console appears to
--     save and the page never changes;
--   * an empty box writes an empty string rather than a null, so the
--     screen renders a blank heading instead of falling back.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The columns exist, and they are nullable
--
-- Null is the value that means "the operator has not written this", and
-- the screen falls back to its shipped copy on it. A not-null default
-- would make emptying a box impossible to express.
-- ---------------------------------------------------------------------
do $$
declare v_col text; v_nullable boolean;
begin
  foreach v_col in array array[
    'unknown_title', 'unknown_body', 'unknown_cta_label', 'unknown_cta_url'
  ] loop
    select c.is_nullable = 'YES' into v_nullable
      from information_schema.columns c
     where c.table_schema = 'public'
       and c.table_name = 'landing_page'
       and c.column_name = v_col;
    perform pg_temp.check_true(
      format('landing_page.%s exists and may be null', v_col),
      coalesce(v_nullable, false));
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- An operator can write it, and it survives an unpublished site
--
-- The second half is the point. `page` is gated on `is_published`;
-- `brand` is not. Somebody standing at a door that does not open needs
-- an answer whether or not anybody has written a marketing site, so
-- this copy has to travel with the logo rather than with the page.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_out jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  delete from public.landing_page;

  perform public.platform_save_landing_page(jsonb_build_object(
    'unknown_title',     'Alamat ini tiada',
    'unknown_body',      'Sila semak semula alamat itu.',
    'unknown_cta_label', 'Ke laman utama',
    'unknown_cta_url',   'https://iakauntan.com'));

  -- Never published. This is the case the whole arrangement exists for.
  v_out := public.landing_page();

  perform pg_temp.check_true(
    'an unpublished page really is unpublished',
    v_out -> 'page' is null or v_out -> 'page' = 'null'::jsonb);

  perform pg_temp.check_eq(
    'the heading reaches a visitor anyway',
    v_out -> 'brand' ->> 'unknown_title', 'Alamat ini tiada');
  perform pg_temp.check_eq(
    'and the body',
    v_out -> 'brand' ->> 'unknown_body', 'Sila semak semula alamat itu.');
  perform pg_temp.check_eq(
    'and the button',
    v_out -> 'brand' ->> 'unknown_cta_label', 'Ke laman utama');
  perform pg_temp.check_eq(
    'and where the button goes',
    v_out -> 'brand' ->> 'unknown_cta_url', 'https://iakauntan.com');
end $$;

-- ---------------------------------------------------------------------
-- An empty box clears it, rather than storing an empty string
--
-- An operator who clears a field is asking for the default back. An
-- empty string is not null, and the screen's `??` would render it — a
-- heading of nothing at all, above a body of nothing at all.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_out jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(jsonb_build_object(
    'unknown_title', '', 'unknown_body', '   ',
    'unknown_cta_label', '', 'unknown_cta_url', ''));

  v_out := public.landing_page();
  perform pg_temp.check_true('an emptied heading is null, not ""',
    v_out -> 'brand' ->> 'unknown_title' is null);
  perform pg_temp.check_true('whitespace counts as empty',
    v_out -> 'brand' ->> 'unknown_body' is null);
  perform pg_temp.check_true('an emptied button label is null',
    v_out -> 'brand' ->> 'unknown_cta_label' is null);
  perform pg_temp.check_true('an emptied button address is null',
    v_out -> 'brand' ->> 'unknown_cta_url' is null);
end $$;

-- ---------------------------------------------------------------------
-- A field left out is a field left alone
--
-- The console sends the four together, but the RPC is public and a
-- patch is a patch: saving the wordmark must not wipe this page.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_out jsonb;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_landing_page(
    jsonb_build_object('unknown_title', 'Tiada di sini'));
  perform public.platform_save_landing_page(
    jsonb_build_object('wordmark', 'iAkauntan'));

  v_out := public.landing_page();
  perform pg_temp.check_eq(
    'saving something else leaves this page where it was',
    v_out -> 'brand' ->> 'unknown_title', 'Tiada di sini');
end $$;

-- ---------------------------------------------------------------------
-- The button needs an address a browser can follow
--
-- The rule the marketing button already has. A visitor who has already
-- been told they are in the wrong place, pressing a button that does
-- nothing, is the worst version of this page.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_ok boolean := false;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('unknown_cta_url', 'iakauntan.com'));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a button address without a scheme is refused',
    v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('unknown_cta_url', 'javascript:alert(1)'));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('nor a scheme the browser should not follow',
    v_ok);
end $$;

-- ---------------------------------------------------------------------
-- Only a platform administrator writes it
--
-- It is the platform's answer at the platform's own domain, and every
-- company's visitors see the same one.
-- ---------------------------------------------------------------------
do $$
declare v_owner uuid; v_ok boolean := false;
begin
  v_owner := pg_temp.test_user();
  delete from public.platform_admins where user_id = v_owner;
  perform pg_temp.sign_in_as(v_owner);

  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('unknown_title', 'Mine'));
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true(
    'an ordinary owner cannot rewrite the page a stranger lands on', v_ok);
end $$;

rollback;
