-- ---------------------------------------------------------------------
-- 0438  The quotation that forgot the tax
-- ---------------------------------------------------------------------
-- The same predicate `0437` came out of, run over every function in
-- this database that inserts a sales or purchase document line: which
-- of them writes a tax rate unconditionally, and which tenant shape
-- makes that wrong. Fourteen functions do; six write no tax code at
-- all. Of those six, one is provably wrong and is fixed here. The other
-- five are named at the bottom, examined and left alone, so the next
-- sweep does not re-find them and so the reasons are on the record.
--
-- `quote_opportunity` -- the CRM's "turn this deal into a quotation" --
-- writes one line and names neither a tax code nor a rate:
--
--     insert into public.sales_document_lines
--       (org_id, document_id, line_no, description, quantity, unit_price)
--     values (v_o.org_id, v_doc, 1, ..., 1, v_o.amount);
--
-- Measured end to end on Sinar, which `demo_books_sinar` registers for
-- service tax at ST8: a deal worth RM84,000 quotes at RM84,000 with
-- RM0.00 of tax, and `transfer_document` -- which copies `tax_code_id`
-- and `tax_rate` from the source line, correctly -- carries that zero
-- straight into the invoice. Subtotal 84,000, tax 0.00, total 84,000,
-- and no line on it with a rate. The customer is billed 84,000, the
-- real price is 90,720, and the RM6,720 is the registrant's to pay
-- whether or not they collected it.
--
-- Worse than `0437` in reach, if not in size. A fee note is one path; a
-- quotation is the front of the whole sales pipeline, and because the
-- transfer faithfully copies what it is given, every invoice raised
-- from a quoted deal inherits the omission. `0417` was the reverse
-- failure on the same pair of documents -- an invoice that charged more
-- than the quotation -- and this is the one that makes them agree on
-- the wrong number.
--
-- The rate comes from `app.default_sales_tax`, which `0437` added: the
-- code the company registered for, if it was registered on the day the
-- quotation is dated, and nothing otherwise. Nothing new is invented
-- here and there is no second source of truth.
--
-- The deal's figure is treated as tax-exclusive, which is a judgement
-- and is stated rather than assumed. A salesperson records the contract
-- value; the tax is added on top when it is invoiced, which is what the
-- invoice raised from this quotation will do. Reading it the other way
-- -- RM84,000 inclusive -- would quote a lower contract value than the
-- deal says it is worth, and the pipeline and the document would then
-- disagree about the size of the deal, which is exactly what
-- `quote_opportunity`'s own comment says it exists to prevent.
-- Three mutants applied and measured:
--
--   * the code named and its rate left at zero -- killed, "a registered
--     company quotes the tax it will charge", got 0.00;
--   * the deal's figure read as tax-inclusive instead -- killed by the
--     SAME assertion, got 6,222.22 on RM84,000. The assertion written
--     for it -- "the deal is still worth what the pipeline says" --
--     made no kill of its own, because the tax assertion runs first.
--     It is the clearer statement of what went wrong and it stays, but
--     it is not credited with catching this;
--   * `app.default_sales_tax` replaced by a bare lookup of the default
--     tax code, ignoring registration -- killed by this migration's own
--     apply-time guard before the test ran, so it did not exercise any
--     assertion.
--
-- The unregistered control caught nothing and could not: no mutant
-- reachable through this function can make an unregistered company
-- quote tax, because `set_sst_registration` leaves a zero-rated 'NA'
-- code as the default on one. It is a guard against a future change
-- that assumes registration, and it is worth having on those terms
-- rather than as a kill it did not make.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The quotation, restated to carry it
-- ---------------------------------------------------------------------
-- Restated from the live `pg_get_functiondef`.

