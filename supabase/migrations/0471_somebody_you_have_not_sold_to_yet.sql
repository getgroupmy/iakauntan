-- ---------------------------------------------------------------------
-- 0471  Somebody you have not sold to yet
-- ---------------------------------------------------------------------
-- `app.contact_type` has been customer, supplier, both, employee and
-- other since `0001`. There is nothing for the company you are talking
-- to and have not sold to — and that is most of a sales pipeline. It
-- gets recorded as a customer, which quietly overstates the customer
-- list, or it gets kept somewhere outside the product.
--
-- `prospect` is that sixth value.
--
-- ### What it does not change
--
-- Nothing gains a rule. There is no guard anywhere in this schema that
-- says only a customer may be invoiced — measured, not assumed: the
-- only functions that reason about `contact_type` at all are the demo
-- seeds, `convert_lead`, `customer_payment_lags`, `import_contacts` and
-- `intercompany_inbox`. So a prospect is not refused anything; it is
-- simply not offered. The app asks for contacts by type and the
-- customer picker asks for `customer` and `both`, so a prospect does
-- not appear on an invoice until somebody says it is a customer, which
-- is the right default and needed no new refusal to get.
--
-- `convert_lead` still creates a **customer**, deliberately. A lead
-- worth converting is one that has bought; a prospect is where a
-- contact starts before there is a lead at all.
--
-- ### The list that would have gone stale
--
-- Adding the value alone would have been a quiet half-fix.
-- `import_contacts` validated against five names typed into the
-- function, so a file of prospects would have been refused row by row
-- with `"prospect" is not a contact type` — and the message it printed
-- named only three of the five it accepted, which is what a hand-copied
-- list does after a while.
--
-- It reads `enum_range` now, so the type is the only place the answer
-- lives and the next value added cannot disagree with it.
--
-- ### Mutants
--
-- Two, restated into a built database and run against
-- `supabase/tests/contact_types.sql`. Both die, and they die on
-- different halves of the same mistake:
--
--   * the five names typed back into the check -- killed by "a file of
--     prospects validates", 0 where 1 was expected. This is the
--     half-fix an `alter type` on its own would have shipped;
--   * the message typed back to naming three of them -- killed by "the
--     refusal lists all of them". Worth its own assertion rather than
--     being folded into the one above: a list that refuses correctly
--     and then tells you the wrong way to fix it costs somebody the
--     same afternoon.
-- ---------------------------------------------------------------------

alter type app.contact_type add value if not exists 'prospect';

