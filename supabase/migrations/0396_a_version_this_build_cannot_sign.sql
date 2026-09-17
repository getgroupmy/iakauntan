-- =====================================================================
-- iAkauntan :: 0396 a version this build cannot sign
--
-- `prepare_einvoice` stamps the document's e-Invoice version like this:
--
--     coalesce(v_org.settings ->> 'einvoice_version', '1.0')
--
-- and `ubl.ts` puts whatever comes out into `listVersionID` on the
-- `InvoiceTypeCode` it sends to LHDN. Nothing between those two points
-- checks it. `organizations.settings` is free-form jsonb and `0010`'s
-- update policy covers the whole row, so any admin of the company can
-- put any string in there — `banana` would be submitted as the version
-- of a tax document.
--
-- ---------------------------------------------------------------------
-- The string that matters is `1.1`
--
-- `0015`'s own comment on the columns it created says it:
--
--     -- PKCS#12 material for the XAdES signature required by version 1.1
--     cert_pem text,
--     cert_private_key_pem text,
--
-- and `README.md` says the other half: documents are submitted as
-- version `1.0` unsigned, version 1.1 needs an XAdES signature from a
-- Malaysian certificate authority, and the signing step is not
-- implemented. That is honest and it is not the defect. `0107` even
-- built the setter for the certificate — five parameters, `p_cert_pem`
-- and its four companions — and nothing has ever passed one, which is
-- how this was found.
--
-- The defect is that nothing enforces the scope the README describes.
-- Set `einvoice_version` to `1.1` in the settings and the next document
-- is stamped `1.1` and submitted with no signature in it. The version
-- on a document is a claim about that document. A document claiming to
-- be the signed version and carrying no signature is worse than one
-- that is refused: refused is a message somebody reads, and this is a
-- filing with a false statement of what it is.
--
-- The same reasoning as `0385` and `0386` — a control that appears to
-- have been applied is worse than one that is absent — and `0388` for
-- the shape: a stated intention with nothing behind it.
--
-- ---------------------------------------------------------------------
-- And the default faces the wrong way
--
-- `0007` gave the column `default '1.1'` on a build that could only
-- ever produce `1.0`. The only reason it has never bitten is that the
-- single insert path happens to name the column every time. A second
-- one, or a row inserted by hand during an incident, gets the default
-- and is wrong in the direction that submits.
--
-- ---------------------------------------------------------------------
-- One predicate, said once
--
-- What this build can produce is a fact about this build, so it is
-- written down once and both the constraint and the trigger read it.
-- Two copies of a rule is how two copies come to disagree — `0393`'s
-- argument for `app.set_filed_by()`.
--
-- The trigger exists as well as the constraint because they answer
-- different questions. The constraint is the structure: no row of this
-- table may claim a version this build cannot produce, whatever writes
-- it. The trigger is the explanation, and it fires first, so the person
-- gets a sentence telling them what to do rather than a constraint name.
--
-- No behaviour can tell the two apart, and the mutation run says so:
-- dropping the constraint leaves every assertion in
-- `einvoice_statutory.sql` passing, because the trigger covers every
-- path a test can take. That is not the `0387` case where an unkillable
-- mutant meant redundant code — there, two triggers derived the same
-- value and could disagree; here both read one predicate and cannot.
-- What survives is a declaration, and a declaration is worth having:
-- it is what a schema dump shows, and it makes removing the rule a
-- deliberate act rather than a side effect of dropping a trigger. So
-- its existence is asserted directly instead of being inferred from
-- behaviour that cannot see it.
--
-- **Whoever implements the XAdES signature changes
-- `app.einvoice_version_supported` and nothing else.** That is the
-- point of putting it there: turning signing on is one deliberate edit
-- in a place that says what it is for, rather than the absence of a
-- check nobody knew was missing. Note that Postgres does not re-verify
-- existing rows when the function behind a check constraint changes —
-- which is harmless in the direction this will move, since widening
-- what is allowed cannot invalidate a row already there.
-- =====================================================================

-- Immutable so a check constraint may call it. It is a constant
-- function of the build, which is exactly what immutable means here.
create or replace function app.einvoice_version_supported(p_version text)
returns boolean
language sql
immutable
set search_path = pg_catalog, public, app, pg_temp
as $$
  -- `1.0` only, and deliberately so: `1.1` requires an XAdES signature
  -- from a Malaysian certificate authority and the signing step is not
  -- implemented. `einvoice_credentials` has held the columns for the
  -- certificate since `0015` and nothing has ever filled them.
  select p_version = '1.0';
$$;

comment on function app.einvoice_version_supported(text) is
  'The e-Invoice versions this build can actually produce. Change this '
  'and nothing else when the XAdES signature is implemented — the check '
  'constraint and the trigger on einvoice_documents both read it, so '
  'they cannot come to disagree about what is supported.';

-- ---------------------------------------------------------------------
-- The default `0007` set the other way round.
alter table public.einvoice_documents
  alter column einvoice_version set default '1.0';

-- ---------------------------------------------------------------------
-- The structure. `not valid` is not used: every row in this table was
-- written by `prepare_einvoice`, which has always resolved the version
-- through `coalesce(..., '1.0')`, so there is nothing here to grandfather
-- and an apply that fails would be telling us something we want to know.
alter table public.einvoice_documents
  add constraint einvoice_documents_version_supported
  check (app.einvoice_version_supported(einvoice_version));

-- ---------------------------------------------------------------------
-- The explanation, which fires first.
create or replace function app.check_einvoice_version()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  if not app.einvoice_version_supported(new.einvoice_version) then
    raise exception
      'This build submits e-Invoices at version 1.0. Version % needs an '
      'XAdES signature from a Malaysian certificate authority and the '
      'signing step is not implemented, so a document stamped % would '
      'reach LHDN claiming a signature it does not carry. Remove '
      '"einvoice_version" from the organization settings, or set it to '
      '1.0.',
      new.einvoice_version, new.einvoice_version
      -- feature_not_supported, not a check violation: the value is not
      -- malformed, it is a thing this build cannot do.
      using errcode = '0A000';
  end if;
  return new;
end $$;

create trigger check_einvoice_version
  before insert or update of einvoice_version on public.einvoice_documents
  for each row execute function app.check_einvoice_version();

comment on constraint einvoice_documents_version_supported
  on public.einvoice_documents is
  'The version on a document is a claim about that document. `0396`: '
  'prepare_einvoice read this straight out of free-form organization '
  'settings, which any admin may write, so a document could be stamped '
  '1.1 — the signed version — and submitted with no signature in it.';
