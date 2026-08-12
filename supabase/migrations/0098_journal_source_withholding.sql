-- =====================================================================
-- iAkauntan :: 0098 withholding is a journal source of its own
--
-- Booking a s.109 deduction as 'manual' would put a lie in the ledger
-- about who raised it, and would make the withholding activity
-- unfilterable from everything else somebody typed by hand. Its own
-- migration because Postgres will not let a new enum value be added and
-- used in the same transaction — the same reason 0057 exists.
-- =====================================================================

alter type app.journal_source add value if not exists 'withholding';
