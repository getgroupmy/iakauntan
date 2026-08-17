-- `set_sst_registration()` is the rule, and until now it was advisory.
--
-- `0145` built one careful way to become SST registered. It refuses
-- without the effective date, refuses without the registration number,
-- refuses without an explicit choice between service tax and sales tax,
-- and refuses a zero-rated code as the default. Its header says why:
--
--     The switch on the settings card writes a boolean. This writes the
--     boolean, the number, the date, *and* the default tax code —
--     because the four together are what "we are SST registered" means,
--     and any three of them is a company that believes it is charging
--     tax and is not.
--
-- Correct, and enforced nowhere. `authenticated` holds table-level
-- `UPDATE` on `public.organizations`, the `organizations_update` policy
-- admits the company's own people, and no trigger looked at these
-- columns. So `PATCH /rest/v1/organizations?id=eq.…` with
-- `{"is_sst_registered": true}` sets the boolean and nothing else, and
-- the careful function is bypassed by the shortest request anyone could
-- write.
--
-- **This is not hypothetical.** One of the three tenants on the hosted
-- project is in exactly that state: `is_sst_registered` true, a
-- registration number present, `sst_registered_from` null, and the
-- default tax code still `NA` at zero per cent. Every line raised there
-- defaults to no tax on a registered company; and because the effective
-- date is null, the `reject_tax_before_registration` triggers `0145`
-- installed have no date to compare a document against. Three of the
-- four, exactly as the header warned.
--
-- The house rule is that a rule enforced only in Dart is not enforced.
-- The Dart is fine here — `sst_card.dart` calls the function properly.
-- It is simply not a control, because being the only polite client never
-- is.
--
-- ## Why a trigger and not a check constraint
--
-- A `check` on the row would be stronger and was the first instinct:
--
--     check (not is_sst_registered or sst_registered_from is not null)
--
-- It cannot be used. The tenant above violates it today, so it could
-- only go on as `not valid` — and a `not valid` check is still evaluated
-- on every `UPDATE` of the row. Correcting that company's phone number
-- would then be rejected for an unrelated reason, and the record would
-- be frozen until the SST problem was fixed. Repairing live tenant data
-- is the operator's call, not this migration's, and a constraint that
-- holds a record hostage until they make it is not a fix.
--
-- The trigger fires only when one of the three columns actually changes.
-- Unrelated edits pass untouched; the bad state is preserved exactly as
-- found, visible and reportable, until somebody decides to correct it —
-- through the function, which is now the only way in.
--
-- ## The session flag
--
-- Same idiom as `app.fs_writing` in `0171`/`0172`: the function raises a
-- transaction-local flag, the trigger honours it, and nothing outside a
-- transaction that has been through the function can raise it. `true`
-- for `is_local`, so it cannot leak into the next statement on a pooled
-- connection.

-- ---------------------------------------------------------------------
-- The guard
-- ---------------------------------------------------------------------
create or replace function app.guard_sst_registration()
returns trigger language plpgsql
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  -- Only when the registration itself moves. `is distinct from` rather
  -- than `<>` so a null on either side counts as a change; with `<>` a
  -- transition to or from null compares null, the `if` does not fire,
  -- and the one case this exists to catch — a boolean set true while the
  -- date stays null — walks straight through.
  if (new.is_sst_registered, new.sst_registered_from, new.sst_registration_no)
     is distinct from
     (old.is_sst_registered, old.sst_registered_from, old.sst_registration_no)
  then
    if coalesce(current_setting('app.sst_writing', true), '') <> 'on' then
      raise exception
        'SST registration is not a field to set. It is the boolean, the '
        'number, the effective date and the default tax code together, '
        'and setting one of them leaves a company that believes it is '
        'charging tax and is not. Use set_sst_registration().'
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

create trigger guard_sst_registration
  before update on public.organizations
  for each row execute function app.guard_sst_registration();

-- ---------------------------------------------------------------------
-- The one door, which now raises the flag on its way through
-- ---------------------------------------------------------------------
--
-- `0145`'s body verbatim. `create or replace` needs the whole function,
-- so the whole function is here, but the *only* edit is the pair of
-- `set_config` calls around the one statement that writes the guarded
-- columns. Everything else — that deregistering clears the number and
-- the date, that it refuses without an `NA` code to fall back to, and
-- that the default is carried by `tax_codes.is_default` rather than by
-- the long-dead `organizations.default_sales_tax_code_id` — is `0145`'s
-- and is deliberately untouched.

create or replace function public.set_sst_registration(
  p_org_id uuid,
  p_registered boolean,
  p_from date default null,
  p_registration_no text default null,
  p_tax_code text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_code_id uuid;
  v_rate numeric;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'You cannot change this company''s tax registration'
      using errcode = '42501';
  end if;

  if p_registered then
    if p_from is null then
      raise exception
        'SST registration needs the date it took effect. Invoices dated '
        'before it must not carry tax, and without the date there is '
        'nothing to compare them against.';
    end if;
    if nullif(btrim(coalesce(p_registration_no, '')), '') is null then
      raise exception
        'SST registration needs the registration number. It has to be '
        'printed on every tax invoice.';
    end if;

    -- Which tax the company registered for is not something to guess:
    -- service tax and sales tax are separate registrations under
    -- separate Acts, at different rates, and the wrong default is a
    -- wrong number on every invoice raised from here on.
    if nullif(btrim(coalesce(p_tax_code, '')), '') is null then
      raise exception
        'Choose the tax code new lines should default to — ST8 or ST6 '
        'for service tax, SL10 or SL5 for sales tax.';
    end if;

    select id, rate into v_code_id, v_rate
      from public.tax_codes
     where org_id = p_org_id and code = btrim(p_tax_code) and is_active;

    if v_code_id is null then
      raise exception 'No active tax code % in this company', p_tax_code;
    end if;
    if coalesce(v_rate, 0) <= 0 then
      raise exception
        'Tax code % is zero rated, so making it the default would leave '
        'every line at nothing. Choose the rate you registered at.',
        p_tax_code;
    end if;
  else
    -- Coming off the register. The number goes with it: a company that
    -- deregistered and kept its old number would print it on invoices
    -- that must not carry one.
    select id into v_code_id
      from public.tax_codes
     where org_id = p_org_id and code = 'NA' and is_active;
    if v_code_id is null then
      raise exception
        'This company has no "NA" tax code to fall back to. Add one '
        'before switching registration off.';
    end if;
  end if;

  perform set_config('app.sst_writing', 'on', true);
  update public.organizations
     set is_sst_registered   = p_registered,
         sst_registration_no = case when p_registered
                               then btrim(p_registration_no) else null end,
         sst_registered_from = case when p_registered then p_from else null end
   where id = p_org_id;
  perform set_config('app.sst_writing', 'off', true);

  -- Exactly one default, always. Cleared first rather than toggled, so a
  -- company that somehow had two — or none, which is also a state this
  -- database is in — comes out of here with one.
  update public.tax_codes set is_default = false
   where org_id = p_org_id and is_default;

  update public.tax_codes set is_default = true where id = v_code_id;
end; $$;

comment on function public.set_sst_registration(uuid, boolean, date, text, text) is
  'The only way to change a company''s SST registration. A trigger on '
  'organizations rejects a direct write to is_sst_registered, '
  'sst_registered_from or sst_registration_no.';
