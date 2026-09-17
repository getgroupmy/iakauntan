-- =====================================================================
-- The consolidated e-Invoice :: which sales go in it
--
-- LHDN lets a shop report the month's unclaimed counter sales as one
-- consolidated e-Invoice within seven days of the month end, instead of
-- one document per teh tarik. What that submission is worth depends
-- entirely on which sales it names, and that is decided in one place:
-- `app.pos_consolidation_absorb`, five conditions in a single `where`.
--
-- Before this file every one of those five could be deleted and the
-- suite stayed green. The month's takings were asserted -- twice over,
-- in `pos.sql` and `monthly_jobs.sql` -- but always against a fixture
-- where every sale belonged in the return, so nothing was ever kept
-- out. A filter is only tested by the row it excludes.
--
-- So this shop has one of each thing that must NOT be reported as an
-- unclaimed counter sale:
--
--   * a sale still parked on a till -- money that has not been taken;
--   * a sale billed to a customer who gave their TIN, who gets their
--     own e-Invoice and would be reported twice;
--   * a sale the shop already submitted individually. LHDN allows a
--     B2C document under the general public TIN, so this is a real
--     route and not a hypothetical one: pressing "send" on a counter
--     invoice and then running the month must not file it twice;
--   * a sale in a different month;
--   * and another company's sale entirely.
--
-- and two that must:
--
--   * the plain walk-in;
--   * and a customer on file whose TIN is blank. `btrim` is doing the
--     work there -- a column holding two spaces is not a tax number,
--     and treating it as one would quietly drop that sale out of both
--     the individual and the consolidated route.
--
-- Who may file it is asserted here too, and asserting it is what found
-- `0501`. The function asked only whether the caller had write access
-- to the e-Invoice module, and `app.module_access` answers 'write' for
-- any member who has no access type assigned -- which is most people in
-- most companies -- whatever their role says. So a member explicitly
-- set to `viewer` could file the month's return to LHDN. It now asks
-- `app.can_write` as well, which is what `prepare_einvoice` has always
-- asked for the individual filing.
--
-- The wider fact is worth writing down rather than quietly fixing: an
-- unassigned access type means module write for every role, so the same
-- shape holds anywhere a write is gated on the module alone. Selling is
-- the deliberate case -- a cashier is not an accountant, and
-- `complete_pos_sale` is meant to be reachable by whoever is on the
-- till. Whether every other caller of `can_write_module` means it is a
-- question for somebody who knows what each of those companies bought.
--
-- Two mutants are left alive, both checked rather than assumed.
--
-- `s.status = 'completed'` in the absorb cannot be observed, because a
-- sale with an invoice IS a completed sale. `pos_sales` has three
-- states; `pos_sales_documents_ck` requires an invoice for the
-- completed one, `void_pos_sale` refuses anything that is not parked,
-- and the only three writers of `pos_sales.invoice_id` are
-- `complete_pos_sale` and the two functions that call it. The filter
-- stays in the query because that is a constraint holding it up rather
-- than an argument: the day a refund path attaches an invoice to a sale
-- that is not completed, this is the line that keeps it out of the
-- return.
--
-- One mutant is left alive on purpose. Widening the totals update at
-- the end of `consolidate_pos_einvoices` from `where c.id = v_con` to
-- every row changes nothing observable: the counts are correlated
-- subqueries over each row's own items, so every consolidation is
-- rewritten with the figures it already had. It is a wasted update,
-- not a wrong one.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_them   uuid;
  v_wh     uuid;
  v_item   uuid;
  v_walkin uuid;
  v_named  uuid;
  v_blank  uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_cash   uuid;
  v_shift  uuid;
  v_sale   uuid;
  v_plain  uuid;
  v_spaces uuid;
  v_claim  uuid;
  v_own    uuid;
  v_parked uuid;
  v_theirs uuid;
  v_owner  uuid := pg_temp.test_user();
  v_clerk  uuid;
  v_start  date := date_trunc('month', current_date)::date;
  v_end    date := (date_trunc('month', current_date)
                    + interval '1 month - 1 day')::date;
  v_n      integer;
  v_a      numeric;
  v_b      numeric;
  v_ps     date;
  v_pe     date;
  v_msg    text;
  v_con        uuid;
  v_again      uuid;
  v_theirs_con uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Konsolidasi Sdn Bhd',
                            array['pos','purchases','inventory','einvoice']);
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  update public.organizations
     set einvoice_enabled = true, tin = 'C11223344550',
         registration_no = '202601000001'
   where id = v_org;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Shop floor') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;

  -- A customer who handed over a tax number, and one whose record holds
  -- two spaces where the number should be.
  insert into public.contacts
    (org_id, code, name, contact_type, tin, id_type, id_value)
  values (v_org, 'BERDAFTAR', 'Syarikat Berdaftar', 'customer',
          'C99887766550', 'BRN', '202301999999') returning id into v_named;
  insert into public.contacts
    (org_id, code, name, contact_type, tin)
  values (v_org, 'KOSONG', 'Kedai Kosong', 'customer', '  ')
  returning id into v_blank;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'ROTI', 'Roti', 'stock', true, 'C62', 10.00, 4.00)
  returning id into v_item;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'SHOP', 'The shop', 'retail', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Counter') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_org, false);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', true, true)
  returning id into v_cash;

  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- ------------------------------------------------------------------
  -- The day's takings
  -- ------------------------------------------------------------------
  -- One roti to somebody who said nothing. This is the whole point of
  -- the consolidated return.
  v_sale := public.open_pos_sale(v_reg, null, null);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 10.00)));
  v_plain := (select s.invoice_id from public.pos_sales s where s.id = v_sale);

  -- Two roti to a company whose record has spaces where the TIN goes.
  -- No tax number means no individual e-Invoice, which means this is a
  -- consolidated sale like any other.
  v_sale := public.open_pos_sale(v_reg, null, null);
  perform public.add_pos_sale_line(v_sale, v_item, 2, 10.00);
  perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 20.00)), v_blank);
  v_spaces := (select s.invoice_id from public.pos_sales s where s.id = v_sale);

  -- Three, to a company that gave its number at the counter. They get
  -- their own document; putting them in the return as well reports the
  -- same thirty ringgit twice.
  v_sale := public.open_pos_sale(v_reg, null, null);
  perform public.add_pos_sale_line(v_sale, v_item, 3, 10.00);
  perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 30.00)), v_named);
  v_claim := (select s.invoice_id from public.pos_sales s where s.id = v_sale);

  -- Four, anonymous, but the shop pressed send on this one. LHDN takes
  -- a B2C document under the general public TIN, so the sale is both
  -- anonymous and already filed.
  v_sale := public.open_pos_sale(v_reg, null, null);
  perform public.add_pos_sale_line(v_sale, v_item, 4, 10.00);
  perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 40.00)));
  v_own := (select s.invoice_id from public.pos_sales s where s.id = v_sale);
  perform public.prepare_einvoice(v_own);

  -- Five, still on the screen. Nobody has paid for these.
  v_parked := public.open_pos_sale(v_reg, null, null);
  perform public.add_pos_sale_line(v_parked, v_item, 5, 10.00);

  -- And the shop next door, which files its own return.
  v_them := pg_temp.test_org('Kedai Sebelah Sdn Bhd',
                             array['pos','purchases','inventory','einvoice']);
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_them, date_trunc('year', current_date)::date);
  update public.organizations
     set einvoice_enabled = true, tin = 'C55667788990'
   where id = v_them;
  insert into public.warehouses (org_id, code, name)
  values (v_them, 'MAIN', 'Their floor') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_them, 'WALK-IN', 'Their counter', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_them, 'NASI', 'Nasi', 'stock', true, 'C62', 7.00, 3.00)
  returning id into v_item;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_them, 'SHOP', 'Their shop', 'retail', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_them, v_outlet, 'T1', 'Their counter') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_them, false);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_them, 'CASH', 'Cash', 'cash', '01', true, true)
  returning id into v_cash;
  perform public.open_pos_shift(v_reg, 50.00);
  v_sale := public.open_pos_sale(v_reg, null, null);
  perform public.add_pos_sale_line(v_sale, v_item, 10, 7.00);
  perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 70.00)));
  v_theirs := (select s.invoice_id from public.pos_sales s where s.id = v_sale);

  -- ------------------------------------------------------------------
  -- Who is anonymous
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('a walk-in sale is anonymous',
    app.pos_invoice_is_anonymous(v_plain));
  perform pg_temp.check_true('so is a customer whose TIN is two spaces',
    app.pos_invoice_is_anonymous(v_spaces));
  perform pg_temp.check_true('a customer who gave their number is not',
    not app.pos_invoice_is_anonymous(v_claim));
  -- The fallback, which decides what happens to a document the lookup
  -- cannot find. Nothing on file is not somebody identified.
  perform pg_temp.check_true('and a document that is not there is anonymous',
    app.pos_invoice_is_anonymous(gen_random_uuid()));

  -- ------------------------------------------------------------------
  -- What the shop is told it owes
  -- ------------------------------------------------------------------
  select o.sales_waiting, o.total_amount into v_n, v_a
    from public.pos_einvoice_outstanding(v_org) o
   where o.period_start = v_start;
  perform pg_temp.check_eq('two counter sales are waiting to be rolled up',
    v_n, 2);
  perform pg_temp.check_eq('for thirty ringgit, not the day''s takings',
    v_a, 30.00);

  -- Asked here, while two sales are actually waiting. Asked after the
  -- consolidation it would prove nothing: there is nothing outstanding
  -- by then, and a guard that returns no rows looks exactly like a
  -- month with nothing left in it.
  perform pg_temp.sign_in_as(pg_temp.another_user('orang@example.test'));
  perform pg_temp.check_eq('a stranger is shown no month at all',
    (select count(*)::integer from public.pos_einvoice_outstanding(v_org)), 0);
  perform pg_temp.sign_in_as(v_owner);

  -- ------------------------------------------------------------------
  -- Last month, which had no shop
  -- ------------------------------------------------------------------
  -- Run for a month with nothing in it. The window is the only thing
  -- keeping this month's sales out of it.
  select r.period_start, r.period_end, r.document_count, r.added
    into v_ps, v_pe, v_n, v_b
    from public.consolidate_pos_einvoices(
           v_org, (v_start - interval '1 month')::date) r;
  perform pg_temp.check_true('a month with no sales opens on its first day',
    v_ps = (v_start - interval '1 month')::date);
  perform pg_temp.check_true('and closes on its last',
    v_pe = (v_start - interval '1 day')::date);
  perform pg_temp.check_eq('and takes nothing from the month after it',
    v_b::integer, 0);
  perform pg_temp.check_eq('so it names no sales at all', v_n, 0);

  -- ------------------------------------------------------------------
  -- This month
  -- ------------------------------------------------------------------
  -- Asked for on the fifteenth, which is what a shop does. The period
  -- is the month the date falls in, not the fortnight after it.
  select r.consolidation_id, r.period_start, r.period_end,
         r.document_count, r.total_amount, r.added
    into v_con, v_ps, v_pe, v_n, v_a, v_b
    from public.consolidate_pos_einvoices(v_org, v_start + 14) r;
  perform pg_temp.check_true('the period starts on the first of the month',
    v_ps = v_start);
  perform pg_temp.check_true('and ends on its last day, not the next first',
    v_pe = v_end);
  perform pg_temp.check_eq('two sales are named', v_n, 2);
  perform pg_temp.check_eq('both of them added on this run', v_b::integer, 2);
  perform pg_temp.check_eq('for thirty ringgit', v_a, 30.00);

  perform pg_temp.check_eq('the walk-in sale is in it',
    (select count(*)::integer from public.einvoice_consolidation_items i
      where i.sales_document_id = v_plain), 1);
  perform pg_temp.check_eq('and the one with a blank TIN',
    (select count(*)::integer from public.einvoice_consolidation_items i
      where i.sales_document_id = v_spaces), 1);
  perform pg_temp.check_eq('the customer who gave their number is not',
    (select count(*)::integer from public.einvoice_consolidation_items i
      where i.sales_document_id = v_claim), 0);
  perform pg_temp.check_eq('nor the sale already filed on its own',
    (select count(*)::integer from public.einvoice_consolidation_items i
      where i.sales_document_id = v_own), 0);
  perform pg_temp.check_eq('nor the sale nobody has paid for',
    (select count(*)::integer from public.einvoice_consolidation_items i
      join public.pos_sales s on s.id = v_parked
     where i.sales_document_id is not distinct from s.invoice_id), 0);
  perform pg_temp.check_eq('and not a sen of the shop next door',
    (select count(*)::integer from public.einvoice_consolidation_items i
      where i.sales_document_id = v_theirs), 0);
  perform pg_temp.check_eq('which still has its own month to file',
    (select count(*)::integer from public.pos_einvoice_outstanding(v_them) o
      where o.period_start = v_start), 1);

  -- ------------------------------------------------------------------
  -- One consolidation, and only ever its own
  -- ------------------------------------------------------------------
  -- A mutation sweep found five conditions here that could be deleted
  -- with the suite still green, and all five are the same shape: this
  -- fixture ran ONE consolidation, so there was no second one for the
  -- function to reach into by mistake. Every `where` that says "this
  -- one" was untested for want of another.
  --
  -- The shop next door has a month of its own, and this shop has last
  -- month's empty return sitting beside this month's. That is enough.
  select r.consolidation_id, r.document_count, r.total_amount, r.added
    into v_theirs_con, v_n, v_a, v_b
    from public.consolidate_pos_einvoices(v_them, v_start + 14) r;
  perform pg_temp.check_true(
    'the shop next door gets a consolidation of its own rather than '
    'being handed ours -- one month, one company, one submission',
    v_theirs_con is distinct from v_con);
  perform pg_temp.check_eq('and it belongs to them',
    (select c.org_id from public.einvoice_consolidations c
      where c.id = v_theirs_con), v_them);
  perform pg_temp.check_eq('holding their one sale', v_n, 1);
  perform pg_temp.check_eq('for their seventy ringgit', v_a, 70.00);

  -- Now run ours again, with theirs alive beside it. The figures on a
  -- consolidation are recomputed from its items on every run, and this
  -- is what says WHOSE items.
  select r.consolidation_id, r.document_count, r.total_amount, r.added
    into v_again, v_n, v_a, v_b
    from public.consolidate_pos_einvoices(v_org, v_start + 14) r;
  perform pg_temp.check_eq('running the month again is the same submission',
    v_again, v_con);
  perform pg_temp.check_eq('with nothing new to add', v_b::integer, 0);
  perform pg_temp.check_eq(
    'and it still names two sales, not every sale on the platform',
    v_n, 2);
  perform pg_temp.check_eq('for thirty ringgit, not a hundred', v_a, 30.00);

  -- And last month's empty return, which belongs to this same company,
  -- still says so. This one does NOT kill the mutant that widens the
  -- totals update to every row of the company -- see the note at the top
  -- of the file, the subqueries are correlated and each row is rewritten
  -- with the figures it already had. It is here because a shop files one
  -- consolidation a month and the two must stay apart.
  select c.document_count, c.total_amount into v_n, v_a
    from public.einvoice_consolidations c
   where c.org_id = v_org and c.period_start = (v_start - interval '1 month')::date;
  perform pg_temp.check_eq(
    'last month''s return still names nothing -- a company files one '
    'consolidation a month, and running one must not restate another',
    v_n, 0);
  perform pg_temp.check_eq('and still totals nought', v_a, 0);

  -- ------------------------------------------------------------------
  -- A return that has been drawn up, and one that has been sent
  -- ------------------------------------------------------------------
  -- `submitted` is refused -- that is asserted in `pos.sql`. What was
  -- never asserted is the other half: `generated` means the document
  -- has been drawn up but not sent, and a sale that arrives late is
  -- still allowed into it. Refusing at `generated` would send a shop to
  -- LHDN with an individual e-Invoice for a teh tarik.
  update public.einvoice_consolidations set status = 'generated'
   where id = v_con;
  select r.consolidation_id, r.document_count
    into v_again, v_n
    from public.consolidate_pos_einvoices(v_org, v_start + 14) r;
  perform pg_temp.check_eq(
    'a consolidation that has been drawn up but not sent is added to, '
    'not refused', v_again, v_con);
  perform pg_temp.check_eq('and still names its two sales', v_n, 2);

  -- ------------------------------------------------------------------
  -- The count is derived, not kept
  -- ------------------------------------------------------------------
  -- The function's own comment says why: "a counter is wrong the moment
  -- a row is removed". Take a sale out of the return and run it again.
  -- The sale is unclaimed once more, so it is absorbed once more --
  -- one added, and still two named. A count that added what it absorbed
  -- to what it thought it held would say three.
  delete from public.einvoice_consolidation_items i
   where i.consolidation_id = v_con and i.sales_document_id = v_spaces;
  select r.document_count, r.total_amount, r.added into v_n, v_a, v_b
    from public.consolidate_pos_einvoices(v_org, v_start + 14) r;
  perform pg_temp.check_eq('a sale put back is one sale added', v_b::integer, 1);
  perform pg_temp.check_eq(
    'and the return names two, which is what it holds -- not three, '
    'which is what it held plus what it just took in', v_n, 2);
  perform pg_temp.check_eq('for the same thirty ringgit', v_a, 30.00);

  -- ------------------------------------------------------------------
  -- Who may file it, and who may look
  -- ------------------------------------------------------------------
  v_clerk := pg_temp.another_user('kerani@example.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'viewer', 'active', now())
  on conflict (org_id, user_id) do update set role = 'viewer', status = 'active';

  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform * from public.consolidate_pos_einvoices(v_org, v_start + 14);
    raise exception 'FAIL a viewer filed the month';
  exception when insufficient_privilege then
    raise notice 'ok   filing the month is not a reading decision';
  end;

  -- And the module itself. A company that does not hold e-Invoice has
  -- no month to file, however senior the person asking -- which is a
  -- different refusal from the one above, so the message is what is
  -- asserted rather than merely that something was raised.
  update public.org_modules set is_enabled = false
   where org_id = v_them and module_code = 'einvoice';
  begin
    perform * from public.consolidate_pos_einvoices(v_them, v_start + 14);
    raise exception 'FAIL filed for a company with no e-Invoice module';
  exception when insufficient_privilege then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a company that never bought e-Invoice has no month to file',
      v_msg like '%not permitted to file e-Invoices%');
  end;
