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

  -- And the console sees the whole table, which is what the reader
  -- function is for. Counted against the table rather than against a
  -- number, because 0295 seeds the catalogue and a literal here would
  -- have to be edited every time a provider is added — which is how a
  -- test ends up asserting the seed's length instead of the rule.
  perform pg_temp.sign_in_as(pg_temp.as_platform_admin());
  perform pg_temp.check_eq('while the console sees every gateway there is',
    (select count(*) from public.platform_payment_gateways()),
    (select count(*) from public.payment_gateways));
  perform pg_temp.check_true('which is more than a company is shown',
    (select count(*) from public.platform_payment_gateways())
      > (select count(*) from public.payment_gateways where is_active));

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

-- =====================================================================
-- The catalogue, and the difference between a listing and a connection
--
-- 0295 seeds forty-odd real payment providers. Two things have to hold
-- about that, and the second is the one worth a test file:
--
--   * a seeded row is a listing. Nothing can be charged through it: no
--     gateway is active, none names a secret, and the read policy shows
--     a tenant only what is active. A migration that shipped forty live
--     gateways would be a migration that offered every company a way to
--     pay that nobody had configured.
--   * this table is readable by every signed-in user on the platform,
--     which is the reason `secret_ref` names an Edge Function secret
--     rather than holding one. Widening a table like that is exactly
--     when somebody pastes a key into the new column, so the assertion
--     is over every text column at once rather than over the ones that
--     existed when this was written.
--
-- Two notes for whoever mutates this next, so they do not conclude the
-- assertions are dead when they are not:
--
--   * these blocks share one transaction with the ones above, which
--     configure `billplz` and `stripe`. By the time the scan runs those
--     two rows carry whatever the fixture put in them, so a mutant
--     planted in one of them is overwritten before it is looked for.
--     Plant it in a row nothing touches -- `chip` will do -- and it dies
--     twice over, on the scan and on the seeded-rows claim.
--   * removing `where g.is_active` from `payment_gateways_for` changes
--     nothing, because the read policy already withholds an inactive
--     gateway from `authenticated` and that is who calls it. Redundant,
--     and kept: a reader whose own text says what it returns is worth
--     more than one leaning entirely on a policy defined elsewhere.
-- =====================================================================
do $$
declare
  v_admin uuid := pg_temp.as_platform_admin();
  v_all integer; v_live integer; v_named integer; v_suspect integer;
begin
  select count(*) into v_all from public.payment_gateways;
  perform pg_temp.check_true('the catalogue was seeded', v_all >= 40);

  -- "As the migration left it" rather than "right now": these blocks
  -- share one transaction and the ones above switch gateways on. A row
  -- that has never been through `platform_save_payment_gateway` has a
  -- null `updated_by`, which is exactly the set this claim is about.
  select count(*) into v_live from public.payment_gateways
   where is_active and updated_by is null;
  perform pg_temp.check_eq('and not one of them arrived switched on',
    v_live, 0);

  select count(*) into v_named from public.payment_gateways
   where updated_by is null
     and (secret_ref is not null or publishable_key is not null);
  perform pg_temp.check_eq('nor does a seeded row claim to be configured',
    v_named, 0);

  -- Every text column of every row, against the shapes a real credential
  -- takes. Written over information_schema rather than over a list of
  -- column names so that the next column added to this table is covered
  -- by it without anybody remembering to come back here.
  select count(*) into v_suspect from (
    select (jsonb_each_text(to_jsonb(g))).value as v
      from public.payment_gateways g
  ) t
   where v ~ '^(sk|rk|pk)_(live|test)_'
      or v ~ '^(rzp|xnd|whsec)_'
      or v ~ '^[A-Za-z0-9+/]{40,}={0,2}$'
      or v ~ '^[0-9a-f]{32,}$';
  perform pg_temp.check_eq(
    'and nothing anywhere in the table is shaped like a credential',
    v_suspect, 0);

  -- Documentation links only, and absolute. A relative one would be a
  -- link into this application from a table describing somebody else's.
  perform pg_temp.check_eq('every documentation link is an absolute https one',
    (select count(*) from public.payment_gateways
      where docs_url is not null and docs_url !~* '^https://'), 0);

  -- Worth having at all: the region the product sells into is covered.
  perform pg_temp.check_true(
    'every country the product sells into has a gateway listed',
    not exists (
      select c from unnest(array['MY','SG','ID','TH','PH','VN']) c
       where not exists (select 1 from public.payment_gateways g
                          where c = any (g.countries))));

  -- Named providers, asserted by name. A count alone would go on
  -- passing if a later migration replaced the catalogue with forty
  -- rows of something else, and these are the ones somebody asked for.
  perform pg_temp.check_true(
    'the providers asked for by name are in the catalogue',
    not exists (
      select c from unnest(array['billplz','toyyibpay','paydibs',
                                 'ipay88','fiuu','curlec']) c
       where not exists (select 1 from public.payment_gateways g
                          where g.code = c)));
  perform pg_temp.check_eq('and Paydibs sells where it says it does',
    (select array_to_string(countries, ',') from public.payment_gateways
      where code = 'paydibs'), 'MY');
