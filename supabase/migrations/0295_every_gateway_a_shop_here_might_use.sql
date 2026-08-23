-- ---------------------------------------------------------------------
-- Every gateway a shop in this part of the world might actually use
--
-- 0292 built the settings surface for a payment gateway and left the
-- catalogue empty, on the reasoning that taking a payment needs an edge
-- function that speaks one named provider's API. That reasoning was
-- about the checkout. It was the wrong reason to leave the list empty:
-- a platform operator in Kuala Lumpur opening this screen and finding
-- nothing has to go and find out for themselves what the options are,
-- and the answer is not obvious even here — it is forty-odd companies,
-- most of them regional, several of them the same company under an
-- older name.
--
-- So the catalogue is the deliverable: who exists, where they sell,
-- what rails they carry, and where to go for keys. Seeded inactive,
-- every one of them, because
--
--   * a row is a listing, not a connection. Nothing is charged through
--     a gateway until somebody puts its secret in Edge Function secrets
--     AND an edge function exists that speaks its API. Seeding forty
--     rows creates neither.
--   * `payment_gateways_read` shows tenants only what `is_active` says,
--     so an inactive catalogue is invisible to every company on the
--     platform until an operator chooses one.
--
-- ## What is stored, and what is still never stored
--
-- Unchanged and worth restating because this migration widens the
-- table: `secret_ref` names an Edge Function secret and never holds
-- one, and the refusal in `platform_save_payment_gateway` that enforces
-- that is asserted in `supabase/tests/platform_pricing_and_payment.sql`.
-- The columns added here — countries, methods, a documentation link —
-- are the kind of thing a provider prints on its own home page.
--
-- ## About the coverage lists
--
-- `countries` is where a provider publicly sells merchant accounts as
-- at this migration, not a promise that a given business will be
-- approved. Providers enter and leave markets; an operator confirms
-- with the provider before switching a gateway live. The list exists so
-- the console can stop showing a Vietnamese wallet to a shop in Ipoh,
-- which is the only job it has.
-- ---------------------------------------------------------------------

alter table public.payment_gateways
  add column if not exists countries text[] not null default '{}';

alter table public.payment_gateways
  add column if not exists methods text[] not null default '{}';

alter table public.payment_gateways
  add column if not exists docs_url text;

-- Two-letter country codes, upper case, or the console's filter quietly
-- stops matching the day somebody writes 'my' instead of 'MY'. Written
-- as one regular expression over the joined array because a check
-- constraint may not contain a subquery, so unnest is not available
-- here; an empty array joins to '' and passes, which is what a gateway
-- that sells everywhere should do.
alter table public.payment_gateways
  drop constraint if exists payment_gateways_countries_iso;
alter table public.payment_gateways
  add constraint payment_gateways_countries_iso
  check (array_to_string(countries, ',') ~ '^([A-Z]{2}(,|$))*$');

-- A closed vocabulary, because a method list nobody agrees on is a
-- method list the console cannot filter by. `over_counter` is the
-- Indonesian and Philippine convenience-store payment, which is a real
-- rail and not a curiosity: a large share of e-commerce there settles
-- at an Alfamart counter.
alter table public.payment_gateways
  drop constraint if exists payment_gateways_methods_known;
alter table public.payment_gateways
  add constraint payment_gateways_methods_known
  check (methods <@ array['fpx', 'duitnow', 'card', 'ewallet', 'qr',
                          'bank_transfer', 'direct_debit', 'bnpl',
                          'over_counter']);

alter table public.payment_gateways
  drop constraint if exists payment_gateways_docs_absolute;
alter table public.payment_gateways
  add constraint payment_gateways_docs_absolute
  check (docs_url is null or docs_url ~* '^https://');

comment on column public.payment_gateways.countries is
  'Where the provider publicly sells merchant accounts, ISO 3166-1 alpha-2. A listing, not a promise of approval.';
comment on column public.payment_gateways.methods is
  'Which rails the gateway carries, from a closed vocabulary so the console can filter by them.';
comment on column public.payment_gateways.docs_url is
  'Where an operator goes to get their own keys. Public documentation, never a credential.';

