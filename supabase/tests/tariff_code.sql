-- =====================================================================
-- iAkauntan :: the code the customs officer reads
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tariff_code.sql
--
-- `0636`. `einvoice_lines.product_tariff_code` has been a column since
-- 0007 and `ubl.ts` has emitted it, correctly, for as long. No INSERT
-- ever named it, so it was null on every line ever written and the
-- emitter's branch never ran. A test of the emitter passed while the
-- feature did not exist.
--
-- What has to hold:
--
--   * **the code reaches the line**, on both writers that have an item
--     behind a line;
--   * **it comes from the ITEM**, because an HS code is a fact about a
--     product and the same product must not reach LHDN under two
--     codes;
--   * **nothing changes for an item that has none**, which is every
--     item in every existing company;
--   * **a consolidated line gets none**, because there is no single
--     item behind one and inventing a code would be a false statement.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company that may e-Invoice at all. The identity fields are the
-- ones prepare_einvoice refuses without; none of them is what this
-- file is about, so they are set once here rather than in each block.
create or replace function pg_temp.tc_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  update public.organizations
     set einvoice_enabled  = true,
         legal_name        = p_name,
         registration_no   = '199901000001',
         tin               = 'C1111111111',
         einvoice_tin      = 'C1111111111',
         einvoice_id_type  = 'BRN',
         einvoice_id_value = '199901000001',
         msic_code         = '62010'
   where id = v_org;
  return v_org;
end;
$$;

create or replace function pg_temp.tc_item(
  p_org uuid, p_name text, p_tariff text, p_country char(3))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.items
    (org_id, code, name, item_type, tariff_code, country_of_origin)
  values (p_org, 'IT-' || substr(gen_random_uuid()::text, 1, 8), p_name,
          'stock', p_tariff, p_country)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function pg_temp.tc_contact(p_org uuid, p_type text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, tin)
  values (p_org, 'C-' || substr(gen_random_uuid()::text, 1, 8),
          'Rakan Niaga', p_type::app.contact_type, 'C1234567890')
  returning id into v_id;
  return v_id;
end;
$$;

-- A posted invoice of one line for one item.
create or replace function pg_temp.tc_invoice(
  p_org uuid, p_buyer uuid, p_item uuid)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', 'INV-' || substr(gen_random_uuid()::text, 1, 8),
          current_date, current_date + 30, p_buyer, 'MYR', 1,
          100, 100, 100, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price, line_subtotal, line_total)
  values (p_org, v_doc, 1, 'item', p_item, 'Barang', 1, 100, 100, 100);
  update public.sales_documents set status = 'posted' where id = v_doc;
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. The code reaches the e-Invoice line, from the item
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.tc_org('Kod Tarif Sdn Bhd');
  v_buyer uuid := pg_temp.tc_contact(v_org, 'customer');
  v_item  uuid := pg_temp.tc_item(v_org, 'Getah asli', '4001.10.10', 'THA');
  v_ein   uuid;
begin
  v_ein := public.prepare_einvoice(pg_temp.tc_invoice(v_org, v_buyer, v_item));

  perform pg_temp.check_eq('the tariff code reaches the line',
    (select product_tariff_code from public.einvoice_lines
      where einvoice_id = v_ein), '4001.10.10');
  perform pg_temp.check_eq('and so does the country of origin',
    (select country_of_origin from public.einvoice_lines
      where einvoice_id = v_ein), 'THA');

  -- The classification code is a DIFFERENT field and must not have been
  -- overwritten on the way past. The matrix conflated the two, which is
  -- how this gap was mis-stated in the first place.
  perform pg_temp.check_true('the classification code is untouched',
    (select classification_code from public.einvoice_lines
      where einvoice_id = v_ein) = '022');
end $$;

-- ---------------------------------------------------------------------
-- 2. An item with none changes nothing
--
-- Every item in every existing company is this one. If the line came
-- out with anything but null the migration would be rewriting history.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.tc_org('Tiada Tarif Sdn Bhd');
  v_buyer uuid := pg_temp.tc_contact(v_org, 'customer');
  v_item  uuid := pg_temp.tc_item(v_org, 'Perkhidmatan', null, null);
  v_ein   uuid;
begin
  v_ein := public.prepare_einvoice(pg_temp.tc_invoice(v_org, v_buyer, v_item));

  perform pg_temp.check_true('an item with no code leaves the line null',
    (select product_tariff_code from public.einvoice_lines
      where einvoice_id = v_ein) is null);
  perform pg_temp.check_true('and no country either',
    (select country_of_origin from public.einvoice_lines
      where einvoice_id = v_ein) is null);

  -- ubl.ts reads that null and omits the element rather than emitting
  -- an empty one. Asserted here as the reason the null is acceptable,
  -- because a blank ItemClassificationCode would fail validation where
  -- an absent one does not.
  perform pg_temp.check_true('the line is otherwise complete',
    (select count(*)::int from public.einvoice_lines
      where einvoice_id = v_ein and classification_code is not null
        and total_incl_tax = 100) = 1);
end $$;