CREATE OR REPLACE FUNCTION public.quote_opportunity(p_opportunity uuid, p_valid_until date DEFAULT NULL::date, p_description text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_o     public.opportunities;
  v_doc   uuid;
  v_no    text;
  v_tax   uuid;
  v_rate  numeric := 0;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  select * into v_o from public.opportunities
   where id = p_opportunity and deleted_at is null;
  if v_o.id is null then
    raise exception 'No such opportunity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_o.org_id) then
    raise exception 'not permitted to raise a quotation'
      using errcode = '42501';
  end if;
  if v_o.contact_id is null then
    raise exception
      'A quotation goes to somebody. Name the customer on the deal '
      'first.' using errcode = '23502';
  end if;
  if v_o.quotation_id is not null then
    raise exception
      'This deal already has a quotation. Revise that one, or the '
      'pipeline ends up with two figures for one job.'
      using errcode = '23505';
  end if;
  if v_o.status <> 'open' then
    raise exception
      'This deal is already %. Quoting a closed deal is quoting for '
      'work nobody is waiting on.', v_o.status using errcode = '23514';
  end if;
  if coalesce(v_o.amount, 0) <= 0 then
    raise exception
      'The deal is worth nothing, so there is nothing to quote. Put the '
      'figure on the deal first.' using errcode = '23514';
  end if;
  if p_valid_until is not null and p_valid_until < v_today then
    raise exception 'A quotation cannot be valid until a day that has '
      'already passed.' using errcode = '23514';
  end if;

  v_no := public.next_document_number(v_o.org_id, 'quotation');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, valid_until, notes, created_by)
  values (v_o.org_id, 'quotation', v_no, v_today, v_o.contact_id,
          coalesce(v_o.currency, app.base_currency(v_o.org_id)), 1,
          'draft',
          -- A quotation with no end is an offer that never runs out,
          -- which `0374` is the note on. Thirty days where nobody said.
          coalesce(p_valid_until, v_today + 30),
          v_o.name, auth.uid())
  returning id into v_doc;

  -- One line, at the deal's own figure. It is a starting point that
  -- somebody prices properly; what matters is that the deal and the
  -- document begin from the same number instead of two.
  --
  -- 0438. With the tax the company is registered for, as of the day the
  -- quotation is dated. `tax_rate` as well as `tax_code_id`: totals are
  -- recalculated from the rate on the line, so naming ST8 without its 8
  -- produces a quotation showing a tax code and charging nothing. The
  -- deal's figure is read as tax-exclusive -- a salesperson records the
  -- contract value and the tax goes on top when it is invoiced.
  v_tax := app.default_sales_tax(v_o.org_id, v_today);
  select coalesce(rate, 0) into v_rate from public.tax_codes
   where id = v_tax;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (v_o.org_id, v_doc, 1,
          coalesce(nullif(btrim(coalesce(p_description, '')), ''), v_o.name),
          1, v_o.amount, v_tax, coalesce(v_rate, 0));

  update public.opportunities
     set quotation_id = v_doc, updated_at = now()
   where id = p_opportunity;

  return v_doc;
end $function$;

-- ---------------------------------------------------------------------
-- The other five, examined and left alone
-- ---------------------------------------------------------------------
-- Recorded so the next sweep does not re-find them, and so that leaving
-- them is a decision on the record rather than an omission.
--
--   * `bill_statutory_charge` writes quit rent and assessment at rate
--     zero. Those are charges levied by a land office and a local
--     authority. They are not a supply of services by anybody and
--     carry no service tax; zero is the right number and adding a
--     default here would put tax on a government charge.
--
--   * `settle_pos_stalls` raises a self-billed purchase for a stall's
--     takings less the operator's commission. What the operator earns
--     is the commission, not the bill, and the two are netted into one
--     figure. Whether that commission is a taxable supply, and how it
--     would be presented if it is, is a question about how stall
--     settlement should be modelled -- not a rate to slot in. Left as
--     it is, deliberately and with the question named.
--
--   * `raise_rent_invoices` and `raise_strata_charges` write rent and
--     maintenance charges at rate zero. Whether service tax reaches
--     rental of immovable property, and whether a management
--     corporation's maintenance charge is a taxable supply at all, are
--     scope questions with thresholds and exclusions attached. Nothing
--     in this repository records which reading it follows, and a rate
--     put in on my reading of the scope rules would be a statutory
--     number nobody chose. This one is a product decision with tax
--     advice behind it, and it is named here rather than guessed.
--
--   * `raise_recurring_document` looked like a sixth and is not. It
--     copies the template's lines wholesale through
--     `jsonb_populate_record`, so it carries whatever tax code and rate
--     the template line has. Nothing hardcoded, nothing to fix.
--
-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = to_regprocedure('public.quote_opportunity(uuid, date, text)');

  if v_src !~ 'default_sales_tax' then
    raise exception
      'FAIL 0438: a quotation still carries no tax code, so a registered '
      'company quotes a price it cannot invoice';
  end if;

  -- Both halves, as in 0437: the rate lives on the line, not on the
  -- code, so naming the code and leaving the rate at zero would satisfy
  -- the check above and quote nothing.
  if v_src !~ 'tax_code_id' or v_src !~ 'v_rate' then
    raise exception
      'FAIL 0438: the quotation names a tax code without its rate';
  end if;

  -- And asked about the quotation's own date, not today's. They are the
  -- same day here, so nothing would fail if this drifted -- which is
  -- exactly why it is asserted rather than left to the reader.
  if v_src !~ 'default_sales_tax\(v_o\.org_id, v_today\)' then
    raise exception
      'FAIL 0438: the tax lookup is not being asked about the date the '
      'quotation is dated';
  end if;

  raise notice
    '0438: a registered company quotes the price it will invoice';
end
$do$;
