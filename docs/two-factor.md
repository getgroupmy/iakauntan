# Two-factor

A six-digit code from an app on the phone, as well as the password.
Settings → Your account → Two-factor.

## What is built

* **Enrolling.** `mfa.enroll` for a TOTP factor, the QR drawn from the
  `otpauth://` URI with `qr_flutter` — the app has no SVG renderer and
  adding one to display a square of black and white would be a dependency
  for nothing — and the secret shown in text beside it, because somebody
  setting this up on the same phone their authenticator is on has no second
  camera to point at the screen.
* **Verifying.** GoTrue leaves a factor unverified until a code is accepted,
  which is the right way round: an authenticator somebody *thinks* they
  scanned is an account they are about to be locked out of. A cancelled
  enrolment is unenrolled rather than left — an unverified factor is
  invisible in every list and collides with the next attempt on the friendly
  name.
* **Removing.** The list is the revocation, the same as the passkey list.
* **The challenge at sign-in.** Inside the vetting hold, before the door
  checks and before the router sees the session, so the app is never briefly
  open on a session that has not finished proving itself. Cancelling signs
  the session out.

## What it does NOT enforce, and this is the important part

**The database does not require `aal2` on anything.**

A GoTrue session produced by a password alone is valid at `aal1`. Every RLS
policy in this schema asks who you are — `app.is_org_member`,
`app.can_write`, `app.can_admin` — and none of them asks how thoroughly you
proved it. So the challenge at sign-in is a gate on the screen rather than a
wall: it genuinely stops somebody who has the password and not the phone,
because cancelling signs them out, and it would not stop a client that
simply never drew the dialog.

That is worth having and it is not what most people mean by two-factor, so
it is written here rather than implied by the feature existing.

### What closing it would take

Policies would have to read the claim:

```sql
(auth.jwt() ->> 'aal') = 'aal2'
```

The obvious place is not each policy but the `app.can_*` guards, which most
permissions already funnel through — `can_write`, `can_admin`, `can_post`,
`can_manage_hr`. Adding the test there reaches almost everything in one
change.

Two things make it more than a one-line edit, and both need a decision
rather than an implementation:

1. **It has to be per user, not per project.** A company where one person
   uses two-factor and nine do not must not lock out the nine. So the guard
   would have to be "aal2, *or* this user has no verified factor", which
   means reading `auth.mfa_factors` from inside a guard that runs on every
   row of every query. That is a per-statement cost on the hottest functions
   in the schema, and it needs measuring before it is shipped.

2. **Sessions already open would break.** Everybody signed in at the moment
   of the migration is at `aal1`, and a guard that refused them would empty
   the product until each of them signed in again. It needs a date, an
   announcement, or a grace column.

Neither is hard. Both are choices somebody has to make, and making them
quietly inside a migration would be the wrong way to make them.

## There are no recovery codes

GoTrue does not issue them. An authenticator nobody can reach is an account
nobody can reach, and only a platform administrator — with dashboard access
— can remove the factor.

So the card says, where somebody is deciding: keep a second authenticator on
another device. That is the recovery, and it is the only one.

## What the Supabase dashboard needs

**Authentication → Configuration → Multi-Factor Authentication.** TOTP has
to be enabled for the project. Where it is not, `listFactors` answers with
an error and the card is absent rather than disabled — the same way the
passkey card is, and for the same reason: a greyed-out control invites
somebody to work out why, and there is nothing they can do about a dashboard
setting.
