-- =====================================================================
-- iAkauntan :: 0057 recurring is a journal source of its own
--
-- Booking a recurring journal as 'manual' would put a lie in the ledger
-- about who raised it. Its own migration because Postgres will not let
-- a new enum value be added and used in the same transaction.
-- =====================================================================

alter type app.journal_source add value if not exists 'recurring';
