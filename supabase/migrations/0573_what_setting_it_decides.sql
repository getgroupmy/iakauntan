-- =====================================================================
-- iAkauntan :: 0573 what setting it decides
--
-- Fifth slice, and the last of the families where the stakes are high
-- enough to be worth this much care. `0569` did the open doors, `0570`
-- the thirteen that move money, `0571` the posting and creating verbs,
-- `0572` the twenty-one that undo something. This one is `set_*`: the
-- whole family, twenty-three of them.
--
-- "Set" reads like the least interesting verb in the schema, and the
-- family turns out to hold the single highest-stakes function in the
-- whole surface -- `set_fiscal_period_status`, which decides what the
-- ledger will accept -- alongside every credential setter and the
-- shape of a group's consolidated accounts.
--
-- ---------------------------------------------------------------------
-- One thing they nearly all share
--
-- A setter that quietly accepted a contradiction would be the worst
-- shape here, and almost none of them do. `set_outlet_channel` refuses
-- a default that is not active, saying so rather than correcting it,
-- because the caller asked for two things that contradict each other.
-- `set_ocr_settings` refuses to switch scanning on with no model to
-- send a document to. `set_line_lots` refuses at the line rather than
-- at posting, because the person who knows which boxes they picked is
-- the one looking at the line now, not whoever presses Post next week.
--
-- The comments say what each refuses, because for a setter that is the
-- whole of what it means.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The one that decides what the ledger accepts
-- ---------------------------------------------------------------------

comment on function public.set_fiscal_period_status(uuid, text) is
  'Opens, closes or LOCKS a fiscal period, which decides what the '
  'ledger will take: posting is refused outside an open period, so this '
  'is the switch behind every "the period is closed" refusal elsewhere. '
  'Three statuses and no others. LOCKED IS TERMINAL -- a locked period '
  'cannot be reopened by any path, because that is what year-end '
  'sign-off means, and a lock somebody can undo is not a sign-off. '
  'Needs `can_admin`: closing the books is not a bookkeeping act.';

-- ---------------------------------------------------------------------
-- Figures somebody will read as fact
-- ---------------------------------------------------------------------

comment on function public.set_group_ownership(uuid, uuid, numeric) is
  'States what share of THIS company the parent holds, which is what '
  'consolidation is computed from. Needs `can_admin` of the company '
  'being owned and deliberately NOT of the parent: this is a fact about '
  'this company''s share capital, and the person who runs it is the one '
  'who knows it. The parent must be in the same group and one the '
  'caller can already reach -- the rule `link_group_contact` uses, for '
  'the same reason: otherwise this becomes a way to discover which '
  'companies exist. Refuses a company owning itself, and a percentage '
  'outside nought to a hundred.';

comment on function public.set_budget_lines(uuid, jsonb) is
  'Replaces a budget''s lines wholesale and returns how many were '
  'written. DRAFT ONLY: an approved budget is what variance is reported '
  'against, and rewriting it underneath a report already circulated '
  'would change what people were told without changing the report. '
  'A ZERO IS NOT A LINE and is dropped rather than stored -- keeping '
  'them would fill the grid with rows that say nothing and make "which '
  'accounts are budgeted" unanswerable. Refuses an account that does '
  'not exist or is a heading, and a period outside the budget''s year.';

comment on function public.set_line_lots(text, uuid, jsonb) is
  'Records which batches or serial numbers a line is made up of, and '
  'returns how many were recorded. Refused for sales lines -- those '
  'take their lots at picking, not at entry. Refuses an item not '
  'tracked by batch or serial, a line with no reference, and a quantity '
  'of nothing. A serial is one unit by definition, so the screen cannot '
  'say otherwise. All of it is refused HERE rather than at posting, '
  'deliberately: the person who knows which boxes they picked is the '
  'one looking at this line now; the one who finds out at posting is '
  'whoever presses the button a week later.';

-- ---------------------------------------------------------------------
-- Credentials, set
--
-- The other half of `0572`'s `clear_*` group. Each takes a secret this
-- company is handing over for us to act in its name, which is why all
-- of them need `can_admin` rather than `can_write`.
-- ---------------------------------------------------------------------

comment on function public.set_einvoice_credentials(uuid, text, text, text, text, text, text, text, timestamp with time zone) is
  'Stores a company''s MyInvois credentials and signing certificate for '
  'one environment, sandbox or production, replacing what was there. '
  'The environment must be one of those two by name. The client secret '
  'may be omitted on a later call to keep the one already stored -- so '
  'a screen can show the certificate details and save them without '
  'having the secret to re-send -- but it must be present the FIRST '
  'time, and the function says so rather than storing a row that cannot '
  'authenticate. Needs `can_admin`.';

comment on function public.set_org_payment_gateway(uuid, text, text, text, text, text, boolean) is
  'Stores a company''s own acquirer credentials for one gateway in one '
  'mode. `can_admin` and not `can_write`, because these are the keys to '
  'taking money in this company''s name. Refuses a gateway this '
  'platform does not know and a mode that is neither sandbox nor '
  'production. The key is resolved BEFORE the insert rather than in the '
  '`on conflict` arm: `api_key` is NOT NULL and the proposed row is '
  'validated before the conflict is looked for, so a coalesce in the '
  'update arm would never run (`0107`).';

comment on function public.set_ocr_credentials(uuid, text, text, text, text, text) is
  'Stores a company''s own document-scanning key for `claude` or '
  '`google`. The key may be omitted to keep the stored one, but is '
  'required the first time a provider is configured. For Google, a '
  'processor id is required as well: Document AI is addressed by '
  'processor, not by project alone, and a key with no processor behind '
  'it is a 404 at the first scan. Needs `can_admin`.';

