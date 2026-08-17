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

## Not done

- **Expenses and manual journals still do not offer a department.**
  `expenses` has a `project_code` column and no department one at all;
  `gl_lines` written by hand through the journal editor could carry a
  department but the editor does not ask. The P&L will therefore
  under-report costs that arrive by those two routes.
- **No department on the balance sheet.** Splitting a balance sheet by
  department is a different report, not this one with a filter, and
  nothing here attempts it.
- **No default department per user or per item.** Every document is
  chosen fresh.
