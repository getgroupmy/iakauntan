# Property management

Two modules, `property_strata` and `property_nonstrata`, sold separately
and gated separately. They share a spine — a site and the units in it —
because a managing agent with a mixed portfolio holds both and thinks of
it as one list.

A site is strata or it is not. `property_sites.tenure` decides, a trigger
enforces what a site of each kind may hold, and nothing on any screen
offers to change it: a scheme does not stop being strata.

## Why the split

Almost nothing about managing the two is the same.

A **strata** scheme is governed by the Strata Management Act 2013. There
is a developer, a Joint Management Body or a management corporation
running it; the parcels carry allocated share units from the Schedule of
Parcels; and the Charges must be levied **in proportion to those share
units** — not per parcel, not per square foot. A contribution to the
sinking fund of at least ten per cent of the Charges rides on top
(s.25(3) for a JMB, s.51(2) for an MC). Arrears attract a late payment
charge, capped at ten per cent per annum on a daily basis by the Third
Schedule of the Strata Management (Maintenance and Management)
Regulations 2015.

A **non-strata** property — a shoplot, a landed house, a whole commercial
building — has none of that. It has a tenancy, a rent, a deposit and an
end date, and the money is rent rather than a statutory contribution.

Putting both behind one module would mean a management corporation
paying for tenancy machinery it may not lawfully use, and a landlord
paying for a sinking fund they do not have.

## Everything bills through the ordinary invoice

A charge run raises `sales_documents` of type `invoice` and posts them.
It does not keep a parallel charge ledger. That is deliberate: aged
receivables, statements, receipts, credit control, reminder emails and
e-Invoice all work on the day this ships instead of each needing a
property-shaped copy. A management corporation's Charges are receivable
in exactly the sense the rest of this system already understands.

Two income accounts are created on demand, because the seeded chart is a
trading company's and has no line for either — `4810 Maintenance
Charges`, `4820 Sinking Fund Contributions`, and `4830 Rental Income` for
the other module.

The sinking fund is a **separate line on the invoice**, not folded into
the charge. The Act requires the fund to be held separately, and an owner
asking what they are paying for should be able to read the split off the
invoice rather than out of a policy document.

## The statutory arithmetic, and where it is proved

`supabase/tests/property.sql`, run in CI. The numbers below are the ones
the test asserts.

| Rule | Where |
|---|---|
| Charges in proportion to allocated share units | `strata_charge_preview` |
| Sinking fund at least 10% of the Charges | `strata_charge_rates.sinking_fund_percent`, floored by a check constraint |
| Late payment charge, 10% a year maximum, daily | `app.strata_late_interest`, ceilinged by a check constraint |

A worked example, which is also the fixture: three parcels of 300, 100
and 200 share units, a rate of RM0.35 per share unit per month, billed
for the quarter. The 300-unit parcel is charged 300 × 0.35 × 3 =
**RM315.00**, the 100-unit parcel **RM105.00**, and the ratio between
them is exactly 3:1 — which is the rule, stated as a ratio so that
changing the rate does not silently change what is being tested. The
sinking fund on the first is **RM31.50**. Unpaid ninety days after the
due date, RM346.50 attracts **RM8.54**.

The test also asserts the refusals, because a rule that only ever passes
is not enforced: a sinking fund below ten per cent, a late payment charge
above ten, a chargeable parcel with no share units, a strata scheme
holding a shoplot, and the rent engine running for a company that bought
only the strata module.

## Quit rent and assessment

Recorded, not computed. Cukai tanah is set by the state and cukai pintu
by the local authority; the rates vary and change, and a system that
guessed them would be wrong quietly. What `property_statutory_charges`
holds is the bill, its period and the date it falls due, and
`property_statutory_due` answers the question a managing agent with forty
sites actually has — which one falls due next, and which has been missed.
It sits at the top of the portfolio screen rather than inside a site,
because a bill is missed by not opening the site it belongs to.

## What this does not do yet

- **No AGM register.** First AGM dates and the management stage are held
  on `strata_schemes`, but there is no minute book, no notice generation
  and no quorum tracking. The corporate secretarial module is the closer
  precedent for that work than anything here.
- **No tenancy stamp duty.** Deliberately left out of this cut.
- **No apportionment on sale.** When a parcel changes hands mid-period
  the charge is not split between the old and new owner; the invoice goes
  to whoever is recorded as owner at the moment of the run.
- **No editors for sites, units, tenancies or rates.** The registers
  read; the rows are entered through the API. The screens to maintain
  them are the obvious next piece.

## The shape of the tables

```
property_sites          tenure decides everything below it
 └── property_units     parcels (strata) or units (non-strata)

strata_schemes          one per strata site — developer / JMB / MC
 ├── strata_charge_rates    what an AGM resolved, never edited
 └── strata_charge_runs     one per period
      └── strata_charge_lines → sales_documents

tenancies               one per let, non-overlapping per unit
 └── rent_runs
      └── rent_run_lines → sales_documents

property_statutory_charges   quit rent and assessment, either tenure
```

Every child carries `org_id` and a composite foreign key back to its
parent on `(org_id, parent_id)`, so a row cannot point at another
company's site, unit, scheme or contact. That is the rule migration
`0160` made declarative across the money paths, applied here from the
start rather than retrofitted.
