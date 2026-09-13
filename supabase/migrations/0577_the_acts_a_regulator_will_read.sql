-- =====================================================================
-- iAkauntan :: 0577 the acts a regulator will read
--
-- Ninth slice, and the first chosen by what the functions DO rather
-- than by the verb they start with: the eight named families are
-- closed, and what is left is a hundred and thirty-four one-offs.
--
-- These seventeen are the ones whose output a regulator reads. An SST
-- return to the Customs Department, a remittance to KWSP or PERKESO,
-- a withholding payment to the Inland Revenue Board, a set of
-- financial statements lodged at SSM through MBRS, a change of
-- registered office, a constitution adopted, a resolution signed by
-- directors.
--
-- `CLAUDE.md` says statutory arithmetic is asserted rather than
-- eyeballed. The arithmetic is asserted. What was never written down
-- is the part that is not arithmetic at all: WHICH OF THESE OPENS A
-- FILING AND WHICH DOES NOT.
--
-- ---------------------------------------------------------------------
-- The distinction worth the whole migration
--
-- `change_registered_office` moves the office, dates the move, and
-- OPENS A FILING -- because s.46 of the Companies Act 2016 requires
-- SSM to be told within fourteen days.
--
-- `correct_registered_office` and `correct_company_name` do not. They
-- set a transaction-local marker that tells the trigger no filing is
-- due, because nothing happened at the registrar: somebody mistyped
-- what we had recorded.
--
-- A caller who reaches for `correct_` when a company has actually
-- moved has silently missed a statutory deadline, and nothing in the
-- system will ever tell them. That is the single most expensive
-- confusion available in this schema, and until now the only way to
-- know was to read both bodies and notice the `set_config` line.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tax: what is declared and what is paid over
-- ---------------------------------------------------------------------

comment on function public.file_sst_return(uuid, date, numeric, text) is
  'Records that the SST-02 for a taxable period has gone in, for how '
  'much, and under what reference. THIS DOES NOT SUBMIT ANYTHING -- the '
  'return is filed on MyTax and what is kept here is that it was. '
  'Refuses a period that has not ended: the return declares what was '
  'charged in the period, and that is not known until it closes. '
  'Refuses a date that is not actually a period end for this company, '
  'so a typed date cannot create a period that does not exist. Needs '
  '`can_post`.';

comment on function public.record_statutory_remittance(uuid, uuid, text, numeric, date, text) is
  'Records a payment over to KWSP, PERKESO or the Inland Revenue Board '
  'against a pay period. ONLY AGAINST A POSTED PAYROLL: recording a '
  'payment to KWSP for a run still in draft would be recording a '
  'payment of a figure that can still change. The code must be one the '
  'system knows somebody is owed under. Needs `can_run_payroll`, which '
  'is its own permission -- what people are paid is not something '
  'everybody who may edit a customer should see.';

comment on function public.remit_withholding(uuid, date, uuid, text) is
  'Records that a withholding certificate has been paid over to the '
  'Inland Revenue Board, and posts the payment. The certificate must be '
  'POSTED FIRST -- there is nothing to remit until the liability is in '
  'the books -- and one already remitted is refused, naming the date. A '
  'bank account belonging to another company is REFUSED BY NAME rather '
  'than quietly ignored: falling back to the default cash account would '
  'post the entry anyway and leave nobody any the wiser. Needs '
  '`can_post`.';

-- ---------------------------------------------------------------------
-- Financial statements, and the two states that matter
--
-- Frozen means "this is the set that was reviewed". Lodged means SSM
-- has it. The functions treat those two as different kinds of
-- finality, and the asymmetry between freezing and unfreezing is the
-- interesting part.
-- ---------------------------------------------------------------------

comment on function public.fs_freeze(uuid) is
  'Fixes a set of financial statements as the reviewed version, and '
  'returns how many figures were captured. REFUSES ACCOUNTS THAT DO NOT '
  'BALANCE: a rejected MBRS submission is a wasted fee and a missed '
  'deadline, and the difference is almost always a journal posted after '
  'the year was reviewed. Audited accounts need an auditor and an '
  'opinion; exempt and unaudited ones do not, and asking for them would '
  'be asking somebody to invent an audit that did not happen. Refuses a '
  'filing already lodged. Needs the `mbrs` module.';

comment on function public.fs_unfreeze(uuid) is
  'Reopens frozen accounts for further work. DELIBERATELY STRICTER THAN '
  'FREEZING -- `can_admin` rather than `can_write` -- because '
  'unfreezing is how a mistake gets fixed and also how a reviewed set '
  'of accounts quietly becomes a different set of accounts. A lodged '
  'filing cannot be reopened at all: SSM has it, and what is here must '
  'go on matching what was sent.';

comment on function public.fs_lodge(uuid, text, date) is
  'Records that the accounts have been lodged at SSM through MBRS, with '
  'the reference mPortal gave back. THE ACCOUNTS MUST BE FROZEN FIRST, '
  'so what is recorded as lodged is the set that was reviewed rather '
  'than whatever the ledger says today. The reference is required -- a '
  'lodgement nobody can quote is a lodgement nobody can prove -- and '
  'the accounts must have been circulated, which under s.258 is the '
  'step that starts the thirty days to lodge. Needs the `mbrs` module.';

