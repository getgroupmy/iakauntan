-- =====================================================================
-- iAkauntan :: 0710 the columns each destination actually wants
--
-- `0681` built `scan_target_fields` so the reader could be handed a
-- destination's OWN columns and their descriptions instead of one
-- fixed invoice schema. `0682` added `repeats` for a bank statement.
-- And then only the bank statement was ever populated.
--
-- Everything else fell through to the fourteen fields in the edge
-- function's `SCHEMA` -- supplier, tax number, SSM number, email,
-- phone, address, document number, date, currency, subtotal, tax,
-- total, lines, note -- which is a supplier's invoice and nothing else.
--
-- Two things followed from that, and both were reported:
--
--   * A HANDWRITTEN PAYMENT VOUCHER came back with its number, its
--     amount and a date nobody had written. "A/C Debited: Office",
--     "File Ref: EPF" and "Pay: Online" have no field in an invoice
--     schema, and the reader cannot return what it is not asked for.
--     Neither can the payee: `supplier_name` means the business
--     ISSUING the document, which on a company's own voucher is that
--     company.
--
--   * `scan_extraction_targets` only returns a target that HAS fields,
--     so the `target` enum offered the model one choice and null. It
--     was being asked "is this a bank statement, or nothing?" -- which
--     is why a statement classified correctly and everything else came
--     back unplaced.
--
-- ---------------------------------------------------------------------
-- A shared column keeps the FIRST description
--
-- `targetSchema` builds one flat map across every non-repeating target
-- and skips a name it has already seen, deliberately: two descriptions
-- of one field is a field with contradictory instructions. Targets
-- arrive ordered by key, so `accounting.expense` gets there before
-- `purchases.bill` and `sales.invoice`.
--
-- So `currency`, `tax_amount`, `total_amount` and `reference` are
-- written to read true of ANY document, not of an expense. That is not
-- a nicety -- it is the difference between a description that helps on
-- one destination and misleads on three.
--
-- ---------------------------------------------------------------------
-- The overlap with the generic schema, said out loud
--
-- The edge function's own `SCHEMA` still asks for its fourteen fields
-- on every document, and some of these repeat it: `currency`,
-- `subtotal`, `tax_amount`, `total_amount` and the three date columns
-- are all asked for twice now -- once at the top level and once inside
-- `fields`.
--
-- That is deliberate for now and it is worth knowing why it is safe.
-- The two answers go to different places: the TOP-LEVEL fields are
-- parsed into `OcrExtraction` and are what actually fills a document,
-- and `fields` is shown beside them by `readerColumns` as "what the
-- reader put in each column". So where they disagree, somebody SEES
-- both -- which is strictly more than today, where a destination's own
-- columns are never asked for at all.
--
-- It is still a model invited to answer the same question twice, which
-- is the argument `targetSchema` itself makes for keeping a repeating
-- target's columns out of the flat map. The next decision on this
-- module is whether a PLACED document should take its values from the
-- destination's fields and drop the generic ones -- which would end the
-- overlap, and is a change to what fills a form rather than to what is
-- asked, so it is not in here.
--
-- ---------------------------------------------------------------------
-- What is NOT asked for
--
-- `contact_id`, `account_id`, `item_id` and every other key: a reader
-- cannot know a uuid, and a column it can only guess at is a column it
-- will fill with something.
--
-- `sales_documents.doc_no`, specifically. A sales document's number is
-- this company's own sequence -- `scan_field_map.dart` has refused to
-- write the read one there since it was written, because filing a
-- customer's reference as our invoice number is a mistake that surfaces
-- in an aged receivables listing months later. The printed number goes
-- to `reference` instead.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A payment voucher is money this company paid out
--
-- The kind has existed since `0614` and pointed at no target at all, so
-- choosing it placed the document nowhere. An expense is what it is:
-- the company's own record of a payment, which is why it has a payee, a
-- reference and a mode and no supplier of its own.
-- ---------------------------------------------------------------------
update public.scan_document_kinds
   set target_module = 'accounting', target_action = 'expense'
 where code = 'payment_voucher'
   and target_module is null;

