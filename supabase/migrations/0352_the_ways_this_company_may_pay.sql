-- ---------------------------------------------------------------------
-- The ways this company may pay, and the columns nobody could set
--
-- `0295` seeded forty-odd gateways with three new columns on them —
-- where each one sells, which rails it carries, and where an operator
-- goes for keys — and stated the point of the catalogue plainly: "the
-- list exists so" an operator "can find anything in it", and "so the
-- console can filter by them".
--
-- Neither happened, for two reasons this migration fixes.
--
-- **`platform_save_payment_gateway` never learned the three columns.**
-- `0292` wrote it with ten arguments and `0295` added the columns
-- underneath it without widening it. So a gateway added by hand gets no
-- countries, no methods and no documentation link, a seeded row cannot
-- be corrected, and the constraints `0295` wrote to keep the vocabulary
-- honest have never had a writer to refuse.
--
-- **`payment_gateways_for` had no caller.** It answers "which of these
-- sell where this company is", it is asserted in
-- `supabase/tests/platform_pricing_and_payment.sql`, and nothing in
-- `app/lib` or `supabase/functions` mentions it. What stopped it being
-- called is a mismatch nobody would notice until it silently returned
-- nothing: `organizations.country_code` has been alpha-3 since `0003`
-- ('MYS'), and `payment_gateways.countries` is alpha-2 because that is
-- what a provider prints on its own page ('MY'). Asking every caller to
-- convert is asking every caller to remember to, and the failure when
-- one forgets is an empty list rather than an error — a company told it
-- has no way to pay.
--
-- So the resolution moves here, where `ref_countries` already holds
-- both spellings.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Alpha-2 or alpha-3, and it does not matter which
-- ---------------------------------------------------------------------
--
-- Same `(text)` signature, so this replaces rather than overloads.
--
-- An unresolvable three-letter code is used as written, which matches
-- nothing but the gateways that sell everywhere. That is deliberately
-- the same answer a bad two-letter code already gave: a typo should
-- narrow the list to what is true for everybody, never widen it to the
-- whole catalogue. Widening is the dangerous direction — it shows a
-- company payment methods that are not sold where it is.
create or replace function public.payment_gateways_for(p_country text default null)
returns setof public.payment_gateways
language sql
stable
set search_path = public, pg_temp as $$
  with asked as (
    select nullif(upper(btrim(coalesce(p_country, ''))), '') as raw
  ),
  want as (
    select case
             when a.raw is null then null
             when length(a.raw) = 3
               then coalesce((select c.alpha2 from public.ref_countries c
                               where c.code = a.raw), a.raw)
             else a.raw
           end as code
      from asked a
  )
  select g.* from public.payment_gateways g, want w
   where g.is_active
     and (w.code is null
          or w.code = any (g.countries)
          or cardinality(g.countries) = 0)
   order by g.sort_order, g.code;
$$;

revoke all on function public.payment_gateways_for(text) from public, anon;
grant execute on function public.payment_gateways_for(text) to authenticated;

comment on function public.payment_gateways_for(text) is
  'The gateways this platform has switched on that sell in a given country, named in alpha-2 or alpha-3. Runs as the caller, so the read policy still decides.';

