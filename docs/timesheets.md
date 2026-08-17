# Timesheets

`timesheets`, an add-on. Hours recorded against a project or a matter,
priced from a billing rate, and turned into an invoice.

## What was already here, and what was not

Time recording was not missing. `time_entries` has existed since the
legal module shipped, with minutes, rate, amount, billable, billed and an
invoice link. Two things were wrong with it.

**It was welded to law firms.** `matter_id` was `NOT NULL` and the table
was gated on the `legal` module, so a consultant, an engineer, an
architect or an agency could not record a minute. `public.projects` had
been sitting unused since the dimensions work with a code, a name, a
client and a budget — the anchor this needed.

**Nothing could bill it.** `is_billed` and `invoice_id` existed, and the
only function in the database that mentioned either was
`report_matter_summary`, which *reads* them. There was no code path
anywhere that set them. A firm could record a year of chargeable time and
had no way to invoice a minute of it. That is the hole `0164` fills, for
matters and projects alike.

## The rate

Three places a rate can come from, most specific first:

1. this person, on this project — `billing_rates` with a `project_id`
2. this person generally — `billing_rates` with `project_id` null
3. the matter's own agreed rate

Resolved as of the **entry's** date, not today's, so backdating a rise
does not reprice work already done at the old rate. Recording time does
not require knowing the rate: `app.time_entry_default_rate` fills it in.

That trigger is called `apply_billing_rate` for a reason. Postgres fires
BEFORE triggers alphabetically and the existing one on the table is
`calc_amount`, which multiplies rate by minutes. A trigger named
`default_rate` would sort after it, fill in a rate that had already been
multiplied by nothing, and every entry would come out at zero — a
timesheet that looks like a lot of free work.

## Billing

`bill_project_time(project, from, to, due)` and `bill_matter_time(...)`.
One invoice, **one line per person** rather than per entry, because that
is what a client queries — not "what did you do at 14:20 on the third"
but "why is there eleven hours of associate time on this". The entries
stay linked to the invoice, so the detail is a click away when they do
ask.

Entries are filtered on `not is_billed`, so running it twice over the
same period bills nothing the second time rather than billing it again.
A double-billed client is a lost client, and that property is asserted.

Fees land in `4840 Professional Fees`, created on demand — the seeded
chart is a trading company's and has no line for it.

## What the test proves

`supabase/tests/timesheets.sql`, run in CI, against a fixture of
90 + 30 chargeable minutes and 60 non-chargeable:

- the project rate (RM450) beats the person's default (RM300)
- a rise effective July does not reach back to February
- 90 minutes bills at **RM675.00**, the pair at **RM900.00**
- both billable entries are marked and linked; the non-billable one is
  not swept in
- a second run over the same period bills nothing — and time recorded
  since still bills, which is the control on that
- utilisation is 180 of 240 minutes = **75%**
- billable time with no matter and no project is refused; non-billable
  time may float free, which is the only way utilisation means anything
- an hour booked to a project *and* a matter is refused
- a project with no client cannot be invoiced, and says so

## Not done

- **No editor for billing rates or projects** in the app yet; the
  registers read and the screen bills. Rates are set through the API.
- **No approval step** on a timesheet before it is billed.
- **No timer.** Time is entered in minutes after the fact.
- **Write-offs.** An entry can be marked non-billable before invoicing,
  but there is no way to bill 8 of 10 hours and write off the rest.
