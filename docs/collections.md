# Debt collection

Not a module. Chasing an unpaid invoice is what the sales ledger is *for*
when a customer does not pay, so this rides on the same entitlement as
the rest of the sales side and needs no separate purchase.

## What was already there, and what was not

Two of the three parts existed. `queue_overdue_reminders` emails a
customer on the day-offsets a company configures, and `report_ar_aging`
says what is owed and how old it is.

Between them sat the part a person does: ringing somebody up, being told
the cheque goes out on Friday, and needing to know on Saturday that it
did not. Nothing recorded that. An attempt left no trace, so two people
could chase the same customer on the same morning, a promise could be
made and forgotten, and the question a credit controller is paid to
answer — *who said they would pay, and did they* — had no data behind it.

## The worklist reads through the aged receivables

`report_collections(org_id, as_at)` gets its money from
`report_ar_aging`, not from a second reading of `sales_documents`. That
report already knows what "outstanding" means as at a date — allocations
whose two ends were both in the ledger by then, void and deleted
documents excluded — and a collections screen quoting a different figure
from the aged receivables is worse than no collections screen at all.
The test asserts the two agree rather than trusting that they do.

## The order is the point

Broken promises, then customers nobody has rung, then oldest debt.

That is deliberately **not** oldest-first. In the test fixture the
never-chased customer is 146 days overdue and the broken promise is 101,
and the broken promise still comes first: it is the account somebody was
actively managing that has just stopped being managed, and it is the one
most likely to be lost if nobody looks today.

The ordering lives in the database and the screen does not re-sort. A
list sorted in Dart would eventually disagree with the report it came
from, and the widget test asserts the order comes through untouched.

## Promises

A promise is the only outcome with a diary, so the table is strict about
it:

- `outcome = 'promised'` **requires** a date. Without one it never
  reaches a follow-up list, which makes it a note rather than a promise.
- A promise date may not precede the conversation. "They promised to have
  paid last week" is a typo that would file itself as already broken.
- A promise date belongs only to `promised`. "Refused, will pay Friday"
  means somebody picked the wrong one of the two.
- An invoice being chased must belong to the customer being chased. The
  composite key stops another *company's*; this stops another customer of
  the same one, which is the mistake a picker actually makes.

**The live promise is the latest one given, not the earliest.** A
customer who rang back to move Friday to the following Tuesday has one
promise, for Tuesday, and chasing them on Friday is chasing a date they
already renegotiated.

**A later attempt does not clear an outstanding promise.** If somebody
emails on the 11th with no answer, the last *contact* is the 11th and the
live promise is still the broken one from May. Both are true and the
report says both.

## Assignment

Carried on the attempt rather than on the customer, so handing an account
over is a dated event with a note attached — which is what the person
picking it up needs to read.

## What the test proves

`supabase/tests/collections.sql`, run in CI, against three customers
owing RM1,000, RM2,000 and RM3,000:

- the worklist total is RM6,000 and equals the aged receivables total
- the broken promise sorts above the older never-chased debt
- the renegotiated 15 July promise wins over the earlier 30 June one
- a promise made on the 5th is invisible in a report run as at the 1st
- a later no-answer does not erase the broken promise still standing
- all four refusals above, plus a positive control that an ordinary
  attempt against the customer's own invoice still goes in

## Not done

- **No dunning letters.** The email reminders that exist are the
  automatic ones on day-offsets; there is no "print a letter of demand"
  from here.
- **No escalation workflow.** `escalated` is an outcome, not a state
  machine — nothing tracks what happened after it went to a solicitor.
- **No promise-kept detection.** A promise whose date has passed and
  whose debt is now nil simply drops off the list, because the customer
  no longer owes anything. Nothing records that they kept it, so there is
  no per-customer reliability score.
- **No purchase-side equivalent.** This is receivables only.