comment on function public.fs_set_entity(uuid, uuid) is
  'Says which corporate entity a set of accounts belongs to, which is '
  'what carries the company number and particulars onto the MBRS '
  'submission. The entity must be one of this company''s. Refused once '
  'the filing is lodged. Needs the `mbrs` module.';

-- ---------------------------------------------------------------------
-- The registrar: what was told to SSM, and what was only ever a typo
-- ---------------------------------------------------------------------

comment on function public.corp_open_filing(uuid, text, date) is
  'Opens a statutory filing against an entity and returns it -- the '
  'record that something is due at SSM, with the dates the Act sets. '
  'REFUSES A FILING TYPE THAT DOES NOT APPLY TO THAT KIND OF ENTITY: an '
  'AGM filing against a Sdn Bhd is not a typo to be tidied up later, it '
  'is a company being told to do something the Act does not require of '
  'it.';

comment on function public.change_registered_office(uuid, text, date) is
  'Moves a company''s registered office, dates the move, AND OPENS THE '
  'FILING -- s.46 of the Companies Act 2016 requires SSM to be told '
  'within fourteen days, so the change and the notification are one '
  'act, not two. Refuses an address that is already the registered '
  'office. USE THIS WHEN THE COMPANY HAS ACTUALLY MOVED. To fix a '
  'mistyped address, use `correct_registered_office`, which opens no '
  'filing.';

comment on function public.correct_registered_office(uuid, text) is
  'Corrects a registered office address that was recorded wrongly. '
  'OPENS NO FILING, deliberately: nothing happened at the registrar, '
  'somebody mistyped what we had. It sets a transaction-local marker '
  'that tells the trigger no notification is due, cleared immediately '
  'so a second bare update cannot ride through on it. USE '
  '`change_registered_office` IF THE COMPANY HAS MOVED -- reaching for '
  'this one instead silently misses a fourteen-day statutory deadline, '
  'and nothing in the system will say so.';

comment on function public.correct_company_name(uuid, text) is
  'Corrects a company name that was recorded wrongly. OPENS NO FILING, '
  'for the same reason `correct_registered_office` does not: this is '
  'fixing our record, not reporting a change. An actual change of name '
  'is a resolution and a filing, not this. The marker is set for '
  'exactly one statement and cleared, because `is_local` alone would '
  'leave it standing for the rest of the transaction.';

comment on function public.adopt_constitution(uuid, date) is
  'Records that a company has adopted a constitution, on the date it '
  'did. Refuses one that already has an adopted constitution -- '
  'adopting twice is a different act, an alteration, with its own '
  'resolution -- and refuses a date before the company was '
  'incorporated.';

-- ---------------------------------------------------------------------
-- Resolutions, and the hash that makes a signature mean something
--
-- The point of this chain is that what was signed is provably what was
-- circulated. `0565`'s link functions are the unauthenticated half;
-- these are the same acts performed by somebody signed in.
-- ---------------------------------------------------------------------

comment on function public.corp_generate_document(uuid, text, jsonb, text) is
  'Generates a corporate document -- a resolution, a notice, a minute '
  '-- from a template, filled with this entity''s particulars. THE '
  'FIRM''S OWN VERSION OF A TEMPLATE WINS over the platform''s, so a '
  'practice''s house wording is what its clients get. Refuses a '
  'template that does not apply to that kind of entity.';

comment on function public.corp_update_document(uuid, text, text) is
  'Edits a corporate document''s title and body before it is '
  'circulated. Editing after signatures are requested is what the body '
  'hash exists to catch: `corp_sign_document` and '
  '`corp_open_signing_link` both re-hash and refuse text that no longer '
  'matches what was sent.';

comment on function public.corp_request_signatures(uuid, uuid[], text[], date, text) is
  'Circulates a document to the people who must sign it, recording the '
  'HASH OF THE BODY AS IT WENT OUT. That hash is what every later '
  'signature is checked against, so nobody can sign text they were not '
  'sent. Refuses a request with nobody to sign.';

comment on function public.corp_create_signing_link(uuid, integer, text) is
  'Issues a link letting a director sign without an account here, and '
  'returns the token ONCE -- only a digest is stored, so a link that is '
  'lost cannot be recovered, only reissued. ONE LIVE LINK PER '
  'SIGNATURE: issuing a new one retires the old, so a forwarded email '
  'cannot be used after a replacement was sent. Refuses a line that is '
  'not pending.';

comment on function public.corp_sign_document(uuid, text) is
  'Signs a line as somebody signed in -- the authenticated counterpart '
  'of `corp_sign_with_link`. Refuses a line that is not pending, a '
  'withdrawn request, an empty name, and a document whose body no '
  'longer hashes to what was circulated. That last refusal is the whole '
  'point of the chain: a signature means the signatory saw THAT text.';
