# Departmental accounting

A connection job, not a build. Every piece of this existed; none of them
were joined up.

## What was already there

- `gl_lines.department_code`, and both posting routines carry it faithfully
  from `sales_document_lines.department_code` and
  `purchase_document_lines.department_code` onto the revenue and expense
  legs of the journal.
- `report_profit_loss_by_dimension(org, from, to, project_code,
  department_code)` — the P&L restricted to one of either.
- `ledger_dimensions(org)`, which lists the project and department codes
  that actually appear in the ledger.
- `departments`, with `code`, `name` and `cost_centre`, maintained on the
  HR setup screen. Its select policy is `app.is_org_member` with **no
  module gate**, so a company without the HR add-on can still read it.

## What was missing

Two things, and between them they made the rest inert.

**Nothing ever wrote the column.** No screen offered a department on a
document line, so `gl_lines.department_code` was null on every row this
deployment has ever posted. A report reading a column nothing fills is a
report that says every department earned nothing — which is worse than
having no report, because it looks like an answer.

**The report had no filter for it.** `report_profit_loss_by_dimension`
has always taken both dimensions; the reports screen only ever offered
the project one, so the department half was unreachable even if the data
had been there.

## What was added

A department picker on the document header, beside the project picker and
built exactly like it: chosen per document, stamped onto every line at
save time. `gl_lines.department_code` is per line because the ledger
needs the analysis there; the choice is per document because that is how
the work arrives. Nobody splits one invoice across two departments often
enough to give every line its own picker.

The picker is hidden until a company has defined departments — the same
rule the project picker follows, for the same reason: a dropdown with
nothing in it on every invoice is a control that teaches people to ignore
controls.

And the department filter on the P&L, built from `ledger_dimensions`
rather than from the `departments` table. A department that has never had
a penny posted against it is not a filter anybody wants; it is a row that
would come back empty.

## Where departments are maintained

The HR setup screen, Structure tab. This is a genuine reachability wrinkle
for a company that has not bought the HR module: the *table* is readable
by any member and writable by any owner, admin or HR manager, but the only
editor for it sits behind the HR navigation gate. A company without HR can
have departments created for it, and can then use them everywhere here —
it just cannot add more from the app.

## The two routes that used to miss it

Both are closed now, and they were closed differently, which is the
part worth remembering.

### Manual journals: no schema change at all

`gl_lines.department_code` has existed as long as the dimensions have,
and `app.create_gl_entry_internal` has always read `department_code`
off each line's JSON. Nothing sent it. The journal editor offered a
project per line and no department, so every cost a bookkeeper moved by
hand arrived with a null.

The fix was a picker and one key in a map. Per LINE and not per
journal, for the reason the project is: the entry that moves a cost
from Sales to Marketing touches both, and a header field could not say
so.

Because nothing in the database changed, nothing in the database would
notice if the app stopped sending it again — so it is asserted on both
sides, in `supabase/tests/pricing_and_dimensions.sql` and in
`app/test/journal_problem_test.dart`.

### Expenses: `0639`

`expenses` had a `project_code` and no department column at all, so
this one needed the schema. Both levels, mirroring `project_code`
exactly: the header's for a whole claim, `expense_lines.department_code`
for one line of a split, and `post_expense` coalesces the line over the
header.

`expenses.project_code` had also never been set by anything in the app,
so the expense editor gained both pickers in the same change.

**Two legs deliberately carry neither dimension**: the reclaimed input
tax and the payment out of the bank account. Neither is a departmental
cost, and giving them one would make every department's figures include
the SST it reclaimed and the cash it spent *on top of* the expense line
that is the actual cost — double counting, in a report whose whole
purpose is to attribute cost once.

Both are asserted, separately, and the tax one is the one that matters:
it is a DEBIT, so a rule written as "only debits carry a department"
passes the bank-leg assertion and still double-counts. A mutation sweep
over `0639` confirms it — six mutants, all killed, including one that
adds a department to the tax leg and one that adds it to the bank leg.

### Why this shape of gap is the worst shape

A department whose spending arrived through expenses or journals read as
a department that had **underspent**. An error that reads as an error
gets found; a missing figure that reads as a small figure reads as good
news, and nobody reports good news. That is why both halves are
asserted rather than simply written.

## Not done

- **No department on the balance sheet.** Splitting a balance sheet by
  department is a different report, not this one with a filter, and
  nothing here attempts it.
- **No default department per user or per item.** Every document is
  chosen fresh.
