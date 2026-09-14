-- =====================================================================
-- iAkauntan :: 0588 from a lead to a bill
--
-- Fifteenth slice of the undocumented writes: the eight that carry work
-- from a name somebody wrote down to an invoice. A lead converted or
-- lost, a deal tied to the quotation it was won on, a matter opened, a
-- project closed, and time turned into a fee note.
--
-- What these have in common is that each is the moment a guess becomes
-- a commitment, and most of them refuse in order to stop the commitment
-- inheriting the guess.
--
-- ---------------------------------------------------------------------
-- The distinction worth the whole migration
--
-- `close_project` will NOT close a project that still has unbilled
-- chargeable time on it. It names the amount and the number of entries
-- and says to bill them or to close writing them off — and writing off
-- marks the entries NON-BILLABLE RATHER THAN DELETING THEM, because the
-- hours were worked and the utilisation report that counts what people
-- did must go on counting them. What changes is only that nobody will
-- be charged.
--
-- That is the opposite of what a caller would assume from the name.
-- "Close" reads like a tidy-up; it is a refusal with money in it, and
-- `p_write_off` is not a formatting option, it is the word that says
-- somebody decided to forgo the fee. Hours left on a closed job are
-- hours nobody is looking at.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The lead, and the two ways out of it
-- ---------------------------------------------------------------------

comment on function public.convert_lead(uuid, boolean, uuid, numeric, date) is
  'Turns a lead into a customer and, unless told not to, opens an '
  'opportunity on it; returns both ids. Starts the deal in the first '
  'OPEN stage of the pipeline, not simply the first — a pipeline whose '
  'lowest sort order is "Closed lost" would otherwise open every '
  'converted lead as already dead. A lead carrying both a company and a '
  'person also gets a contact person, which is the row the e-Invoice '
  'preparation and every delivery note reach for; before that existed '
  'the person was simply lost. Refuses a lead already converted, a lost '
  'one (reopen it first), and one with neither a company nor a person '
  'to name a customer after. Needs `can_write`.';

comment on function public.close_lead(uuid, text) is
  'Marks a lead lost. A REASON IS REQUIRED and the refusal says why: a '
  'list of dead leads with no reasons on it is a list nobody reads '
  'twice, and the only value in keeping them is learning what keeps '
  'going wrong. Refuses a lead that has already become a customer — it '
  'cannot also be a lost one. Needs `can_write`.';

comment on function public.link_opportunity_quotation(uuid, uuid) is
  'Ties a deal to the quotation it will be won on, and OVERWRITES THE '
  'DEAL''S AMOUNT with the quotation''s total. That is the point rather '
  'than a side effect: the document is the priced answer and the deal''s '
  'figure was a guess, so the pipeline should report the number '
  'somebody actually worked out. Passing null unlinks and leaves the '
  'amount alone. Refuses a document that is not a quotation — a deal is '
  'won on a quotation, not on an invoice — and refuses one addressed to '
  'a different customer, which would report one company''s business '
  'under another''s. Needs `can_write`.';

-- ---------------------------------------------------------------------
-- Opening a file, with the conflict check the Act asks for
-- ---------------------------------------------------------------------

comment on function public.open_matter(uuid, text, text, uuid, text, text, uuid, uuid, numeric, numeric, text) is
  'Opens a legal matter and returns it. CHECKS FOR A CONFLICT before it '
  'does: where open or closed files already touch these parties it '
  'refuses, names how many and the first of them, and cites Rule 3 of '
  'the Legal Profession (Practice and Etiquette) Rules 1978 — the point '
  'being to stop and look, not to make the decision. A conflict '
  'considered and cleared is recorded in `p_conflict_note`, which is '
  'what turns a refusal into a written judgement somebody signed. The '
  'fee earner and the responsible solicitor must both be active members '
  'of the practice: the Act''s question is who is on the file, and it '
  'is not one to answer with somebody who does not work there. Needs '
  '`can_write` and the legal module.';

comment on function public.close_project(uuid, boolean) is
  'Closes a project. REFUSES WHILE UNBILLED CHARGEABLE TIME REMAINS, '
  'naming the amount and how many entries, because hours left on a '
  'closed job are hours nobody is looking at. `p_write_off` is the '
  'decision to forgo the fee, not a formatting option — and it marks '
  'those entries non-billable RATHER THAN DELETING THEM, so the '
  'utilisation report goes on counting hours that were genuinely '
  'worked. Needs `can_post`, which is heavier than editing a project: '
  'writing off billable time is a decision about revenue.';

-- ---------------------------------------------------------------------
-- Time into a fee note
-- ---------------------------------------------------------------------

comment on function public.bill_matter_time(uuid, date, date, date) is
  'Raises one fee note for all unbilled chargeable time on a matter '
  'between two dates, marks that time billed, and returns the invoice. '
  'A thin wrapper: everything that decides the figures is in '
  '`app.bill_time_internal`, shared with `bill_project_time`, and the '
  'two differ only in which module must be on and which engagement is '
  'named. THE TAX IS THE TAX ON THE PERIOD END, not today — work done '
  'before the firm registered for SST is billed without it. The due '
  'date comes from the client''s agreed payment terms unless one is '
  'passed, and a passed date wins because that is a date somebody '
  'negotiated. Refuses when there is no unbilled chargeable time in the '
  'period, and refuses an engagement with no client to invoice. Needs '
  '`can_post` and the legal module.';

comment on function public.bill_project_time(uuid, date, date, date) is
  'The same for a project, through the same '
  '`app.bill_time_internal` — same tax-on-the-period-end rule, same '
  'payment terms, same refusals. Needs `can_post` and the timesheets '
  'module. Time on a project whose contact is empty cannot be billed at '
  'all, which is worth knowing before a quarter''s work is entered '
  'against one.';

comment on function public.bill_statutory_charge(uuid, uuid, date, text, uuid) is
  'Raises a supplier bill for a quit rent, assessment or other '
  'statutory property charge, and links the charge to it. Refuses a '
  'charge already on a bill, naming that bill. REFUSES A CHARGE ALREADY '
  'MARKED PAID BY HAND, and says to clear the paid date first — a typed '
  'date and a bill would each claim to be the record of the payment, '
  'and clearing it is the deliberate step that says which one is right. '
  'Refuses a nil charge: a bill is for something. The link is made LAST '
  'because a trigger derives the charge''s paid date from the bill the '
  'moment it exists, and a bill not yet posted has no balance to derive '
  'it from. Needs `can_post` and the property module.';