comment on function public.set_ocr_settings(uuid, boolean, text, text) is
  'Switches document scanning on or off and chooses whose key it uses '
  '-- the company''s own or the platform''s. Refuses to switch on a '
  'provider that is not available, and refuses to switch on a reader '
  'with nowhere to send the document and no model to send it to. That '
  'last one is caught HERE, where an operator can still do something '
  'about it, rather than becoming a 404 waiting for somebody to press '
  'Scan. Needs `can_admin`.';

comment on function public.set_ai_credentials(uuid, text, text, text) is
  'Stores a company''s own key for one AI provider, so the assistant '
  'bills them rather than us. Refuses an unknown provider, an empty '
  'key, and a provider that needs a base URL given without one. Needs '
  '`can_admin`.';

comment on function public.set_platform_ai_key(text, text, text) is
  'Stores the PLATFORM''s key for one AI provider -- ours, used by every '
  'company that has not set its own. Needs a platform administrator, '
  'which is a different question from being an administrator of any '
  'company.';

comment on function public.set_platform_ai_default(text, text) is
  'Chooses which provider and model the assistant uses by default. '
  'Refuses a provider that is not switched on and a model that provider '
  'does not offer, so the default can never name something that cannot '
  'answer. Platform administrators only.';

-- ---------------------------------------------------------------------
-- Who may do what, and what a company sees
-- ---------------------------------------------------------------------

comment on function public.set_member_access_type(uuid, uuid) is
  'Puts a member on an access type -- the named bundle of permissions '
  'this company defined -- or takes them off it with null. The access '
  'type must belong to the SAME company, refused by name rather than '
  'ignored: an id from another company''s list would otherwise be '
  'silently dropped and read as applied. Needs `can_admin`.';

comment on function public.set_module_hidden(uuid, text, boolean) is
  'Puts a module away, or brings it back, for one company. The test is '
  'ENTITLEMENT, not whether a row happens to exist: `0233`''s backfill '
  'left `is_enabled = false` rows on companies that do not hold the '
  'module, and a "no row" test let those straight through -- which is '
  'what the production probe caught. You cannot put away something you '
  'were never given. Needs `can_admin`.';

comment on function public.set_bank_feed_paused(uuid, boolean) is
  'Pauses or resumes the automatic statement feed on one bank account. '
  'Pausing stops new statement lines arriving; it does not disconnect '
  'the feed or discard what has already come in. Needs `can_admin`.';

comment on function public.set_custom_field_active(uuid, text, text, boolean) is
  'Switches one custom field on or off for an entity type. Switching '
  'off hides the field from forms and keeps every value already '
  'recorded against it, so turning it back on restores the data rather '
  'than an empty column. Refuses a field that does not exist on that '
  'entity, naming both. Needs `can_admin`.';

comment on function public.set_onboarding_task_done(uuid, boolean) is
  'Ticks or unticks one task on somebody''s onboarding checklist. '
  'WHOEVER THE TASK BELONGS TO MAY TICK IT -- the assignee as well as '
  'HR -- which is the point of assigning one to a line manager rather '
  'than to a department. The checklist''s completion timestamp is '
  'written only when the answer actually changes, so ticking a fourth '
  'optional task does not keep moving the completion date of a '
  'checklist that finished last week.';

-- ---------------------------------------------------------------------
-- The counter
-- ---------------------------------------------------------------------

comment on function public.set_membership_status(uuid, app.pos_membership_status) is
  'Changes a membership''s status and returns what it became. Ending a '
  'membership -- cancelled or expired -- ALSO STOPS ITS RECURRING '
  'BILLING, and that second half is the point: a cancelled member who '
  'keeps receiving invoices is the complaint that reaches the '
  'regulator. Needs the `memberships` module.';

comment on function public.set_booking_status(uuid, app.pos_booking_status, text) is
  'Moves a table booking along. `arrived` and `completed` CANNOT be set '
  'here: they are claims about money and stock, and checking in and '
  'settling the sale are the only things entitled to make them. A '
  'completed booking cannot be moved at all. Needs the `pos` module.';

comment on function public.set_pos_sale_channel(uuid, app.pos_order_channel) is
  'Says how an order arrived -- counter, delivery, and the rest -- for '
  'one sale. ONLY WHILE IT IS STILL A BASKET: once the sale completes '
  'the channel is on an issued invoice and part of what has been '
  'reported, and an issued document does not change because somebody '
  're-categorised it. A channel the outlet does not offer is refused.';

comment on function public.set_outlet_channel(uuid, app.pos_order_channel, boolean, boolean, integer) is
  'Configures one order channel for an outlet -- whether it is offered, '
  'whether it is the default, and where it sits in the list. Refuses a '
  'default that is not active rather than quietly correcting it: a '
  'default nobody can order through is not a default, and the caller '
  'asked for two things that contradict each other. Making one the '
  'default clears the previous one in the same transaction. Needs the '
  '`pos` module.';

comment on function public.set_item_stall(uuid, uuid) is
  'Puts an item on a stall in a food court, or takes it off with null. '
  'The stall must be this company''s, refused by name rather than '
  'ignored. Needs the `pos` module.';

comment on function public.set_item_weighed(uuid, boolean, text) is
  'Marks an item as sold by weight, with the PLU the scale prints. '
  'Refuses it unless the item''s unit actually measures something -- a '
  'kilogram, a litre -- because a third of a box is not a quantity and '
  'neither is a third of a piece. Needs the `inventory` module.';

comment on function public.set_feedback_status(uuid, app.feedback_status, text) is
  'Moves a piece of feedback somebody sent us along, with a note. '
  'Platform administrators only: this is our own queue, not a '
  'tenant''s.';