-- ---------------------------------------------------------------------
-- The catalogue
--
-- Ordered roughly by how likely a Malaysian business is to reach for
-- it, then outward through the region, then the global processors that
-- happen to serve it. Seeded inactive and without a secret_ref, so an
-- unconfigured row reads as unconfigured rather than as broken.
--
-- The upsert refreshes the catalogue facts — name, coverage, rails,
-- documentation, ordering — and deliberately never touches `is_active`,
-- `mode`, `secret_ref`, `publishable_key`, `checkout_url` or
-- `instructions`. Those are the operator's, and a migration that reset
-- somebody's live gateway to sandbox on a Tuesday afternoon would be a
-- migration that took a shop's payments down.
-- ---------------------------------------------------------------------
insert into public.payment_gateways
  (code, name, currency, countries, methods, docs_url, sort_order, instructions)
values
  -- Malaysia
  ('billplz', 'Billplz', 'MYR', array['MY'],
   array['fpx','duitnow','ewallet','card'],
   'https://www.billplz.com/api', 10,
   'Needs BILLPLZ_SECRET_KEY and BILLPLZ_COLLECTION_ID in Edge Function secrets.'),
  ('toyyibpay', 'toyyibPay', 'MYR', array['MY'],
   array['fpx','card'],
   'https://toyyibpay.com/apireference/', 20,
   'Needs TOYYIBPAY_SECRET_KEY and TOYYIBPAY_CATEGORY_CODE in Edge Function secrets.'),
  ('bayarcash', 'Bayarcash', 'MYR', array['MY'],
   array['fpx','duitnow','direct_debit'],
   'https://api.webimpian.support/bayarcash', 30,
   'Needs BAYARCASH_PAT and BAYARCASH_PORTAL_KEY in Edge Function secrets.'),
  ('chip', 'CHIP', 'MYR', array['MY'],
   array['fpx','card','ewallet','duitnow'],
   'https://developer.chip-in.asia/', 40,
   'Needs CHIP_SECRET_KEY and CHIP_BRAND_ID in Edge Function secrets.'),
  ('senangpay', 'senangPay', 'MYR', array['MY'],
   array['fpx','card','ewallet'],
   'https://senangpay.my/docs/', 50,
   'Needs SENANGPAY_SECRET_KEY and SENANGPAY_MERCHANT_ID in Edge Function secrets.'),
  ('ipay88', 'iPay88', 'MYR',
   array['MY','SG','PH','ID','TH','VN','KH','MM','BD'],
   array['card','fpx','ewallet','over_counter'],
   'https://www.ipay88.com/', 60,
   'Needs IPAY88_MERCHANT_CODE and IPAY88_MERCHANT_KEY in Edge Function secrets.'),
  ('fiuu', 'Fiuu (formerly Razer Merchant Services, MOLPay)', 'MYR',
   array['MY','SG','TH','ID','PH','VN'],
   array['card','fpx','ewallet','duitnow','bnpl'],
   'https://fiuu.com/', 70,
   'Needs FIUU_MERCHANT_ID, FIUU_VERIFY_KEY and FIUU_SECRET_KEY in Edge Function secrets.'),
  ('eghl', 'eGHL', 'MYR',
   array['MY','SG','PH','TH','ID'],
   array['card','fpx','ewallet'],
   'https://www.eghl.com/', 80,
   'Needs EGHL_SERVICE_ID and EGHL_PASSWORD in Edge Function secrets.'),
  ('revenue_monster', 'Revenue Monster', 'MYR', array['MY'],
   array['duitnow','qr','ewallet','card'],
   'https://doc.revenuemonster.my/', 90,
   'Needs REVENUE_MONSTER_CLIENT_ID and REVENUE_MONSTER_PRIVATE_KEY in Edge Function secrets.'),
  ('curlec', 'Curlec by Razorpay', 'MYR', array['MY'],
   array['direct_debit','fpx','card','duitnow'],
   'https://curlec.com/docs/', 100,
   'Needs CURLEC_KEY_ID and CURLEC_KEY_SECRET in Edge Function secrets.'),
  ('payex', 'PayEx', 'MYR', array['MY'],
   array['fpx','card','ewallet','duitnow'],
   'https://payex.io/', 110,
   'Needs PAYEX_API_KEY in Edge Function secrets.'),
  ('securepay', 'SecurePay', 'MYR', array['MY'],
   array['fpx','card','ewallet'],
   'https://securepay.my/', 120,
   'Needs SECUREPAY_TOKEN and SECUREPAY_CHECKSUM_TOKEN in Edge Function secrets.'),
  ('kiplepay', 'kiplePay', 'MYR', array['MY'],
   array['ewallet','duitnow','qr'],
   'https://kiplepay.com/', 130,
   'Needs KIPLEPAY_MERCHANT_ID and KIPLEPAY_SECRET in Edge Function secrets.'),
  ('touch_n_go', 'Touch ''n Go eWallet', 'MYR', array['MY'],
   array['ewallet','duitnow','qr'],
   'https://www.touchngo.com.my/', 140,
   'Direct merchant integration. Needs TNG_MERCHANT_ID and TNG_SECRET in Edge Function secrets.'),
  ('boost', 'Boost', 'MYR', array['MY'],
   array['ewallet','duitnow','qr'],
   'https://myboost.com.my/', 150,
   'Needs BOOST_MERCHANT_ID and BOOST_SECRET in Edge Function secrets.'),
  ('grabpay', 'GrabPay', 'MYR',
   array['MY','SG','ID','TH','VN','PH','KH','MM'],
   array['ewallet','qr','bnpl'],
   'https://developer.grab.com/docs/', 160,
   'Needs GRABPAY_PARTNER_ID and GRABPAY_PARTNER_SECRET in Edge Function secrets.'),
  ('shopeepay', 'ShopeePay', 'MYR',
   array['MY','SG','ID','TH','VN','PH'],
   array['ewallet','qr'],
   'https://shopeepay.com.my/', 170,
   'Needs SHOPEEPAY_MERCHANT_ID and SHOPEEPAY_SECRET in Edge Function secrets.'),

  -- Singapore
  ('hitpay', 'HitPay', 'SGD', array['SG','MY'],
   array['card','ewallet','qr','bank_transfer'],
   'https://docs.hitpayapp.com/', 200,
   'Needs HITPAY_API_KEY and HITPAY_SALT in Edge Function secrets.'),
  ('nets', 'NETS', 'SGD', array['SG'],
   array['card','qr','bank_transfer'],
   'https://www.nets.com.sg/', 210,
   'Needs NETS_MERCHANT_ID and NETS_SECRET_KEY in Edge Function secrets.'),
  ('red_dot', 'Red Dot Payment', 'SGD',
   array['SG','MY','ID','TH'],
   array['card','ewallet','bank_transfer'],
   'https://reddotpayment.com/', 220,
   'Needs RED_DOT_MERCHANT_ID and RED_DOT_SECRET_KEY in Edge Function secrets.'),

  -- Indonesia
  ('midtrans', 'Midtrans', 'IDR', array['ID'],
   array['card','bank_transfer','ewallet','qr','over_counter','bnpl'],
   'https://docs.midtrans.com/', 300,
   'Needs MIDTRANS_SERVER_KEY and MIDTRANS_CLIENT_KEY in Edge Function secrets.'),
  ('xendit', 'Xendit', 'IDR',
   array['ID','PH','MY','TH','VN'],
   array['card','bank_transfer','ewallet','qr','over_counter','direct_debit'],
   'https://developers.xendit.co/', 310,
   'Needs XENDIT_SECRET_KEY and XENDIT_CALLBACK_TOKEN in Edge Function secrets.'),
  ('doku', 'DOKU', 'IDR', array['ID'],
   array['card','bank_transfer','ewallet','qr','over_counter'],
   'https://dashboard.doku.com/docs/', 320,
   'Needs DOKU_CLIENT_ID and DOKU_SECRET_KEY in Edge Function secrets.'),
  ('duitku', 'Duitku', 'IDR', array['ID'],
   array['bank_transfer','ewallet','qr','over_counter','card'],
   'https://docs.duitku.com/', 330,
   'Needs DUITKU_MERCHANT_CODE and DUITKU_API_KEY in Edge Function secrets.'),
  ('faspay', 'Faspay', 'IDR', array['ID'],
   array['bank_transfer','ewallet','qr','over_counter'],
   'https://docs.faspay.co.id/', 340,
   'Needs FASPAY_MERCHANT_ID and FASPAY_USER_ID in Edge Function secrets.'),

  -- Thailand
  ('omise', 'Opn Payments (Omise)', 'THB',
   array['TH','SG','MY','JP'],
   array['card','qr','bank_transfer','ewallet','bnpl'],
   'https://docs.opn.ooo/', 400,
   'Needs OMISE_SECRET_KEY and OMISE_PUBLIC_KEY in Edge Function secrets.'),
  ('gbprimepay', 'GB Prime Pay', 'THB', array['TH'],
   array['card','qr','bank_transfer'],
   'https://doc.gbprimepay.com/', 410,
   'Needs GBPRIMEPAY_SECRET_KEY and GBPRIMEPAY_PUBLIC_KEY in Edge Function secrets.'),
  ('truemoney', 'TrueMoney', 'THB',
   array['TH','MM','KH','VN','ID','PH'],
   array['ewallet','qr'],
   'https://www.truemoney.com/', 420,
   'Needs TRUEMONEY_APP_ID and TRUEMONEY_SECRET in Edge Function secrets.'),

  -- Philippines
  ('paymongo', 'PayMongo', 'PHP', array['PH'],
   array['card','ewallet','qr','over_counter'],
   'https://developers.paymongo.com/', 500,
   'Needs PAYMONGO_SECRET_KEY and PAYMONGO_PUBLIC_KEY in Edge Function secrets.'),
  ('dragonpay', 'Dragonpay', 'PHP', array['PH'],
   array['bank_transfer','over_counter','ewallet'],
   'https://www.dragonpay.ph/', 510,
   'Needs DRAGONPAY_MERCHANT_ID and DRAGONPAY_PASSWORD in Edge Function secrets.'),
  ('maya', 'Maya (PayMaya)', 'PHP', array['PH'],
   array['ewallet','card','qr'],
   'https://developers.maya.ph/', 520,
   'Needs MAYA_PUBLIC_KEY and MAYA_SECRET_KEY in Edge Function secrets.'),
  ('gcash', 'GCash', 'PHP', array['PH'],
   array['ewallet','qr'],
   'https://www.gcash.com/', 530,
   'Usually reached through PayMongo or Xendit. Direct integration needs GCASH_MERCHANT_ID and GCASH_SECRET in Edge Function secrets.'),

  -- Vietnam
  ('vnpay', 'VNPAY', 'VND', array['VN'],
   array['card','bank_transfer','qr','ewallet'],
   'https://sandbox.vnpayment.vn/apis/', 600,
   'Needs VNPAY_TMN_CODE and VNPAY_HASH_SECRET in Edge Function secrets.'),
  ('momo', 'MoMo', 'VND', array['VN'],
   array['ewallet','qr'],
   'https://developers.momo.vn/', 610,
   'Needs MOMO_PARTNER_CODE, MOMO_ACCESS_KEY and MOMO_SECRET_KEY in Edge Function secrets.'),
  ('zalopay', 'ZaloPay', 'VND', array['VN'],
   array['ewallet','qr','card'],
   'https://docs.zalopay.vn/', 620,
   'Needs ZALOPAY_APP_ID, ZALOPAY_KEY1 and ZALOPAY_KEY2 in Edge Function secrets.'),
  ('onepay', 'OnePAY', 'VND', array['VN'],
   array['card','bank_transfer','qr'],
   'https://mtf.onepay.vn/', 630,
   'Needs ONEPAY_MERCHANT_ID and ONEPAY_HASH_CODE in Edge Function secrets.'),
  ('payoo', 'Payoo', 'VND', array['VN'],
   array['bank_transfer','over_counter','ewallet','qr'],
   'https://payoo.vn/', 640,
   'Needs PAYOO_BUSINESS_USERNAME and PAYOO_CHECKSUM_KEY in Edge Function secrets.'),

  -- Cambodia and Myanmar
  ('aba_payway', 'ABA PayWay', 'USD', array['KH'],
   array['card','bank_transfer','qr','ewallet'],
   'https://www.payway.com.kh/', 700,
   'Needs ABA_PAYWAY_MERCHANT_ID and ABA_PAYWAY_API_KEY in Edge Function secrets.'),
  ('wing', 'Wing', 'USD', array['KH'],
   array['ewallet','bank_transfer','over_counter','qr'],
   'https://www.wingmoney.com/', 710,
   'Needs WING_MERCHANT_ID and WING_SECRET in Edge Function secrets.'),
  ('kbzpay', 'KBZPay', 'MMK', array['MM'],
   array['ewallet','qr'],
   'https://www.kbzpay.com/', 720,
   'Needs KBZPAY_MERCHANT_CODE and KBZPAY_SECRET in Edge Function secrets.'),

  -- Regional and global processors that serve the region
  ('2c2p', '2C2P', 'SGD',
   array['SG','TH','MY','ID','PH','VN','KH','MM','HK'],
   array['card','bank_transfer','ewallet','qr','over_counter','bnpl'],
   'https://developer.2c2p.com/', 800,
   'Needs TWO_C_TWO_P_MERCHANT_ID and TWO_C_TWO_P_SECRET_KEY in Edge Function secrets.'),
  ('antom', 'Antom (Ant International)', 'SGD',
   array['SG','MY','ID','TH','PH','VN'],
   array['ewallet','card','qr','bnpl'],
   'https://global.alipay.com/docs/', 810,
   'Needs ANTOM_CLIENT_ID and ANTOM_PRIVATE_KEY in Edge Function secrets.'),
  ('stripe', 'Stripe', 'MYR',
   array['MY','SG','TH','ID','PH'],
   array['card','ewallet','bank_transfer','qr','bnpl'],
   'https://stripe.com/docs/api', 820,
   'Needs STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET in Edge Function secrets. The publishable key is public and goes in the field above.'),
  ('adyen', 'Adyen', 'SGD',
   array['SG','MY','ID','TH','PH'],
   array['card','ewallet','bank_transfer','qr','bnpl'],
   'https://docs.adyen.com/', 830,
   'Needs ADYEN_API_KEY and ADYEN_HMAC_KEY in Edge Function secrets.'),
  ('paypal', 'PayPal', 'USD',
   array['MY','SG','TH','ID','PH','VN'],
   array['card','ewallet'],
   'https://developer.paypal.com/api/rest/', 840,
   'Needs PAYPAL_CLIENT_ID and PAYPAL_CLIENT_SECRET in Edge Function secrets.'),
  ('dlocal', 'dLocal', 'USD',
   array['ID','PH','MY','TH','VN'],
   array['card','bank_transfer','ewallet','over_counter'],
   'https://docs.dlocal.com/', 850,
   'Needs DLOCAL_X_LOGIN, DLOCAL_X_TRANS_KEY and DLOCAL_SECRET_KEY in Edge Function secrets.'),

  -- The manual arrangement every one of these competes with, and the
  -- one a small shop starts on: a bank transfer and a screenshot.
  ('manual_transfer', 'Bank transfer, reconciled by hand', 'MYR',
   array['MY','SG','ID','TH','PH','VN','KH','MM','BN','LA'],
   array['bank_transfer','duitnow','qr'],
   null, 900,
   'No API and no secret. The company is told where to send the money and somebody marks the invoice paid. Put the account details in the instructions a payer sees.')
