-- ---------------------------------------------------------------------
-- 0477  One company, one record per role
-- ---------------------------------------------------------------------
-- 0476 read "the supplier who starts selling to you" as a contact that
-- changes what it is, and built a conversion: pick the new type, keep
-- the one record. That is not how the books are kept, and the
-- instruction that corrected it is worth quoting:
--
--     Al Hardware Sdn Bhd   supplier   S-2026-00001
--     Al Hardware Sdn Bhd   customer   C-2026-00013
--     Al Hardware Sdn Bhd   prospect   P-2026-00343
--
-- The same company, three records, three codes -- one series per role,
-- numbered independently, restarting each year. The supplier record is
-- not touched when the customer record is created; it goes on carrying
-- its bills under its own code. Nothing is converted.
--
-- ### What changes
--
--   * Two more series. `contact` (C-) has numbered every contact since
--     0009 and goes on numbering customers; `supplier` (S-) and
--     `prospect` (P-) join it. The shape is the one `number_sequences`
--     already produces -- prefix, four-digit year, five-digit body --
--     so C-2026-00013 is what today's counter says next, not a new
--     format. Codes already issued are not rewritten: a supplier filed
--     as SUP-AMP stays SUP-AMP; the next one created is S-2026-00001.
--
--   * `next_contact_code(org, type)` picks the series from the type,
--     for the editor and for the scanner. `both` is numbered C-: it is
--     a customer among other things, and it was numbered C- before
--     this.
--
--   * `create_contact_as(contact, type)` makes the second record from
--     the first: the company's details, addresses and people copied, a
--     code from the right series, the type asked for. What is *not*
--     copied is what belongs to a role rather than to a company --
--     credit limit and hold, payment term, price level, discount,
--     control accounts -- because the terms you buy on are not the
--     terms you sell on.
--
--   * `contacts.party_id` says which records are the same company:
--     the first record's id, shared by every record created from it.
--     That is how a company is never given two supplier records by
--     accident, and how the screen shows the customer record from the
--     supplier one. Setting it on the source is the one write this
--     makes to the source, and it changes nothing the record says
--     about itself.
--
--   * `contact_records(contact)` is what the screen asks: the other
--     records of this company, and which roles it has no record for
--     yet. It replaces `contact_conversions`, which offered a
--     conversion, and is dropped.
--
-- ### What stays
--
-- 0476's trigger. The editor still has a Type dropdown, and a supplier
-- with open bills retyped to customer would still lose them from the
-- payment screen. The refusal now points at the right remedy: keep
-- this record, create a separate one.
--
-- ### The series and a code typed by hand
--
-- 0116 explains it: the counter counts, it does not look. A supplier
-- somebody filed by hand as S-2026-00001 sits exactly where the series
-- lands next. `create_contact_as` retries on the collision -- each
-- attempt takes the next number, so a second attempt is a different
-- code by construction -- and the counters for the two new series are
-- moved past what each organization already holds, as 0116 did for
-- C-, so the first attempt is normally right.
--
-- ### Mutants
--
-- Run against `supabase/tests/contact_records.sql`, each named with
-- the assertion that kills it:
--   * the series lookup answering `contact` for everything -- "a
--     supplier record is coded S-";
--   * the type copied from the source rather than taken from the
--     argument -- "and it is a supplier";
--   * the source retyped instead of a record created (0476's
--     behaviour, the one the correction was about) -- "the customer
--     record is still there, still C-";
--   * `party_id` never set -- "the customer record knows its supplier
--     record";
--   * the sibling check dropped -- "a second supplier record is
--     refused";
--   * the collision retry dropped -- "a code typed by hand does not
--     block the series";
--   * the write guard dropped -- "somebody who may only read cannot";
--   * addresses and people not copied -- "the delivery address comes
--     along" and "and the people";
--   * the role-specific columns copied too -- "and the credit terms do
--     not".
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The series
-- ---------------------------------------------------------------------
create or replace function app.default_doc_prefix(p_doc_type text)
returns text
language sql immutable
set search_path = public, pg_temp as $$
  select case p_doc_type
    when 'quotation'            then 'QT-'
    when 'sales_order'          then 'SO-'
    when 'delivery_order'       then 'DO-'
    when 'invoice'              then 'INV-'
    when 'credit_note'          then 'CN-'
    when 'debit_note'           then 'DN-'
    when 'refund_note'          then 'RN-'
    when 'proforma'             then 'PF-'
    when 'purchase_request'     then 'PR-'
    when 'purchase_order'       then 'PO-'
    when 'goods_received'       then 'GRN-'
    when 'bill'                 then 'BILL-'
    when 'purchase_credit_note' then 'PCN-'
    when 'purchase_debit_note'  then 'PDN-'
    when 'purchase_return'      then 'PRT-'
    when 'receipt'              then 'RCP-'
    when 'payment'              then 'PAY-'
    when 'payroll_run'          then 'PYR-'
    when 'leave_request'        then 'LV-'
    when 'expense'              then 'EXP-'
    when 'journal'              then 'JV-'
    when 'stock_adjustment'     then 'ADJ-'
    when 'stock_movement'       then 'SM-'
    when 'lead'                 then 'LD-'
    when 'opportunity'          then 'OPP-'
    -- Customers, and everything that is not a supplier or a prospect,
    -- as it has been since 0009.
    when 'contact'              then 'C-'
    when 'supplier'             then 'S-'
    when 'prospect'             then 'P-'
    when 'item'                 then 'I-'
    when 'withholding'          then 'WHT-'
    when 'bank_transfer'        then 'TRF-'
    when 'manufacturing_order'  then 'MO-'
    when 'pos_shift'            then 'SH-'
    when 'pos_sale'             then 'POS-'
    when 'stock_transfer'       then 'STN-'
    when 'landed_cost'          then 'LC-'
    when 'contra'               then 'CTR-'
    when 'deposit'              then 'DEP-'
    when 'cheque'               then 'PDC-'
    else upper(left(p_doc_type, 3)) || '-'
  end;