end $$;

-- ---------------------------------------------------------------------
-- A shop in Ipoh is not offered a Vietnamese wallet
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.as_platform_admin();
  v_member uuid; v_role text;
  v_my integer; v_vn integer; v_any integer;
begin
  perform public.platform_save_payment_gateway('billplz', p_is_active => true);
  perform public.platform_save_payment_gateway('vnpay', p_is_active => true);

  v_member := pg_temp.another_user('kedai@iakauntan.test');
  perform pg_temp.sign_in_as(v_member);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_my  from public.payment_gateways_for('MY');
    select count(*) into v_vn  from public.payment_gateways_for('VN');
    select count(*) into v_any from public.payment_gateways_for(null);
  end;
  reset role;

  perform pg_temp.check_true('the reader ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('Malaysia is offered the Malaysian gateway', v_my, 1);
  perform pg_temp.check_eq('Vietnam the Vietnamese one', v_vn, 1);
  perform pg_temp.check_eq('and no country at all sees both', v_any, 2);
  perform pg_temp.check_eq('the Malaysian one is the one it says',
    (select code from public.payment_gateways_for('MY')), 'billplz');
  -- Lower case out of a form, which is how a country code actually
  -- arrives from a dropdown somebody typed the values of.
  perform pg_temp.check_eq('and a lower case country still matches',
    (select count(*) from public.payment_gateways_for('my')), 1);

  -- The function is not security definer, so the policy is still what
  -- decides. Switching a gateway off takes it out of the answer.
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_payment_gateway('billplz', p_is_active => false);
  perform pg_temp.sign_in_as(v_member);
  begin
    set local role authenticated;
    select count(*) into v_my from public.payment_gateways_for('MY');
  end;
  reset role;
  perform pg_temp.check_eq('and switching it off takes it back out', v_my, 0);
end $$;

-- ---------------------------------------------------------------------
-- The catalogue refreshes; the configuration does not
--
-- Re-running the seed has to bring the facts up to date without
-- touching what an operator set, because a migration that reset
-- somebody's live gateway to sandbox on a Tuesday afternoon is a
-- migration that took a shop's payments down.
--
-- Said plainly, because it would be easy to read this block as more
-- than it is: the upsert below is written here, not imported from the
-- migration, so it asserts the shape a re-seed must have rather than
-- proving 0295 has it. Migrations here are append-only and run once, so
-- what this is really for is the next one -- whoever adds a provider in
-- 0311 copies a clause, and this says which clause is the right one.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.as_platform_admin(); v_row record;
begin
  perform public.platform_save_payment_gateway(
    'toyyibpay', p_mode => 'live', p_secret_ref => 'TOYYIBPAY_SECRET_KEY',
    p_is_active => true, p_instructions => 'Ask Aida for the category code.');

  -- The seed again, as a later migration or a re-run would apply it.
  insert into public.payment_gateways
    (code, name, currency, countries, methods, docs_url, sort_order)
  values ('toyyibpay', 'toyyibPay (renamed upstream)', 'MYR', array['MY','SG'],
          array['fpx','card','duitnow'], 'https://toyyibpay.com/apireference/', 25)
  on conflict (code) do update set
    name = excluded.name, countries = excluded.countries,
    methods = excluded.methods, docs_url = excluded.docs_url,
    sort_order = excluded.sort_order;

  select * into v_row from public.payment_gateways where code = 'toyyibpay';
  perform pg_temp.check_eq('the catalogue fact is refreshed',
    v_row.name, 'toyyibPay (renamed upstream)');
  perform pg_temp.check_eq('and so is where it sells',
    array_to_string(v_row.countries, ','), 'MY,SG');
  perform pg_temp.check_true('while the gateway stays live', v_row.is_active);
  perform pg_temp.check_eq('in the mode somebody put it in', v_row.mode, 'live');
  perform pg_temp.check_eq('still naming the secret they named',
    v_row.secret_ref, 'TOYYIBPAY_SECRET_KEY');
  perform pg_temp.check_eq('and keeping the note they left',
    v_row.instructions, 'Ask Aida for the category code.');
  perform public.platform_save_payment_gateway('toyyibpay', p_is_active => false);
end $$;

-- ---------------------------------------------------------------------
-- The two lists mean something
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.as_platform_admin(); v_ok boolean;
begin
  v_ok := false;
  begin
    update public.payment_gateways set countries = array['my']
     where code = 'billplz';
  exception when check_violation then v_ok := true;
  end;
  perform pg_temp.check_true(
    'a lower case country code is refused, or the filter stops matching',
    v_ok);

  v_ok := false;
  begin
    update public.payment_gateways set countries = array['MYS']
     where code = 'billplz';
  exception when check_violation then v_ok := true;
  end;
  perform pg_temp.check_true('and a three letter one', v_ok);

  v_ok := false;
  begin
    update public.payment_gateways set methods = array['telepathy']
     where code = 'billplz';
  exception when check_violation then v_ok := true;
  end;
  perform pg_temp.check_true('a rail nobody has heard of is refused', v_ok);

  perform pg_temp.check_eq('none of which changed the row',
    (select array_to_string(countries, ',') from public.payment_gateways
      where code = 'billplz'), 'MY');

  -- And a documentation link has to be a link.
  v_ok := false;
  begin
    update public.payment_gateways set docs_url = 'billplz.com/api'
     where code = 'billplz';
  exception when check_violation then v_ok := true;
  end;
  perform pg_temp.check_true('a documentation link has to be absolute', v_ok);
end $$;


-- ---------------------------------------------------------------------
-- And a writer for the three columns 0295 added
--
-- The block above asserts the constraints, by writing the table
-- directly. Nothing an operator does goes that way: they go through
-- `platform_save_payment_gateway`, which until `0352` had ten arguments
-- and none of them was `countries`, `methods` or `docs_url`. So a
-- gateway added by hand got no coverage list, a seeded row could not be
-- corrected, and the constraints above had never once refused a real
-- caller.
--
-- What is asserted here is the difference: the columns are writable,
-- what arrives is normalised before it is stored, and a wrong value
-- comes back named. A check constraint failing says
-- `payment_gateways_countries_iso`; an operator who typed `Malaysia`
-- needs to be told which value was wrong.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.as_platform_admin();
  v_row   record;
  v_said  text;
begin
  -- Mixed case, a stray space, and the same country twice. All three
  -- are what a form produces and none of them is what the column may
  -- hold.
  perform public.platform_save_payment_gateway(
    'ipay88', p_name => 'iPay88',
    p_countries => array['my', ' MY ', 'sg'],
    p_methods   => array['FPX', 'card', 'card'],
    p_docs_url  => 'https://ipay88.com/docs');

  select * into v_row from public.payment_gateways where code = 'ipay88';
  perform pg_temp.check_eq('a country list is upper cased, trimmed and deduped',
    array_to_string(v_row.countries, ','), 'MY,SG');
  perform pg_temp.check_eq('and a method list lower cased and deduped',
    array_to_string(v_row.methods, ','), 'card,fpx');
  perform pg_temp.check_eq('and the documentation link is kept',
    v_row.docs_url, 'https://ipay88.com/docs');

  -- Null is not an empty list. Most callers pass one field and nothing
  -- else, and a save that blanked the coverage list every time somebody
  -- flicked the switch would empty the catalogue one gateway at a time.
  perform public.platform_save_payment_gateway('ipay88', p_is_active => true);
  select * into v_row from public.payment_gateways where code = 'ipay88';
  perform pg_temp.check_eq('saving something else leaves the lists alone',
    array_to_string(v_row.countries, ','), 'MY,SG');

  -- An empty array is a statement, and a different one: it is what a
  -- gateway that sells everywhere holds, and `payment_gateways_for`
  -- reads it that way.
  perform public.platform_save_payment_gateway(
    'ipay88', p_countries => array[]::text[]);
  select * into v_row from public.payment_gateways where code = 'ipay88';
  perform pg_temp.check_eq('but an empty one means sells everywhere',
    cardinality(v_row.countries), 0);

  begin
    perform public.platform_save_payment_gateway(
      'ipay88', p_countries => array['Malaysia']);
    v_said := null;
  exception when others then v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a country that is not two letters is refused',
    v_said is not null);
  perform pg_temp.check_true('and the refusal names the value, not a constraint',
    v_said like '%Malaysia%');

  begin
    perform public.platform_save_payment_gateway(
      'ipay88', p_methods => array['telepathy']);
    v_said := null;
  exception when others then v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a rail nobody has heard of is refused here too',
    v_said is not null);
  perform pg_temp.check_true('and the refusal says which rails there are',
    v_said like '%telepathy%' and v_said like '%duitnow%');

  begin
    perform public.platform_save_payment_gateway(
      'ipay88', p_docs_url => 'ipay88.com/docs');
    v_said := null;
  exception when others then v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a documentation link over http is refused',
    v_said is not null);

  -- None of the three refusals wrote anything.
  select * into v_row from public.payment_gateways where code = 'ipay88';
  perform pg_temp.check_eq('and a refused save changed nothing',
    array_to_string(v_row.methods, ','), 'card,fpx');
  perform pg_temp.check_eq('nor the link it already had',
    v_row.docs_url, 'https://ipay88.com/docs');

  perform public.platform_save_payment_gateway('ipay88', p_is_active => false);