on conflict (code) do update set
  -- Catalogue facts only. Whether a gateway is on, which mode it is in,
  -- and what its secret is called belong to whoever configured it.
  name       = excluded.name,
  countries  = excluded.countries,
  methods    = excluded.methods,
  docs_url   = excluded.docs_url,
  sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------
-- What a company is offered, in the country it is actually in
--
-- The tenant-facing read already exists as the `payment_gateways_read`
-- policy, and it answers "what has the platform switched on". This
-- narrows that by country, because a shop in Ipoh being offered a
-- Vietnamese wallet is the catalogue leaking through as noise.
--
-- Null country means everything active, which is what a platform that
-- has not filled in its companies' countries should see rather than an
-- empty list.
-- ---------------------------------------------------------------------
create or replace function public.payment_gateways_for(p_country text default null)
returns setof public.payment_gateways
language sql
stable
set search_path = public, pg_temp as $$
  select * from public.payment_gateways g
   where g.is_active
     and (nullif(btrim(coalesce(p_country, '')), '') is null
          or upper(btrim(p_country)) = any (g.countries)
          or cardinality(g.countries) = 0)
   order by g.sort_order, g.code;
$$;

revoke all on function public.payment_gateways_for(text) from public, anon;
grant execute on function public.payment_gateways_for(text) to authenticated;

comment on function public.payment_gateways_for(text) is
  'The gateways this platform has switched on that sell in a given country. Runs as the caller, so the read policy still decides.';
