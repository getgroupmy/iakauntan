-- ---------------------------------------------------------------------
-- Three things the platform console could not change
--
-- The colours the product is drawn in, what a module costs, and how a
-- company pays for one. All three were decided somewhere a platform
-- operator cannot reach: the first in `theme.dart` at build time, the
-- second in a column with no editor, the third nowhere at all.
--
-- ## Colours
--
-- Two more fields on `landing_page`. That row is already the platform's
-- presentation rather than only its marketing copy — `brand_colour` has
-- lived there since 0290 — and it is already the one thing an
-- unauthenticated visitor can read, which matters because the landing
-- page has to be drawn in the brand's colours before anybody has signed
-- in. A second anon-readable function would have meant a second name on
-- an allowlist that is meant to stay short.
--
-- Both are checked to be `#RRGGBB`. A colour that does not parse is not
-- a wrong colour, it is a screen drawn in whatever the fallback is, and
-- finding that out in a browser is worse than being told in a form.
--
-- ## Prices
--
-- `platform_modules.monthly_price` has existed since 0018 and nothing
-- has ever written to it. Changing what a module costs has meant SQL
-- against production on the table that decides what every tenant is
-- billed. `platform_save_module` is the same shape as
-- `platform_set_ocr_provider`: null means leave it alone, so correcting
-- a price cannot blank a description.
--
-- There is no delete. A module that anybody has ever enabled is
-- referenced by `org_modules`, so it goes inactive and stops being
-- offered rather than disappearing from under its own history.
--
-- ## A way to pay
--
-- `platform_invoices` already bills a company for its modules and
-- `platform_mark_invoice_paid` already settles one by hand. What was
-- missing is the option of the company paying it themselves.
--
-- This is the settings surface for that, and it is deliberately
-- gateway-agnostic: code, name, mode, currency, the publishable key and
-- the address to send somebody to. Which gateway — Billplz, ToyyibPay,
-- iPay88, Stripe — changes the edge function that talks to it, not this
-- table.
--
-- ### What is not in this table
--
-- The secret key. `secret_ref` names an Edge Function secret; it does
-- not hold one. This is the pattern `organizations.einvoice_secret_ref`
-- already uses, and it is the project's standing rule: a provider's
-- secret lives in Edge Function secrets, never in the repository, never
-- in a migration, never in a table, never in the Flutter bundle. The
-- publishable key is in the table because publishing it is what it is
-- for.
--
-- The table is readable by any signed-in user, because a company being
-- offered a way to pay has to be told which ways exist and needs the
-- publishable key to start a checkout. Everything that could not safely
-- be read by a tenant is absent rather than protected.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------
alter table public.landing_page
  add column if not exists brand_colour_dark text;

do $$ begin
  alter table public.landing_page
    add constraint landing_page_brand_colour_hex
    check (brand_colour is null or brand_colour ~ '^#[0-9A-Fa-f]{6}$');
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.landing_page
    add constraint landing_page_brand_colour_dark_hex
    check (brand_colour_dark is null or brand_colour_dark ~ '^#[0-9A-Fa-f]{6}$');
exception when duplicate_object then null;
end $$;

