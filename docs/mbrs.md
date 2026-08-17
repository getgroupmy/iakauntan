# Audited financial statements and MBRS

A paid module, `mbrs`, RM79. **Not granted to existing tenants** — unlike
the fixed-assets and approvals migrations, nothing here existed before,
so there is nothing anyone can lose by having to ask for it.

## What this does not do

MBRS is SSM's XBRL platform. A preparer keys or imports figures into
**mTool** — an Excel application SSM distributes — which generates the
XBRL instance, and uploads that through **mPortal**. There is no public
API for third-party lodgement.

**So nothing here submits to SSM.** What the module does is produce the
dataset that goes *into* mTool, and record the reference that comes back
out of mPortal. The screen says so at the top, in a banner, above the
button marked "Record lodgement" — because a team changes, and a screen
with a lodgement button that never says where the lodging happens is a
screen somebody will assume filed their client's accounts.

## The numbers already existed

`report_balance_sheet`, `report_profit_loss`, `report_changes_in_equity`
and `report_cash_flow` have been here since `0014`. This adds the four
things between a trial balance and a lodgeable set of accounts.

### 1. The mapping mostly writes itself

`accounts.account_subtype` already says what every account is —
`accounts_receivable`, `inventory`, `finance_cost`, `payroll_expense`.
That is very nearly the taxonomy already, so `app.fs_default_element`
maps every one of the 26 subtypes to an element and `fs_account_map`
holds only the deviations. **An empty map means a standard chart mapped
the standard way, not an unmapped one.**

`accumulated_depreciation` deliberately lands on the same element as the
cost it relieves: the face of the statement shows carrying amount, and
the cost/depreciation split is a note. `drawings` lands on retained
earnings and comes back negative from the balance sheet, so it reduces
them without needing a sign column.

### 2. The statements have to balance, and by default they do not

**There is no year-end close in this ledger.** Nothing sweeps revenue and
expense into retained earnings, so `report_balance_sheet` on its own is
out by exactly the profit accumulated since the company started trading.

That is fine for a management balance sheet and fatal for a statutory
one — a Statement of Financial Position whose assets do not equal equity
plus liabilities is a rejected filing. So retained earnings *as
presented* is the posted balance of the retained-earnings accounts plus
`app.fs_cumulative_profit` to the year end, and `fs_freeze` refuses to
freeze accounts that do not balance.

In the test fixture: RM100,000 capital, RM250,000 revenue, RM180,000
costs. Assets RM170,000, equity RM170,000 — of which RM70,000 is profit
no close has swept anywhere.

### 3. Frozen means frozen

A set of accounts lodged in May must still read the same in November,
after somebody posts a correction into the closed year. `fs_freeze`
copies the ledger's answer into `fs_figures` and stops asking.

The test proves both halves: after a RM5,000 journal dated inside the
frozen year, the filed figure is still RM180,000 **and the live ledger
now says RM185,000**. Asserting only the first would pass even if the
ledger had never moved.

Enforcement is a trigger rather than a policy, because the rule is about
the row's own state rather than about who is asking — and because
`fs_freeze` and `fs_lodge` are SECURITY DEFINER and would sail past a
policy. They set `app.fs_writing` for the one statement allowed to write.

Lodged accounts refuse a restatement entirely. The reference and the
lodgement date may still be corrected: a typo in what mPortal returned is
a typo, not a restatement.

### 4. The statutory clock, and the exemption

**Sections 258 and 259, CA 2016.** Circulate to members within six months
of the year end; lodge within thirty days of that circulation. A public
company lays the accounts at the AGM within six months (s.340) and lodges
within thirty days of the meeting.

Two things the test pins down:

- **Six months is not 180 days.** From 31 August it is 28 February —
  181 days — and a deadline computed by adding 180 would say the 27th.
  `corp_filing_types` carries 210 as a worst-case reminder offset, which
  is right for a diary and wrong for an actual due date.
- **The lodgement clock runs from the act, not the entitlement.** A
  company that circulated on 20 April owes its lodgement on 20 May, not
  thirty days after the deadline it did not use.

**Practice Directive 3/2018.** Three grounds — dormant, zero-revenue,
threshold-qualified — each tested across the current financial year *and
the immediate past two*. That is the part people get wrong: one good year
does not exempt you, and the test's fixture deliberately puts the
offending year in the oldest of the three.

Thresholds: zero-revenue needs total assets not above RM300,000 in all
three years; threshold-qualified needs revenue not above RM100,000, total
assets not above RM300,000, and not more than five employees, in each of
the three.

`fs_audit_exemption` returns **one row per ground including the ones that
fail, with the reason** — because "why am I not exempt" is the question
an accountant actually asks. Headcount comes off each year's own filing
row rather than from today's employee list, which would answer a question
about 2023 with a fact about 2026; where it is missing the answer is
"cannot tell", not "no".

## The element codes are a working set

**`mbrs_elements` is a table, not a hardcoded list.** The MBRS taxonomy is
versioned and changes between releases; codes baked into a migration
would be wrong the first time SSM published a new one and would need a
deployment to correct.

The 25 codes seeded in `0171` are the standard MPERS and MFRS statement
lines under their conventional names, and `taxonomy_version` says
`working-set`, which is not a taxonomy version and is meant to look wrong.
**They must be reconciled against the mTool taxonomy in use before the
first live lodgement.** Platform staff can load a real release without a
migration.

## The export

A flat CSV keyed on the element — statement, section, element, label,
current year, prior year — rather than an attempt at mTool's own
workbook. Generating a workbook against a template version we cannot see
would produce a file that looks right and fails validation at SSM.

`mtool_csv.dart` has no Flutter imports so the format can be asserted
directly. A draft export is named `mbrs-figures-DRAFT.csv`: draft figures
follow the ledger, two exports an hour apart can differ, and the filename
is the only thing distinguishing them once the file is on a desktop.

The widget test covers the case that matters most — "Property, plant and
equipment" is the first line of every Malaysian balance sheet and has a
comma in it. An unquoted comma would move money between lines in a
statutory filing.

## Not done

- **No XBRL generation.** The output is a dataset for mTool, not an
  instance document.
- **No Annual Return or Exemption Application scopes.** MBRS covers
  those; this covers Financial Statements only.
- **No notes to the accounts.** `fs_disclosures` exists and holds
  key/value narrative; nothing composes a full set of notes, and the
  directors' report and statutory declaration are not generated.
- **No cash flow or changes-in-equity elements.** `report_cash_flow` and
  `report_changes_in_equity` exist and are not yet mapped to taxonomy
  elements, so those two statements are not in the export.
- **No comparative restatement.** The prior year is computed from the
  ledger as it stands, not read from the prior year's frozen figures —
  so a restated comparative will not match what was actually filed last
  year. Reading the prior filing's `fs_figures` when one exists is the
  obvious next step.
- **No consolidation.** Group companies exist; these are entity accounts.
