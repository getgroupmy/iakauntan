-- =====================================================================
-- iAkauntan :: 0602 which module, and whether both
--
-- `docs/api/` files every function under ONE module, taken from the
-- first `can_read_module` or `can_write_module` in its body. Twelve
-- functions check more than one, and for those the first name is at
-- best half the answer -- and the missing half is the half a caller
-- acts on.
--
-- Three different relationships hide behind the same list of names:
--
--   * `create_contra` needs `sales` AND `purchases`. Somebody who reads
--     "sales", switches Sales on and tries again still gets 42501, and
--     nothing published says why.
--   * `pdc_list` needs EITHER, and then filters the rows by which one
--     you have. Somebody with only Purchases reads "sales", concludes
--     it is shut to them, and never calls a function that would have
--     returned their outgoing cheques.
--   * `module_dashboard` names seven, requires none, and shows the
--     section for each module the company has. It was filed under
--     `ticketing` because that is the first one in the body.
--
-- `not A or not B` and `not A and not B` are one character apart and
-- mean opposite things, so no generator is going to tell them apart.
-- The description can, and `scripts/check_module_gates.py` now insists
-- every one of these names every module it checks.
--
-- ---------------------------------------------------------------------
-- The thing that changes most of these answers
--
-- `sales` IS A CORE MODULE. `app.has_module` returns true for a core
-- code before it looks at `org_modules` at all, for every company there
-- is. So in all ten of the `sales`/`purchases` pairs below, the `sales`
-- half is already satisfied and the guard turns entirely on Purchases:
--
--   * the five contra functions read `not sales or not purchases`,
--     which is `not purchases`. They need Purchases.
--   * the four deposit and PDC lists read `not sales and not purchases`,
--     which is `false`. The guard CANNOT FIRE, and what actually
--     decides anything is the per-row filter underneath it.
--
-- That is worth knowing and worth writing down, and `0601` is what it
-- costs not to: `deposit_history` had the second shape with no filter
-- underneath, so its only real check was one that could never fire.
--
-- Each description below says what the code requires, and says where
-- Sales being core makes that a distinction without a difference today.
-- If Sales ever stops being core, the code is already right and only
-- these words go stale.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Contra: both, because a contra has one end in each ledger
-- ---------------------------------------------------------------------

comment on function public.contra_candidates(uuid) is
  'What could be set off against what for one party: their unpaid '
  'invoices and their unpaid bills, in the company''s own currency. '
  'NEEDS BOTH `sales` AND `purchases` -- a contra has one end in each '
  'ledger, so having one module is having half the answer, and the '
  'function refuses rather than showing that half. Since Sales is a '
  'core module every company already has it, so in practice this turns '
  'on Purchases.';

comment on function public.create_contra(uuid, date, jsonb, jsonb, text) is
  'Offsets a party''s outstanding invoices against their outstanding '
  'bills. Both sides must come to the same figure, both must be in the '
  'company''s own currency, and both contacts must be the same party. '
  'NEEDS WRITE ON BOTH `sales` AND `purchases`, because it settles a '
  'document in each ledger -- switching on the one named first is not '
  'enough, and the refusal for the missing one looks the same as the '
  'refusal for the first. Since Sales is a core module every company '
  'already has it, so in practice this turns on Purchases. There is a '
  'second overload taking an idempotency key; prefer it, and see its '
  'own note.';

comment on function public.void_contra(uuid, text) is
  'Reverses a contra note, putting the balance back on both the '
  'invoices and the bills it settled. NEEDS WRITE ON BOTH `sales` AND '
  '`purchases`, the same pair as creating one -- undoing it touches '
  'both ledgers exactly as making it did. Since Sales is core, in '
  'practice this turns on Purchases.';

comment on function public.contra_notes_list(uuid, text) is
  'The company''s contra notes, newest first, optionally narrowed to '
  'one status. NEEDS BOTH `sales` AND `purchases`: every row has an '
  'end in each ledger, so this is not a list a company with one of '
  'them can be shown a part of. Since Sales is core, in practice it '
  'turns on Purchases.';

comment on function public.contra_lines(uuid) is
  'The two sides of one contra note -- which invoices and which bills '
  'it set off, and for how much. NEEDS BOTH `sales` AND `purchases`, '
  'for the same reason the note itself does. Since Sales is core, in '
  'practice it turns on Purchases.';

