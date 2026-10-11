-- =====================================================================
-- iAkauntan :: 0815 a payment is applied by applying it
--
-- `payment_allocations` ties a receipt or a payment to the invoices or
-- bills it settles, and its trigger, `app.apply_allocation`, moves the
-- documents' paid and balance figures to match. The app writes every
-- allocation through `allocate_with_discount`,
-- `allocate_payment_with_discount` and their siblings -- credit notes,
-- deposits, contras, post-dated cheques, the till -- all SECURITY
-- DEFINER; its own comment says one path means "the discount cannot be
-- written by a route that forgets the journal". But `authenticated`
-- could insert, update and delete allocations directly.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: a posted receipt of RM950 settled a RM1,000 invoice
-- with a RM50 settlement discount, journal and all. Its allocation
-- deleted by hand, and the invoice owed RM1,000 again and the receipt
-- had RM950 unapplied -- while the ledger, which had posted the
-- discount, said nothing was owed. The documents and the ledger
-- disagreed by RM50, and nothing would say so.
--
-- Answered "read-only to clients", as `0804` and `0806` to `0811`: the
-- grants are revoked and the write policies dropped. Reading stays.
--
-- Production held seventy-six allocations, none discounted, on 11
-- October.
-- =====================================================================

revoke insert, update, delete on public.payment_allocations from authenticated, anon;
drop policy if exists payment_allocations_insert on public.payment_allocations;
drop policy if exists payment_allocations_update on public.payment_allocations;
drop policy if exists payment_allocations_delete on public.payment_allocations;

comment on table public.payment_allocations is
  'What a receipt or payment settled, invoice by invoice and bill by bill; '
  'app.apply_allocation moves the documents'' figures to match. WRITTEN '
  'ONLY BY FUNCTION -- 0815 revoked insert, update and delete from '
  'clients and dropped the write policies; allocate_with_discount, '
  'allocate_payment_with_discount and the credit note, deposit, contra, '
  'cheque and till functions write it.';
