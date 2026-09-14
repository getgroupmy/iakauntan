-- =====================================================================
-- iAkauntan :: 0583 what leaves the building
--
-- Thirteenth slice of the undocumented writes: the ten by which a
-- company's data reaches somebody outside it, and the record kept when
-- it does. A link to an invoice, an email with the invoice attached, a
-- ticket shown to a requester with no login, an export of the whole
-- company, and the three logs that say who did which.
--
-- These are the functions a regulator, an auditor or a customer asks
-- about after something has gone wrong, and "what does it record" is
-- not an implementation detail of any of them -- it is the answer.
--
-- ---------------------------------------------------------------------
-- The distinction worth the whole migration
--
-- `audit_trail` and `security_log` LOOK like reads. They are declared
-- VOLATILE and they appear in this list because they write, and what
-- they write is that you read them.
--
-- `security_log` says so in its own body: "a security log that does not
-- record who read it is the one record an insider has no reason to
-- avoid." Somebody who can see where every colleague signs in from is
-- exercising a real power, and the only thing that makes it accountable
-- is that using it leaves a mark.
--
-- So a caller must not treat either as a cheap read. Polling
-- `security_log` on a timer writes a `sensitive_read` event every
-- interval, for ever, and buries the events somebody is actually
-- looking for underneath it. That is not a hypothetical: it is the
-- obvious way to build a dashboard.
--
-- ---------------------------------------------------------------------
-- The second thing: a token is returned once and never again
--
-- `share_document` and `share_ticket` store `app.corp_token_hash(token)`
-- and hand back the token itself. There is no way to read it out
-- afterwards, by design -- the database cannot tell anybody what the
-- link was, which is what stops a stolen backup from being a stolen
-- inbox. A caller that discards the return value has created a link
-- nobody will ever hold.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Links: one live one at a time, and only ever seen once
-- ---------------------------------------------------------------------

comment on function public.share_document(uuid, integer, text) is
  'Creates a link that shows one sales document to somebody with no '
  'login, and RETURNS THE TOKEN — the only time it can be read. Only '
  'the hash is stored, so nothing can recover it afterwards and a '
  'caller that discards the return value has made a link nobody holds. '
  'REVOKES ANY LIVE LINK FOR THE SAME DOCUMENT first: reissuing means '
  'the newest link is the one that should work, and leaving the old one '
  'alive would make "revoke" mean nothing. Refuses a draft, void or '
  'rejected document — a link is for something that has actually been '
  'issued. `p_valid_days` is clamped to between 1 and 365, so there is '
  'no such thing as a link that never expires. Needs `can_write`.';

comment on function public.share_ticket(uuid, integer, text) is
  'The same for a support ticket, and returns the token once for the '
  'same reason. REFUSES A TICKET RAISED BY STAFF: they can already read '
  'it with their own login, and a link is for a requester who has none '
  '— handing one to a colleague creates a credential that outlives '
  'their employment. Refuses a cancelled ticket. Revokes any live link '
  'for the ticket, and clamps the life to 1–365 days. Needs '
  '`can_write_module(''ticketing'')`.';

-- ---------------------------------------------------------------------
-- Email: what is attached, and what is quietly also created
-- ---------------------------------------------------------------------

comment on function public.email_document(uuid, text, text, integer, text, text, text) is
  'Queues an email about a sales document and returns the outbox row. '
  'ALSO ISSUES A SHARE LINK as a side effect, with the life given by '
  '`p_share_days`, and puts it in the template — so sending an email is '
  'also creating a credential, and sending twice replaces the first '
  'link. A draft, void or rejected document is emailed WITHOUT a link '
  'rather than refused, because the covering note may still be worth '
  'sending. The address defaults to the customer''s primary contact '
  'person and then the contact itself, and is checked for shape before '
  'anything is queued. An attachment must live under '
  '`<org>/<documents>/<id>/` in storage: a path pointing anywhere else '
  'is refused, which is what stops an email being used to post any '
  'object in the bucket to an outside address. Refuses when email is '
  'switched off for the company. `p_dispatch` is `queued` or '
  '`immediate`. Needs `can_write`.';

