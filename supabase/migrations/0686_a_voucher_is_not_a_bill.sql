-- =====================================================================
-- iAkauntan :: 0686 a voucher is not a bill
--
-- A payment voucher was photographed into Bills, and the screen asked
-- "which supplier?" with an empty search box and no explanation.
--
-- The paper:
--
--     SHAHARUDIN, SHAM SUNDER & PARTNERS
--             PAYMENT VOUCHER
--     A/C Debited: Office      File Ref: EPF
--     Pay: Online   To: KWSP   No: 16851
--     being payment of September 2023 payment      1,320.00
--
-- Every part of that is a company recording money LEAVING. The only
-- company name on it is the firm's own, on its own voucher book, and
-- the payee is the EPF. There is no supplier, there is no bill, and
-- nothing is owed to anybody once it is filed.
--
-- The reader was right to return no supplier name. Asked for the
-- supplier of a bill and told to transcribe rather than infer, the only
-- honest answer about this page is none -- and had it guessed, the
-- letterhead would have become a contact record of the firm itself and
-- a payable the firm owed to the firm.
--
-- ---------------------------------------------------------------------
-- What was actually wrong
--
-- Not the reading. The screen: `resolveSupplier` returns "ask the usual
-- way" whenever the reading names no supplier, which drops straight
-- into the ordinary picker -- the same one somebody gets when they
-- press New. No sentence about why, no near matches, no offer to
-- create, and a search box seeded with the nothing that was read.
--
-- So the person is asked a question about a document that cannot answer
-- it, in a dialog that looks exactly like the one they would have got
-- if they had never scanned anything.
--
-- The app change says so instead. This migration gives the thing a
-- name.
--
-- ---------------------------------------------------------------------
-- Why `expense` and not a destination of its own
--
-- A voucher is somebody's own record of a payment, and what the books
-- need out of it is exactly what an expense needs: who was paid, how
-- much, when, and what it was for. `0614`'s `receipt` kind already goes
-- there for the same reason.
--
-- A destination of its own would mean a screen of its own, and there is
-- no record here that an expense does not already hold. The one thing a
-- voucher carries that a receipt does not -- an authorisation trail,
-- "prepared by" and "approved by" -- is not something this system
-- models, and inventing a home for it on the strength of one photograph
-- would be the worse mistake.
--
-- `is_builtin`, so the console shows it and cannot delete it, and
-- `on conflict do nothing` so a platform that has already made its own
-- keeps theirs.
-- =====================================================================

insert into public.scan_document_kinds
  (code, label, label_my, destination, hint, sort_order, is_builtin)
values
  ('payment_voucher', 'Payment voucher', 'Baucar bayaran', 'expense',
   'Your own record of money going out. Becomes an expense — there is '
   'no supplier to owe, because nothing is owed once it is written.',
   25, true)
on conflict (code) do nothing;