-- ---------------------------------------------------------------------
-- 3. A line with no item at all
--
-- A free-text line carries no item, so the left join gives null and
-- must not raise. This is the ordinary shape of a service invoice.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.tc_org('Baris Bebas Sdn Bhd');
  v_buyer uuid := pg_temp.tc_contact(v_org, 'customer');
  v_doc   uuid;
  v_ein   uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'INV-FREE', current_date, current_date + 30,
          v_buyer, 'MYR', 1, 100, 100, 100, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, line_subtotal, line_total)
  values (v_org, v_doc, 1, 'item', 'Nasihat', 1, 100, 100, 100);
  update public.sales_documents set status = 'posted' where id = v_doc;

  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_true('a line with no item prepares',
    (select product_tariff_code from public.einvoice_lines
      where einvoice_id = v_ein) is null);
end $$;

-- ---------------------------------------------------------------------
-- 4. The shape check refuses a description in the wrong box
--
-- Not membership of the PDK, which this repository cannot keep
-- current: refusing a code that is correct is worse than accepting one
-- that is wrong, because the first stops an invoice that should go.
-- What it catches is the realistic error.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid := pg_temp.test_org('Bentuk Kod Sdn Bhd');
begin
  perform pg_temp.check_refused(
    'a description is not a tariff code',
    format($f$insert into public.items (org_id, code, name, item_type,
              tariff_code) values (%L::uuid, 'X1', 'X', 'stock',
              'Natural rubber')$f$, v_org),
    '%items_tariff_code_shape%');
  perform pg_temp.check_refused(
    'nor is a three-digit number',
    format($f$insert into public.items (org_id, code, name, item_type,
              tariff_code) values (%L::uuid, 'X2', 'X', 'stock', '400')$f$,
           v_org),
    '%items_tariff_code_shape%');

  -- The three real shapes, all accepted. A check that refused any of
  -- these would be worse than no check.
  perform pg_temp.check_true('a four-digit heading is accepted',
    pg_temp.tc_item(v_org, 'A', '4001', null) is not null);
  perform pg_temp.check_true('a six-digit subheading is accepted',
    pg_temp.tc_item(v_org, 'B', '4001.10', null) is not null);
  perform pg_temp.check_true('a full Malaysian code is accepted',
    pg_temp.tc_item(v_org, 'C', '4001.10.10.00', null) is not null);
  perform pg_temp.check_true('and no code at all is accepted',
    pg_temp.tc_item(v_org, 'D', null, null) is not null);
end $$;

-- ---------------------------------------------------------------------
-- 5. A country must be a country
-- ---------------------------------------------------------------------
do $$
declare v_org uuid := pg_temp.test_org('Negara Asal Sdn Bhd');
begin
  perform pg_temp.check_refused(
    'an invented country code is refused',
    format($f$insert into public.items (org_id, code, name, item_type,
              country_of_origin) values (%L::uuid, 'X3', 'X', 'stock',
              'ZZZ')$f$, v_org),
    '%country_of_origin%');
end $$;

-- ---------------------------------------------------------------------
-- 5b. The self-billed side, which is where it matters most
--
-- A self-billed e-Invoice is the one a BUYER files for a supply the
-- seller cannot -- typically a foreign supplier. Imported goods are
-- exactly the case a tariff code is asked for, so a change that
-- carried the code on the sales side and not this one would have
-- missed the half that matters.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.tc_org('Bil Sendiri Sdn Bhd');
  v_supp uuid;
  v_item uuid := pg_temp.tc_item(v_org, 'Cip', '8542.31.00', 'TWN');
  v_bill uuid;
  v_ein  uuid;
begin
  -- Foreign, because that is what makes it self-billable.
  insert into public.contacts
    (org_id, code, name, legal_name, contact_type, country_code, tin,
     id_type, id_value)
  values (v_org, 'F-TC', 'Chip Vendor Inc', 'Chip Vendor Incorporated',
          'supplier', 'TWN', 'EI00000000020', 'BRN', 'TW-123456')
  returning id into v_supp;

  perform public.create_fiscal_year(v_org,
    date_trunc('year', app.today())::date);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, tax_amount, total_amount,
     base_total_amount, balance_amount)
  values (v_org, 'bill', 'BILL-TC', app.today(), v_supp, 'MYR', 1,
          'draft', 1000, 0, 1000, 1000, 1000)
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_rate)
  values (v_org, v_bill, 1, 'item', v_item, 'Cip', 1, 'C62', 1000, 0);
  update public.purchase_documents set status = 'posted' where id = v_bill;

  v_ein := public.prepare_self_billed_einvoice(v_bill);

  perform pg_temp.check_eq('a self-billed line carries the tariff code',
    (select product_tariff_code from public.einvoice_lines
      where einvoice_id = v_ein), '8542.31.00');
  perform pg_temp.check_eq('and the country the goods came from',
    (select country_of_origin from public.einvoice_lines
      where einvoice_id = v_ein), 'TWN');
end $$;

-- ---------------------------------------------------------------------
-- 6. The consolidated e-Invoice deliberately has none
--
-- One line per till receipt, classification 004, no single item behind
-- it. A tariff code there would be a statement to LHDN about goods
-- nobody identified.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true(
    'the consolidated writer does not name the column',
    (select count(*) from pg_proc p
      where p.proname = 'prepare_consolidated_einvoice_internal'
        and p.prosrc like '%insert into public.einvoice_lines%'
        and p.prosrc not like '%product_tariff_code%') = 1);
end $$;

rollback;

\echo 'tariff_code.sql passed'
