-- =====================================================================
-- iAkauntan :: 0581 who may say yes
--
-- Eleventh slice of the undocumented writes: the thirteen where one
-- person asks and another decides. Leave, expense claims, a document
-- approval chain, access to payslips, a web address, an email address,
-- and a budget.
--
-- An approval gate is the one kind of write whose whole value is the
-- refusal. A gate that can be talked round is decoration, and a gate
-- that refuses the wrong person is a queue that never moves. So the
-- only question worth publishing about each of these is WHO MAY SAY
-- YES -- and the answers are not the same, which is the part nobody
-- wrote down.
--
-- ---------------------------------------------------------------------
-- The distinction worth the whole migration
--
-- Three of these refuse self-approval and two do not, and it is not an
-- oversight in either direction.
--
-- `decide_approval` refuses it in as many words: "You raised this, so
-- you cannot approve it." The commonest way an approval chain becomes
-- decoration is the person who raised the document also holding the
-- role that clears it. `decide_payslip_access` refuses it for the same
-- reason, more sharply -- an auditor who could approve their own
-- request for payslips has not been granted access, they have taken it.
--
-- `decide_leave_request` does NOT refuse it. An HR manager can approve
-- their own leave, and that is deliberate: the alternative is a company
-- whose only HR manager cannot take a holiday. The balance arithmetic
-- is the control instead -- the days come off whether or not anybody
-- else looked.
--
-- `decide_claim_step` does not refuse it either, and the reason is
-- written into `app.may_decide_claim_step`: an owner or administrator
-- may act at any stage, because a manager who has left the company
-- would otherwise strand every claim behind them. The row records who
-- actually decided it, which is the control that replaces the refusal.
--
-- A reader who assumes all four behave alike will be wrong about two of
-- them, and wrong in the direction that matters -- believing a control
-- exists where it does not.
--
-- ---------------------------------------------------------------------
-- The second thing: one of these is an alias
--
-- `decide_expense_claim` does nothing but call `decide_claim_step`. Two
-- published names, one behaviour, and the published description said so
-- nowhere. Both are named below and both say which is which.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Leave: the hold, and what releases it
-- ---------------------------------------------------------------------

comment on function public.submit_leave_request(uuid, uuid, date, date, numeric, text, boolean, text, uuid, text) is
  'Files a leave request and HOLDS THE DAYS against the balance while '
  'it waits — which is what stops two requests each passing a check the '
  'pair of them would fail. Only HR may file for somebody else, and '
  'only for an employee of this company: the composite key held the '
  'leave type to the organization but not the employee, so without that '
  'check HR in one company could file against another company''s staff. '
  'Paid leave is refused when it exceeds what is left; unpaid leave has '
  'no balance to check. NO BALANCE ROW AT ALL IS NOT A REFUSAL — it '
  'means nobody has set an entitlement for this type and year yet, and '
  'refusing until somebody does would stop a company using the module '
  'on the day it starts.';

comment on function public.decide_leave_request(uuid, boolean, text) is
  'Approves or rejects a filed leave request. THE HOLD COMES OFF EITHER '
  'WAY and only an approval consumes the balance, which is the other '
  'half of what `submit_leave_request` put on. HR or the employee''s own '
  'manager may decide. DOES NOT REFUSE SELF-APPROVAL, unlike '
  '`decide_approval` and `decide_payslip_access` — an HR manager can '
  'approve their own leave, because the alternative is a company whose '
  'only HR manager cannot take a holiday; the balance arithmetic is the '
  'control instead. Refuses a request that is not still submitted, so a '
  'decision cannot be made twice or reversed here.';

-- ---------------------------------------------------------------------
-- Expense claims: a chain, and the alias over it
-- ---------------------------------------------------------------------

comment on function public.decide_claim_step(uuid, boolean, text, numeric) is
  'Decides the ONE step at the front of a claim''s approval chain — '
  'approving out of order would make the chain a list of opinions '
  'rather than a sequence. A rejection at any step rejects the whole '
  'claim and zeroes the approved amount; an approval only marks that '
  'step, and the claim becomes approved when nothing is left pending. '
  '`p_approved_amount` is read only on the last approval, and defaults '
  'to the full total — a figure passed at an earlier step is silently '
  'not the one that lands. Who may decide is `app.may_decide_claim_step`: '
  'the named approver for a manager or unit-head stage, anyone who can '
  'manage HR or post for those stages, AND ANY OWNER OR ADMIN AT ANY '
  'STAGE — not a loophole so much as the way out of one, since a manager '
  'who has left would otherwise strand every claim behind them. The row '
  'records who actually decided.';

comment on function public.decide_expense_claim(uuid, boolean, text, numeric) is
  'AN ALIAS. Calls `decide_claim_step` with the same arguments and adds '
  'nothing — same chain, same permissions, same refusals. Kept because '
  'callers name it; read `decide_claim_step` for what it does.';

-- ---------------------------------------------------------------------
-- The document approval chain
-- ---------------------------------------------------------------------