end $$;

-- =====================================================================
-- And the document it becomes
--
-- `0616`. Everything above gathers the month's unclaimed sales into
-- `einvoice_consolidations` and its items. Until 0616 that is where it
-- stopped: `einvoice_consolidations.einvoice_id` has been nullable and
-- null since `0007` and nothing ever wrote it, so the screen's
-- "Consolidated, and queued for MyInvois" described something that had
-- not happened and the seven-day clock ran out against nothing.
--
-- What is asserted is the shape LHDN asks for: the general public as
-- the buyer, one line per receipt under classification `004`, and a
-- tax figure taken off the sales documents rather than derived by
-- subtraction from a gross total.
-- =====================================================================
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org   uuid;
  v_con   uuid;
  v_ei    uuid;
  v_again uuid;
  v_doc   public.einvoice_documents;
  v_lines integer;
  v_codes text;
  v_empty uuid;
begin
  perform pg_temp.sign_in_as(v_owner);

  select id into v_org from public.organizations
   where name = 'Kedai Konsolidasi Sdn Bhd';
  select id into v_con from public.einvoice_consolidations
   where org_id = v_org
     and period_start = date_trunc('month', app.today())::date;
  perform pg_temp.check_true(
    'the month above left a consolidation to prepare', v_con is not null);

  v_ei := public.prepare_consolidated_einvoice(v_con);
  select * into v_doc from public.einvoice_documents where id = v_ei;

  -- ------------------------------------------------------------------
  -- The document
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'it is an invoice, not a self-billed anything',
    v_doc.einvoice_type_code, '01');
  perform pg_temp.check_eq(
    'and it says where it came from, which is a third kind of source',
    v_doc.source_table, 'einvoice_consolidations');
  perform pg_temp.check_eq(
    'numbered after the period, so preparing it twice cannot raise two',
    v_doc.internal_doc_no,
    'CONS-' || to_char(date_trunc('month', app.today())::date, 'YYYYMM'));
  perform pg_temp.check_eq(
    'it is queued, which is what submit picks up', v_doc.status::text, 'queued');

  -- ------------------------------------------------------------------
  -- There is no buyer
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'the buyer is the general public', v_doc.buyer_name, 'General Public');
  perform pg_temp.check_eq(
    'under LHDN''s own TIN for them',
    v_doc.buyer_tin, app.general_public_tin());
  perform pg_temp.check_eq(
    'with NA where a registration number would go',
    v_doc.buyer_id_value, 'NA');
  -- Not decoration. A consolidated e-Invoice is not sent to anybody,
  -- and an address or an e-mail on it would be somebody's -- the last
  -- walk-in customer whose details happened to be to hand.
  perform pg_temp.check_true(
    'and no contact details at all, because there is nobody to contact',
    v_doc.buyer_email is null and v_doc.buyer_phone is null);

  -- ------------------------------------------------------------------
  -- One line per receipt
  -- ------------------------------------------------------------------
  select count(*), string_agg(distinct classification_code, ',')
    into v_lines, v_codes
    from public.einvoice_lines where einvoice_id = v_ei;
  perform pg_temp.check_eq('two receipts, two lines', v_lines, 2);
  perform pg_temp.check_eq(
    'every one of them classified as a consolidated e-Invoice, which is '
    'what code 004 exists for', v_codes, '004');

  perform pg_temp.check_eq(
    'and each line is named after the receipt it stands for, which is '
    'the only thing tying it back to a sale',
    -- `in` rather than a join: document numbers repeat across
    -- companies, and joining `sales_documents` on the number alone
    -- counted the shop next door's receipt as well. It said 3.
    (select count(*)::integer from public.einvoice_lines l
      where l.einvoice_id = v_ei
        and l.description in (
              select d.doc_no from public.einvoice_consolidation_items i
                join public.sales_documents d on d.id = i.sales_document_id
               where i.consolidation_id = v_con)), 2);

  perform pg_temp.check_eq(
    'the totals are the month''s takings', v_doc.total_incl_tax, 30.00);
  perform pg_temp.check_eq(
    'and the payable amount agrees with them', v_doc.payable_amount, 30.00);
  -- Summed from the sales documents rather than taken off the items'
  -- gross, which carries no tax figure at all.
  perform pg_temp.check_eq(
    'the tax is what the sales carried, to the sen',
    v_doc.total_tax,
    (select coalesce(sum(d.tax_amount), 0)
       from public.einvoice_consolidation_items i
       join public.sales_documents d on d.id = i.sales_document_id
      where i.consolidation_id = v_con));

  -- ------------------------------------------------------------------
  -- The consolidation knows about it now
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'the consolidation points at the document it became',
    (select einvoice_id from public.einvoice_consolidations where id = v_con),
    v_ei);
  perform pg_temp.check_eq(
    'and says it has been generated',
    (select status from public.einvoice_consolidations where id = v_con),
    'generated');

  -- ------------------------------------------------------------------
  -- Preparing it twice
  -- ------------------------------------------------------------------
  -- A shop presses the button again. It must reach the same document
  -- rather than raise a second e-Invoice for the same month, which
  -- LHDN would take as two filings.
  v_again := public.prepare_consolidated_einvoice(v_con);
  perform pg_temp.check_eq('preparing it twice reaches one document',
    v_again::text, v_ei::text);
  perform pg_temp.check_eq('and does not double the lines',
    (select count(*)::integer from public.einvoice_lines
      where einvoice_id = v_ei), 2);

  -- ------------------------------------------------------------------
  -- Once it is at LHDN
  -- ------------------------------------------------------------------
  update public.einvoice_consolidations set status = 'submitted'
   where id = v_con;
  perform pg_temp.check_refused(
    'a consolidation already at LHDN is not prepared again, and the '
    'refusal says what to do with a sale that missed it',
    format($q$select public.prepare_consolidated_einvoice(%L)$q$, v_con),
    '%needs its own e-Invoice%');
  update public.einvoice_consolidations set status = 'generated'
   where id = v_con;

  -- ------------------------------------------------------------------
  -- An empty month
  -- ------------------------------------------------------------------
  -- The rollup opens a consolidation for a month with nothing in it --
  -- asserted above. Filing a zero-value e-Invoice for it would be a
  -- statement to LHDN that the shop sold nothing, which is a different
  -- claim from not having filed.
  select id into v_empty from public.einvoice_consolidations
   where org_id = v_org
     and period_start = (date_trunc('month', app.today())
                         - interval '1 month')::date;
  perform pg_temp.check_refused(
    'a month with nothing in it is not filed as nothing',
    format($q$select public.prepare_consolidated_einvoice(%L)$q$, v_empty),
    '%nothing to file%');

  -- ------------------------------------------------------------------
  -- And it is not a reading decision
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.another_user('luar@example.test'));
  perform pg_temp.check_refused(
    'somebody outside the company cannot file its month',
    format($q$select public.prepare_consolidated_einvoice(%L)$q$, v_con),
    '%not permitted to file e-Invoices%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- The scheduler's way in is nobody else's
--
-- Its own block, because it needs `set local role authenticated` and
-- that has to be undone. `0612` learned this the hard way: this suite
-- runs as the table OWNER, and an owner is not subject to its own
-- GRANTs -- so a permission assertion made without switching role
-- passes against a function granted to nobody at all, which is exactly
-- what it looked like here on the first run.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_con uuid;
begin
  select id into v_org from public.organizations
   where name = 'Kedai Konsolidasi Sdn Bhd';
  select id into v_con from public.einvoice_consolidations
   where org_id = v_org
     and period_start = date_trunc('month', app.today())::date;

  set local role authenticated;
  -- That the switch happened, before anything is concluded from it.
  perform pg_temp.check_eq(
    'and we really are somebody signed in', current_user, 'authenticated');

  perform pg_temp.check_refused(
    'the scheduler''s way in is not reachable by anybody signed in',
    format(
      $q$select public.scheduler_prepare_consolidated_einvoice(%L)$q$, v_con),
    '%permission denied%', '42501');

  -- CONTROL. The ordinary way in IS reachable by the same role, so the
  -- refusal above is about that function rather than about the role
  -- being unable to call anything.
  perform pg_temp.check_true(
    'while the ordinary one is',
    has_function_privilege('authenticated',
      'public.prepare_consolidated_einvoice(uuid)', 'execute'));

  -- And the list the scheduler reads across every company, which is
  -- the one that would leak what the shop next door owes LHDN.
  perform pg_temp.check_refused(
    'nor is the list of what every company owes',
    'select * from public.einvoice_consolidations_due(7)',
    '%permission denied%', '42501');

  reset role;
end $$;

rollback;
