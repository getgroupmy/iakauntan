# Signing an e-Invoice

A MyInvois e-Invoice at **version 1.0** is submitted as it stands. One at
**version 1.1** must carry a XAdES digital signature made with a
certificate issued to the taxpayer by a Malaysian certification
authority, and LHDN recomputes both digests and the signature before it
will validate the document.

This is what `0615` built, and what is honestly unfinished about it.

## What is built

| Piece | Where |
|---|---|
| Reading a certificate — serial, issuer, validity, public key | `supabase/functions/_shared/der.ts` |
| Building and verifying the signature | `supabase/functions/_shared/xades.ts` |
| Loading a certificate, and proving the key matches it | `supabase/functions/myinvois/certificate.ts` |
| Signing at submission | `supabase/functions/myinvois/submit.ts` |
| Custody, and the order of the setup | `supabase/migrations/0615_*.sql` |
| The screen | Settings → **The certificate that signs them** |

## Where the key lives

In `einvoice_credentials`, in the columns `0107` created for it —
a table with row level security, **no policies and no grants at all**.
Nothing an organization can call returns it. The only reader is the edge
function, through the service role, and nothing it returns carries the
key out.

`einvoice_credential_status` says whether a certificate is on file, who
issued it, its serial number and when it expires. All four are printed
on the paperwork the certification authority sends; none of them is the
key. `einvoice_signing_certificate.sql` asserts that the function's
declared output columns contain no certificate, no private key and no
client secret — against the signature rather than against a row, so a
column added later cannot slip through.

## The order to do it in

1. **Client id and secret**, from MyTax → e-Invoice → API. The database
   refuses a certificate before this: `client_secret` is NOT NULL, and a
   company that cannot log in to MyInvois has nothing to sign *for*.
2. **The certificate and its key.** A certification authority sends one
   `.p12` holding both. WebCrypto does not read PKCS#12, so convert it
   once:

   ```
   openssl pkcs12 -in signing.p12 -nodes -legacy -out signing.pem
   ```

   and paste the `CERTIFICATE` and `PRIVATE KEY` blocks separately.
   **Press Check first.** A key that does not match its certificate
   produces a structurally perfect document that LHDN rejects at
   validation, hours later, with a code naming neither half.
3. **Version 1.1.** The database refuses this without a certificate on
   the environment the company submits to — a sandbox certificate does
   not make a production company ready — because a 1.1 document that
   cannot be signed is a submit button that stops working.

Per environment, like the credentials. The certificate that signs
sandbox documents is usually a test certificate, and putting it on
production is how a real invoice goes out signed by nothing anyone
recognises.

## What the version means for documents already queued

Nothing. `prepare_einvoice` stamps the version onto each
`einvoice_documents` row as it is prepared, so switching to 1.1 does not
retroactively invalidate what is queued, and `submit` decides per
document. A batch containing a 1.1 document with no certificate is
refused **before** anything is sent, naming the documents: half a
submission is worse than none, because what was accepted is validated
and immutable and the rest come back as "queued" with nothing saying
why.

## What is NOT verified, and cannot be from here

The structure is written to LHDN's published JSON binding and agrees
with two independent implementations of it. **It has never been
submitted to MyInvois from this repository.** There is no sandbox
credential here, and `sdk.myinvois.hasil.gov.my` is unreachable from the
network this is built on — `WebFetch` answers `EGRESS_BLOCKED`.

What the tests prove is the arithmetic, which is the check LHDN
performs:

- both digests recompute from the emitted document;
- the signature verifies against the certificate inside it;
- the version is raised **before** the digest is taken, so a document
  hashed at 1.0 and relabelled 1.1 is caught here rather than rejected
  there;
- the properties digest covers the `Target` wrapper and not the bare
  properties;
- a tampered figure breaks exactly the document digest, and a back-dated
  signing time breaks exactly the properties digest;
- a mismatched pair, an expired certificate and one that has not started
  yet are each refused with a sentence naming the problem.

What they cannot prove is that LHDN agrees about the **shape** — chiefly
two things the published sample settles and the two reference
implementations disagree about:

- the **order of the two `Reference` entries** inside `SignedInfo`. This
  emits the signed properties first and the document second. They are
  told apart by `URI` rather than by position, and
  `verifySignedUblJsonDocument` reads them that way, so swapping them
  needs one edit and no other change.
- whether `SignedInfo` carries a **`CanonicalizationMethod`**. This
  omits it.

### Closing that gap

It takes a sandbox credential and one submission, not more code:

1. Register for MyInvois **preprod** and put the client id and secret on
   a test company, environment `sandbox`.
2. Load a test certificate — any Malaysian CA's test issuance, or a
   self-signed one if preprod accepts it.
3. Set version 1.1 and submit one invoice.
4. If it is rejected, the response body is stored on the
   `einvoice_submissions` row and the full exchange in `einvoice_logs`.
   The code will name the failing property.

Until somebody does that, treat 1.1 as **built and unproven**, and leave
production at 1.0. The screen does not say this — a settings card is the
wrong place for a caveat about our own confidence — so it is written
here, and the README says it too.