comment on function public.decide_approval(uuid, boolean, text) is
  'Decides the next undecided step of a document approval chain and '
  'returns where the request now stands — pending, approved or '
  'rejected. Only the step at the front: approving out of order would '
  'let the last signatory clear a document the first has not seen, '
  'which is the entire point of having steps. A single rejection ends '
  'the whole request. A step naming a person may be decided only by '
  'that person; a step naming a role, only by somebody holding it. '
  'REFUSES SELF-APPROVAL OUTRIGHT — the commonest way an approval chain '
  'becomes decoration is the person who raised the document also '
  'holding the role that clears it. Refuses a request already decided.';

-- ---------------------------------------------------------------------
-- Payslips: the one where self-approval would be taking access
-- ---------------------------------------------------------------------

comment on function public.request_payslip_access(uuid, text, date, date, uuid, uuid) is
  'Asks a company admin for temporary sight of payslips, and returns '
  'the request. ONLY AN AUDITOR MAY ASK: somebody who can already run '
  'payroll is told they have access rather than given a second route to '
  'it, and anybody else is refused. A reason is required — an '
  'unexplained request for other people''s pay is the one nobody should '
  'be able to file. One live request at a time, which keeps the admin''s '
  'queue honest.';

comment on function public.decide_payslip_access(uuid, boolean, text, integer) is
  'Approves or refuses an auditor''s request to see payslips. An '
  'approval ALWAYS EXPIRES: `p_days` must be positive, so there is no '
  'way to grant sight of payroll that does not end by itself. Only a '
  'company admin may decide, and REFUSES SELF-APPROVAL — an auditor who '
  'could approve their own request has not been granted access, they '
  'have taken it. Refuses a request already decided, so access cannot '
  'be quietly extended by deciding twice; ask again instead.';

-- ---------------------------------------------------------------------
-- Platform requests: asked by a company, decided by us
-- ---------------------------------------------------------------------

comment on function public.request_subdomain(uuid, text) is
  'Asks the platform for a name on our domain. ASKING AGAIN REPLACES '
  'THE STANDING REQUEST, which is what somebody who has been refused '
  'will do — the previous decision and note are cleared with it. An '
  'address already APPROVED is not quietly swapped: it is a live door, '
  'and changing it is an operator''s decision rather than a form '
  'submission, so this refuses and says to ask. Needs `can_admin` and '
  'the `workspace_address` module. The name is normalised and checked '
  'before it is stored; a name already taken is refused rather than '
  'queued behind the company that has it.';

comment on function public.request_mailbox(uuid, text, uuid) is
  'Asks the platform for an address on our mail domain, personal to '
  'somebody when `p_owner_id` is given. That person must be an active '
  'member of the company — an address for somebody who does not work '
  'here would be an address its owner could not read. Needs `can_admin` '
  'and the `mailbox` module. Unlike `request_subdomain` this does NOT '
  'replace a standing request: a company has many addresses, so each '
  'ask is its own row, and a local part already taken is refused.';

comment on function public.decide_subdomain(uuid, boolean, text) is
  'Platform staff approve or refuse a company''s request for a name on '
  'our domain. `app.is_platform_admin()` only — no company '
  'administrator can approve their own company''s address. NOTE THAT '
  'THIS DOES NOT CHECK THE CURRENT STATUS: calling it again on a '
  'decided request re-decides it, which is how an operator withdraws an '
  'address that should not have been approved. That is the intended '
  'route for a change, and it is why `request_subdomain` refuses to '
  'swap an approved one.';

comment on function public.decide_mailbox(uuid, boolean, text) is
  'Platform staff approve or refuse a company''s request for an email '
  'address. `app.is_platform_admin()` only. Like `decide_subdomain` and '
  'for the same reason, this DOES NOT CHECK THE CURRENT STATUS — '
  're-deciding is how an operator withdraws an address that should not '
  'have been approved.';

-- ---------------------------------------------------------------------
-- The budget, which is agreed to rather than approved by a chain
-- ---------------------------------------------------------------------

comment on function public.approve_budget(uuid) is
  'Agrees a draft budget, which is the act that makes it the thing '
  'variances are measured against. NEEDS `can_post`, not merely the '
  'right to edit — a figure everything will be reported against is a '
  'posting-weight decision. Refuses a budget that is not still draft, '
  'and refuses an empty one: an empty budget is not something to agree '
  'to. There is no un-approve; a budget that should not have been '
  'agreed is archived and replaced.';

comment on function public.archive_budget(uuid) is
  'Puts a budget out of use. ARCHIVED RATHER THAN DELETED — last year''s '
  'budget is what last year''s variance report was run against, and '
  'deleting it would make a report somebody has already circulated '
  'impossible to reproduce. Works on a draft or an approved budget, '
  'which makes it the only way back from `approve_budget`. Refuses one '
  'already archived. Needs `can_write_module(''accounting'')`, which is '
  'lighter than approving: putting a budget beyond use breaks nothing '
  'that was posted.';