-- 0290's saver takes a patch of the fields that changed, so the new one
-- has to be named in it or it would be silently unsavable.
create or replace function public.platform_save_landing_page(p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_row public.landing_page; v_colour text;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;
  if jsonb_typeof(p_patch) <> 'object' then
    raise exception 'A patch has to be an object of the fields that changed'
      using errcode = '22023';
  end if;

  -- Caught here as well as by the constraint, so somebody typing a
  -- colour into a form is told what is wrong with what they typed
  -- rather than being shown a constraint name.
  foreach v_colour in array array['brand_colour', 'brand_colour_dark'] loop
    if nullif(btrim(p_patch ->> v_colour), '') is not null
       and btrim(p_patch ->> v_colour) !~ '^#[0-9A-Fa-f]{6}$' then
      raise exception 'A colour has to be six hex digits after a hash, like '
                      '#0B7A6B. Got % for %', p_patch ->> v_colour, v_colour
        using errcode = '22023';
    end if;
  end loop;

  insert into public.landing_page (id) values (true) on conflict (id) do nothing;

  update public.landing_page p set
    logo_url          = coalesce(p_patch ->> 'logo_url', p.logo_url),
    logo_dark_url     = coalesce(p_patch ->> 'logo_dark_url', p.logo_dark_url),
    wordmark          = coalesce(nullif(btrim(p_patch ->> 'wordmark'), ''), p.wordmark),
    tagline           = coalesce(p_patch ->> 'tagline', p.tagline),
    brand_colour      = coalesce(nullif(btrim(p_patch ->> 'brand_colour'), ''),
                                 p.brand_colour),
    brand_colour_dark = coalesce(nullif(btrim(p_patch ->> 'brand_colour_dark'), ''),
                                 p.brand_colour_dark),
    hero_headline     = coalesce(nullif(btrim(p_patch ->> 'hero_headline'), ''),
                                 p.hero_headline),
    hero_subhead      = coalesce(p_patch ->> 'hero_subhead', p.hero_subhead),
    hero_image_url    = coalesce(p_patch ->> 'hero_image_url', p.hero_image_url),
    sign_in_label     = coalesce(nullif(btrim(p_patch ->> 'sign_in_label'), ''),
                                 p.sign_in_label),
    register_label    = coalesce(nullif(btrim(p_patch ->> 'register_label'), ''),
                                 p.register_label),
    register_enabled  = coalesce((p_patch ->> 'register_enabled')::boolean,
                                 p.register_enabled),
    company_name      = coalesce(p_patch ->> 'company_name', p.company_name),
    company_reg_no    = coalesce(p_patch ->> 'company_reg_no', p.company_reg_no),
    address           = coalesce(p_patch ->> 'address', p.address),
    support_email     = coalesce(p_patch ->> 'support_email', p.support_email),
    support_phone     = coalesce(p_patch ->> 'support_phone', p.support_phone),
    privacy_url       = coalesce(p_patch ->> 'privacy_url', p.privacy_url),
    terms_url         = coalesce(p_patch ->> 'terms_url', p.terms_url),
    meta_title        = coalesce(p_patch ->> 'meta_title', p.meta_title),
    meta_description  = coalesce(p_patch ->> 'meta_description', p.meta_description),
    is_published      = coalesce((p_patch ->> 'is_published')::boolean, p.is_published),
    updated_by        = auth.uid()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

grant execute on function public.platform_save_landing_page(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- What a module costs
-- ---------------------------------------------------------------------
create or replace function public.platform_save_module(
  p_code text,
  p_name text default null,
  p_description text default null,
  p_monthly_price numeric default null,
  p_is_core boolean default null,
  p_sort_order integer default null,
  p_is_active boolean default null)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_code text := lower(btrim(coalesce(p_code, '')));
begin
  if not app.is_platform_admin() then
    raise exception 'Module prices are what every organization is billed and '
                    'may only be changed by a platform administrator'
      using errcode = '42501';
  end if;
  if v_code = '' then
    raise exception 'A module needs a code' using errcode = '23514';
  end if;
  if p_monthly_price is not null and p_monthly_price < 0 then
    raise exception 'A module cannot cost less than nothing, got %',
      p_monthly_price using errcode = '23514';
  end if;

  if not exists (select 1 from public.platform_modules where code = v_code) then
    if coalesce(btrim(p_name), '') = '' then
      raise exception 'A new module needs a name' using errcode = '23514';
    end if;
    insert into public.platform_modules
      (code, name, description, monthly_price, is_core, sort_order, is_active)
    values (v_code, btrim(p_name), p_description,
            coalesce(p_monthly_price, 0), coalesce(p_is_core, false),
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.platform_modules)),
            coalesce(p_is_active, true));
    return v_code;
  end if;

  update public.platform_modules m set
    name          = coalesce(nullif(btrim(p_name), ''), m.name),
    description   = coalesce(p_description, m.description),
    monthly_price = coalesce(p_monthly_price, m.monthly_price),
    is_core       = coalesce(p_is_core, m.is_core),
    sort_order    = coalesce(p_sort_order, m.sort_order),
    is_active     = coalesce(p_is_active, m.is_active)
   where m.code = v_code;

  return v_code;
end;
$$;