comment on function public.email_receipt(uuid, text, text, text, text, text) is
  'Queues an email about a receipt and returns the outbox row. Unlike '
  '`email_document` it issues NO share link — a receipt is the '
  'acknowledgement, and there is nothing further to show. Same path '
  'rule on the attachment (`<org>/receipts/<id>/`, anything else '
  'refused), same address fallback, same shape check, same refusal when '
  'email is off for the company. Needs `can_write`.';

-- ---------------------------------------------------------------------
-- Taking a copy
-- ---------------------------------------------------------------------

comment on function public.company_export_page(uuid, text, text, integer) is
  'Returns one page of one table of the whole company, for somebody '
  'taking their data out. THE TABLE NAME REACHES DYNAMIC SQL, so it is '
  'matched against `app.company_export_tables()` rather than quoted and '
  'hoped for — a name not on that list is not a table as far as this is '
  'concerned, including the ones deliberately held back. Every row goes '
  'through `app.audit_redact`, so the export is not a way to read what '
  'the app will not show. RECORDS THE EXPORT as a security event on '
  'every page, so a large export appears as many events and not one. '
  'Pages on `id` with the `next` cursor; `next` is null when the page '
  'came back short. Owner or administrator only.';

comment on function public.record_export(uuid, text, text) is
  'Writes that somebody took a copy of something. Called by the app '
  'for the exports it does client-side, where the database never sees '
  'the rows leave and would otherwise have no record at all. Any member '
  'may write one — the point is the record, and a member who could not '
  'file it could export silently. Refuses a company the caller is not '
  'in, so nobody can write into somebody else''s log.';

comment on function public.log_document_download(uuid, text) is
  'Writes that somebody downloaded a document, and returns the row. The '
  'PDF is rendered in the browser, so without this the database would '
  'never know a document had left at all. Any member of the company may '
  'record one, for the same reason as `record_export`. Refuses a '
  'document that is deleted or belongs elsewhere.';

-- ---------------------------------------------------------------------
-- The three logs, two of which write when you read them
-- ---------------------------------------------------------------------

comment on function public.audit_trail(uuid, text, uuid, integer) is
  'Returns what changed, most recent first, with the before and after '
  'of each row. A READ THAT WRITES: it records a `sensitive_read` '
  'against the caller, which is why it is volatile and why it is in the '
  'undocumented-writes list at all. Do not poll it — a dashboard on a '
  'timer writes an event every interval and buries the ones somebody is '
  'looking for. Capped at 500 rows however large `p_limit` is. Owner or '
  'administrator only.';

comment on function public.security_log(uuid, app.security_event, timestamptz, integer) is
  'Returns who signed in, from what address, who exported, who read '
  'something sensitive and who was refused. A READ THAT WRITES, and '
  'this is the one where that matters most: the body says a security '
  'log that does not record who read it is the one record an insider '
  'has no reason to avoid. Do not poll it. Capped at 1,000 rows. Owner '
  'or administrator only — it says where every colleague works from, '
  'which is the same bar as the audit trail and for a sharper reason.';

comment on function public.report_denied(uuid, text, text) is
  'Lets the app write down a refusal the database never saw — one the '
  'client enforced itself, which would otherwise leave no trace of '
  'somebody probing at doors. RETURNS QUIETLY rather than raising when '
  'the caller is not in the company: taking the caller''s word for the '
  'organization would let anybody write into anybody''s log, and a '
  'refusal aimed at a company you are not in is not that company''s '
  'event. RATE LIMITED to one a minute per person, so a loop cannot '
  'bury the rest of the log — which means a burst of refusals appears '
  'as one entry, and the count is not the number of attempts.';
