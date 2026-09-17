-- =====================================================================
-- iAkauntan :: 0575 the console that is not a console
--
-- Seventh slice: the `platform_*` family, all twenty-seven.
--
-- I put this family off twice as "our own console, least urgent". That
-- was wrong, and reading it says how wrong. This family holds:
--
--   * the STATUTORY RATE TABLES that every EPF, SOCSO, EIS and PCB
--     figure in every company is computed from;
--   * tenant account credit, added and adjusted by hand;
--   * forced transfer of a company's ownership to another person;
--   * the module prices every company is billed at;
--   * suspending and archiving a company.
--
-- None of that is a console in the sense of "internal tooling nobody
-- much cares about". A wrong rate table is wrong payroll for every
-- employee of every company, and `CLAUDE.md`'s first rule is that
-- statutory arithmetic is asserted rather than eyeballed.
--
-- ---------------------------------------------------------------------
-- What the reading turned up
--
-- The two guards on `platform_publish_statutory_schedule` are the most
-- careful pieces of code in the family and neither was written down.
-- It refuses to replace a table that PAYSLIPS HAVE ALREADY BEEN
-- CALCULATED ON -- correcting it under them would change what people
-- were paid without changing what they were told -- and it asserts the
-- bands have no gap IN THE SAME TRANSACTION that inserts them, so a
-- schedule with a hole is never published rather than published and
-- then found.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The rate tables every payroll in the system reads
-- ---------------------------------------------------------------------

comment on function public.platform_publish_statutory_schedule(text, text, text, date, jsonb, text, text, numeric, text, boolean) is
  'Publishes a statutory rate table -- EPF, SOCSO, EIS or PCB -- that '
  'EVERY company''s payroll is then computed from. Platform '
  'administrators only, and the refusal says why: these rates are '
  'shared by every organization. '
  'REFUSES TO CORRECT A TABLE PAYSLIPS HAVE ALREADY BEEN CALCULATED ON, '
  'telling the operator to publish the correction from the date it '
  'takes effect instead -- rewriting it underneath existing payslips '
  'would change what people were paid without changing what they were '
  'told. Closes only schedules that started EARLIER, so republishing a '
  'correction to the current table cannot give it an `effective_to` '
  'before its own `effective_from`. Asserts the bands have no gap in '
  'the same transaction that inserts them (`0404`), so a schedule with '
  'a hole in it is never published rather than published and then '
  'found. Refuses a schedule with no rates at all, and a rounding mode '
  'outside nearest_cent, nearest_5sen and up_ringgit.';

comment on function public.platform_set_schedule_verified(uuid, boolean, text, text) is
  'Marks a statutory rate table as checked against its published '
  'source, with the source and a note. This is a claim about whether '
  'somebody compared the numbers to the gazette, not a calculation: '
  'nothing recomputes when it changes. Platform administrators only.';

-- ---------------------------------------------------------------------
-- Money and ownership
-- ---------------------------------------------------------------------

comment on function public.platform_topup_credit(uuid, numeric, text) is
  'Adds credit to a company''s platform account and raises the invoice '
  'for it, returning both. Refuses a top-up of nothing. Invoice '
  'numbers are taken under a TRANSACTION-SCOPED ADVISORY LOCK, so two '
  'administrators topping up at the same moment queue rather than both '
  'reading the same maximum and colliding on the unique index. '
  'Platform administrators only.';

comment on function public.platform_adjust_credit(uuid, numeric, text) is
  'Moves a company''s credit balance by hand, up or down, and returns '
  'the new balance. THE REASON IS REQUIRED: an unexplained adjustment '
  'to somebody''s account is the one an auditor asks about, and this is '
  'the path that does not go through an invoice. Platform '
  'administrators only.';

