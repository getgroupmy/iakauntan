# The first live ringgit

`docs/gaps-against-akaunting.md` closes its payment section with a
sentence that has been true for months:

> Section closed as far as code goes; a first live ringgit is still a
> thing somebody has to do.

This is how. Nothing below can be done from a commit — it is the same
class as the four items at the end of `docs/pre-deployment.md` — and
none of it can be done from the environment this was written in, which
has no acquirer sandbox and no credentials.

Written down because the alternative is that whoever does it
rediscovers the shape of the thing at the same time as they discover
whatever is wrong with it, which is two problems at once and the wrong
two.

## What is already asserted, so you are not looking for it

Everything either side of the HTTP call. `shared_invoice_payment.sql`
carries 58 assertions, including the retried callback, the short
payment, and the invoice settled by bank transfer while the acquirer
was still thinking. `_shared/billplz_test.ts` asserts the signature
verification in CI.

So a failure on the day is **the network, the credentials or the
configuration** — not the settlement logic, and not the receipt. Look
there first, and in that order.

## Before the day

1. **A Billplz account for the shop**, not for the platform.
   `billplz-checkout` and `BILLPLZ_XSIGNATURE_KEY` are the platform
   billing its own subscribers and are a different account entirely.
   Mixing them up produces a signature that never verifies, and the
   only symptom is a 401 in the function log.

2. **The shop's own credentials in Settings → Let customers pay
   online.** Three things, and `0412` names them generically because
   ten acquirers are registered and they do not agree on vocabulary:
   the secret key, the collection reference, and the X Signature key.
   Enter them in **Sandbox** first — sandbox and production are
   separate rows by design, so both can be configured at once and
   neither overwrites the other.

3. **Nominate the bank account the takings land in.** The receipt posts
   to it. Without one, `shared_payment_options` tells the payer this
   shop cannot settle and no Pay button is drawn — which is the
   correct behaviour and looks like a broken page if you were not
   expecting it.

4. **The callback URL at Billplz** points at the deployed
   `pay-invoice-callback`, not at `billplz-callback`. Those are two
   functions and only one of them looks up *the shop's* key.

5. **Check `ALLOWED_ORIGINS`** includes the origin the share link is
   opened from. Item 2 of pre-deployment's list, and a payer on a
   company's own subdomain is not on the platform's origin.

## The run

Raise a small invoice to a contact you control, share it, open the link
as the customer would, and press Pay.

Watch three things, in this order:

- **`pay-invoice` returns a url.** If it does not, the failure is the
  shop's key or collection. The function deliberately returns a
  sentence and puts the detail in its log, because a Billplz error body
  can quote the key back.
- **Billplz takes the money.** Nothing of ours is involved.
- **`pay-invoice-callback` is reached and answers 200.** A 401 here is
  a signature that did not verify OR a reference nobody has heard of,
  answered identically on purpose — telling them apart would make the
  endpoint an oracle for guessing references. On the day, assume the
  key.

Then look at the invoice. It should carry a receipt, the receivable
should be down by the amount, and the bank account nominated in step 3
should be up by it.

## What each outcome means

`settle_shared_payment` names five, and the name is in the payment row:

| Outcome | What happened |
|---|---|
| `paid` | Settled. A receipt is posted and the ledger has moved |
| `underpaid` | Less than was owed. **Recorded and refused**, never rounded up into a settled invoice |
| `already_paid` | A retried callback found the payment it already settled. Correct, and the commonest one after the first |
| `not_paid` | The acquirer said the bill was not paid |
| `unknown` | No such reference. Returns quietly, for the oracle reason above |

A verified callback is answered **200 even when the outcome is
`unknown`**, because acquirers retry anything that is not 2xx. A 200 is
not a claim that money moved; the payment row is.

## What to do with the ringgit afterwards

Refund it at the acquirer, and leave the receipt in the books or void
it as you would any other. Do not delete the payment row: it is the
only record that the path has ever carried money, which is the thing
this whole exercise exists to establish.

## When it works

Update `docs/gaps-against-akaunting.md` section 3 — the last paragraph
is written to be replaced — and say which acquirer and which mode, so
the next person knows whether production has been proved or only the
sandbox.