grant execute on function public.platform_save_module(
  text, text, text, numeric, boolean, integer, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- How a company pays for one
-- ---------------------------------------------------------------------
create table if not exists public.payment_gateways (
  code             text primary key,
  name             text not null,
  -- 'sandbox' until somebody has taken a real payment through it.
  mode             text not null default 'sandbox'
                     check (mode in ('sandbox', 'live')),
  currency         character(3) not null default 'MYR',
  -- Publishable by definition: it identifies the merchant to the
  -- gateway and is meant to be seen by the browser.
  publishable_key  text,
  -- The NAME of an Edge Function secret, never a secret. Nothing in this
  -- table is confidential, which is what lets it be read by a tenant.
  secret_ref       text,
  checkout_url     text,
  instructions     text,
  is_active        boolean not null default false,
  sort_order       integer not null default 0,
  updated_by       uuid references auth.users (id),
  updated_at       timestamptz not null default now(),
  constraint payment_gateways_checkout_absolute
    check (checkout_url is null or checkout_url ~* '^https://')
);

comment on table public.payment_gateways is
  'How a company may settle a platform invoice. Holds no secret: '
  'secret_ref names an Edge Function secret rather than containing one.';
comment on column public.payment_gateways.secret_ref is
  'The name of an Edge Function secret. Never the secret itself.';

alter table public.payment_gateways enable row level security;

drop policy if exists payment_gateways_read on public.payment_gateways;
create policy payment_gateways_read on public.payment_gateways
  for select to authenticated using (is_active);

grant select on public.payment_gateways to authenticated;

drop trigger if exists set_updated_at on public.payment_gateways;
create trigger set_updated_at before update on public.payment_gateways
  for each row execute function app.set_updated_at();

create or replace function public.platform_save_payment_gateway(
  p_code text,
  p_name text default null,
  p_mode text default null,
  p_currency text default null,
  p_publishable_key text default null,
  p_secret_ref text default null,
  p_checkout_url text default null,
  p_instructions text default null,
  p_is_active boolean default null,
  p_sort_order integer default null)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_code text := lower(btrim(coalesce(p_code, '')));
begin
  if not app.is_platform_admin() then
    raise exception 'Payment gateways are how every organization pays and '
                    'may only be changed by a platform administrator'
      using errcode = '42501';
  end if;
  if v_code = '' then
    raise exception 'A gateway needs a code' using errcode = '23514';
  end if;
  if p_mode is not null and p_mode not in ('sandbox', 'live') then
    raise exception 'A gateway is either sandbox or live, got %', p_mode
      using errcode = '22023';
  end if;
  if p_checkout_url is not null and p_checkout_url !~* '^https://' then
    raise exception 'A checkout address has to be https, got %', p_checkout_url
      using errcode = '22023';
  end if;

  -- The one refusal that is about safety rather than tidiness. This
  -- table is readable by every signed-in user, so a secret pasted into
  -- `secret_ref` would be a secret handed to every tenant. The names
  -- Edge Function secrets have are short and shouty; the things they
  -- hold are long. Refusing the long ones is a blunt rule that catches
  -- the paste.
  if p_secret_ref is not null
     and (length(btrim(p_secret_ref)) > 64
          or btrim(p_secret_ref) ~ '[^A-Za-z0-9_]') then
    raise exception
      'secret_ref names an Edge Function secret; it does not hold one. '
      'Use a name like BILLPLZ_SECRET_KEY.'
      using errcode = '22023';
  end if;

  if not exists (select 1 from public.payment_gateways where code = v_code) then
    if coalesce(btrim(p_name), '') = '' then
      raise exception 'A new gateway needs a name' using errcode = '23514';
    end if;
    insert into public.payment_gateways
      (code, name, mode, currency, publishable_key, secret_ref, checkout_url,
       instructions, is_active, sort_order, updated_by)
    values (v_code, btrim(p_name), coalesce(p_mode, 'sandbox'),
            coalesce(p_currency, 'MYR'), p_publishable_key,
            nullif(btrim(p_secret_ref), ''), p_checkout_url, p_instructions,
            coalesce(p_is_active, false),
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.payment_gateways)),
            auth.uid())
    returning code into v_code;
    return v_code;
  end if;

  update public.payment_gateways g set
    name            = coalesce(nullif(btrim(p_name), ''), g.name),
    mode            = coalesce(p_mode, g.mode),
    currency        = coalesce(p_currency::character(3), g.currency),
    publishable_key = coalesce(p_publishable_key, g.publishable_key),
    secret_ref      = coalesce(nullif(btrim(p_secret_ref), ''), g.secret_ref),
    checkout_url    = coalesce(p_checkout_url, g.checkout_url),
    instructions    = coalesce(p_instructions, g.instructions),
    is_active       = coalesce(p_is_active, g.is_active),
    sort_order      = coalesce(p_sort_order, g.sort_order),
    updated_by      = auth.uid()
   where g.code = v_code;

  return v_code;
end;
$$;

-- The console needs to see the inactive ones too, which the read policy
-- withholds from a tenant.
create or replace function public.platform_payment_gateways()
returns setof public.payment_gateways
language sql
stable
security definer
set search_path = public, app, pg_temp as $$
  select * from public.payment_gateways
   where app.is_platform_admin()
   order by sort_order, code;
$$;

grant execute on function public.platform_save_payment_gateway(
  text, text, text, text, text, text, text, text, boolean, integer)
  to authenticated;
grant execute on function public.platform_payment_gateways() to authenticated;