comment on function public.platform_mark_invoice_paid(uuid, text) is
  'Marks a platform invoice paid when the money arrived some way the '
  'system did not see -- a bank transfer reconciled by hand. Sends the '
  'company the payment-received notice, because a transfer somebody '
  'reconciled by hand is still a payment and the company that made it '
  'has no other way of learning it landed (`0491`). The notice is '
  'queued only if the invoice actually moved to paid, so the guard on '
  'the update is the guard on the mail: marking an already-paid invoice '
  'sends nothing.';

comment on function public.platform_force_transfer(uuid, text, text) is
  'Hands a company over to somebody else without the current owner''s '
  'consent -- the path for an owner who has died, left, or lost their '
  'account. The reason is REQUIRED and recorded: this is the most '
  'serious thing a platform administrator can do to a customer, and it '
  'must be answerable afterwards. The recipient must already have an '
  'account here, refused by name rather than invited. Goes through the '
  'same `app.hand_company_over` as a consented handover, so the '
  'membership changes and the audit trail are identical; what differs '
  'is only who authorised it.';

comment on function public.platform_set_org_status(uuid, text) is
  'Sets a company to active, trial, suspended or archived. This is what '
  '`workspace_by_host` reads when it decides whether a company''s own '
  'subdomain still opens: suspended and archived companies stop having '
  'a door. Platform administrators only.';

-- ---------------------------------------------------------------------
-- What companies are entitled to, and billed
-- ---------------------------------------------------------------------

comment on function public.platform_save_module(text, text, text, numeric, boolean, integer, boolean, text) is
  'Creates or edits a module in the catalogue -- its name, its monthly '
  'price, whether it is core, where it sits in the navigation. The '
  'refusal names the stake: module prices are what every organization '
  'is billed. A price below nothing is refused, and a NEW module needs '
  'a name. Platform administrators only.';

comment on function public.platform_set_module(uuid, text, boolean) is
  'Grants or withdraws one module for one company. A CORE MODULE '
  'CANNOT BE SWITCHED OFF: those are what the product is, and a company '
  'without them would be signed in to nothing. Note this is '
  'entitlement, not visibility -- a company putting a module away for '
  'itself is `set_module_hidden`. Platform administrators only.';

comment on function public.platform_end_promotion(uuid, date) is
  'Ends a promotion on a date, so it stops applying to new billing '
  'without touching what it has already discounted. Platform '
  'administrators only.';

-- ---------------------------------------------------------------------
-- Names on our domain
-- ---------------------------------------------------------------------

comment on function public.platform_reserve_subdomain(text, uuid, text, text, text, text) is
  'Holds a name on our domain -- for a company, for the platform''s own '
  'use, or parked so nobody else takes it. The SHAPE of a host label is '
  'always checked; the reserved-names BLOCKLIST only when the name is '
  'about to become a company''s (`0562`). That split is the point: '
  '`mail` sits on the blocklist with the reason "the mail service", and '
  'until `0562` nothing could ever point it AT the mail service -- the '
  'list held the name against the very use it was being held for. A '
  'null purpose means "read it off the rest of the call", which is what '
  'every caller written before `0562` meant and had no way to say. '
  'Platform administrators only.';

comment on function public.platform_update_reservation(text, uuid, uuid, text, text, text, boolean, text) is
  'Moves a reserved name between companies, repoints it, or releases '
  'it. RELEASING MEANS LETTING GO OF THE COMPANY AND KEEPING THE NAME '
  '(`0342`), not deleting the reservation. A mailbox is always a '
  'company''s, so a purpose given for one is REFUSED rather than '
  'ignored: accepting it silently would leave a caller believing a '
  'mailbox can be the platform''s. Handing a name to a company here '
  'runs the same blocklist the reservation itself does, so a rule '
  'refused in one move cannot be reached in two. Platform '
  'administrators only.';

-- ---------------------------------------------------------------------
-- The front door and the pages behind it
--
-- All of these carry the same refusal, in the same words: the landing
-- page is the whole platform's front door. The interesting rule they
-- share is that a blank field means "leave what is stored alone", so
-- an operator correcting one line does not blank the rest.
-- ---------------------------------------------------------------------

