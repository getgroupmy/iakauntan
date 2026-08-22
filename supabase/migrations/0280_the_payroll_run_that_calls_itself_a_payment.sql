-- =====================================================================
-- iAkauntan :: 0280 the payroll run that calls itself a payment
--
-- app.default_doc_prefix decides what a document series is called.
-- 0030 gave the HRMS and legal document types their own prefixes and
-- 0044 kept them. 0099 then re-created the function from a copy that
-- predated 0030 and dropped seven arms in one edit:
--
--   payroll_run 'PYR-'   expense_claim 'CLM-'   leave_request 'LV-'
--   job_requisition 'JR-'   client_transaction 'CLI-'
--   matter 'MAT-'   employee 'EMP-'
--
-- Nothing failed, because the function ends in
--
--   else upper(left(p_doc_type, 3)) || '-'
--
-- which quietly produces something plausible for anything it has never
-- heard of. Three of the seven happen to land on the value they lost
-- (client_transaction, matter and employee), which is part of why this
-- went unnoticed for a hundred and eighty migrations.
--
-- Of the seven, only two are ever passed to the numbering function:
-- payroll_run and leave_request. The other five are numbered by their
-- callers or not at all -- expense_claims.claim_no is supplied by
-- whoever raises the claim -- so their arms were already dead when
-- 0099 removed them, and they are not restored here. Restoring an arm
-- nothing reaches would only make the next person believe it is load
-- bearing.
--
-- payroll_run is the one that matters, because its fallback is a
-- collision rather than a cosmetic difference:
--
--   payment      -> 'PAY-'
--   payroll_run  -> upper(left('payroll_run', 3)) || '-'  ->  'PAY-'
--
-- The counters are separate, one per (org_id, doc_type), so both
-- series count from one and a company ends up with a supplier payment
-- PAY-000007 and a payroll run PAY-000007. Nothing in the schema stops
-- it, because nothing in the schema knows the two series were ever
-- meant to be different. leave_request is the cosmetic one: 'LEA-'
-- where 'LV-' was meant.
--
-- A prefix is copied onto the number_sequences row the first time a
-- series is used, so correcting the function alone would fix new
-- organizations and leave every existing one numbering payroll runs
-- PAY-. The update below repairs those rows, and only where the stored
-- prefix is exactly the wrong fallback, so a company that deliberately
-- chose its own prefix keeps it.
--
-- Documents already issued keep the numbers they were issued under: a
-- series that has reached PAY-000007 continues at PYR-000008. Renaming
-- a document after the fact is worse than a visible change of prefix,
-- because the old number is on paperwork that has left the building.
-- =====================================================================

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
    -- Restored. 0030 added it, 0044 kept it, 0099 dropped it, and
    -- without it a payroll run is numbered PAY- like a payment.
    when 'payroll_run'          then 'PYR-'
    -- Restored for the same reason; 'LEA-' is not wrong, only not what
    -- the series was named.
    when 'leave_request'        then 'LV-'
    when 'expense'              then 'EXP-'
    when 'journal'              then 'JV-'
    when 'stock_adjustment'     then 'ADJ-'
    when 'stock_movement'       then 'SM-'
    when 'lead'                 then 'LD-'
    when 'opportunity'          then 'OPP-'
    when 'contact'              then 'C-'
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

-- The rows already carrying the fallback, and only those.
update public.number_sequences
   set prefix = 'PYR-'
 where doc_type = 'payroll_run' and prefix = 'PAY-';

update public.number_sequences
   set prefix = 'LV-'
 where doc_type = 'leave_request' and prefix = 'LEA-';

-- 0165's event trigger strips PUBLIC and anon from a newly created
-- function, so the grant is written back after every re-create.
grant execute on function app.default_doc_prefix(text) to authenticated;
