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
