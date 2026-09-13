-- =====================================================================
-- iAkauntan :: 0569 the open doors nobody wrote down
--
-- `docs/api/` now describes what this database serves over HTTP, and
-- the first thing it made countable was its own silence: of the 662
-- functions a tenant's token can reach, 436 carry no
-- `comment on function`, so the description prints the name and the
-- argument list and nothing else.
--
-- Split by who can reach them, the number stops being uniform:
--
--     reachable without signing in   12 of 19 undocumented
--     writes, signed in             278 of 398
--     reads, signed in              148 of 245
--
-- Two-thirds of the open doors. These are the functions `anon` may
-- call -- no token, no membership, no company -- and they are the ones
-- `supabase/tests/statutory.sql` already guards by name, with a
-- paragraph beside each saying what breaks if it silently stops
-- working. What that list does not say, and what nothing said, is what
-- each one *is for* and what it will hand over.
--
-- ---------------------------------------------------------------------
-- Why the comment belongs here and not in a document
--
-- `comment on function` lives in the catalog, beside the rule, and
-- travels with it. A paragraph in a markdown file three directories
-- away does not: `docs/gaps-against-akaunting.md` claimed three
-- features were missing for months after they were built, and said so
-- about the same feature twice.
--
-- And the generator reads the catalog. Prose written here appears in
-- `docs/api/openapi.json` as the endpoint's description and in
-- `llms.txt` as its summary, on the next run, without anybody
-- remembering to copy it.
--
-- ---------------------------------------------------------------------
-- What each comment has to say
--
-- Not what the function is called. The reader of a published
-- description can already see that. What matters for an unauthenticated
-- door is narrower and is the same three things every time:
--
--   * what it hands to a stranger holding a token;
--   * what it deliberately does NOT hand over, because that is the
--     decision somebody made and the one a future edit can undo
--     without noticing;
--   * what it writes, if it writes -- four of these do, and a write
--     reachable without signing in is worth stating out loud.
--
-- No grants change here. No behaviour changes here. This migration is
-- entirely `comment on function`, and the assertion added beside it in
-- `statutory.sql` is what stops the next open door being added without
-- one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The reads
-- ---------------------------------------------------------------------

comment on function public.landing_page() is
  'The marketing site''s own contents, for the signed-out landing page. '
  'Wraps `app.landing_payload(false)`, and the `false` is the whole '
  'security decision: it asks for the published payload, so unpublished '
  'copy being drafted is not served to a stranger who calls this '
  'directly rather than loading the page.';

comment on function public.site_pages() is
  'The published pages of the marketing site, plus `signin`, `signup` '
  'and `login` whether or not they are published. Those three are '
  'exempt because they are not marketing: they carry the terms '
  'somebody is asked to agree to while registering, and a terms page '
  'that 404s is a registration nobody can honestly complete. '
  'Everything else must be published to appear.';

comment on function public.workspace_by_host(text) is
  'Resolves a company''s own subdomain to the door that should be drawn '
  'at it: the name, the logo, the module, and the login wording if the '
  'company wrote any. Only the first label is read, so '
  '`sinar.iakauntan.com` and `sinar.staging.iakauntan.com` are one '
  'company. Returns nothing unless the reservation is approved AND the '
  'company is active or on trial, undeleted, and still has the '
  '`workspace_address` module -- an address outliving the company that '
  'named it would be a page wearing a stranger''s mark. Parked names '
  'resolve to nothing, which is the point of parked.';

comment on function public.public_pos_menu_modifiers(text, uuid) is
  'The option groups for one item on a QR menu, for a customer holding '
  'a phone at a table. The token names the outlet and the item is '
  'checked against that outlet''s own company, so a valid token cannot '
  'be pointed at another shop''s item id to read its menu. Prices are '
  'the deltas the customer will be charged; nothing about cost or '
  'margin is here.';

comment on function public.shared_payment_options(text) is
  'Which acquirers a customer can pay a shared invoice through: the '
  'gateway code and its name, and nothing else. Returns nothing at all '
  'unless the link is live and unrevoked and unexpired, the document '
  'is neither void, rejected nor deleted, and there is a balance left '
  'to pay -- so an unpayable document offers no buttons. A gateway '
  'with no settlement account is omitted, because money must have '
  'somewhere to land. No key, secret or merchant identifier is '
  'returned.';

