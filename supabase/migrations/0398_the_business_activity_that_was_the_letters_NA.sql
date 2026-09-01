-- =====================================================================
-- iAkauntan :: 0398 the business activity that was the letters NA
--
-- `organizations.business_activity` is written by nothing.
-- `create_organization` takes `p_business_activity` and the onboarding
-- form does not pass it — the sweep's fifteenth unpassed parameter —
-- and `Repo.updateCompanyDetails` writes `msic_code` and omits this
-- column beside it.
--
-- `prepare_einvoice` snapshots it onto every document as
-- `supplier_business_activity`, and `ubl.ts` does this with it:
--
--     party.IndustryClassificationCode = v(msicCode, {
--       name: businessActivity || "NA",
--     });
--
-- So every e-Invoice, from every organization, has ever told LHDN that
-- what the business does is `NA`.
--
-- ---------------------------------------------------------------------
-- The answer is already in the database
--
-- `ref_msic_codes` has held `(code, description)` since `0002`, and the
-- MSIC code is picked from exactly that list — `msic_picker.dart` reads
-- it, the onboarding form sends `p_msic_code` from it, and the company
-- card sets it. `IndustryClassificationCode` carries the code, and its
-- `name` is the description *of that code*. The two are one fact.
--
-- Which is why this migration does not add a text box.
--
-- A free-text `business_activity` beside a picked `msic_code` is two
-- places to say one thing, and the second is how the two come to
-- disagree — `0393`'s argument for `app.set_filed_by()`, and `0396`'s
-- for one predicate behind both the constraint and the trigger. An
-- organization that already has its own wording keeps it; one that has
-- not is not asked to retype what it chose from a list a moment ago.
--
-- ---------------------------------------------------------------------
-- Resolved once, at the document
--
-- Filled in on insert rather than read at send time, because an
-- e-Invoice is a snapshot and `prepare_einvoice` is careful to make it
-- one: it copies the supplier's name, TIN, address and SST number onto
-- the row so that a document filed in March still says what the company
-- was in March. A description resolved at send time would rewrite the
-- history of filed documents whenever the reference list was corrected.
--
-- A trigger rather than a change to `prepare_einvoice`, for `0396`'s
-- reason: it is the only insert path today, and a rule that depends on
-- that stops being true the moment somebody adds another.
--
-- ---------------------------------------------------------------------
-- What this does not claim
--
-- It does not make an e-Invoice correct that was otherwise wrong. `NA`
-- is a value LHDN accepts, and `ubl.ts` emits the classification block
-- only when there is an MSIC code at all, so a company that has not
-- picked one still sends nothing here and that is still right. What
-- changes is that a company which *has* said what it does now says it
-- on the document instead of saying `NA`.
-- =====================================================================

create or replace function app.business_activity_of(p_org_id uuid)
returns text
language sql
stable
set search_path = pg_catalog, public, app, pg_temp
as $$
  -- The organization's own wording if it has one, and otherwise the
  -- description of the MSIC code it picked. Blank is not a wording:
  -- `''` and null both mean nobody has said anything.
  select coalesce(
           nullif(btrim(o.business_activity), ''),
           (select r.description from public.ref_msic_codes r
             where r.code = o.msic_code))
    from public.organizations o
   where o.id = p_org_id;
$$;

comment on function app.business_activity_of(uuid) is
  'What the company does, for the `name` on an e-Invoice''s '
  'IndustryClassificationCode. Derived from the MSIC code rather than '
  'typed beside it: `0398` found the column had never been written by '
  'anything, so every document said `NA`, while `ref_msic_codes` held '
  'the answer for the code the picker had already set.';

-- ---------------------------------------------------------------------
create or replace function app.set_einvoice_business_activity()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- Only when the snapshot has none. A caller that supplies one is
  -- believed, the same way `0393`'s `set_filed_by` believes a caller
  -- that names somebody: an import knows what the company did at the
  -- time better than today's reference list does.
  if nullif(btrim(coalesce(new.supplier_business_activity, '')), '') is null
  then
    new.supplier_business_activity := app.business_activity_of(new.org_id);
  end if;
  return new;
end $$;

create trigger set_einvoice_business_activity
  before insert on public.einvoice_documents
  for each row execute function app.set_einvoice_business_activity();

revoke all on function app.set_einvoice_business_activity()
  from public, anon, authenticated;