$$;

-- 0165's event trigger strips PUBLIC and anon from a newly created
-- function, so the grant is written back after every re-create.
grant execute on function app.default_doc_prefix(text) to authenticated;

-- A counter row that happened to be created under the fallback, if
-- any organization has one, takes the prefix it was always meant to
-- have. Only the fallback rows: a prefix somebody chose is theirs.
update public.number_sequences set prefix = 'S-'
 where doc_type = 'supplier' and prefix = 'SUP-';
update public.number_sequences set prefix = 'P-'
 where doc_type = 'prospect' and prefix = 'PRO-';

-- Which series numbers which type. One place, read by the code the
-- editor asks for and by the record `create_contact_as` makes, so the
-- two cannot number the same role differently.
create or replace function app.contact_series(p_type app.contact_type)
returns text
language sql immutable
set search_path = public, pg_temp as $$
  select case p_type
    when 'supplier' then 'supplier'
    when 'prospect' then 'prospect'
    else 'contact'
  end;
$$;

comment on function app.contact_series(app.contact_type) is
  'The number_sequences doc_type that codes a contact of this type: '
  'supplier -> S-, prospect -> P-, everything else the C- series that '
  'has numbered contacts since 0009. See 0477.';

create or replace function public.next_contact_code(
  p_org_id uuid, p_type app.contact_type)
returns text
language sql volatile
security definer
set search_path = public, app, pg_temp as $$
  select public.next_document_number(p_org_id, app.contact_series(p_type));
$$;

comment on function public.next_contact_code(uuid, app.contact_type) is
  'The next code in the series for a contact of this type -- '
  'C-2026-00013, S-2026-00001, P-2026-00343. What the contact editor '
  'and the scanner ask before a record is typed. See 0477.';

grant execute on function public.next_contact_code(uuid, app.contact_type)
  to authenticated;

-- Whether a record of one type stands for a role. `both` stands for
-- two; nothing else stands for more than itself.
create or replace function app.contact_carries(
  p_type app.contact_type, p_role app.contact_type)
returns boolean
language sql immutable
set search_path = public, pg_temp as $$
  select p_type = p_role
      or (p_type = 'both' and p_role in ('customer', 'supplier'));
$$;

-- ---------------------------------------------------------------------
-- Which records are the same company
-- ---------------------------------------------------------------------
alter table public.contacts add column if not exists party_id uuid;

comment on column public.contacts.party_id is
  'The company behind the record. A company that is a supplier and '
  'also a customer is two contact rows with two codes and one '
  'party_id -- the id of the first record, shared by every record '
  'created from it. Null on a record nobody has made a second record '
  'of. See 0477.';

create index if not exists contacts_org_party_idx
  on public.contacts (org_id, party_id)
  where party_id is not null and deleted_at is null;

