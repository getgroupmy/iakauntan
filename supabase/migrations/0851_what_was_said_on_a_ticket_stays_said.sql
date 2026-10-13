-- =====================================================================
-- iAkauntan :: 0851 what was said on a ticket stays said
--
-- A ticket's comments are made by two functions: `add_ticket_comment`
-- (`0194`), an agent's, which always signs the comment as whoever is
-- signed in, and `reply_to_shared_ticket` (`0390`), the customer's,
-- through a share link. The table also carried `ticket_comments_write`,
-- a policy for all commands asking only `can_write_module('ticketing')`,
-- so anybody who could work tickets could write any comment directly.
--
-- Measured on 13 October 2026, locally, as the owner with the role
-- `authenticated`: a comment inserted in the CUSTOMER's name -- "I agree
-- to the RM800 call-out fee" -- was accepted; the customer's own reply,
-- "I do NOT agree to any call-out fee", was rewritten and then deleted;
-- a colleague's reply was rewritten under the colleague's name; and an
-- internal note, "Customer is difficult; quote high", was made public,
-- which shows it to the customer through the share link and the portal.
-- The app never writes the table; it calls the two functions.
--
-- Answered "read-only to clients": insert, update and delete are
-- revoked from `authenticated` and `anon`, and the write policy is
-- dropped. A comment is said through a function and stays as it was
-- said. A ticket deleted still takes its comments with it -- the
-- foreign key's cascade runs as the table's owner.
--
-- Production held eleven ticket comments on 13 October.
-- =====================================================================

revoke insert, update, delete on public.ticket_comments from authenticated, anon;
drop policy if exists ticket_comments_write on public.ticket_comments;