comment on function public.platform_save_landing_page(jsonb) is
  'Patches the landing page: only the fields present in the patch are '
  'changed. Validates the theme mode against system, light and dark, '
  'every colour as six hex digits after a hash, and the call-to-action '
  'as a full https address -- the same rule the store links and '
  'customer logos have, because a button the browser cannot follow is '
  'worse than an absent one: the visitor presses it and decides the '
  'product is broken. Platform administrators only.';

comment on function public.platform_save_site_page(text, text, text, boolean) is
  'Writes one of the platform''s own six pages: signin, signup, login, '
  'terms, privacy, about. A slug outside those six is refused BY NAME '
  '-- the check constraint would catch it too, with a message about a '
  'constraint, and an operator who mistyped a slug wants to be told '
  'which six there are. An emptied box stores null, so clearing a field '
  'restores what the screen ships with rather than showing a blank. '
  'Note `site_pages()` serves signin, signup and login whether or not '
  'they are published, because they carry the terms somebody is asked '
  'to agree to while registering.';

comment on function public.platform_save_landing_section(uuid, text, text, text, integer, boolean, text) is
  'Creates or edits one section of the landing page. A blank field '
  'leaves what is stored alone, so correcting a title does not empty '
  'the body. Platform administrators only.';

comment on function public.platform_save_landing_stat(uuid, text, text, text, integer, boolean) is
  'Creates or edits one of the figures on the landing page -- "12,000 '
  'invoices a month" and the like. A blank field leaves the stored one '
  'alone. Platform administrators only.';

comment on function public.platform_save_landing_testimonial(uuid, text, text, text, text, integer, boolean) is
  'Creates or edits a customer quote on the landing page. A blank field '
  'leaves the stored one alone. Platform administrators only.';

comment on function public.platform_save_landing_logo(uuid, text, text, integer, boolean) is
  'Creates or edits a customer logo on the landing page. Platform '
  'administrators only.';

comment on function public.platform_save_landing_app_link(text, text, text, text, integer, boolean) is
  'Creates or edits a download button -- App Store, Play Store -- on '
  'the landing page. The URL must be one the browser can follow, for '
  'the reason the call-to-action gives: a button that goes nowhere '
  'tells a visitor the product is broken. Platform administrators '
  'only.';

comment on function public.platform_delete_landing_section(uuid) is
  'Removes one section from the landing page. Platform administrators '
  'only.';

comment on function public.platform_delete_landing_stat(uuid) is
  'Removes one figure from the landing page. Platform administrators '
  'only.';

comment on function public.platform_delete_landing_testimonial(uuid) is
  'Removes one customer quote from the landing page. Platform '
  'administrators only.';

comment on function public.platform_delete_landing_logo(uuid) is
  'Removes one customer logo from the landing page. Platform '
  'administrators only.';

comment on function public.platform_delete_landing_app_link(text) is
  'Removes one download button from the landing page. Platform '
  'administrators only.';

-- ---------------------------------------------------------------------
-- The rest of the console
-- ---------------------------------------------------------------------

comment on function public.platform_update_setting(text, jsonb) is
  'Writes one row of `platform_settings`. Every key here is read by '
  'something -- `scripts/check_settings_are_read.py` fails the build if '
  'one is not -- because three settings once said what they did and did '
  'nothing: `nav_grouping`, `signup_enabled` and `maintenance_mode`. '
  'Platform administrators only.';

comment on function public.platform_set_ocr_provider(text, text, text, text, text, numeric, boolean, text) is
  'Creates or edits a document-scanning provider in the platform''s '
  'catalogue. NULL LEAVES WHAT IS STORED ALONE, so correcting a price '
  'does not blank the endpoint -- the trap `0107` exists to document. '
  'Platform administrators only.';

comment on function public.platform_feedback(app.feedback_status, integer) is
  'Reads what people have sent us, optionally filtered by status. '
  'Ordered faults first, worst first, then whatever came in most '
  'recently -- so the queue opens on the thing most likely to be '
  'costing somebody something. Platform administrators only.';
