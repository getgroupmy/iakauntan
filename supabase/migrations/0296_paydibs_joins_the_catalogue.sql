-- ---------------------------------------------------------------------
-- Paydibs
--
-- A Malaysian payment aggregator, asked for by name. 0295 seeded the
-- catalogue and this adds one row to it in the way 0295's own test says
-- a later migration should: the same upsert, refreshing the catalogue
-- facts and touching nothing an operator has configured.
--
-- ## What is asserted here and what is not
--
-- `https://v3api-docs.paydibs.com` could not be reached from the
-- environment this migration was written in — the network egress proxy
-- refuses that host — so the coverage and the credential names below
-- are the convention this table already uses rather than a reading of
-- the v3 documentation. The `docs_url` is the address to check them
-- against, and it is the first thing to do before switching this
-- gateway on. Nothing here depends on being right about the field
-- names: a listing carries no secret, and the edge function that will
-- eventually speak this API is where the real names have to be correct.
--
-- Seeded inactive with no secret, like every other row: a listing is
-- not a connection.
-- ---------------------------------------------------------------------

insert into public.payment_gateways
  (code, name, currency, countries, methods, docs_url, sort_order, instructions)
values
  ('paydibs', 'Paydibs', 'MYR', array['MY'],
   array['fpx', 'card', 'ewallet', 'duitnow', 'qr'],
   'https://v3api-docs.paydibs.com/docs/introduction', 35,
   'Confirm the field names against the v3 API documentation before '
   'switching this on. The credentials go in Edge Function secrets, '
   'conventionally as PAYDIBS_MERCHANT_ID and PAYDIBS_MERCHANT_KEY.')
on conflict (code) do update set
  -- Catalogue facts only. Whether a gateway is on, which mode it is in,
  -- and what its secret is called belong to whoever configured it.
  name       = excluded.name,
  countries  = excluded.countries,
  methods    = excluded.methods,
  docs_url   = excluded.docs_url,
  sort_order = excluded.sort_order;