end $$;

-- ---------------------------------------------------------------------
-- Alpha-2 or alpha-3, and the direction a typo may move the answer
--
-- The mismatch that kept `payment_gateways_for` from ever being called:
-- `organizations.country_code` is alpha-3 and has been since `0003`,
-- and `payment_gateways.countries` is alpha-2 because that is what a
-- provider prints on its own page. A caller holding 'MYS' got an empty
-- list rather than an error -- a company told it has no way to pay --
-- so the resolution moved into the function.
--
-- The second claim is the one worth having. A code nobody recognises
-- must *narrow* the answer to the gateways that sell everywhere, never
-- widen it to the whole catalogue: showing a company a payment method
-- that is not sold where it is, is the failure that costs somebody a
-- phone call to a provider that will not take them.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.as_platform_admin();
  v_user  uuid := pg_temp.test_user();
  v_a2 integer; v_a3 integer; v_lower integer; v_junk integer; v_all integer;
  v_role text;
begin
  perform public.platform_save_payment_gateway(
    'billplz', p_is_active => true, p_countries => array['MY']);
  perform public.platform_save_payment_gateway(
    'everywhere', p_name => 'Sells Everywhere', p_is_active => true,
    p_countries => array[]::text[]);

  perform pg_temp.sign_in_as(v_user);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_a2    from public.payment_gateways_for('MY');
    select count(*) into v_a3    from public.payment_gateways_for('MYS');
    select count(*) into v_lower from public.payment_gateways_for('mys');
    select count(*) into v_junk  from public.payment_gateways_for('ZZZ');
    select count(*) into v_all   from public.payment_gateways_for(null);
  end;
  reset role;

  perform pg_temp.check_true('the reader ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_true('alpha-2 finds the Malaysian gateway', v_a2 >= 2);
  perform pg_temp.check_eq('and alpha-3 finds exactly the same', v_a3, v_a2);
  perform pg_temp.check_eq('lower case alpha-3 too', v_lower, v_a2);

  -- Not "returns nothing": the gateways with an empty coverage list are
  -- true for every country including one nobody could resolve.
  perform pg_temp.check_true('a country nobody recognises still sees the '
    'ones that sell everywhere', v_junk >= 1);
  perform pg_temp.check_true('and it narrows rather than widens',
    v_junk < v_a2);
  perform pg_temp.check_true('while no country at all sees everything',
    v_all >= v_a2);

  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_payment_gateway('everywhere', p_is_active => false);
  perform public.platform_save_payment_gateway('billplz', p_is_active => false);
end $$;


-- ---------------------------------------------------------------------
-- The setting a user's own menu depends on
--
-- 0293 stored the grouping choice in `platform_settings`, whose read
-- policy is platform-administrators-only. So the switch worked for the
-- one person who set it and did nothing for anybody else: `navGrouping()`
-- read no rows and fell back to flat, with no error anywhere.
--
-- 0298 names the one key rather than opening the table, and this is the
-- pair of assertions that keeps it that way — the setting is reachable,
-- and nothing else in there became reachable with it.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.as_platform_admin();
  v_member uuid; v_role text; v_mine integer; v_others integer;
begin
  perform public.platform_update_setting('nav_grouping',
    jsonb_build_object('mode', 'by_module'));
  insert into public.platform_settings (key, value)
  values ('trial_days', to_jsonb(30))
  on conflict (key) do update set value = excluded.value;

  v_member := pg_temp.another_user('ahli@iakauntan.test');
  perform pg_temp.sign_in_as(v_member);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_mine from public.platform_settings
     where key = 'nav_grouping';
    select count(*) into v_others from public.platform_settings
     where key <> 'nav_grouping';
  end;
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq(
    'an ordinary member can read how their own menu is grouped', v_mine, 1);
  perform pg_temp.check_eq(
    'and nothing else the platform keeps in that table', v_others, 0);

  -- Reading it is not writing it. The grouping is the platform's choice
  -- to make for everybody, not a per-user preference, and the write
  -- policy is what says so. Asserted by its effect rather than by an
  -- exception, because that is how it actually refuses: `authenticated`
  -- holds the UPDATE grant, so row level security filters the statement
  -- to nothing and it succeeds having changed nothing.
  begin
    set local role authenticated;
    update public.platform_settings
       set value = jsonb_build_object('mode', 'flat')
     where key = 'nav_grouping';
  end;
  reset role;
  perform pg_temp.check_eq('but cannot change it for everybody',
    (select value ->> 'mode' from public.platform_settings
      where key = 'nav_grouping'), 'by_module');
  perform pg_temp.sign_out();
end $$;

rollback;
