-- =====================================================================
-- The invoice a supplier sent us
--
-- `_shared/ubl_parse.ts` (0649's neighbour, committed just before this)
-- can READ a MyInvois document. Nothing could keep one. This is the
-- place a received document lands, and the two things worth doing with
-- it once it has: linking the supplier, and turning it into a draft
-- bill.
--
-- ## The parse stays in TypeScript, and that is the whole point
--
-- There is no SQL parser here and there will not be one. `ubl_parse.ts`
-- is 29 assertions deep, most of them a round trip against the builder
-- that writes the same binding, and a second implementation of one
-- contract is a contract that drifts -- silently, because both halves
-- keep passing their own tests. So the edge function parses and this
-- stores the RESULT, alongside the raw document, so that a later fix to
-- the parser can be re-run against everything already received.
--
-- `p_parsed` is therefore the shape of `ReceivedInvoice`, camelCase and
-- all, read here with `->>` and coerced defensively. It arrives from a
-- function we wrote, but the RPC is granted to `authenticated`, so it
-- must survive a caller who sends something else entirely. Hence
-- `app.received_num`, which returns zero rather than raising when a
-- field that should be a number is the word "later".
--
-- ## Importing the same file twice is the commonest thing that happens
--
-- Somebody forwards the e-mail again, or clicks import on the file
-- still sitting in Downloads. Two rows means two draft bills means a
-- supplier paid twice, and nothing downstream would notice. So the raw
-- document is hashed and the hash is unique per company.
--
-- The hash is taken of `p_raw::text`, and it matters that this is
-- `jsonb`: Postgres renders jsonb canonically -- keys sorted,
-- whitespace gone, numbers normalised -- so the same document
-- re-exported with different formatting hashes the SAME. A hash of the
-- bytes would have caught only the identical file, which is the case
-- that needs catching least.
--
-- A second import returns the id of the first and says so, rather than
-- raising. A duplicate is not an error; it is an answer.
--
-- ## The reference codes come from somebody else's system
--
-- `purchase_document_lines.classification_code` and `uom_code` have
-- foreign keys into our reference tables. A received document carries
-- whatever its producer used, and a code we merely do not stock would
-- refuse the entire import over a field nobody reads. So the received
-- lines carry those codes as PLAIN TEXT with no foreign key, and the
-- draft bill carries them across only where they resolve. What arrived
-- is kept either way; what we could not recognise simply does not reach
-- the bill.
--
-- ## Our arithmetic wins on the bill, and the difference is written down
--
-- `app.calc_document_line` and `app.recalc_purchase_totals` recompute a
-- purchase document from its lines, and they run on every insert. So
-- the supplier's stated totals CANNOT be written onto the bill; the
-- triggers would replace them within the same statement.
--
-- That is the right behaviour -- the bill has to add up by our rules,
-- because it is going into our ledger -- but it hides exactly the
-- difference `receivedTotalsAgree` exists to surface. So after the
-- lines are in, the drafted total is compared with what the supplier
-- said was payable, and any difference is written into the bill's
-- internal notes naming both figures. A sen of rounding is worth a
-- sentence; a hundred ringgit is worth finding before it is paid.
--
-- ## What the client may write, which is nothing
--
-- The policies are SELECT and DELETE. There is no update policy,
-- because a policy is a rule about ROWS and the interesting rule here
-- is about COLUMNS: a record of what a supplier sent is worthless if
-- the person who received it can edit the figures. Status, the linked
-- contact and the drafted bill each move through a function that says
-- which transitions exist. Deleting the whole row is a different act --
-- "this was not for us" -- and it is allowed, because the alternative
-- is a list that fills with other people's invoices forever.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Reading a field out of a document somebody else wrote
-- ---------------------------------------------------------------------
create or replace function app.received_num(p jsonb, p_key text)
returns numeric
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when p is null or jsonb_typeof(p) <> 'object' then 0
    when jsonb_typeof(p -> p_key) = 'number' then (p ->> p_key)::numeric
    when (p ->> p_key) ~ '^-?[0-9]+(\.[0-9]+)?$' then (p ->> p_key)::numeric
    else 0
  end;
$$;

comment on function app.received_num is
  'A number out of a parsed document, or zero. Never raises: the value '
  'may be anything at all, and one bad field must not lose the import.';

create or replace function app.received_text(p jsonb, p_key text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when p is null or jsonb_typeof(p) <> 'object' then null
    when jsonb_typeof(p -> p_key) not in ('string', 'number') then null
    else nullif(btrim(p ->> p_key), '')
  end;
$$;

comment on function app.received_text is
  'A string out of a parsed document, trimmed, empty becoming null. An '
  'object or array where a string was expected becomes null rather '
  'than its JSON rendering.';

-- ---------------------------------------------------------------------
-- What arrived
-- ---------------------------------------------------------------------
create table public.received_einvoices (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations (id) on delete cascade,

  -- How it reached us. Only one value today, and that is deliberate:
  -- there is no MyInvois fetcher, because writing one against an API
  -- nobody here can call is writing one nobody has tested.
  source              text not null default 'upload'
                      check (source in ('upload')),

  -- MyInvois identifiers, when the document carries them. A document
  -- sent directly by a supplier often does not.
  myinvois_uuid       text,
  myinvois_long_id    text,

  doc_no              text,
  issue_date          date,
  issue_time          time,
  type_code           text,
  einvoice_version    text,

  -- No foreign key: the currency is whatever the producer wrote.
  -- `draft_bill_from_received_einvoice` is where it has to be one we
  -- know, and it says so by name when it is not.
  currency            text,
  exchange_rate       numeric(18, 8) not null default 1,

  supplier_name       text,
  supplier_tin        text,
  supplier_id_type    text,
  supplier_id_value   text,
  supplier_sst_no     text,
  supplier_email      text,
  supplier_phone      text,
  supplier_address    jsonb not null default '{}'::jsonb,

  buyer_name          text,
  buyer_tin           text,
  buyer_id_type       text,
  buyer_id_value      text,
  buyer_sst_no        text,
  buyer_email         text,
  buyer_phone         text,
  buyer_address       jsonb not null default '{}'::jsonb,

  total_excl_tax      numeric(18, 2) not null default 0,
  total_incl_tax      numeric(18, 2) not null default 0,
  total_discount      numeric(18, 2) not null default 0,
  total_charges       numeric(18, 2) not null default 0,
  total_tax           numeric(18, 2) not null default 0,
  rounding_amount     numeric(18, 2) not null default 0,
  payable_amount      numeric(18, 2) not null default 0,

  -- A credit or debit note names the invoice it adjusts.
  original_doc_no     text,
  original_uuid       text,

  -- The document exactly as it arrived, and its hash. The raw copy is
  -- what makes a later parser fix retroactive.
  raw                 jsonb not null,
  payload_hash        text not null,

  -- What the parser could not make sense of, in its own words.
  problems            jsonb not null default '[]'::jsonb,

  status              text not null default 'received'
                      check (status in ('received', 'billed', 'ignored')),

  contact_id          uuid,
  bill_id             uuid,

  created_by          uuid references auth.users (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  -- The same document twice is one row. See the header.
  unique (org_id, payload_hash),

  -- The parent key the lines' composite reference needs. 0160's rule:
  -- a foreign key on the id alone says nothing about whose row it is.
  unique (org_id, id),

  -- The column list is 0511's rule and it is not optional: a composite
  -- `set null` with no list nulls EVERY referencing column, and the
  -- first of ours is `org_id`, which is NOT NULL -- so deleting a
  -- contact would raise rather than empty the reference.
  constraint received_einvoices_contact_same_org
    foreign key (org_id, contact_id)
    references public.contacts (org_id, id) on delete set null (contact_id),
  constraint received_einvoices_bill_same_org
    foreign key (org_id, bill_id)
    references public.purchase_documents (org_id, id) on delete set null (bill_id)
);

create index on public.received_einvoices (org_id, status, issue_date desc);
create index on public.received_einvoices (org_id, contact_id);
create index on public.received_einvoices (org_id, supplier_tin);

comment on table public.received_einvoices is
  'A MyInvois document somebody sent US, parsed by _shared/ubl_parse.ts '
  'and kept whole. The inbound half of e-Invoice. 0650.';
comment on column public.received_einvoices.payload_hash is
  'sha256 of raw::text. jsonb renders canonically, so the same document '
  'formatted differently hashes the same and imports once.';

create trigger set_updated_at before update on public.received_einvoices
  for each row execute function app.set_updated_at();

create table public.received_einvoice_lines (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations (id) on delete cascade,
  received_id         uuid not null,

  -- The POSITION in the document, counted here. The document's own
  -- line identifier goes in `source_line_no` and is not trusted to be
  -- unique, sequential, or a number at all: `ubl_parse.ts` reads it
  -- straight out of `ID`, and a producer that numbers every line "1"
  -- would otherwise take out the whole import on this unique
  -- constraint.
  line_no             integer not null,
  source_line_no      text,

  -- Text, not a reference. See the header.
  classification_code text,
  description         text not null default '',
  quantity            numeric(18, 4) not null default 1,
  uom_code            text,
  unit_price          numeric(18, 4) not null default 0,
  discount_amount     numeric(18, 2) not null default 0,

  tax_type_code       text,
  tax_rate            numeric(9, 4) not null default 0,
  tax_amount          numeric(18, 2) not null default 0,
  tax_exemption_reason text,

  total_excl_tax      numeric(18, 2) not null default 0,
  total_incl_tax      numeric(18, 2) not null default 0,

  product_tariff_code text,
  country_of_origin   text,

  created_at          timestamptz not null default now(),
  unique (received_id, line_no),

  constraint received_einvoice_lines_document_same_org
    foreign key (org_id, received_id)
    references public.received_einvoices (org_id, id) on delete cascade
);

create index on public.received_einvoice_lines (received_id);

alter table public.received_einvoices enable row level security;
alter table public.received_einvoice_lines enable row level security;

create policy received_einvoices_select on public.received_einvoices
  for select to authenticated using (app.is_org_member(org_id));
create policy received_einvoices_delete on public.received_einvoices
  for delete to authenticated using (app.can_write(org_id));

create policy received_einvoice_lines_select on public.received_einvoice_lines
  for select to authenticated using (app.is_org_member(org_id));
create policy received_einvoice_lines_delete on public.received_einvoice_lines
  for delete to authenticated using (app.can_write(org_id));

grant select, delete on public.received_einvoices to authenticated;
grant select, delete on public.received_einvoice_lines to authenticated;
revoke all on public.received_einvoices from anon;
revoke all on public.received_einvoice_lines from anon;

-- ---------------------------------------------------------------------
-- Keeping one
-- ---------------------------------------------------------------------
create or replace function public.record_received_einvoice(
  p_org_id uuid,
  p_parsed jsonb,
  p_raw    jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_hash     text;
  v_existing uuid;
  v_id       uuid;
  v_supplier jsonb;
  v_buyer    jsonb;
  v_currency text;
  v_rate     numeric;
  v_line     jsonb;
  v_no       integer := 0;
  v_tin      text;
  v_contact  uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'Not allowed to record e-Invoices for organization %',
      p_org_id using errcode = '42501';
  end if;

  if p_raw is null or jsonb_typeof(p_raw) <> 'object' then
    raise exception 'The document must be a JSON object'
      using errcode = '22023';
  end if;
  if p_parsed is null or jsonb_typeof(p_parsed) <> 'object' then
    raise exception 'The parsed document must be a JSON object'
      using errcode = '22023';
  end if;

  v_hash := encode(sha256(convert_to(p_raw::text, 'UTF8')), 'hex');

  select id into v_existing
    from public.received_einvoices
   where org_id = p_org_id and payload_hash = v_hash;
  if v_existing is not null then
    -- Not an error. Somebody imported the same file twice, which is the
    -- single commonest thing that happens here.
    return jsonb_build_object('id', v_existing, 'duplicate', true);
  end if;

  v_supplier := coalesce(p_parsed -> 'supplier', '{}'::jsonb);
  v_buyer    := coalesce(p_parsed -> 'buyer', '{}'::jsonb);

  -- Three letters or nothing. A char(3) column would raise on a longer
  -- value and lose the whole import over a field the bill re-checks.
  v_currency := upper(app.received_text(p_parsed, 'currency'));
  if v_currency is not null and length(v_currency) <> 3 then
    v_currency := null;
  end if;

  v_rate := app.received_num(p_parsed, 'exchangeRate');
  if v_rate <= 0 then
    v_rate := 1;
  end if;

  v_tin := app.received_text(v_supplier, 'tin');

  insert into public.received_einvoices (
    org_id, source, myinvois_uuid, myinvois_long_id,
    doc_no, issue_date, issue_time, type_code, einvoice_version,
    currency, exchange_rate,
    supplier_name, supplier_tin, supplier_id_type, supplier_id_value,
    supplier_sst_no, supplier_email, supplier_phone, supplier_address,
    buyer_name, buyer_tin, buyer_id_type, buyer_id_value,
    buyer_sst_no, buyer_email, buyer_phone, buyer_address,
    total_excl_tax, total_incl_tax, total_discount, total_charges,
    total_tax, rounding_amount, payable_amount,
    original_doc_no, original_uuid,
    raw, payload_hash, problems, created_by)
  values (
    p_org_id, 'upload',
    app.received_text(p_parsed, 'myinvoisUuid'),
    app.received_text(p_parsed, 'myinvoisLongId'),
    app.received_text(p_parsed, 'docNo'),
    -- A date the producer mangled must not lose the document: the
    -- parser already says so in `problems`, and a null here is honest.
    case when app.received_text(p_parsed, 'issueDate') ~ '^\d{4}-\d{2}-\d{2}$'
      then (app.received_text(p_parsed, 'issueDate'))::date end,
    case when app.received_text(p_parsed, 'issueTime') ~ '^\d{2}:\d{2}(:\d{2})?'
      then (substring(app.received_text(p_parsed, 'issueTime') from 1 for 8))::time end,
    app.received_text(p_parsed, 'typeCode'),
    app.received_text(p_parsed, 'version'),
    v_currency, v_rate,
    app.received_text(v_supplier, 'name'), v_tin,
    app.received_text(v_supplier, 'idType'),
    app.received_text(v_supplier, 'idValue'),
    app.received_text(v_supplier, 'sstNo'),
    app.received_text(v_supplier, 'email'),
    app.received_text(v_supplier, 'phone'),
    coalesce(v_supplier -> 'address', '{}'::jsonb),
    app.received_text(v_buyer, 'name'),
    app.received_text(v_buyer, 'tin'),
    app.received_text(v_buyer, 'idType'),
    app.received_text(v_buyer, 'idValue'),
    app.received_text(v_buyer, 'sstNo'),
    app.received_text(v_buyer, 'email'),
    app.received_text(v_buyer, 'phone'),
    coalesce(v_buyer -> 'address', '{}'::jsonb),
    app.received_num(p_parsed, 'totalExclTax'),
    app.received_num(p_parsed, 'totalInclTax'),
    app.received_num(p_parsed, 'totalDiscount'),
    app.received_num(p_parsed, 'totalCharges'),
    app.received_num(p_parsed, 'totalTax'),
    app.received_num(p_parsed, 'roundingAmount'),
    app.received_num(p_parsed, 'payableAmount'),
    app.received_text(p_parsed, 'originalDocNo'),
    app.received_text(p_parsed, 'originalUuid'),
    p_raw, v_hash,
    case when jsonb_typeof(p_parsed -> 'problems') = 'array'
      then p_parsed -> 'problems' else '[]'::jsonb end,
    auth.uid())
  returning id into v_id;

  if jsonb_typeof(p_parsed -> 'lines') = 'array' then
    for v_line in select * from jsonb_array_elements(p_parsed -> 'lines') loop
      v_no := v_no + 1;
      insert into public.received_einvoice_lines (
        org_id, received_id, line_no, source_line_no,
        classification_code, description, quantity, uom_code, unit_price,
        discount_amount, tax_type_code, tax_rate, tax_amount,
        tax_exemption_reason, total_excl_tax, total_incl_tax,
        product_tariff_code, country_of_origin)
      values (
        p_org_id, v_id, v_no,
        app.received_text(v_line, 'lineNo'),
        app.received_text(v_line, 'classificationCode'),
        coalesce(app.received_text(v_line, 'description'), ''),
        app.received_num(v_line, 'quantity'),
        app.received_text(v_line, 'uomCode'),
        app.received_num(v_line, 'unitPrice'),
        app.received_num(v_line, 'discountAmount'),
        app.received_text(v_line, 'taxTypeCode'),
        app.received_num(v_line, 'taxRate'),
        app.received_num(v_line, 'taxAmount'),
        app.received_text(v_line, 'taxExemptionReason'),
        app.received_num(v_line, 'totalExclTax'),
        app.received_num(v_line, 'totalInclTax'),
        app.received_text(v_line, 'productTariffCode'),
        app.received_text(v_line, 'countryOfOrigin'));
    end loop;
  end if;

  -- Match the supplier by IDENTIFIER only.
  --
  -- Matching on the name as well was the obvious next line and is
  -- deliberately not here: "Sinar Holdings" and "Sinar Holdings Sdn
  -- Bhd" are two rows in most contact lists, and a wrong link that
  -- nobody chose becomes a bill against the wrong supplier. A TIN or a
  -- registration number is an assertion; a name is a resemblance. The
  -- screen can offer candidates by name, where somebody sees the choice
  -- being made.
  if v_tin is not null then
    select c.id into v_contact
      from public.contacts c
     where c.org_id = p_org_id
       and c.deleted_at is null
       and c.contact_type in ('supplier', 'both')
       and upper(btrim(c.tin)) = upper(btrim(v_tin))
     order by c.created_at
     limit 1;
  end if;

  if v_contact is null and app.received_text(v_supplier, 'idValue') is not null then
    select c.id into v_contact
      from public.contacts c
     where c.org_id = p_org_id
       and c.deleted_at is null
       and c.contact_type in ('supplier', 'both')
       and upper(btrim(coalesce(c.registration_no, c.id_value)))
           = upper(btrim(app.received_text(v_supplier, 'idValue')))
     order by c.created_at
     limit 1;
  end if;

  if v_contact is not null then
    update public.received_einvoices set contact_id = v_contact where id = v_id;
  end if;

  return jsonb_build_object('id', v_id, 'duplicate', false);
end;
$$;

comment on function public.record_received_einvoice is
  'Keeps a parsed MyInvois document. Idempotent on the hash of the raw '
  'document: a second import returns the first row and says so.';

revoke all on function public.record_received_einvoice(uuid, jsonb, jsonb)
  from public, anon;
grant execute on function public.record_received_einvoice(uuid, jsonb, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------
-- Naming the supplier
-- ---------------------------------------------------------------------
create or replace function public.link_received_einvoice_contact(
  p_id uuid, p_contact_id uuid)
returns public.received_einvoices
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_row public.received_einvoices;
begin
  select * into v_row from public.received_einvoices where id = p_id;
  if not found then
    raise exception 'No such received e-Invoice' using errcode = 'P0002';
  end if;
  if not app.can_write(v_row.org_id) then
    raise exception 'Not allowed to change this received e-Invoice'
      using errcode = '42501';
  end if;
  if v_row.bill_id is not null then
    raise exception
      'This document is already on a bill; the supplier cannot be changed'
      using errcode = '22023';
  end if;

  -- The composite foreign key refuses another company's contact, but a
  -- constraint violation reads like a bug. Say it plainly first.
  if p_contact_id is not null and not exists (
    select 1 from public.contacts
     where id = p_contact_id and org_id = v_row.org_id and deleted_at is null)
  then
    raise exception 'That contact is not in this organization'
      using errcode = '42501';
  end if;

  update public.received_einvoices
     set contact_id = p_contact_id
   where id = p_id
  returning * into v_row;
  return v_row;
end;
$$;

comment on function public.link_received_einvoice_contact is
  'Says which supplier a received document is from. Refuses a contact '
  'in another company, and refuses to change one once a bill has been '
  'drafted from the document. Null clears the link.';

revoke all on function public.link_received_einvoice_contact(uuid, uuid)
  from public, anon;
grant execute on function public.link_received_einvoice_contact(uuid, uuid)
  to authenticated;

create or replace function public.set_received_einvoice_status(
  p_id uuid, p_status text)
returns public.received_einvoices
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_row public.received_einvoices;
begin
  -- 'billed' is not here. It means a bill exists, and the only thing
  -- that can make that true is the function that creates one. A status
  -- somebody can type is a status that stops meaning anything.
  if p_status is null or p_status not in ('received', 'ignored') then
    raise exception 'Status must be received or ignored, not %', p_status
      using errcode = '22023';
  end if;

  select * into v_row from public.received_einvoices where id = p_id;
  if not found then
    raise exception 'No such received e-Invoice' using errcode = 'P0002';
  end if;
  if not app.can_write(v_row.org_id) then
    raise exception 'Not allowed to change this received e-Invoice'
      using errcode = '42501';
  end if;
  if v_row.status = 'billed' then
    raise exception
      'This document is already on a bill; delete the bill first'
      using errcode = '22023';
  end if;

  update public.received_einvoices set status = p_status where id = p_id
  returning * into v_row;
  return v_row;
end;
$$;

comment on function public.set_received_einvoice_status is
  'Moves a received document between received and ignored. Refuses '
  'any other value, and refuses billed in particular: that means a '
  'bill exists, which only draft_bill_from_received_einvoice can make '
  'true.';

revoke all on function public.set_received_einvoice_status(uuid, text)
  from public, anon;
grant execute on function public.set_received_einvoice_status(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Making the supplier a contact
-- ---------------------------------------------------------------------
create or replace function public.create_supplier_from_received_einvoice(
  p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_row     public.received_einvoices;
  v_addr    jsonb;
  v_state   text;
  v_country char(3);
  v_exists  uuid;
  v_id      uuid;
begin
  select * into v_row from public.received_einvoices where id = p_id;
  if not found then
    raise exception 'No such received e-Invoice' using errcode = 'P0002';
  end if;
  if not app.can_write(v_row.org_id) then
    raise exception 'Not allowed to create contacts in this organization'
      using errcode = '42501';
  end if;
  if v_row.contact_id is not null then
    return v_row.contact_id;
  end if;
  if v_row.supplier_name is null then
    raise exception
      'The document does not name the supplier, so there is nothing to create'
      using errcode = '22023';
  end if;

  -- A second row for a supplier already on file is the trap this whole
  -- function walks towards. If the TIN is already known, link that one.
  if v_row.supplier_tin is not null then
    select c.id into v_exists
      from public.contacts c
     where c.org_id = v_row.org_id
       and c.deleted_at is null
       and upper(btrim(c.tin)) = upper(btrim(v_row.supplier_tin))
     order by c.created_at
     limit 1;
    if v_exists is not null then
      update public.received_einvoices set contact_id = v_exists where id = p_id;
      return v_exists;
    end if;
  end if;

  v_addr := coalesce(v_row.supplier_address, '{}'::jsonb);

  select code into v_state from public.ref_states
   where code = app.received_text(v_addr, 'state');
  select code into v_country from public.ref_countries
   where code = upper(app.received_text(v_addr, 'country'));

  insert into public.contacts (
    org_id, code, contact_type, name,
    tin, registration_no, id_type, id_value, sst_registration_no,
    email, phone,
    address_line1, address_line2, address_line3,
    postcode, city, state_code, country_code,
    created_by)
  values (
    v_row.org_id,
    app.next_document_number_internal(v_row.org_id, 'contact'),
    'supplier', v_row.supplier_name,
    v_row.supplier_tin,
    case when v_row.supplier_id_type = 'BRN' then v_row.supplier_id_value end,
    case when v_row.supplier_id_type in ('NRIC', 'BRN', 'PASSPORT', 'ARMY')
      then v_row.supplier_id_type end,
    v_row.supplier_id_value,
    v_row.supplier_sst_no,
    -- citext, and a malformed address would raise on nothing here, but
    -- an empty string is not an address.
    nullif(btrim(coalesce(v_row.supplier_email, '')), ''),
    v_row.supplier_phone,
    app.received_text(v_addr, 'line1'),
    app.received_text(v_addr, 'line2'),
    app.received_text(v_addr, 'line3'),
    app.received_text(v_addr, 'postcode'),
    app.received_text(v_addr, 'city'),
    v_state,
    coalesce(v_country, 'MYS'),
    auth.uid())
  returning id into v_id;

  update public.received_einvoices set contact_id = v_id where id = p_id;
  return v_id;
end;
$$;

comment on function public.create_supplier_from_received_einvoice is
  'Creates the supplier named by a received document, or links the one '
  'already holding that TIN. Never creates a second row for a known TIN.';

revoke all on function public.create_supplier_from_received_einvoice(uuid)
  from public, anon;
grant execute on function public.create_supplier_from_received_einvoice(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- Turning it into a bill
-- ---------------------------------------------------------------------
create or replace function public.draft_bill_from_received_einvoice(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_row      public.received_einvoices;
  v_type     app.purchase_doc_type;
  v_bill     uuid;
  v_line     public.received_einvoice_lines;
  v_class    text;
  v_uom      text;
  v_total    numeric(18, 2);
  v_diff     numeric(18, 2);
  v_note     text;
begin
  select * into v_row from public.received_einvoices where id = p_id;
  if not found then
    raise exception 'No such received e-Invoice' using errcode = 'P0002';
  end if;
  if not app.can_write(v_row.org_id) then
    raise exception 'Not allowed to create bills in this organization'
      using errcode = '42501';
  end if;
  if v_row.bill_id is not null then
    raise exception 'This document is already on a bill' using errcode = '22023';
  end if;
  if v_row.contact_id is null then
    raise exception
      'Link a supplier to this document before drafting a bill'
      using errcode = '22023';
  end if;

  -- MyInvois document types, from the supplier's side of the trade.
  -- 04 is a refund note and 11 to 14 are self-billed, which we ISSUE
  -- rather than receive; neither has a purchase document to become, and
  -- guessing one would post the wrong sign.
  v_type := case v_row.type_code
    when '01' then 'bill'
    when '02' then 'purchase_credit_note'
    when '03' then 'purchase_debit_note'
    else null
  end::app.purchase_doc_type;
  if v_type is null then
    raise exception
      'e-Invoice type % has no purchase document to become', coalesce(v_row.type_code, '(none)')
      using errcode = '22023';
  end if;

  if v_row.currency is null
     or not exists (select 1 from public.ref_currencies where code = v_row.currency)
  then
    raise exception 'Currency % is not one this company knows',
      coalesce(v_row.currency, '(none)') using errcode = '22023';
  end if;

  insert into public.purchase_documents (
    org_id, doc_type, doc_no, doc_date, contact_id,
    supplier_doc_no, supplier_doc_date,
    currency, exchange_rate,
    -- The line discounts are already on the lines. A document-level
    -- discount here would take them off twice.
    discount_amount,
    -- A charge stated only at document level has nowhere else to land,
    -- and the parser does not read line-level charges at all, so this
    -- is where that money is restored.
    shipping_amount,
    status, einvoice_status, notes, created_by)
  values (
    v_row.org_id, v_type,
    app.next_document_number_internal(v_row.org_id, v_type::text),
    -- `app.today()` and not `current_date`: the caller's session zone
    -- decides what `current_date` is, and a bill dated by whoever
    -- happened to press the button is a bill in the wrong period.
    coalesce(v_row.issue_date, app.today()),
    v_row.contact_id,
    v_row.doc_no, v_row.issue_date,
    v_row.currency, v_row.exchange_rate,
    0,
    v_row.total_charges,
    'draft', 'not_applicable',
    case when v_row.myinvois_uuid is not null
      then 'From e-Invoice ' || v_row.myinvois_uuid end,
    auth.uid())
  returning id into v_bill;

  for v_line in
    select * from public.received_einvoice_lines
     where received_id = p_id order by line_no
  loop
    select code into v_class from public.ref_classification_codes
     where code = v_line.classification_code;
    select code into v_uom from public.ref_uom_codes
     where code = v_line.uom_code;

    insert into public.purchase_document_lines (
      org_id, document_id, line_no, line_type,
      description, classification_code,
      quantity, uom_code, unit_price,
      discount_amount, tax_rate, is_tax_inclusive)
    values (
      v_row.org_id, v_bill, v_line.line_no, 'item',
      v_line.description, v_class,
      v_line.quantity, v_uom, v_line.unit_price,
      v_line.discount_amount, v_line.tax_rate, false);
  end loop;

  -- The triggers have recomputed the bill by our rules. Whether that
  -- agrees with what the supplier asked for is a separate question, and
  -- it is the one somebody paying this needs answered.
  select total_amount into v_total from public.purchase_documents where id = v_bill;
  v_diff := round(v_total - v_row.payable_amount, 2);
  if abs(v_diff) > 0.005 then
    v_note := format(
      'This bill totals %s but the e-Invoice states %s payable, a difference of %s. '
      'The bill is calculated from the lines; check the line the supplier rounded.',
      to_char(v_total, 'FM999999999990.00'),
      to_char(v_row.payable_amount, 'FM999999999990.00'),
      to_char(v_diff, 'FM999999999990.00'));
    update public.purchase_documents set internal_notes = v_note where id = v_bill;
  end if;

  update public.received_einvoices
     set bill_id = v_bill, status = 'billed'
   where id = p_id;

  return v_bill;
end;
$$;

comment on function public.draft_bill_from_received_einvoice is
  'Drafts a purchase document from a received e-Invoice. The totals are '
  'recomputed by our own triggers; any difference from the stated '
  'payable amount is written into the bill internal notes.';

revoke all on function public.draft_bill_from_received_einvoice(uuid)
  from public, anon;
grant execute on function public.draft_bill_from_received_einvoice(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- On the change feed
-- ---------------------------------------------------------------------
-- 0547 asks it of every org-scoped table, and a document arriving from
-- a supplier is exactly the case the feed exists for: it lands while
-- nobody is looking at the screen. Neither table is a read receipt.
create trigger live_change_insert after insert on public.received_einvoices
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.received_einvoices
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.received_einvoices
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

create trigger live_change_insert after insert on public.received_einvoice_lines
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.received_einvoice_lines
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.received_einvoice_lines
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
begin
  if app.received_num('{"a": "12.50"}'::jsonb, 'a') <> 12.50 then
    raise exception 'received_num does not read a numeric string';
  end if;
  if app.received_num('{"a": "later"}'::jsonb, 'a') <> 0 then
    raise exception 'received_num raises or returns non-zero for a word';
  end if;
  if app.received_num('{"a": {"b": 1}}'::jsonb, 'a') <> 0 then
    raise exception 'received_num does not refuse an object';
  end if;
  if app.received_text('{"a": "  x  "}'::jsonb, 'a') <> 'x' then
    raise exception 'received_text does not trim';
  end if;
  if app.received_text('{"a": ""}'::jsonb, 'a') is not null then
    raise exception 'received_text does not empty to null';
  end if;
  if app.received_text('{"a": ["x"]}'::jsonb, 'a') is not null then
    raise exception 'received_text renders an array instead of refusing it';
  end if;

  -- The hash has to be of the CANONICAL rendering, or the same document
  -- formatted differently imports twice.
  if encode(sha256(convert_to('{"b":1,"a":2}'::jsonb::text, 'UTF8')), 'hex')
     <> encode(sha256(convert_to('{ "a" : 2, "b" : 1 }'::jsonb::text, 'UTF8')), 'hex')
  then
    raise exception 'jsonb rendering is not canonical, so the hash is of the bytes';
  end if;
end
$do$;