-- Restated from the live definition; the change is the type check and
-- the message it prints.
CREATE OR REPLACE FUNCTION public.import_contacts(p_org_id uuid, p_rows jsonb, p_commit boolean DEFAULT false)
 RETURNS TABLE(row_no integer, code text, status text, message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r jsonb;
  i integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_seen text[] := '{}';
  v_bad integer := 0;
  v_code text; v_name text; v_type text; v_currency text;
  v_country text; v_state text; v_limit numeric; v_problem text;
begin
  if not app.can_write(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'Rows must be a list' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) = 0 then
    raise exception 'There is nothing in the file' using errcode = '22023';
  end if;

  for r in select * from jsonb_array_elements(p_rows)
  loop
    i := i + 1;
    v_problem := null;

    v_code := app.import_text(r, 'code');
    v_name := app.import_text(r, 'name');
    v_type := lower(coalesce(app.import_text(r, 'contact_type'), 'customer'));
    v_currency := upper(coalesce(app.import_text(r, 'currency'), 'MYR'));
    v_country := upper(coalesce(app.import_text(r, 'country_code'), 'MYS'));
    v_state := upper(coalesce(app.import_text(r, 'state_code'), ''));
    v_limit := app.import_number(app.import_text(r, 'credit_limit'));

    if v_code is null then
      v_problem := 'No code. Every contact needs one, and it is what an '
                || 'invoice will refer to.';
    elsif v_name is null then
      v_problem := 'No name.';
    elsif lower(v_code) = any (v_seen) then
      -- Caught here rather than by the unique index, because the index
      -- would fail the whole import on the second occurrence without
      -- saying which two rows clashed.
      v_problem := format('The code %s is in this file more than once.', v_code);
    elsif exists (select 1 from public.contacts c
                   where c.org_id = p_org_id and lower(c.code) = lower(v_code)
                     and c.deleted_at is null) then
      v_problem := format('%s is already a contact here.', v_code);
    elsif not exists (
      select 1 from unnest(enum_range(null::app.contact_type)) t
       where t::text = v_type) then
      -- Read out of the type rather than typed here again. The list was
      -- five names hardcoded, and the message named three of them; a
      -- sixth was added by 0471 and neither would have known. Now the
      -- type is the only place the answer lives.
      v_problem := format(
        '"%s" is not a contact type. Use one of: %s.', v_type,
        (select string_agg(t::text, ', ' order by t::text)
           from unnest(enum_range(null::app.contact_type)) t));
    elsif not exists (select 1 from public.ref_currencies rc
                       where rc.code = v_currency) then
      v_problem := format('"%s" is not a currency this system knows.', v_currency);
    elsif not exists (select 1 from public.ref_countries rc
                       where rc.code = v_country) then
      v_problem := format('"%s" is not a country code. Malaysia is MYS.', v_country);
    elsif v_state <> '' and not exists (select 1 from public.ref_states rs
                                         where rs.code = v_state) then
      v_problem := format('"%s" is not a Malaysian state code.', v_state);
    elsif v_limit is null then
      v_problem := format('"%s" is not a credit limit.',
                          app.import_text(r, 'credit_limit'));
    end if;

    if v_problem is null then
      v_seen := v_seen || lower(v_code);
    else
      v_bad := v_bad + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row_no', i,
      'code', coalesce(v_code, ''),
      'status', case when v_problem is null then 'ok' else 'error' end,
      'message', coalesce(v_problem, ''));
  end loop;

  -- All of it or none of it.
  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file and '
      'run it again.', v_bad, i using errcode = '22023';
  end if;

  if p_commit then
    i := 0;
    for r in select * from jsonb_array_elements(p_rows)
    loop
      i := i + 1;
      insert into public.contacts (
        org_id, code, name, legal_name, contact_type,
        tin, registration_no, sst_registration_no,
        email, phone, mobile, website,
        address_line1, address_line2, address_line3,
        postcode, city, state_code, country_code,
        currency, credit_limit, notes)
      values (
        p_org_id,
        app.import_text(r, 'code'),
        app.import_text(r, 'name'),
        app.import_text(r, 'legal_name'),
        lower(coalesce(app.import_text(r, 'contact_type'), 'customer'))
          ::app.contact_type,
        app.import_text(r, 'tin'),
        app.import_text(r, 'registration_no'),
        app.import_text(r, 'sst_registration_no'),
        app.import_text(r, 'email'),
        app.import_text(r, 'phone'),
        app.import_text(r, 'mobile'),
        app.import_text(r, 'website'),
        app.import_text(r, 'address_line1'),
        app.import_text(r, 'address_line2'),
        app.import_text(r, 'address_line3'),
        app.import_text(r, 'postcode'),
        app.import_text(r, 'city'),
        nullif(upper(coalesce(app.import_text(r, 'state_code'), '')), ''),
        upper(coalesce(app.import_text(r, 'country_code'), 'MYS')),
        upper(coalesce(app.import_text(r, 'currency'), 'MYR')),
        app.import_number(app.import_text(r, 'credit_limit')),
        app.import_text(r, 'notes'));
    end loop;

    v_results := (
      select jsonb_agg(jsonb_set(x, '{status}', '"imported"'))
        from jsonb_array_elements(v_results) x);
  end if;

  return query
    select (x ->> 'row_no')::integer, x ->> 'code', x ->> 'status', x ->> 'message'
      from jsonb_array_elements(v_results) x
     order by 1;
end; $function$;

comment on type app.contact_type is
  'customer, supplier, both, employee, other, prospect. A prospect is '
  'somebody you have not sold to yet: not refused anything, but not '
  'offered as a customer either, so it stays off invoices until '
  'somebody says otherwise. See 0471.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    to_regprocedure('public.import_contacts(uuid, jsonb, boolean)'));
begin
  -- Read out of the catalogue, not out of the type. CI applies each
  -- migration file in one transaction, and `enum_range` on a type whose
  -- value was added in that same transaction is refused with 55P04,
  -- `unsafe use of new value`; so is any cast to it. `pg_enum` is a
  -- table of rows, and the row is there the moment `alter type` runs.
  -- The local harness applies statements one at a time and so never
  -- asked this question -- which is how the first shape of this block
  -- passed here and failed in CI.
  if not exists (
    select 1
      from pg_enum e
      join pg_type t on t.oid = e.enumtypid
      join pg_namespace n on n.oid = t.typnamespace
     where n.nspname = 'app'
       and t.typname = 'contact_type'
       and e.enumlabel = 'prospect') then
    raise exception '0471: there is still nowhere to put a prospect';
  end if;

  if position('enum_range' in v_src) = 0 then
    raise exception
      '0471: the importer still checks the type against a list typed '
      'into it, so a prospect cannot be imported';
  end if;
end
$do$;