insert into public.scan_target_fields
  (module_code, action, column_name, description, sort_order)
values
  -- -------------------------------------------------------------
  -- accounting.expense — a receipt, a payment voucher, a petty cash
  -- slip. First alphabetically, so its wording for the four shared
  -- columns is the wording every destination gets.
  -- -------------------------------------------------------------
  ('accounting', 'expense', 'expense_date',
   'The date on the document, as YYYY-MM-DD. Malaysian documents are '
   'DD/MM/YYYY, and a HANDWRITTEN one is often DD/MM/YY -- 28/1/25 is '
   '2025-01-28. If the date itself is unreadable this is null: a period '
   'named in the body is what the payment is FOR, not when it was made.',
   10),
  ('accounting', 'expense', 'reference',
   'The document''s own reference, as printed or written. On a payment '
   'voucher this is the voucher number, or the "File Ref" beside it. '
   'Not an approval code from a card terminal and not the company''s '
   'registration number.',
   20),
  ('accounting', 'expense', 'description',
   'What the money was for, in the words on the page. On a voucher this '
   'is the "being payment of" line, including any period it names. Keep '
   'the original language.',
   30),
  ('accounting', 'expense', 'payment_mode_code',
   'How it was paid, as one of these codes: 01 cash, 02 cheque, 03 bank '
   'transfer (including online transfer, DuitNow and IBG), 04 credit '
   'card, 05 debit card, 06 e-wallet, 07 digital bank, 08 anything '
   'else. Null if the page does not say. A voucher usually writes it '
   'beside "Pay".',
   40),
  ('accounting', 'expense', 'currency',
   'ISO 4217 code for the amounts on this document. RM and MYR both '
   'mean MYR. Null if nothing on the page says.',
   50),
  ('accounting', 'expense', 'amount',
   'The amount before tax, if the document separates it. Digits and one '
   'dot, no currency symbol and no thousands separators. Null where the '
   'document shows only one figure.',
   60),
  ('accounting', 'expense', 'tax_amount',
   'Service tax or sales tax charged, as printed. SST on current '
   'documents, GST on older ones. Null where the document shows none; '
   'zero only where it prints a zero.',
   70),
  ('accounting', 'expense', 'total_amount',
   'The amount actually payable, tax included -- the figure somebody '
   'pays. On a voucher this is the figure in the amount column, and it '
   'is usually written twice: once on the line and once as the total.',
   80),

  -- -------------------------------------------------------------
  -- contacts.contact — a name card, a letterhead, an SSM print-out.
  -- -------------------------------------------------------------
  ('contacts', 'contact', 'name',
   'The business or person''s name as printed. The trading name where '
   'both a trading name and a legal name appear.',
   10),
  ('contacts', 'contact', 'legal_name',
   'The registered name where it differs from the one above -- the one '
   'ending Sdn. Bhd., Berhad, Enterprise or PLT. Null where only one '
   'name is printed.',
   20),
  ('contacts', 'contact', 'registration_no',
   'The SSM company registration number. Malaysian companies carry '
   'two: the twelve-digit number issued since 2019 (201901030189) and '
   'the older form (571389-H). This one is the twelve-digit one.',
   30),
  ('contacts', 'contact', 'old_registration_no',
   'The pre-2019 SSM number -- 571389-H, JM0167410-V. Where both are '
   'printed, the twelve-digit one goes above and this one here.',
   40),
  ('contacts', 'contact', 'tin',
   'The LHDN tax identification number, usually starting C, IG, D or '
   'CS. Not the SST number and not the SSM number, which have their '
   'own fields.',
   50),
  ('contacts', 'contact', 'sst_registration_no',
   'The SST registration number, where the document shows one. Often '
   'labelled "SST No." or "No. Pendaftaran SST".',
   60),
  ('contacts', 'contact', 'email',
   'The email address as printed. Null unless one is plainly there -- a '
   'wrong address is where a remittance goes.',
   70),
  ('contacts', 'contact', 'phone',
   'The landline as printed, with its area code. Not a mobile, which '
   'has its own field, and not a customer service number for somebody '
   'else''s product.',
   80),
  ('contacts', 'contact', 'mobile',
   'The mobile number as printed -- in Malaysia these begin 01. Null '
   'where only one number is given and nothing says which it is.',
   90),
  ('contacts', 'contact', 'website',
   'The website as printed, without inventing a scheme it does not '
   'show.',
   100),
  ('contacts', 'contact', 'address_line1',
   'The first line of the address exactly as printed -- the lot, unit '
   'or building. Do not reorder the address and do not move parts of it '
   'between lines.',
   110),
  ('contacts', 'contact', 'address_line2',
   'The second printed line of the address, usually the road or the '
   'industrial park. Null where the address is one line.',
   120),
  ('contacts', 'contact', 'address_line3',
   'The third printed line, where there is one. Null otherwise.',
   130),
  ('contacts', 'contact', 'postcode',
   'The five-digit Malaysian postcode, where one is printed.',
   140),
  ('contacts', 'contact', 'city',
   'The town or city -- Kajang, Shah Alam, Georgetown. Not the state, '
   'which has its own field.',
   150),
  ('contacts', 'contact', 'state_code',
   'The Malaysian state as printed: Selangor, Johor, Pulau Pinang, '
   'Wilayah Persekutuan Kuala Lumpur. Null for an address outside '
   'Malaysia.',
   160),

  -- -------------------------------------------------------------
  -- purchases.bill — a supplier's invoice or bill.
  -- -------------------------------------------------------------
  ('purchases', 'bill', 'supplier_doc_no',
   'The SUPPLIER''S own number for this document -- labelled Invoice '
   'No, Bill No, No. Invois, Tax Invoice No, or printed under such a '
   'label rather than beside it. Not an approval code from a card '
   'terminal, not the SST or SSM number, and not this company''s '
   'account number with them.',
   10),
  ('purchases', 'bill', 'supplier_doc_date',
   'The date the supplier put on it, as YYYY-MM-DD. Malaysian '
   'documents are DD/MM/YYYY; a handwritten one is often DD/MM/YY.',
   20),
  ('purchases', 'bill', 'due_date',
   'The date payment is due, where the document states one -- "Payment '
   'due", "Tempoh bayaran", or a date beside terms such as 30 days. '
   'Null where it only states terms and no date.',
   30),
  ('purchases', 'bill', 'subtotal',
   'The total before tax, where the document separates it.',
   40),

  -- -------------------------------------------------------------
  -- purchases.purchase_order — a supplier's quotation or pro forma,
  -- which becomes an order once somebody accepts the price.
  -- -------------------------------------------------------------
  ('purchases', 'purchase_order', 'supplier_doc_no',
   'The supplier''s own number for the quotation or pro forma.',
   10),
  ('purchases', 'purchase_order', 'supplier_doc_date',
   'The date on it, as YYYY-MM-DD.',
   20),
  ('purchases', 'purchase_order', 'subtotal',
   'The total before tax, where it is separated.',
   30),

  -- -------------------------------------------------------------
  -- purchases.goods_received — a delivery order. Usually no money on
  -- it at all, which is how it is told apart from a bill.
  -- -------------------------------------------------------------
  ('purchases', 'goods_received', 'supplier_doc_no',
   'The delivery order number -- labelled DO No, Delivery Order No, or '
   'No. Penghantaran.',
   10),
  ('purchases', 'goods_received', 'supplier_doc_date',
   'The delivery date on the document, as YYYY-MM-DD.',
   20),

  -- -------------------------------------------------------------
  -- sales.invoice — this company's own invoice, typed in after the
  -- fact. Its NUMBER is deliberately not asked for.
  -- -------------------------------------------------------------
  ('sales', 'invoice', 'doc_date',
   'The date on the invoice, as YYYY-MM-DD.',
   10),
  ('sales', 'invoice', 'reference',
   'The number printed on this document. It goes to `reference` and '
   'not to the invoice number, because the invoice number is this '
   'company''s own sequence and is drawn when the invoice is saved.',
   20),
  ('sales', 'invoice', 'due_date',
   'The date payment is due, where the document states one.',
   30),
  ('sales', 'invoice', 'subtotal',
   'The total before tax, where the document separates it.',
   40)