-- ---------------------------------------------------------------------
-- The writes
--
-- Each of these is reachable by a stranger and each changes something.
-- What they change is deliberately small and is named.
-- ---------------------------------------------------------------------

comment on function public.open_shared_document(text) is
  'Opens an invoice or quotation shared by link, for a customer who is '
  'not a user of this system. Returns the company, the contact, the '
  'document and its lines, plus which acquirers can take payment if '
  'there is a balance. `internal_notes` is deliberately absent: `notes` '
  'is what the sender wrote for the customer to read and the other is '
  'not. An invalid, revoked, expired or withdrawn link returns only '
  'that state and no document. WRITES: records every open against the '
  'link -- the count, the time, the first caller''s IP and user agent '
  '-- even when the answer is a refusal, because that somebody tried '
  'is worth as much as that somebody read it.';

comment on function public.open_shared_ticket(text) is
  'Opens a support ticket shared by link, for the customer who raised '
  'it. Returns the ticket, the company and the conversation as far as '
  'the customer is entitled to see it. An invalid, revoked or expired '
  'link returns only that state. WRITES: records the open against the '
  'link, the same way `open_shared_document` does and for the same '
  'reason.';

comment on function public.reply_to_shared_ticket(text, text) is
  'Lets the customer answer their own ticket through the share link, '
  'without an account. WRITES: a comment, always visible -- '
  '`is_internal` defaults to TRUE and a customer''s own message landing '
  'as an internal note would be invisible to the person who sent it -- '
  'plus a `requester_reply` event, and the ticket reopens if it was '
  'pending, on hold, resolved or closed. `first_response_at` is '
  'deliberately left alone: the first-response target is a promise the '
  'company made about how quickly IT would answer, and stopping that '
  'clock on the customer''s own message would report a target met that '
  'nobody met. An empty body is refused.';

comment on function public.report_failed_sign_in(text) is
  'Lets the browser tell the audit log that a password was rejected, '
  'which Supabase''s own sign-in does not tell this database. Returns '
  'void in every branch INCLUDING the branch where the address is '
  'unknown: a function that behaved differently for an address that '
  'exists would be a way to find out which addresses exist. WRITES: at '
  'most one `sign_in`/`refused` security event per account per minute, '
  'so a stranger cannot push the events that matter off the end of an '
  'auditor''s screen.';

-- ---------------------------------------------------------------------
-- Signing a resolution from a link
--
-- A director reads a document and signs it without ever having an
-- account here. Nobody is signed in, so the link IS the attribution and
-- is recorded as such.
-- ---------------------------------------------------------------------

comment on function public.corp_open_signing_link(text) is
  'Opens a resolution or document sent to a director to sign. The body '
  'is handed over ONLY when the state is `open` -- an expired, revoked, '
  'used, withdrawn or already-signed link returns the state, the '
  'company and the title and no text. `changed` means the document has '
  'been edited since it was circulated: the body is re-hashed on every '
  'open and compared with the hash recorded when the request went out, '
  'so nobody signs text they were not sent. WRITES: records the first '
  'open against the link with its IP and user agent, which is the only '
  'evidence the link reached anybody.';

comment on function public.corp_sign_with_link(text, text) is
  'Signs the line the link names. Refuses an empty name, an invalid, '
  'revoked, used or expired link, a line that is not pending, a '
  'withdrawn request, and -- the one that matters -- a document whose '
  'body no longer hashes to what was circulated, telling the signatory '
  'to ask for a new link rather than signing text nobody sent them. '
  'WRITES: marks the signature signed with the name typed, the hash '
  'signed against, the IP and the user agent, and spends the link. '
  '`signed_by` is deliberately null: nobody was signed in, and the '
  'link recorded beside it is the attribution.';

comment on function public.corp_decline_with_link(text, text) is
  'The other half of `corp_sign_with_link`: lets a director say no. It '
  'exists because `app.signature_status` has had `declined` since '
  '`0069` and nothing could produce it, so a director reading a '
  'resolution could sign it or close the tab -- and a line that stays '
  'pending for ever reads at the other end as an email nobody opened. '
  'WRITES: marks the signature declined with the reason, the IP and '
  'the user agent, and spends the link either way, because a link that '
  'survives a refusal is one somebody can come back and sign with '
  'after saying no.';