-- ---------------------------------------------------------------------
-- The second record
-- ---------------------------------------------------------------------
create or replace function public.create_contact_as(
  p_contact_id uuid, p_type app.contact_type)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_src     public.contacts;
  v_have    public.contacts;
  v_party   uuid;
  v_code    text;
  v_new     uuid;
  v_attempt integer;
begin
  select * into v_src
    from public.contacts
   where id = p_contact_id and deleted_at is null;
  if v_src.id is null then
    raise exception 'No such contact' using errcode = 'P0002';
  end if;
  if not app.can_write(v_src.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  -- A record is one of the three coded roles. `both` is what a record
  -- becomes, not what one is created as; `employee` and `other` have
  -- no series of their own.
  if p_type not in ('customer', 'supplier', 'prospect') then
    raise exception
      'A record is created as a customer, a supplier or a prospect'
      using errcode = '22023';
  end if;

  v_party := coalesce(v_src.party_id, v_src.id);

  -- One record per role. The source counts -- a supplier does not get
  -- a second supplier record -- and so does any record already made
  -- from it, or from the record it was made from.
  select c.* into v_have
    from public.contacts c
   where c.org_id = v_src.org_id
     and c.deleted_at is null
     and (c.id = v_src.id or c.party_id = v_party)
     and app.contact_carries(c.contact_type, p_type)
   order by c.code
   limit 1;
  if v_have.id is not null then
    raise exception '% already has a % record, %',
      v_src.name, p_type, v_have.code
      using errcode = '23505';
  end if;

  -- The code, and the retry 0116 explains: the counter does not look
  -- at the table, so a code typed by hand can sit where it lands next.
  -- Every attempt takes the next number, so the second is a different
  -- code by construction, and the counter is left past the collision.
  for v_attempt in 1 .. 5 loop
    v_code := app.next_document_number_internal(
      v_src.org_id, app.contact_series(p_type));
    begin
      insert into public.contacts (
        org_id, code, contact_type, party_id,
        name, legal_name, entity_type,
        tin, registration_no, old_registration_no, sst_registration_no,
        id_type, id_value, msic_code, is_tin_verified, tin_verified_at,
        email, phone, mobile, fax, website,
        address_line1, address_line2, address_line3, postcode, city,
        state_code, country_code, currency,
        owner_id, tags, notes, custom_fields, created_by)
      values (
        v_src.org_id, v_code, p_type, v_party,
        v_src.name, v_src.legal_name, v_src.entity_type,
        v_src.tin, v_src.registration_no, v_src.old_registration_no,
        v_src.sst_registration_no,
        v_src.id_type, v_src.id_value, v_src.msic_code,
        v_src.is_tin_verified, v_src.tin_verified_at,
        v_src.email, v_src.phone, v_src.mobile, v_src.fax, v_src.website,
        v_src.address_line1, v_src.address_line2, v_src.address_line3,
        v_src.postcode, v_src.city,
        v_src.state_code, v_src.country_code, v_src.currency,
        v_src.owner_id, v_src.tags, v_src.notes, v_src.custom_fields,
        auth.uid())
      returning id into v_new;
      exit;
    exception when unique_violation then
      if v_attempt >= 5 then
        raise;
      end if;
    end;
  end loop;

  -- The one write to the source: which company it is. Not its code,
  -- not its type, not a document.
  update public.contacts
     set party_id = v_party
   where id = v_src.id and party_id is null;

  -- The same company has the same doors and the same people.
  insert into public.contact_addresses (
    org_id, contact_id, label, address_type, attention,
    address_line1, address_line2, address_line3, postcode, city,
    state_code, country_code, phone, is_default)
  select org_id, v_new, label, address_type, attention,
         address_line1, address_line2, address_line3, postcode, city,
         state_code, country_code, phone, is_default
    from public.contact_addresses
   where contact_id = v_src.id;

  insert into public.contact_persons (
    org_id, contact_id, name, designation, department,
    email, phone, mobile, is_primary, notes)
  select org_id, v_new, name, designation, department,
         email, phone, mobile, is_primary, notes
    from public.contact_persons
   where contact_id = v_src.id;

  return v_new;
end $$;

comment on function public.create_contact_as(uuid, app.contact_type) is
  'A second record of the same company, in another role: the details, '
  'addresses and people copied, a code from that role''s own series, '
  'the source left as it was. Refused where the company already has a '
  'record for the role. See 0477.';

revoke all on function public.create_contact_as(uuid, app.contact_type)
  from public, anon;
grant execute on function public.create_contact_as(uuid, app.contact_type)
  to authenticated;

-- ---------------------------------------------------------------------
-- What the screen shows
-- ---------------------------------------------------------------------
create or replace function public.contact_records(p_contact_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_src     public.contacts;
  v_have    public.contacts;
  v_party   uuid;
  v_records jsonb;
  v_options jsonb := '[]'::jsonb;
  r         app.contact_type;
begin
  select * into v_src
    from public.contacts
   where id = p_contact_id and deleted_at is null;
  if v_src.id is null then
    raise exception 'No such contact' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_src.org_id) then
    raise exception 'Not a member of that company' using errcode = '42501';
  end if;

  v_party := coalesce(v_src.party_id, v_src.id);

  -- The other records of this company. Not this one: the screen is
  -- already looking at it.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'code', c.code, 'contact_type', c.contact_type)
           order by c.code), '[]'::jsonb)
    into v_records
    from public.contacts c
   where c.org_id = v_src.org_id
     and c.deleted_at is null
     and c.id <> v_src.id
     and c.party_id = v_party;

  -- Each coded role, with the record that already fills it, if any.
  -- The same arithmetic `create_contact_as` refuses on, so the menu
  -- cannot offer what the function will refuse.
  foreach r in array
    array['customer', 'supplier', 'prospect']::app.contact_type[]
  loop
    select c.* into v_have
      from public.contacts c
     where c.org_id = v_src.org_id
       and c.deleted_at is null
       and (c.id = v_src.id or c.party_id = v_party)
       and app.contact_carries(c.contact_type, r)
     order by c.code
     limit 1;

    v_options := v_options || jsonb_build_object(
      'as', r,
      'prefix', app.default_doc_prefix(app.contact_series(r)),
      'existing', case when v_have.id is null then null
                       else jsonb_build_object(
                              'id', v_have.id, 'code', v_have.code) end);
  end loop;

  return jsonb_build_object(
    'id', v_src.id,
    'code', v_src.code,
    'name', v_src.name,
    'contact_type', v_src.contact_type,
    'records', v_records,
    'options', v_options);
