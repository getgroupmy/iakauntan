# Approvals

Not a module. Deciding who may reach the ledger is not a product a
company buys; it is how a company that already has the ledger governs it,
so this rides on whatever the tenant already pays for and needs no
separate entitlement.

## Nothing changes until somebody writes a rule

This is the property the whole design is built around, and it is asserted
before anything else in `supabase/tests/approvals.sql`.

Every gate asks `app.approval_required` first, which is false when no
rule matches. No rules exist anywhere on this deployment, so a company
that never opens the Approvals screen will not notice the migration. A
release that quietly held up every tenant's invoicing would be a far
worse failure than one that approves too little, and the test rules it
out before it tests anything else.

## Why not widen `claim_approvals`

Expense claims have had a real chain since `0116`. It cannot be widened
to cover documents: it is keyed on `claim_id`, its steps are
`app.claim_stage` — manager, unit head, HR, finance — and its approvers
are `employees`. Those are the right shapes for a staff expense and the
wrong ones for a journal. `0167` is therefore a second, polymorphic layer
beside it, and expense claims keep the chain they have.

## The gate is a trigger, not a check in the posting routine

There are several ways a document reaches `posted` — the editor, a
transfer, a recurring schedule, a strata charge run — and a check written
into one of them is a check the others do not have. `refuse_unapproved`
is on the table, so it covers the paths nobody has written yet.

The journal trigger is **deferred**, and that is not decoration. A rule
reading "journals over ten thousand" cannot be evaluated at INSERT: the
entry has no lines yet, so every journal would look like nothing.
Deferring it to commit means the lines are in by the time it looks, which
is exactly why `assert_balanced` on `gl_lines` is deferred, and that is
the precedent this follows.

Only `source = 'manual'` journals are gated. Every other entry in
`gl_entries` is the by-product of a document that has its own gate, and
holding those up would stop an approved invoice posting itself.

## Nobody signs their own

The commonest way an approval chain becomes decoration is the person
raising the document also holding the role that clears it.
`decide_approval` refuses it, `my_approvals` hides it, and
`approval_state` reports `awaiting_me = false` for the raiser even when
they hold the role — so the button that would fail is never offered.

The test's two-step fixture has the *clerk* raise the requisition
deliberately. Had the owner raised it, every assertion about step
ordering would have been answered by the self-approval rule instead and
passed for the wrong reason.

## Steps are decided in order

`decide_approval` looks only at the lowest-numbered pending step.
Approving out of order would let the last signatory clear a document the
first has not seen, which is the entire point of having steps.

A rejection at any step ends the whole request. The request may then be
sent round again — that is the normal way a document gets fixed — and the
partial unique index allows it precisely because it only covers the
pending ones.

## What the screen adds

The trigger only speaks when it refuses, and a screen cannot build a
button out of an exception. `public.approval_state` (`0169`) answers, in
one round trip, the three things the editor needs: does a rule cover this,
has it been cleared, and whose desk is it on.

The banner has four states because they are four different things to do
next — unsent, with somebody else, **with you**, or approved. Rendering
the middle two the same is how a document sits for a week on the desk of
the one person who could have released it in a second.

## Purchase requisitions

`purchase_request` has been in `purchase_doc_type` all along, and
`transferTargets` has known `purchase_request → purchase_order` all
along. What it never had was a row in `docTypes`, which is the only
reason it could not be reached from the app. It now has one.

A requisition posts nothing — a request is not a liability — which is
exactly why an approval rule, rather than a posting gate, is the only
thing that can make it mean anything. A rule with `min_amount = 0` is how
a company says "every requisition needs signing".

## What the tests prove

`supabase/tests/approvals.sql`, run in CI:

- nothing is required before a rule exists (asserted first)
- a rule bites only at or above its amount, only for the type it names,
  and only for the kind of thing it names
- an invoice **under** the threshold posts untouched — the positive
  control on the whole file
- one over it is refused, with `insufficient_privilege`
- the raiser cannot approve their own, and neither can somebody without
  the role — who also sees an empty inbox
- the admin's inbox shows exactly one, approving clears it, and the
  document then posts
- a two-step chain refuses the second approver while the first is open,
  reports `pending` after one of two, `rejected` after a rejection, and
  accepts a resubmission

`app/test/approvals_test.dart` asserts the four banner states, that
"waiting for you" outranks "waiting for approval", the inbox routes, and
the sentence a rule describes itself with.

## Not done

- **No delegation.** Somebody on leave holds their step until they come
  back or an administrator edits the rule.
- **No reminders.** Nothing emails an approver that something has been
  sitting in their inbox for a week.
- **No amount-changed invalidation.** Editing a document after it was
  approved does not re-open the chain. The document is locked for editing
  once posted, but between approval and posting it is not.
- **The rejection note is written and never displayed** anywhere except
  the row itself; the raiser has to open the request to read it.
