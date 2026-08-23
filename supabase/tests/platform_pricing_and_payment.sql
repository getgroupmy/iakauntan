-- =====================================================================
-- iAkauntan :: colours, prices and a way to pay
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/platform_pricing_and_payment.sql
--
-- Three things 0292 lets a platform operator change, and the one that
-- matters most is not the money.
--
-- `payment_gateways` is readable by every signed-in user, because a
-- company being offered a way to pay has to be told which ways exist.
-- That is only safe while nothing confidential is in it — so the test
-- that earns its place here is the one asserting that a secret pasted
-- into `secret_ref` is refused, and that the column names an Edge
-- Function secret rather than holding one.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.as_platform_admin()
returns uuid language plpgsql as $$
declare v_id uuid := pg_temp.test_user();
begin
  insert into public.platform_admins (user_id) values (v_id)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_id);
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- The colours the product is drawn in
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.as_platform_admin(); v_ok boolean;
begin
  perform public.platform_save_landing_page(jsonb_build_object(
    'brand_colour', '#0BD00B', 'brand_colour_dark', '#34D399'));
  perform pg_temp.check_eq('the light colour is kept',
    (select brand_colour from public.landing_page), '#0BD00B');
  perform pg_temp.check_eq('and the dark one beside it',
    (select brand_colour_dark from public.landing_page), '#34D399');

  -- A colour that does not parse is not a wrong colour; it is a screen
  -- drawn in whatever the fallback is, found out in a browser.
  v_ok := false;
  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('brand_colour', 'green'));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true('a colour that is not hex is refused by name', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('brand_colour_dark', '#GGGGGG'));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true('and so are six characters that are not hex', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_landing_page(
      jsonb_build_object('brand_colour', '#0BD'));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true('and the three-digit short form', v_ok);

  perform pg_temp.check_eq('none of which changed the colour that was set',
    (select brand_colour from public.landing_page), '#0BD00B');

  -- The table refuses one too, for a writer that is not this function.
  v_ok := false;
  begin
    update public.landing_page set brand_colour = 'teal';
  exception when check_violation then v_ok := true;
  end;
  perform pg_temp.check_true('and the column refuses it whoever writes it', v_ok);
end $$;

-- ---------------------------------------------------------------------
-- What a module costs
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.as_platform_admin(); v_ok boolean;
begin
  perform public.platform_save_module('pos', null, null, 79.00);
  perform pg_temp.check_eq('a price can be corrected',
    (select monthly_price from public.platform_modules where code = 'pos'), 79.00);
  perform pg_temp.check_true('without blanking the name it did not mention',
    (select coalesce(btrim(name), '') <> ''
       from public.platform_modules where code = 'pos'));

  perform public.platform_save_module('pos', null, null, 0);
  perform pg_temp.check_eq('and a module can be made free',
    (select monthly_price from public.platform_modules where code = 'pos'), 0);

  v_ok := false;
  begin
    perform public.platform_save_module('pos', null, null, -1);
  exception when sqlstate '23514' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true('a module cannot cost less than nothing', v_ok);

  -- A new one, and the refusal that stops a nameless row appearing in
  -- everybody's module list.
  v_ok := false;
  begin
    perform public.platform_save_module('brand_new_thing');
  exception when sqlstate '23514' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true('a new module needs a name', v_ok);

  perform public.platform_save_module('brand_new_thing', 'Brand new thing',
    'Does something', 25.00);
  perform pg_temp.check_eq('and with one it is added',
    (select monthly_price from public.platform_modules
      where code = 'brand_new_thing'), 25.00);
end $$;

-- ---------------------------------------------------------------------
-- Only a platform administrator sets a price
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid;
  v_org uuid := pg_temp.test_org('Pembeli Modul Sdn Bhd');
  v_before numeric; v_ok boolean;
begin
  v_owner := pg_temp.test_user();
  delete from public.platform_admins where user_id = v_owner;
  select monthly_price into v_before from public.platform_modules where code = 'pos';
  perform pg_temp.sign_in_as(v_owner);

  v_ok := false;
  begin
    perform public.platform_save_module('pos', null, null, 0);
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true(
    'a company owner cannot set what they are billed', v_ok);
  perform pg_temp.check_eq('and the price is as the platform left it',
    (select monthly_price from public.platform_modules where code = 'pos'),
    v_before);

  v_ok := false;
  begin
    perform public.platform_save_payment_gateway('billplz', 'Billplz');
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('nor add a gateway everyone would pay through', v_ok);
end $$;

-- ---------------------------------------------------------------------
-- A gateway holds no secret
--
-- The assertion this file exists for. `payment_gateways` is readable by
-- every signed-in user, so anything confidential in it is confidential
-- handed to every tenant. `secret_ref` names an Edge Function secret;
-- the refusal below is what stops somebody pasting the secret itself
-- into the field labelled for its name.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.as_platform_admin(); v_ok boolean; v_cols text;
begin
  perform public.platform_save_payment_gateway(
    'billplz', 'Billplz', 'sandbox', 'MYR', 'pk_test_visible_to_everyone',
    'BILLPLZ_SECRET_KEY', 'https://www.billplz-sandbox.com/api/v3/bills',
    'Pay by FPX or card.', true, 10);
  perform pg_temp.check_eq('the gateway is stored',
    (select name from public.payment_gateways where code = 'billplz'), 'Billplz');
  perform pg_temp.check_eq('with the name of a secret, not a secret',
    (select secret_ref from public.payment_gateways where code = 'billplz'),
    'BILLPLZ_SECRET_KEY');

  -- Anything that is not shaped like an environment variable name is
  -- refused. A pasted key is long and full of characters a name never
  -- has.
  v_ok := false;
  begin
    perform public.platform_save_payment_gateway(
      'billplz', null, null, null, null,
      'sk_live_51H8xYz2eZvKYlo2CqLtBGhY7wQrTuVwXyZaBcDeFgHiJkLmNoPqRsTuVwXyZ');
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true('a pasted secret is refused, not stored', v_ok);

  v_ok := false;
  begin
    perform public.platform_save_payment_gateway(
      'billplz', null, null, null, null, 'has spaces and-dashes');
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true('and so is anything not shaped like a name', v_ok);

  perform pg_temp.check_eq('neither of which changed what was stored',
    (select secret_ref from public.payment_gateways where code = 'billplz'),
    'BILLPLZ_SECRET_KEY');

  -- Stated structurally as well, because this is what makes the read
  -- policy safe and "we were careful" is not an assertion.
  --
  -- Exactly one column here is named after a secret, and it holds the
  -- name of one rather than one. Asserted as that exact set rather than
  -- as an absence: an absence would have to exempt `secret_ref` and
  -- would then also exempt a `secret_key` somebody added next year.
  -- This fails the moment a second such column appears, which is the
  -- moment somebody should stop and think.
  select string_agg(attname, ', ' order by attname) into v_cols
    from pg_attribute
   where attrelid = 'public.payment_gateways'::regclass
     and attnum > 0 and not attisdropped
     and attname ~* '(^|_)(secret|password|private_key|api_key|token|credential)(_|$)';
  perform pg_temp.check_eq(
    'the only column named after a secret is the one naming one',
    v_cols, 'secret_ref');
  perform pg_temp.check_true('and it says so in the schema itself',
    (select col_description('public.payment_gateways'::regclass, attnum)
       ilike '%name of an Edge Function secret%'
       from pg_attribute
      where attrelid = 'public.payment_gateways'::regclass
        and attname = 'secret_ref'));
end $$;

-- ---------------------------------------------------------------------
-- What a tenant may see of it
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.as_platform_admin();
  v_member uuid; v_org uuid;
  v_role text; v_live integer; v_draft integer;
begin
  perform public.platform_save_payment_gateway(
    'billplz', 'Billplz', 'live', 'MYR', 'pk_live', 'BILLPLZ_SECRET_KEY',
    null, null, true, 10);
  perform public.platform_save_payment_gateway(
    'stripe', 'Stripe', 'sandbox', 'MYR', 'pk_test', 'STRIPE_SECRET_KEY',
    null, null, false, 20);

  -- A genuinely different person. `test_user()` is idempotent and hands
  -- back the same fixture every time, so using it here made the tenant
  -- and the administrator one user and the last assertion below passed
  -- for the wrong reason — twice, before this comment existed.
  v_org := pg_temp.test_org('Penyewa Sdn Bhd');
  v_member := pg_temp.another_user('penyewa@iakauntan.test');
  perform pg_temp.sign_in_as(v_member);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_live  from public.payment_gateways where is_active;
    select count(*) into v_draft from public.payment_gateways where not is_active;
  end;
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('a company is offered the live gateway', v_live, 1);
  perform pg_temp.check_eq('and is not shown one being set up', v_draft, 0);

  -- And the console sees both, which is what the reader function is for.
  perform pg_temp.sign_in_as(pg_temp.as_platform_admin());
  perform pg_temp.check_eq('while the console sees both',
    (select count(*) from public.platform_payment_gateways()), 2);

  -- A company owner calling the console's reader gets nothing rather
  -- than everything: the guard is inside the function, not on the call.
  perform pg_temp.sign_in_as(v_member);
  perform pg_temp.check_eq('and a company owner calling it sees none',
    (select count(*) from public.platform_payment_gateways()), 0);
end $$;

-- ---------------------------------------------------------------------
-- What the menu is grouped by, and what each module is called
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.as_platform_admin(); v_ok boolean;
begin
  perform public.platform_save_module('pos', 'Point of sale', null, null,
    null, null, null, 'Sell');
  perform pg_temp.check_eq('a module can be renamed',
    (select name from public.platform_modules where code = 'pos'),
    'Point of sale');
  perform pg_temp.check_eq('and given a heading to sit under',
    (select nav_group from public.platform_modules where code = 'pos'), 'Sell');

  -- The rule the rest of the saver follows: null leaves it alone, so
  -- renaming does not blank the grouping and regrouping does not blank
  -- the name.
  perform public.platform_save_module('pos', 'Till');
  perform pg_temp.check_eq('renaming leaves the heading where it was',
    (select nav_group from public.platform_modules where code = 'pos'), 'Sell');
  perform public.platform_save_module('pos', null, null, null, null, null,
    null, 'Front of house');
  perform pg_temp.check_eq('and regrouping leaves the name',
    (select name from public.platform_modules where code = 'pos'), 'Till');

  -- The console lists every module, including ones added later and ones
  -- retired, because it is where a retired one is brought back. Asserted
  -- against the table rather than a list somebody typed.
  perform public.platform_save_module('future_thing', 'Something later',
    'Not built yet', 0, false, 999, false);
  perform pg_temp.check_eq('a module added later is in the catalogue',
    (select count(*) from public.platform_modules where code = 'future_thing'), 1);
  perform pg_temp.check_true('and being switched off does not hide it',
    (select not is_active from public.platform_modules where code = 'future_thing'));

  -- The setting itself, which the shell reads.
  perform pg_temp.check_eq('the menu is one flat list until somebody says otherwise',
    (select value ->> 'mode' from public.platform_settings
      where key = 'nav_grouping'), 'flat');
  perform public.platform_update_setting('nav_grouping',
    jsonb_build_object('mode', 'by_module'));
  perform pg_temp.check_eq('and can be grouped',
    (select value ->> 'mode' from public.platform_settings
      where key = 'nav_grouping'), 'by_module');

  v_ok := false;
  begin
    perform pg_temp.sign_in_as(pg_temp.another_user('bukan-admin@iakauntan.test'));
    perform public.platform_update_setting('nav_grouping',
      jsonb_build_object('mode', 'flat'));
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true(
    'and only a platform administrator decides which', v_ok);
end $$;

rollback;
