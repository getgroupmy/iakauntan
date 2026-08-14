-- =====================================================================
-- iAkauntan :: a company has two addresses
--
-- `organizations` has carried one address since 0001, and it is not a
-- cosmetic one: `app.prepare_einvoice` in 0015 sends exactly those
-- columns to LHDN as the supplier address. A company that never filled
-- them in submits an invoice with no address on it. There has never been
-- a screen to fill them in, so the only companies that have an address
-- are the ones that were seeded with one.
--
-- That single address is the business address — where the company
-- actually trades, what goes on the invoice, what LHDN receives. The
-- registered office is a different fact: the address filed with SSM,
-- which for a great many companies is their secretary's office and not
-- somewhere the business has ever been.
--
-- Null throughout means "the same as the business address", which is the
-- ordinary case and keeps one address in one place. A company that has
-- never thought about the distinction is not asked to.
--
-- The secretarial module has `corp_entities.registered_office` already,
-- but that table is the register of entities a practice keeps *for its
-- clients* — a different thing from this company's own address, and not
-- present at all for a company without that module.
-- =====================================================================

alter table public.organizations
  add column registered_address_line1 text,
  add column registered_address_line2 text,
  add column registered_address_line3 text,
  add column registered_postcode      text,
  add column registered_city          text,
  add column registered_state_code    text,
  add column registered_country_code  char(3) default 'MYS';

comment on column public.organizations.registered_address_line1 is
  'Registered office as filed with SSM. Null means the same as the '
  'business address in address_line1..3, which is what goes to LHDN.';