end $$;

comment on function public.contact_records(uuid) is
  'The other records of the same company, and which of customer, '
  'supplier and prospect it has no record for yet -- each with the '
  'series it would be coded in. Reads app.contact_carries, the same '
  'helper create_contact_as refuses on. See 0477.';

grant execute on function public.contact_records(uuid) to authenticated;

-- The menu that offered a conversion. Its caller is gone with it.
drop function if exists public.contact_conversions(uuid);

-- ---------------------------------------------------------------------
-- The trigger's remedy, restated
-- ---------------------------------------------------------------------
create or replace function app.contact_type_still_fits()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_in_use text[];
  v_lost   text[];
begin
  if new.contact_type is not distinct from old.contact_type then
    return new;
  end if;

  v_in_use := app.contact_roles_in_use(new.id);

  -- Which roles the new type no longer carries. `both` carries both,
  -- `customer` and `supplier` one each, everything else neither --
  -- which is what makes `prospect` strict without a rule of its own.
  select coalesce(array_agg(r), '{}'::text[]) into v_lost
    from unnest(v_in_use) r
   where not (
     r = 'customer' and new.contact_type in ('customer', 'both')
     or r = 'supplier' and new.contact_type in ('supplier', 'both'));

  if array_length(v_lost, 1) is null then
    return new;
  end if;

  raise exception
    '% is still trading as a %. Making them % would take that away, and '
    'their documents would stop appearing where they are paid. Keep this '
    'record as it is and create a separate % for them instead.',
    new.name, array_to_string(v_lost, ' and a '), new.contact_type,
    case when new.contact_type in ('customer', 'supplier', 'prospect')
         then new.contact_type || ' record'
         else 'record' end
    using errcode = '23514';
end $$;

-- ---------------------------------------------------------------------
-- The two new counters, moved past what each organization already holds
-- ---------------------------------------------------------------------
--
-- 0116, for the two series that did not exist when it ran. A code that
-- looks like this series' own output, filed by hand, would otherwise
-- be the first thing the series tries.
do $$
declare
  v_org     uuid;
  v_series  text;
  v_seq     record;
  v_period  text;
  v_pattern text;
  v_max     bigint;