-- ---------------------------------------------------------------------
-- Saving the three columns 0295 added
-- ---------------------------------------------------------------------
--
-- The old ten-argument version is dropped rather than left beside this
-- one, for the reason `0351` gives about `create_organization`: a
-- default does not replace a function, it overloads it, and with both
-- in place every existing caller keeps resolving to the old one and
-- keeps being unable to write these columns — the failure this
-- migration exists to end, now arriving silently.
drop function if exists public.platform_save_payment_gateway(
  text, text, text, text, text, text, text, text, boolean, integer);

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
  p_sort_order integer default null,
  p_countries text[] default null,
  p_methods text[] default null,
  p_docs_url text default null)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_code       text := lower(btrim(coalesce(p_code, '')));
  v_countries  text[];
  v_methods    text[];
  v_bad        text;
  v_known      constant text[] := array['fpx', 'duitnow', 'card', 'ewallet',
                                        'qr', 'bank_transfer', 'direct_debit',
                                        'bnpl', 'over_counter'];
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
  -- The same rule the checkout address has, and for a plainer reason:
  -- this one is a link a person clicks from a console, and a console
  -- that sends an operator somewhere over http to fetch API keys is
  -- doing the opposite of its job.
  if p_docs_url is not null and p_docs_url !~* '^https://' then
    raise exception 'A documentation address has to be https, got %', p_docs_url
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

  -- Normalised here rather than left to the check constraints, because
  -- what a constraint can say when it fails is its own name. An
  -- operator who typed `my` deserves the row saved, and one who typed
  -- `Malaysia` deserves to be told which of the values was wrong.
  --
  -- Null and an empty array are different answers and stay different.
  -- Null means "leave this column alone" -- most callers pass one field
  -- and nothing else -- and `{}` means "sells everywhere", which is
  -- what an empty `countries` already means to `payment_gateways_for`.
  -- Checked as typed and reported as typed, before the upper-casing.
  -- An operator who wrote `Malaysia` should read `Malaysia` back; being
  -- told `MALAYSIA` was rejected sends them looking for a value they
  -- never entered.
  if p_countries is not null then
    select btrim(x) into v_bad
      from unnest(p_countries) as x
     where btrim(coalesce(x, '')) <> '' and btrim(x) !~ '^[A-Za-z]{2}$'
     limit 1;
    if v_bad is not null then
      raise exception 'A country is two letters, ISO 3166-1 alpha-2, got %',
        v_bad using errcode = '22023';
    end if;
    select array_agg(distinct c order by c)
      into v_countries
      from (select upper(btrim(x)) as c
              from unnest(p_countries) as x
             where btrim(coalesce(x, '')) <> '') s;
    v_countries := coalesce(v_countries, '{}');
  end if;

  if p_methods is not null then
    select btrim(x) into v_bad
      from unnest(p_methods) as x
     where btrim(coalesce(x, '')) <> ''
       and not (lower(btrim(x)) = any (v_known))
     limit 1;
    if v_bad is not null then
      raise exception 'No such payment method: %. Known ones are %.',
        v_bad, array_to_string(v_known, ', ') using errcode = '22023';
    end if;
    select array_agg(distinct m order by m)
      into v_methods
      from (select lower(btrim(x)) as m
              from unnest(p_methods) as x
             where btrim(coalesce(x, '')) <> '') s;
    v_methods := coalesce(v_methods, '{}');
  end if;

  if not exists (select 1 from public.payment_gateways where code = v_code) then
    if coalesce(btrim(p_name), '') = '' then
      raise exception 'A new gateway needs a name' using errcode = '23514';
    end if;
    insert into public.payment_gateways
      (code, name, mode, currency, publishable_key, secret_ref, checkout_url,
       instructions, is_active, sort_order, countries, methods, docs_url,
       updated_by)
    values (v_code, btrim(p_name), coalesce(p_mode, 'sandbox'),
            coalesce(p_currency, 'MYR'), p_publishable_key,
            nullif(btrim(p_secret_ref), ''), p_checkout_url, p_instructions,
            coalesce(p_is_active, false),
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.payment_gateways)),
            coalesce(v_countries, '{}'), coalesce(v_methods, '{}'), p_docs_url,
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
    countries       = coalesce(v_countries, g.countries),
    methods         = coalesce(v_methods, g.methods),
    docs_url        = coalesce(p_docs_url, g.docs_url),
    updated_by      = auth.uid()
   where g.code = v_code;

  return v_code;
end;
$$;

revoke all on function public.platform_save_payment_gateway(
  text, text, text, text, text, text, text, text, boolean, integer,
  text[], text[], text)
  from public, anon;
grant execute on function public.platform_save_payment_gateway(
  text, text, text, text, text, text, text, text, boolean, integer,
  text[], text[], text)
  to authenticated;

comment on function public.platform_save_payment_gateway(
  text, text, text, text, text, text, text, text, boolean, integer,
  text[], text[], text) is
  'Adds or amends a payment gateway. Platform administrators only. Null leaves a column alone; an empty countries array means the gateway sells everywhere.';