on conflict (module_code, action, column_name) do update
   set description = excluded.description,
       sort_order = excluded.sort_order;


-- ---------------------------------------------------------------------
-- And a bug this data exposed
--
-- `scan_target_columns` is the console's picker: every column of a
-- destination's table, with the ones currently asked for ticked, plus
-- any field configured for a column that has since been dropped.
--
-- It builds that last part with a FULL OUTER JOIN, and put the
-- `module_code` and `action` predicates in the ON clause. A full outer
-- join keeps an unmatched right-hand row whatever the ON clause says,
-- so every field belonging to every OTHER destination came back as a
-- column of whichever one was being looked at -- marked as configured
-- and no longer on the table.
--
-- Nothing could see it while `accounting.bank_statement` was the only
-- target with fields: there was nothing to leak from. Populating the
-- other six turned one destination's five columns into forty-two, and
-- `supabase/tests/smartscan_module.sql` caught it on the next run.
--
-- Restated in full from what is in the database, with the filter moved
-- where it belongs.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.scan_target_columns(p_module text, p_action text)
 RETURNS TABLE(column_name text, data_type text, is_required boolean, is_foreign boolean, is_asked boolean, description text, sort_order integer, still_there boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_table text;
begin
  if not app.is_platform_admin() then
    return;
  end if;

  select t.table_name into v_table from public.scan_targets t
   where t.module_code = p_module and t.action = p_action;
  if v_table is null then
    return;
  end if;

  return query
  with real_columns as (
    select c.column_name::text as name,
           c.data_type::text   as kind,
           c.is_nullable = 'NO' and c.column_default is null as required,
           exists (
             select 1
               from information_schema.key_column_usage k
               join information_schema.table_constraints tc
                 on tc.constraint_name = k.constraint_name
                and tc.constraint_schema = k.constraint_schema
              where k.table_schema = 'public'
                and k.table_name = v_table
                and k.column_name = c.column_name
                and tc.constraint_type = 'FOREIGN KEY') as foreign_key
      from information_schema.columns c
     where c.table_schema = 'public'
       and c.table_name = v_table
       -- Plumbing a reader cannot supply. Asking for them would spend
       -- tokens inviting a model to invent a uuid.
       and c.column_name not in (
             'id', 'org_id', 'created_at', 'created_by',
             'updated_at', 'updated_by', 'deleted_at')
       and c.is_generated = 'NEVER'
       and c.is_identity = 'NO'
  )
  select coalesce(rc.name, f.column_name),
         coalesce(rc.kind, 'gone'),
         coalesce(rc.required, false),
         coalesce(rc.foreign_key, false),
         f.column_name is not null,
         f.description,
         coalesce(f.sort_order, 100),
         rc.name is not null
    from real_columns rc
    -- THIS TARGET'S fields, narrowed BEFORE the join and not in the ON
    -- clause. `0710`.
    --
    -- A full outer join keeps a right-hand row that matched nothing, so
    -- predicates in the ON clause do not remove it -- they only stop it
    -- matching. Every row of `scan_target_fields` belonging to any
    -- OTHER destination was therefore emitted here as a column of this
    -- one, marked `still_there = false`, which the console draws as
    -- "configured, and no longer on the table".
    --
    -- Invisible until `0710`, because `bank_statement` was the only
    -- target with any fields and it had nothing to leak from.
    full outer join (
      select f2.column_name, f2.description, f2.sort_order
        from public.scan_target_fields f2
       where f2.module_code = p_module
         and f2.action = p_action
    ) f on f.column_name = rc.name
   order by (f.column_name is not null) desc, coalesce(f.sort_order, 100),
            coalesce(rc.name, f.column_name);
end;
$function$;
