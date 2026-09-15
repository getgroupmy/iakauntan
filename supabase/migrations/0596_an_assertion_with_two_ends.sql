-- =====================================================================
-- iAkauntan :: 0596 an assertion with two ends
--
-- The eleventh slice of the undocumented writes: the four that say one
-- company is related to another. A practice keeps this company's books.
-- These companies are a group. This contact IS that company.
--
-- Every one of them checks BOTH ENDS, and the second check is the
-- interesting half in all four, because a caller reading the signature
-- would expect only the first:
--
--   * `attach_company_to_firm` asks `can_admin` on the company AND
--     `is_firm_member` on the firm. Without the second, an
--     administrator could hand their books to a practice that has never
--     heard of them;
--   * `join_company_group` asks `can_admin` on the company AND, when
--     the group already has companies in it, membership of one of them.
--     Joining a group means being able to see what is in it;
--   * `link_group_contact` asks `can_write` on the company that owns
--     the contact AND that the company being pointed at is one the
--     caller can already reach -- WITHOUT WHICH IT IS A WAY TO FIND OUT
--     WHICH COMPANIES EXIST, one uuid at a time, by reading which
--     refusal comes back.
--
-- `invite_firm_member` is the exception that proves it: there is only
-- one end, the firm, and the other end is an e-mail address that may
-- not answer to an account yet.
--
-- ---------------------------------------------------------------------
-- What happens afterwards is the part with the consequences
--
-- Three of these call `app.sync_firm_access`, and that is where the
-- access actually moves. Appointing a firm does not grant one person
-- access to one company; it grants every member of that practice access
-- to every company on its list, and the number returned by
-- `attach_company_to_firm` is how many rows that came to.
--
-- Which is deliberate and is the point of a portfolio. A new joiner
-- with forty clients to be invited to one at a time is how people end
-- up sharing a login.
--
-- ---------------------------------------------------------------------
-- And one refusal that is about what the words mean
--
-- `attach_company_to_firm` will not take `owner`. A firm keeps the
-- books; it does not own the company. Somebody who means to transfer
-- ownership should have to say so somewhere that says so.
-- =====================================================================

comment on function public.attach_company_to_firm(uuid, uuid, app.member_role) is
  'Appoints a practice to keep this company''s books, and returns how '
  'many access rows that came to. CHECKS BOTH ENDS: the caller must be '
  'an owner or administrator of the COMPANY and a member of the FIRM, '
  'because without the second an administrator could hand their books '
  'to a practice that has never heard of them. Refuses the `owner` '
  'role outright -- a firm keeps the books, it does not own the '
  'company, and transferring ownership should be done somewhere that '
  'says so. What follows is `app.sync_firm_access`, which gives every '
  'member of the practice access to every company on its list; the '
  'return value is the size of that, not of this appointment.';

comment on function public.invite_firm_member(uuid, text, app.firm_role) is
  'Adds somebody to a practice, by address. An address that already '
  'answers to an account is a member FROM THIS MOMENT -- no invitation '
  'to accept, because they are already a person this system knows -- '
  'and one that does not is invited, with fourteen days to sign up. '
  'Inviting somebody who is already a member changes their role rather '
  'than failing. A new member is given the whole portfolio at once '
  'through `app.sync_firm_access`: forty clients to be invited to one '
  'at a time is how people end up sharing a login. Only a partner or a '
  'manager may do it.';

comment on function public.join_company_group(uuid, uuid) is
  'Moves a company into a group, or out of one when `p_group_id` is '
  'null. Needs `can_admin` on the company, and ALSO membership of the '
  'group when the group already has companies in it -- because being '
  'in a group means being able to see the others, and a group with '
  'nothing in it yet is the one the caller has just made. Consolidated '
  'reporting and the group''s shared contacts follow from this one '
  'column, so it is a wider change than moving a row.';

comment on function public.link_group_contact(uuid, uuid) is
  'Says that a contact on this company''s books IS another company in '
  'the same group -- what makes an intercompany balance something that '
  'can be eliminated on consolidation rather than a coincidence of '
  'names. Needs `can_write` where the contact lives, AND that the '
  'company being pointed at is in the same group and is one THE CALLER '
  'CAN ALREADY REACH. That second test is not belt and braces: without '
  'it the refusals differ between a company that exists and one that '
  'does not, and this becomes a way to discover which companies exist, '
  'one uuid at a time. Refuses a company as its own customer. '
  'UNLINKING IS ALWAYS ALLOWED -- passing null removes an assertion '
  'rather than making one, and nothing is learned by being allowed to.';
