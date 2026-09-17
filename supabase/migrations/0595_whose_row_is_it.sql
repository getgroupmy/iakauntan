-- =====================================================================
-- iAkauntan :: 0595 whose row is it
--
-- The tenth slice of the undocumented writes: the six that are not
-- scoped by a company at all.
--
-- Everything else in this API takes an `org_id` and asks `app.can_*`.
-- These six ask `auth.uid()`. A caller reading the published
-- description has no way to tell the two kinds apart from a name and an
-- argument list, and the difference decides who is affected by the
-- call -- which is the one thing worth knowing before making it.
--
-- ---------------------------------------------------------------------
-- And two of them are not personal after all
--
-- That is the finding of this slice, and it is the opposite of what the
-- names suggest. `notifications` is ONE TABLE with `read_at` and
-- `dismissed_at` on the row. There is no per-person read state
-- anywhere. So a notification addressed to somebody (`user_id` set) is
-- theirs, and a notification addressed to NOBODY is the company's --
-- one row, shared.
--
-- Which means the boss marking the e-Invoice rejection read has marked
-- it read for the clerk too, and dismissing it takes it off everybody's
-- list. That is a reasonable design for a company-wide notice and a
-- surprising one to meet by accident.
--
-- `notifications.sql` asserts it now as well: if somebody later adds a
-- per-person read table, the assertion fails and these descriptions
-- have to be rewritten with it.
--
-- ---------------------------------------------------------------------
-- Returning false rather than raising, for a better reason this time
--
-- `mark_notification_read` and `dismiss_notification` answer false for
-- a notification that is not yours AND for one that does not exist,
-- without distinguishing them. In `0593` the same pattern was a wart.
-- Here it is the right answer: telling a caller "that exists but is not
-- yours" would confirm the existence of somebody else's notification,
-- and a bell is not worth an information leak.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The bell
-- ---------------------------------------------------------------------

comment on function public.mark_notification_read(uuid) is
  'Marks one notification read, and returns whether anything changed. '
  'Reaches a notification addressed to you, and one addressed to '
  'nobody in particular -- WHICH IS SHARED: a company-wide notice is a '
  'single row with a single `read_at`, so reading it reads it for '
  'every member. Somebody else''s is not yours to touch, and the '
  'answer for one of those is the same false as for a notification '
  'that does not exist, deliberately: distinguishing them would '
  'confirm that another person''s notification is there. Already-read '
  'keeps its original timestamp rather than moving.';

comment on function public.mark_all_notifications_read(uuid) is
  'Marks everything currently unread in one company read and returns '
  'how many. Leaves dismissed ones alone -- they are gone already -- '
  'and leaves notifications addressed to OTHER people alone, so this '
  'is not a way to clear a colleague''s list. Company-wide notices are '
  'included, and those are shared, so this clears them for everybody. '
  'Unlike the single-row calls it raises `42501` rather than returning '
  'a count when the caller is not a member: the company is named in '
  'the argument, so there is nothing to protect by staying silent.';

comment on function public.dismiss_notification(uuid) is
  'Takes a notification off the list for good, and marks it read on '
  'the way past if it was not -- dismissed but unread is a state '
  'nothing needs. Same reach and same silence as '
  '`mark_notification_read`: yours or the company''s, false for '
  'anything else whether it exists or not. A company-wide notice is '
  'one row, so dismissing it removes it from EVERY member''s list, not '
  'just the caller''s.';

-- ---------------------------------------------------------------------
-- The handset
-- ---------------------------------------------------------------------

comment on function public.register_device(text, text, text, text, text) is
  'Records a device to send push notifications to, and returns its '
  'row. Keyed ON THE TOKEN, not on the pair of user and token: one '
  'handset is one row, belonging to whoever is signed in on it now, so '
  'a colleague signing in on a shared tablet takes the row over rather '
  'than adding a second and getting the first person''s notifications '
  '(0141). A browser subscription must bring its `p256dh` and `auth` '
  'keys or there is nothing to encrypt the notification to, and a '
  'phone must not bring them; on a re-subscribe the keys are REPLACED '
  'rather than merged, because a browser that re-subscribes has thrown '
  'the old keypair away. Platform is android, ios or web.';

comment on function public.unregister_device(text) is
  'Stops sending to one device. Deletes by token AND by the signed-in '
  'user, so it only ever removes your own -- and, following from '
  '`register_device` keying on the token alone, it does nothing at all '
  'if somebody else has since signed in on that handset and taken the '
  'row over. That is the intended outcome: the row now belongs to '
  'them, and the notifications going to it are theirs.';

-- ---------------------------------------------------------------------
-- And the one that leaves the company altogether
-- ---------------------------------------------------------------------

comment on function public.report_feedback(
  text, app.feedback_kind, text, text, text, smallint, uuid) is
  'Files a bug report or a suggestion, and is the ONE WRITE IN THIS '
  'API THAT DOES NOT STAY WITH THE TENANT: `feedback_reports` is the '
  'platform''s table, read by whoever runs the service rather than by '
  'the company. `p_org_id` is optional and is only a label saying '
  'which company the person was in at the time -- it is checked for '
  'membership when given, so it cannot be used to file against '
  'somebody else. `p_severity` is kept only for a bug; a severity on a '
  'suggestion is dropped rather than refused. Needs a signed-in user '
  'and a one-line title, and nothing else.';
