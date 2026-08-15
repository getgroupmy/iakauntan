-- =====================================================================
-- iAkauntan :: becoming SST registered, and the date it took effect
--
-- ---------------------------------------------------------------------
-- What was wrong
--
-- `organizations.is_sst_registered` has existed since 0001 and is read
-- by one file in the whole system: the settings card that draws the
-- switch. Nothing in the ledger, the document editor, the invoice PDF or
-- the e-Invoice path consults it. Turning it on stored a boolean and
-- changed a chip.
--
-- `default_sales_tax_code_id` and `default_purchase_tax_code_id` are
-- worse: 0012 sets them at creation, pointing at service tax for a
-- company created as registered, and *nothing anywhere reads them*.
--
-- What actually decides the tax on a line is `tax_codes.is_default` —
-- see `applyItemToLine`, which takes the item's own code and falls back
-- to whichever code carries that flag. And 0012 seeds `NA` as the
-- default unconditionally, registered or not.
--
-- So a company that registered for SST, in the app, by the only means
-- the app offers, went on defaulting every invoice line to 0%. This is
-- not hypothetical: it is the state of a company in this database right
-- now, whose taxed invoices were each corrected by hand.
--
-- ---------------------------------------------------------------------
-- Why the date, and not just the switch
--
-- Registration takes effect on a date, and it is rarely the date
-- somebody gets round to telling the accounting system. Both directions
-- are wrong without it:
--
--   * told late, and invoices raised between the effective date and
--     today were issued without tax that was due,
--   * told early, and invoices before the effective date carry tax the
--     company had no authority to charge.
--
-- The second is the one this migration can actually prevent, because it
-- is about documents raised from now on. It is also the more serious:
-- collecting service tax you are not registered for is not a rounding
-- error.
--
-- ---------------------------------------------------------------------
-- What the guard deliberately does not do
--
-- It does not refuse tax on a document belonging to a company that is
-- simply not registered. That rule sounds right and would break real
-- data: the flag has never done anything, so nobody has had a reason to
-- keep it true, and there is at least one company here carrying tax on
-- posted documents with the flag set and no date at all.
--
-- So the guard fires only where somebody has stated an effective date.
-- It is opt-in by knowing the answer, which is the only honest basis for
-- refusing a posting.
-- =====================================================================

alter table public.organizations
  add column sst_registered_from date;

comment on column public.organizations.sst_registered_from is
  'The date SST registration took effect. Set through '
  'set_sst_registration(). While it is null nothing is enforced; once it '
  'is set, a document dated before it may not carry tax.';

comment on column public.organizations.default_sales_tax_code_id is
  'Dead since 0001: written by create_organization and read by nothing. '
  'The tax code a line actually defaults to is the one carrying '
  'tax_codes.is_default. Kept rather than dropped because '
  'create_organization still writes it, and a migration that removed the '
  'column would have to rewrite that function to no purpose.';

comment on column public.organizations.default_purchase_tax_code_id is
  'Dead since 0001. See default_sales_tax_code_id.';

-- ---------------------------------------------------------------------
-- One way to become registered, which does all of it
--
-- The switch on the settings card writes a boolean. This writes the
-- boolean, the number, the date, *and* the default tax code — because
-- the four together are what "we are SST registered" means, and any
-- three of them is a company that believes it is charging tax and is
-- not.
-- ---------------------------------------------------------------------
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

  update public.organizations
     set is_sst_registered   = p_registered,
         sst_registration_no = case when p_registered
                               then btrim(p_registration_no) else null end,
         sst_registered_from = case when p_registered then p_from else null end
   where id = p_org_id;

  -- Exactly one default, always. Cleared first rather than toggled, so a
  -- company that somehow had two — or none, which is also a state this
  -- database is in — comes out of here with one.
  update public.tax_codes set is_default = false
   where org_id = p_org_id and is_default;

  update public.tax_codes set is_default = true where id = v_code_id;
end; $$;

revoke all on function public.set_sst_registration(uuid, boolean, date, text, text)
  from public, anon;
grant execute on function
  public.set_sst_registration(uuid, boolean, date, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- A document dated before the company was registered carries no tax
--
-- A trigger rather than a check inside the posting functions, for two
-- reasons: it catches the mistake when the document is saved rather than
-- when somebody finally posts it, and it does not require rewriting
-- `post_sales_document` and `post_purchase_document`, which are the most
-- load-bearing functions in this system and not worth disturbing for a
-- rule that has nothing to do with how a document posts.
-- ---------------------------------------------------------------------
create or replace function app.reject_tax_before_registration()
returns trigger
language plpgsql
set search_path = public, app, pg_temp as $$
declare
  v_from date;
begin
  if coalesce(new.tax_amount, 0) = 0 then
    return new;
  end if;

  select sst_registered_from into v_from
    from public.organizations where id = new.org_id;

  if v_from is not null and new.doc_date < v_from then
    raise exception
      'This document is dated % , before SST registration took effect on '
      '%. A company cannot charge tax it was not registered for. Remove '
      'the tax, or correct the registration date in Settings.',
      new.doc_date, v_from
      using errcode = '22000';
  end if;

  return new;
end; $$;

create trigger sales_documents_tax_before_registration
  before insert or update of tax_amount, doc_date on public.sales_documents
  for each row execute function app.reject_tax_before_registration();

create trigger purchase_documents_tax_before_registration
  before insert or update of tax_amount, doc_date on public.purchase_documents
  for each row execute function app.reject_tax_before_registration();
