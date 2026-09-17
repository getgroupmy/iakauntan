-- =====================================================================
-- iAkauntan :: 0594 what gets used up
--
-- The ninth slice of the undocumented writes: the seven that consume
-- something finite. A credit balance, a slot in somebody's day, a
-- session out of a membership that was paid for once.
--
-- The question a caller cannot get from the signature is the same in
-- all seven, and it has three parts: what does this use up, WHEN is it
-- used up, and what stops it being used twice or given away?
--
-- ---------------------------------------------------------------------
-- Charged before the answer
--
-- `ai_ask` takes the money first and refuses when the credit is not
-- there. That is not tidiness: the model bills for the attempt, so
-- charging after a successful answer would let a company at nil ask for
-- ever and pay for none of it.
--
-- The price is worth publishing for a second reason. `ai_ask` carries
-- RM0.20 as a CONSTANT IN ITS OWN BODY, while `ocr_begin` reads the
-- price off the `ocr_providers` row an operator maintains in the
-- console. Two prices in one product, one of them data and one of them
-- a migration. A caller reading the description should know which kind
-- they are looking at.
--
-- ---------------------------------------------------------------------
-- And the two that charge nothing, for different reasons
--
-- `ocr_begin` charges nothing when the company is on its own provider
-- key: it is paying the provider directly, and billing it here would
-- be charging twice. `ocr_record_local` charges nothing because the
-- reading happened on the phone and cost us nothing at all -- but it
-- still writes the scan row, failures included, so the history of what
-- was read is complete whether or not anybody was billed.
--
-- ---------------------------------------------------------------------
-- The two refusals that stop something being given away
--
-- `start_membership` will not start one until the sale is COMPLETED --
-- "an entitlement nobody paid for" -- and will not start one that is
-- not on that sale, because otherwise the button is a way to hand out
-- memberships.
--
-- `cover_line_with_membership` computes the covered amount from the
-- line rather than taking it as an argument. A caller that could name
-- the amount could cover a fifty-ringgit treatment with a ten-ringgit
-- membership, and no refusal anywhere would have caught it.
--
-- ---------------------------------------------------------------------
-- Nothing new is asserted here
--
-- `pos_service.sql` already pins the behaviour of the four POS
-- functions, including that checking in twice reaches the same sale and
-- that the membership covers the whole line. This migration publishes
-- what those tests already hold true; it does not add a claim nothing
-- checks.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Credit
-- ---------------------------------------------------------------------

comment on function public.ai_ask(uuid, text, uuid) is
  'Puts a question to the assistant and returns the conversation it '
  'belongs to, starting one when `p_conversation` is null. CHARGES '
  'RM0.20 BEFORE THE ANSWER and refuses when the credit is short: the '
  'model bills for the attempt, so charging afterwards would let a '
  'company at nil ask for ever. That price is a constant in the '
  'function rather than a setting -- unlike scanning, changing it is a '
  'migration. Needs the `ai` module and membership of the company; an '
  'existing conversation must be one you started, or you must be an '
  'administrator.';

comment on function public.ocr_begin(uuid, uuid) is
  'Opens a scan and hands back what the caller needs to run it -- '
  'provider, endpoint, model, storage path -- having first charged for '
  'it. The price comes from the `ocr_providers` catalogue, so an '
  'operator can change it without a release. CHARGES NOTHING WHEN THE '
  'COMPANY IS ON ITS OWN KEY: it pays the provider directly and '
  'billing here would be charging twice; in that case the function '
  'instead refuses if the key has since been removed, because a scan '
  'with no key is a failure with no explanation. Refuses when scanning '
  'is switched off, and refuses with `0A000` when the chosen reader '
  'runs on the device -- there is nothing for the server to do. The '
  'scan row is written whether or not anything was charged. Needs '
  '`can_write`.';

comment on function public.ocr_record_local(uuid, uuid, jsonb, text) is
  'Records a scan that was read ON THE DEVICE and charges nothing, '
  'because it cost nothing: `key_source` is `device` and '
  '`amount_charged` is zero. The row is written either way -- pass '
  '`p_error` and it is filed as failed -- so the history of what was '
  'read is complete even where no money moved. The mirror of '
  '`ocr_begin`: this one refuses when the company''s reader does NOT '
  'run on the device, so a server-side reader cannot be billed as a '
  'free local one. Needs `can_write`.';

-- ---------------------------------------------------------------------
-- A slot in somebody's day
-- ---------------------------------------------------------------------

comment on function public.book_appointment(uuid, uuid, timestamp with time zone, uuid, text) is
  'Takes a slot with a provider. The end is worked out here, not '
  'passed in: the service''s duration PLUS its turnaround, so the next '
  'customer is not booked into the time it takes to clean the chair. '
  'Refuses a provider who is inactive or not working then, and refuses '
  'a service with no duration set. The overlap message names the time '
  'of the clashing appointment -- but that look-up is only there to '
  'make a sentence; what actually decides is the exclusion constraint '
  'on the table, which has no window between the check and the insert '
  'for a second booking to slip through. Price and description are '
  'snapshotted from the item, so a later price change does not rewrite '
  'a quote. Needs the POS module.';

comment on function public.check_in_booking(uuid, uuid) is
  'Marks the customer as arrived and opens the sale for the '
  'appointment, returning it. IDEMPOTENT ON PURPOSE: a booking that '
  'already has a sale returns that same sale rather than opening a '
  'second one, because a receptionist whose screen was slow will tap '
  'again, and two bills against one appointment is the kind of mess '
  'that is found at close of day. Refuses an appointment that was '
  'cancelled or marked a no-show, and refuses a register at a '
  'different outlet. Needs the POS module.';

-- ---------------------------------------------------------------------
-- An entitlement somebody paid for
-- ---------------------------------------------------------------------

comment on function public.start_membership(uuid, uuid) is
  'Starts a membership off the sale that bought it, and sets up the '
  'renewal from the invoice that sale raised -- which already carries '
  'the right price, tax code and terms. TWO REFUSALS ARE THE POINT: '
  'the sale must be COMPLETED, because a membership that starts before '
  'the money is taken is an entitlement nobody paid for; and the '
  'membership''s item must actually be on that sale, because otherwise '
  'this is a button that gives memberships away. Also needs a contact '
  '-- a membership belongs to a member. Needs the memberships module.';

comment on function public.cover_line_with_membership(uuid, uuid) is
  'Discounts a bill line away against a membership and records the '
  'session used, returning what was covered. THE AMOUNT IS COMPUTED '
  'FROM THE LINE AND CANNOT BE PASSED IN: a caller that could name it '
  'could cover a fifty-ringgit treatment with a ten-ringgit '
  'membership, and nothing downstream would have noticed. Refuses a '
  'bill that is not parked, a membership that is not active, an item '
  'the membership does not cover -- where a membership listing NO '
  'items covers everything, which is what unlimited means -- and a '
  'period with no sessions left. Needs the memberships module.';