begin
  for v_org in select distinct org_id from public.contacts loop
    foreach v_series in array array['supplier', 'prospect'] loop
      insert into public.number_sequences (org_id, doc_type, prefix)
      values (v_org, v_series, app.default_doc_prefix(v_series))
      on conflict (org_id, doc_type) do nothing;
    end loop;
  end loop;

  for v_seq in
    select * from public.number_sequences
     where doc_type in ('supplier', 'prospect')
  loop
    v_period := case v_seq.reset_policy
      when 'yearly'  then to_char(app.today(), 'YYYY')
      when 'monthly' then to_char(app.today(), 'YYYYMM')
      else null end;

    v_pattern := '^'
      || regexp_replace(coalesce(v_seq.prefix, ''),
                        '([.^$*+?()\[\]{}|\\])', '\\\1', 'g')
      || coalesce(v_period || '-', '')
      || '(\d+)'
      || regexp_replace(coalesce(v_seq.suffix, ''),
                        '([.^$*+?()\[\]{}|\\])', '\\\1', 'g')
      || '$';

    select max((regexp_match(c.code, v_pattern))[1]::bigint)
      into v_max
      from public.contacts c
     where c.org_id = v_seq.org_id
       and c.code ~ v_pattern;

    if v_max is not null and v_seq.next_value <= v_max then
      update public.number_sequences
         set next_value = v_max + 1,
             period_key = coalesce(v_period, period_key)
       where id = v_seq.id;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
begin
  -- The three series, by the letters the instruction used.
  if app.default_doc_prefix('contact')  <> 'C-'
     or app.default_doc_prefix('supplier') <> 'S-'
     or app.default_doc_prefix('prospect') <> 'P-' then
    raise exception '0477: the series are not C-, S- and P-';
  end if;
  if app.contact_series('customer') <> 'contact'
     or app.contact_series('both')  <> 'contact'
     or app.contact_series('supplier') <> 'supplier'
     or app.contact_series('prospect') <> 'prospect' then
    raise exception '0477: a type is numbered in the wrong series';
  end if;

  -- The link the sibling check and the screen both stand on.
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'contacts'
       and column_name = 'party_id') then
    raise exception '0477: contacts has no party_id';
  end if;

  -- One arithmetic for "already has a record for this role", read by
  -- the function that refuses and the function that offers.
  if position('app.contact_carries' in
        pg_get_functiondef(to_regprocedure(
          'public.create_contact_as(uuid, app.contact_type)'))) = 0
     or position('app.contact_carries' in
        pg_get_functiondef(to_regprocedure(
          'public.contact_records(uuid)'))) = 0 then
    raise exception
      '0477: the refusal and the menu no longer read the same helper';
  end if;

  -- And both number from one place, or the editor's suggestion and the
  -- second record could put the same role in different series.
  if position('app.contact_series' in
        pg_get_functiondef(to_regprocedure(
          'public.create_contact_as(uuid, app.contact_type)'))) = 0
     or position('app.contact_series' in
        pg_get_functiondef(to_regprocedure(
          'public.next_contact_code(uuid, app.contact_type)'))) = 0 then
    raise exception '0477: the two callers do not share the series lookup';
  end if;

  if not has_function_privilege('authenticated',
       to_regprocedure('public.create_contact_as(uuid, app.contact_type)'),
       'execute')
     or not has_function_privilege('authenticated',
       to_regprocedure('public.contact_records(uuid)'), 'execute')
     or not has_function_privilege('authenticated',
       to_regprocedure('public.next_contact_code(uuid, app.contact_type)'),
       'execute') then
    raise exception '0477: the screen cannot reach what it needs';
  end if;

  -- The conversion is gone, not merely unadvertised.
  if to_regprocedure('public.contact_conversions(uuid)') is not null then
    raise exception '0477: contact_conversions is still there';
  end if;

  -- 0476's rule is still on the table; only its remedy changed.
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.contacts'::regclass
       and tgname = 'contact_type_still_fits'
       and not tgisinternal) then
    raise exception '0476: the rule is no longer on the table';
  end if;
  if position('separate' in
        pg_get_functiondef(to_regprocedure(
          'app.contact_type_still_fits()'))) = 0 then
    raise exception '0477: the refusal still points at the old remedy';
  end if;
end
$do$;