-- ---------------------------------------------------------------------
-- Deposits and post-dated cheques: either, and the rows follow
-- ---------------------------------------------------------------------
--
-- These four read `not sales and not purchases`, which cannot fire
-- while Sales is core. What decides anything is the row filter.

comment on function public.deposit_notes_list(uuid, text, text) is
  'Money held before there was anything to bill: customer deposits and '
  'supplier advances, optionally narrowed to one kind or status. '
  'EITHER `sales` OR `purchases` gets you in, AND THE ROWS FOLLOW THE '
  'ONE YOU HAVE -- customer deposits need `sales`, supplier ones need '
  '`purchases`, and a company with one module sees its half rather '
  'than a refusal. Since Sales is core the door is always open, so '
  'what Purchases decides is whether the supplier rows appear.';

comment on function public.deposits_held_for(uuid) is
  'The deposits still holding money for one contact, with what is left '
  'on each. EITHER `sales` OR `purchases` gets you in, AND THE ROWS '
  'FOLLOW THE ONE YOU HAVE: a customer''s deposits need `sales` and a '
  'supplier''s need `purchases`. Since Sales is core, what Purchases '
  'decides is whether a supplier''s advances appear. A deposit hidden '
  'this way is hidden, not deleted -- switch the module back on and it '
  'is there.';

comment on function public.pdc_list(uuid, text, text) is
  'Post-dated cheques on hand, optionally narrowed by direction or '
  'status. EITHER `sales` OR `purchases` gets you in, AND THE ROWS '
  'FOLLOW THE ONE YOU HAVE -- incoming cheques need `sales`, outgoing '
  'ones need `purchases`. So a company with only Purchases is NOT shut '
  'out despite `sales` being the module this is filed under: it sees '
  'its outgoing cheques. Since Sales is core the door is always open, '
  'and Purchases decides whether the outgoing half appears.';

comment on function public.pdc_maturing(uuid, date, date) is
  'The post-dated cheques falling due between two dates, which is the '
  'list somebody works from on a Monday. EITHER `sales` OR `purchases` '
  'gets you in, AND THE ROWS FOLLOW THE ONE YOU HAVE: incoming need '
  '`sales`, outgoing need `purchases`. Since Sales is core, Purchases '
  'decides whether the cheques this company has written appear beside '
  'the ones it is waiting on.';

-- ---------------------------------------------------------------------
-- Two modules for two halves of one act
-- ---------------------------------------------------------------------

comment on function public.create_po_from_suggestions(
  uuid, jsonb, date, uuid) is
  'Turns forecast reorder suggestions into purchase orders, one per '
  'supplier, and returns how many it raised. NEEDS BOTH, AT TWO '
  'DIFFERENT POINTS AND IN THIS ORDER: `forecasting` to read the '
  'suggestions, checked first, and WRITE on `purchases` to raise the '
  'orders, checked second. So a company with Forecasting and no '
  'Purchases gets past the first gate and fails at the second, having '
  'raised nothing -- the two refusals name different modules and both '
  'are real.';

comment on function public.pos_receipt_text(uuid) is
  'The receipt as plain text, wrapped to the outlet''s paper width. '
  'Rendered on the server so the counter, the phone, the kiosk and an '
  'hour-later reprint all produce the same paper. NEEDS `pos`. IT ALSO '
  'CHECKS `loyalty`, and that one is not a gate but a SECTION: the '
  'points earned and the balance are printed only for a company that '
  'has Loyalty, on a sale attached to a member, with points switched '
  'on in the receipt settings. Without the module the receipt still '
  'prints, one block shorter -- which is why somebody looking for '
  'missing points should check the module before the settings.';

comment on function public.module_dashboard(uuid) is
  'One figure set per module for the company''s home screen, built in '
  'Kuala Lumpur time. CHECKS SEVEN MODULES AND REQUIRES NONE OF THEM: '
  '`ticketing`, `pos`, `inventory`, `hr`, `payroll`, `crm` and '
  '`secretarial` each gate their own section, so the answer is a '
  'jsonb object carrying a key for every module this company has and '
  'nothing for the rest. A missing key means the module is off or '
  'hidden, NOT that the figure is zero -- the two are different and '
  'only one of them is worth telephoning somebody about. The only '
  'thing it insists on is membership of the company; it is filed under '
  '`ticketing` in this document because that is the first module its '
  'body names, which is an artefact of the filing and not a claim '
  'about the function.';
