# Modules and entitlement

A company buys the parts of this system it needs. `platform_modules` is
the price list, `org_modules` is what a company holds, and
`app.module_access(org, module)` is the function every RLS policy and
every module guard in the system asks.

## Two questions, and both have to be yes

- **Has the company bought this module?** A fact about the company, in
  `org_modules.is_enabled`, with `expires_at` for a trial.
- **Is this person allowed into it?** A fact about the person, through
  their access type in `access_type_modules`.

`module_access` asks them in that order, and the order matters: an owner
must not be able to reach a module the company does not hold. Asking
permission first would leave every owner and admin — the accounts most
worth protecting — with the run of everything on the price list.

Core modules (`sales`, `accounting`, `contacts`) skip the first
question. They are what the product *is* rather than what it sells, and
no organization has ever had an `org_modules` row for one.

## The hole this closed

Until `0232`, `module_access` never read `org_modules` at all. It went
straight from "is a member" to "is an admin" to the access type. So the
first question was asked only in the Flutter client, in
`enabledModulesProvider` — whose own comment said both questions had to
be yes, while only one of them was being asked anywhere the answer is
enforced.

Switching a module off therefore hid its screens and left its API open.
Measured on production before the fix: the warung's `payroll` row said
`is_enabled = false`, and `can_write_module(warung, 'payroll')` returned
**true**, as did `secretarial` and `legal`. Any member could have called
those functions directly from a terminal for features the company had
never paid for.

`CLAUDE.md` states the rule this broke: *a rule enforced only in Dart is
not enforced.*

It was found by a test. `0231` split loyalty and memberships into their
own modules and asserted that a company without loyalty cannot see a
card; the assertion failed, because no server-side code had ever cared
which modules a company held.

## Turning a check on without taking anything away

Enforcing a check that has never run can only remove access, so `0232`
fills the gap first: any module a company has data for — outlets,
tickets, employees, assets, purchase documents — and no enabled row is
switched on before the check starts biting. The list is written by hand
rather than derived, because "which table proves a module is in use" is
a judgement about the product that no catalogue query knows.

## What this means for tests

`pg_temp.test_org()` switches every module on. These files assert
business rules, not billing, and a fixture that said nothing would be a
fixture that cannot post a journal. A test *about* entitlement says so
by switching one back off, which is what `pos_loyalty.sql` does — and
then switches it on again as a positive control, because every refusal
it asserts would also hold if the function were simply broken.

## Entitlement, and the weaker idea beside it

`0234` adds a second question, and the value of it is entirely in not
mixing it up with the first:

- **Entitled** — the company holds the module. `app.has_module`, and
  through it `app.module_access` and every policy. Decides what the API
  answers.
- **Visible** — entitled, and the company has not put it away.
  `app.module_visible`, read only by the navigation and the dashboard.

Visibility is a preference and runs one way: hiding can take a door off
the wall, it can never open one. A company that hides `accounting` still
has a ledger, its tickets still post to it, and `module_access` still
says `write`. A company that never bought `payroll` still cannot call
`post_payroll_run`, whatever its preferences say — `set_module_hidden`
refuses a module the company does not hold and writes only `is_hidden`,
never `is_enabled`.

The reason it exists: a firm that bought Service Desk and nothing else
signed in to nineteen destinations that carried no module tag at all —
Sales, Expenses, Collections, Reconcile, Fixed assets, Journals,
Withholding tax, Reports — and a dashboard of four accounting figures,
all zero. Fourteen of those are fixed by tagging the destination.
`sales`, `accounting` and `contacts` cannot be, because they are core
and core means reachable without a row; those need a preference, and now
have one.

Hiding a core module writes the row core modules have never needed, with
`is_enabled = false` — which is exactly what a core module's row has
always meant: nothing. Entitlement goes on reading
`platform_modules.is_core`.

### Where each one is asked

| Question | Function | Read by |
|---|---|---|
| May this call succeed? | `app.module_access` → `app.can_read_module` / `can_write_module` | every RLS policy, every SECURITY DEFINER guard |
| Does the company hold it? | `app.has_module` | `module_access`, `set_module_hidden` |
| Does it belong on the rail? | `app.module_visible` → `public.org_module_surface` | `enabledModules()`, the navigation, `module_dashboard` |

### The dashboard

`public.module_dashboard(org)` returns one JSON object per visible
module that has figures worth a card, and omits the rest. A service desk
company gets `ticketing`; a warung gets `pos`; a company with books gets
neither and keeps the accounting dashboard it already had. The client
draws a card for each key it recognises and skips the rest, so a module
added to the function needs no client release to stop being wrong — only
one to start being shown.

### The five destinations that carry no module

Dashboard, Import, Team, Email and Settings. They are the workspace
rather than the product: a company that runs nothing but a service desk
still has people to invite and a company name to change. Settings in
particular must never be hideable — it is where a module that has been
put away is taken out again.
