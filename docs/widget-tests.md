# Widget tests that actually ask something

Ten ways a Flutter widget test passes while asserting nothing, and the
one thing to check before writing it at all. Every entry happened in
this repository, was caught by mutation testing, and is written down
here so it is caught by reading next time.

This is not a style guide. Each entry is a specific mechanism by which
a green test covers a broken screen.

## How they were found

Write the test, watch it pass, then **break the code on purpose and
watch the test fail**. If it still passes, the assertion was not asking
the question you thought.

```sh
python3 scripts/mutate.py \
  lib/src/features/stock/lots_screen.dart \
  test/lots_screen_test.dart \
  /tmp/lots_mutants.py
```

The first two paths are relative to `app/`; the third is the mutant
list, which is scratch and does not belong in the repository.

`mutants.py` is a list of `m("name", old, new)` calls, each a one-line
change to the source. Every real mutant should fail the test; the run
is only trustworthy if it also contains a **no-op control** that does
not — twice this session a broken harness reported every mutant as
killed because the test file path was wrong and every run errored
identically.

The harness mutates **one file**. Logic that lives in `models.dart` —
`LeaveBalance.available`, `Todo.isOverdue`, `EinvoiceDocument.canCancel`
— needs its own run against that file.

## The twelve

### 1. `find.byType` matches the exact runtime type

`FilledButton.icon`, `OutlinedButton.icon` and `TextButton.icon` build
private subclasses. `find.byType(FilledButton)` does **not** match
them, so `widgetWithText(FilledButton, 'Save')` finds nothing with the
button on screen — and the `findsNothing` assertion beside it passes
against a screen that always shows it.

Assert on the text, or use
`find.byWidgetPredicate((w) => w is FilledButton)`.

This one hid a real behavioural mutant: a voided journal offered for
reversal a second time.

### 2. Present is not the same as positioned

Debit and credit are two cells holding the same `Money` widget.
`find.text('RM 900.00')` finds the figure in either of them, so
swapping the columns — a journal saying the opposite of what was
posted — passes every count.

Use `tester.getCenter(finder).dx` for columns and `.dy` for list order.
A list re-sorted in the widget contains all the same names.

### 3. Two realistic fixtures can hide a bug between them

A journal that balances makes `total_debit` and `total_credit` the same
number. A reconciled bank account makes `expected_statement` and
`statement_balance` the same number. In both cases a row wired to the
WRONG key renders an identical page.

Use the unbalanced, unreconciled, mid-failure case deliberately. It is
also the case somebody opens the screen for.

### 4. A fixture that violates a SQL invariant fails for the wrong reason

`report_collections` returns `never_chased` as `(l.contact_id is null)`
on the same left join that produces `last_attempt_on`, so they are one
fact. A fixture with neither is not a row the database can return, and
the screen's `DateTime.parse(last!)` throws a `TypeError` that says
nothing about the screen.

Encode the invariant in the fixture helper and quote the migration that
establishes it.

### 5. Repainted is not re-queried

Changing "Within 90 days" to 30 moves the chip and rewords the empty
message. A screen that only calls `setState` does both — and leaves the
list underneath as the answer to the old question.

Record the argument in the fake repository and assert it:

```dart
expect(repo.lastWithinDays, 30);
```

### 6. Some behaviour is invisible to a screenshot

A billed timesheet row and an editable one look identical; the
difference is `ListTile.onTap` being null. A finished to-do's overdue
flag reaches the row only through the subtitle's **colour**, because
the text comes from the "Done" branch either way.

Read the property off the widget:

```dart
tester.widget<ListTile>(finder).onTap            // null means not editable
(tile.subtitle as Text?)?.style?.color           // null means not late
```

### 7. `textContaining` on a prefix asks nothing

Three separate times:

- `'Puan Aminah · 14/09/2026'` matched a row rendering the literal word
  **`null`** on the end — Dart interpolates a null field as four
  letters, which is not whitespace and survives a `trim().isNotEmpty`
  filter.
- `'Invoice · X'` matched **`Self-billed Invoice · X`**, so an
  assertion meant to tell two LHDN document types apart found both.
- `'Every day'` matched **`Every days`**, so a mutant dropping every
  singular form passed all eight cadences.

Use `find.text` with the exact string, or include the separator that
follows: `find.textContaining('Every day · ')`.

The mirror of this is a check for a **doubled separator** — `'·  ·'` —
meant to catch a field that rendered empty. Four tests here had one and
in three of them nothing could ever produce a doubled separator,
because the `.where(isNotEmpty)` before the join drops an empty entry
first. In the fourth the real damage was a LEADING separator,
`'  ·  20 to make'`, which the doubled check does not match either.

Assert the whole line. It fails when a field goes missing, when one
appears that should not, and when a separator lands anywhere at all.

### 8. A `?? default` in a fixture helper undoes the null case

`myEmployeeProvider.overrideWith((ref) async => me ?? employee())`
turns "this login has no employee record" back into an ordinary
employee, so the empty-state test fails against a screen that works.

Use an explicit flag, not a nullable parameter.

### 9. Two assertions either side of a behaviour do not pin it

"A high priority task is flagged" and "a finished one is not" both pass
against a screen that flags **every unfinished task**. The case that
separates them is an ordinary open one, and it has to be written.

Every conditional needs its control: the card that must be absent, the
clause that must not appear, the chip that carries neither state.

### 10. Re-pumping a `ProviderScope` reuses the elements

A loop of `pumpWidget` cases can go on showing the previous case's
text, which reads as a failure of the code rather than of the test.

Put every case on one screen as separate rows instead. It is also the
stronger assertion: each must be distinguishable from the others beside
it.

### 11. Opening it with nothing in it

The eleventh way, and it is the newest because it was found emptying
`check_dialogs_built.py`'s backlog. **All fifty remaining dialogs opened
cleanly at 412x900 with every provider answering `const []`.** Fifty
tests, fifty passes, and nothing learned: an empty list draws an
`EmptyState`, and an `EmptyState` is one icon and two centred sentences
that cannot overflow anything.

Feeding each one **a single realistic row** broke two of them
immediately. `credit_ledger_dialog.dart` has a totals line —
`Expanded(Text(...))` beside an unflexed `Text` of two money figures —
that *does not exist at all* in the empty state that had been "tested";
with one movement in the ledger it overflowed by 46 pixels. And the
collections sheet threw `Null is not a subtype of String` on a cast,
because the test had invented `attempted_at` where the query selects
`attempted_on` — a dialog fed a shape the database never sends.

What "realistic" has to mean:

- **A long name.** `'Perniagaan Sinar Teknologi Maju Bersatu Sdn Bhd'`,
  not `'Test'`. Malaysian company names run like that, and a short
  string is the same lie as an empty list.
- **The column names the repository actually selects.** Read the method,
  do not guess from the screen. A wrong key is a null, a null is either
  a silent blank or a cast that throws, and neither tells you anything
  about the dialog.
- **Figures with digits in them.** Two five-figure totals are wider than
  two zeros, and the width is the thing under test.

One caveat, stated because it would otherwise be over-claimed: the test
font draws every glyph at a full em, so text in a widget test is wider
than the same text in Roboto. The credit-ledger totals line fits on a
real phone *today*; it would not with two five-figure totals and a large
system font scale. Treat an overflow found this way as a latent
fragility to make unbreakable — `Flexible` costs nothing — rather than
as a bug already in front of a customer.

### 12. A fixture that collapses the thing under test into one row

The twelfth, and the first that is about SQL rather than Dart — kept
here because the shape is the same and this is where people look.

`0727` closed one place where a posting function, handed no bank
account, credited account **1120** instead. 1120 is "Bank Accounts":
postable, but the HEADING that `upsert_bank_account` hangs the real
accounts beneath in the range 1121-1199. `0728` then found the same
fallback in five more functions.

With 382 assertion files running in CI, not one had noticed — because
every fixture that needed a bank account wrote

    insert into public.bank_accounts (org_id, account_id, ...)
    values (v_org, (select id from public.accounts
                     where org_id = v_org and code = '1120'), ...)

hanging it on 1120 ITSELF. So "the function used the account it was
handed" and "the function fell through to the heading" were the same
row, and nothing could tell them apart. `deposits.sql` even asserted
*"the money leaves the bank"* by checking the credit on
`code = '1120'`, which was true either way.

The lesson generalises past bank accounts: **a fixture that makes the
correct value and the fallback value identical cannot test which one
was used.** It is the SQL twin of entry 8 — a `?? default` in a fixture
helper undoing the null case — and of entry 11, where every provider
answering `const []` made fifty dialogs indistinguishable.

The remedy is a fixture that distinguishes them. `_helpers.sql` now has
`pg_temp.test_bank_account(org, ...)`, which does what the real path
does — the next free code in 1121-1199, a child of 1100, the bank
account on that — `pg_temp.a_bank_account(org)`, which reuses the one
already there, and `pg_temp.bank_gl(bank)`, which hands back the ledger
account behind one. Use them, and then an assertion can say WHICH
account was debited and mean it.

**`0730` finished the sweep**, because a trigger refusing a new bank
account on the heading cannot be added while the fixtures depend on
one: its first run failed 23 of the 382 files. Writing them the right
way round then found four more defects of exactly this kind, in
fixtures nobody was suspicious of — a law firm's office account on 1100
"Cash and Bank", the parent of its own client account; a bank account
on **1000**, the root of the asset side, chosen by
`account_type = 'asset' limit 1`; a card and a current account sharing
one ledger account, in the file asserting which of them the money was
banked against; and an opening trial balance whose "current account"
was on 1110 Cash in hand while its "petty cash" was on the bank
heading, each name pointing at the other one's account.

So the shape is not rare and it is not only about 1120. **When a
fixture picks an account with `limit 1`, a `case`, or a code that is
the parent of the right answer, the test cannot see the difference it
was written to see.** Read what the fixture actually selected.

## Before you write the test, read the SQL it has to agree with

The most expensive defect found this way was not a vacuous assertion.
It was a Dart getter that disagreed with the database.

`BusinessDocument.isOverdue` compared `dueDate` — a date column, so
midnight — against `DateTime.now()`. From 00:01 on the day an invoice
fell due, the document list showed a red "overdue" chip. `v_ar_aging`,
which the aging report, the collections worklist and every statement
are built from, says:

    when d.due_date is null or current_date <= d.due_date
      then 'current'

One day wide, every invoice, every day of the year, and two screens
quoting different answers down the phone. It was found by reading the
view BEFORE writing the test, then writing the test to say what the
view says. Exactly one case failed.

So: when a getter restates a rule the database also holds, open the
migration. Six have been checked, and two of them were wrong:

| Getter | What it is compared against | Verdict |
|---|---|---|
| `BusinessDocument.isOverdue` | `v_ar_aging` aging bucket | **disagreed**, fixed |
| `CorpOfficer.licenceLapsed` | `licence_expires_on`, a `date` | **disagreed**, fixed |
| `Item.isLowStock` | the `low_stock` count in `0014` | agrees, `track_inventory` and all |
| `EinvoiceDocument.canCancel` | `set_einvoice_cancel_deadline` | agrees; reads the stored deadline rather than recomputing it, and LHDN is the real gate |
| `PayslipAccessRequest.hasLapsed` | `expires_at`, a `timestamptz` | agrees — a moment compared to a moment |
| `Contact.readyForEinvoice` | `coalesce(nullif(tin, ''), app.general_public_tin())` | no conflict — the Dart WARNS, the SQL substitutes the general-public TIN |

The pattern to look for is a getter that recomputes rather than reads.
`canCancel` is safe because the 72 hours are set by a trigger and
stored; `isOverdue` was not because it worked the comparison out again,
in a different unit, on the other side of the wire.

**And the unit is the tell.** A `date` column arrives as MIDNIGHT.
Compared against `DateTime.now()` it is true from 00:01 on the day
itself, so every such getter is a day early — the invoice due today
reads overdue, the licence expiring today reads expired. A
`timestamptz` compared to `DateTime.now()` is right, which is why
`canCancel` and `hasLapsed` are fine and the other two were not.

So the check is one line of grep and then one line of SQL:

```sh
grep -rn 'isBefore(DateTime.now())\|isAfter(DateTime.now())' lib/src/data/
grep -rn '<column_name>' supabase/migrations/   # date, or timestamptz?
```

Three hits in this app, and the one against a `date` column was the
bug. It had shipped for a year, on every company secretary's licence,
raising "the company has no validly appointed secretary" in the danger
colour one day early.

## A test double cannot intercept an extension method

`_FakeRepo implements Repo` with a `noSuchMethod` that throws is the
test double this repository uses everywhere, and it has a hole in it
that reports nothing.

About half of `Repo`'s surface is not on the class. It is on
`extension RepoExtras on Repo`, `extension RepoGroupContacts on Repo`
and a dozen more, which is how a 12,000-line repository is kept in
readable pieces. A Dart extension method binds to the STATIC type of
the receiver, so it is not a virtual call and there is nothing to
override:

```dart
class _FakeRepo implements Repo {
  @override                                    // the analyzer says this
  Future<void> addTimeEntry({...}) async {}    // is not an override
}
```

With the `@override` the analyzer catches it — `override_on_non_overriding_member`,
which is a warning and `--fatal-warnings` makes it a build failure.
WITHOUT the annotation nothing says anything at all. The method sits
there looking like a stub, the real extension body runs against the
fake, reaches `client` or `callRpc`, and either throws into whatever
catches errors on that screen or does something worse.

Both halves of that happened in one afternoon:

  * `contact_credit_limit_test.dart` declared `linkGroupContact`, which
    is on `RepoGroupContacts`. The real body ran, hit `callRpc` on the
    fake, threw, and `runWithFeedback` caught it — so the form showed a
    failed save while every assertion in the file passed, because they
    all read a field set earlier in `_save`.
  * `matter_client_ledger_test.dart` tried the same for `addTimeEntry`
    and never saw the call.

Two rules follow.

**Check where a method is declared before faking it.** If it is inside
an `extension ... on Repo`, a double cannot see it; answer the thing
the extension body calls instead (`callRpc`, usually) and assert
somewhere else.

**Assert something the whole action produces, not only a field set
partway through it.** `expect(repo.saved, ...)` is true the moment the
first call lands. `expect(find.text('Contact saved'), findsOneWidget)`
is true only if the action finished.

### And the mirror image: answering `callRpc` is not enough either

The advice above — "answer the thing the extension body calls instead,
`callRpc`, usually" — is right for an extension method and **silently
wrong for a method on the class.** `implements Repo` INHERITS NO
BODIES. A double that answers only `callRpc` sends every other member
to `noSuchMethod`, so a class method never runs and never reaches the
RPC it would have made.

`remit_withholding` is where this was met. The fake answered `callRpc`
and recorded nothing, because `Repo.remitWithholding` — declared on the
class, not in an extension — went to `noSuchMethod` and threw. The
throw was caught by `runWithFeedback`, which drew its error snackbar,
and the only visible symptom was an assertion failing on an empty list.

So the question is not "is this an extension method" but **"will this
member's body actually run against my double"**, and the answer differs
for the two halves of the same class:

| declared | a double that answers `callRpc` | what to do |
| --- | --- | --- |
| `extension ... on Repo` | real body runs, reaches `callRpc` | assert on the RPC |
| `class Repo` | `noSuchMethod`, body never runs | override the method and record its ARGUMENTS |

Overriding the method means the test no longer proves how its arguments
become RPC parameters. Say so where the override is: that mapping wants
a `SupabaseClient` nobody has in a widget test, so it belongs to the
SQL assertions, and a test file that quietly loses the claim is worse
than one that names the seam.

## An unanswered method channel does not fail, it stops

A `testWidgets` case that reaches a platform channel nobody has mocked
**hangs**. The message is handed to a platform that is not there, the
reply never arrives, and because `testWidgets` runs under fake async
there is nothing to time it out: the test does not fail, it stops, and
the run sits there until the job's own timeout kills it with no failing
assertion to look at.

That is how it was found. `notifications_card_test.dart` had a case
asserting that a device with no native half reports `unsupported`, and
it passed for months because `push_native.dart` answered `unsupported`
for Android in DART, without crossing the channel. The moment Android
gained a native half, the same test on the same line went from passing
in a millisecond to running for ten minutes.

Two things follow:

* **Mock the handler to throw, rather than leaving it absent.** A
  handler that throws `MissingPluginException` is what a missing
  plugin actually looks like to Dart, and it answers.

  ```dart
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        pushChannel,
        (call) async => throw MissingPluginException(call.method),
      );
  ```

* **A plain `test` is the better home for channel work.** Real async,
  no pumping, and `push_native_test.dart` is the file that does it that
  way — which is why the assertion now lives there.

A VM widget test is `defaultTargetPlatform == android`, so this is not
a rare corner: any code that newly reaches a channel on Android reaches
it from every widget test that renders the widget containing it.

## Four more worth knowing

**Rendering at phone width is itself an overflow test.** A `RenderFlex`
overflow is a test failure in Flutter, so this needs no assertion —
but there are two ways to make the screen narrow and only one of them
works:

```dart
tester.view.devicePixelRatio = 1.0;          // this one
tester.view.physicalSize = const Size(393, 852);
addTearDown(tester.view.reset);

await tester.binding.setSurfaceSize(const Size(393, 852));   // not this one
```

`setSurfaceSize` resizes the RENDER SURFACE, so it does catch an
overflow. It does NOT move `MediaQuery`, which goes on reporting 800 —
so every `MediaQuery.sizeOf(context).width < 700` in the app still
takes the DESKTOP branch, and a test asserting the narrow one is
asserting against a layout that is not on the screen. Fourteen files
here branch on that expression. `tester.view.physicalSize` drives both,
and forty-odd tests already use it; the shorter call is the trap.

The default surface is 800 wide and hides what a phone would show.
`check_narrow_rows.py` reads `trailing:` widgets only, so an
overflowing `title:` row is uncovered by it — `receipts_screen.dart`
had two and `document_list_screen.dart` had a third.

**An overflow sweep is worth more than one phone-width test.** The
document list takes a document type, a role and a width, and the app
bar it builds is different for each. One screenshot at 393 found one of
three overflows; a loop over 5 types × 2 roles × 7 widths found all of
them, and is what now holds the two width constants in that screen
honest. It costs seventy tests that assert nothing but `findsOneWidget`
on the screen itself — the failure is the overflow.

**`Duration.inHours` truncates.** A fixture built exactly 70 hours out
is computed a moment later and arrives as 69. Build it 70 hours and a
half out, and say why.

**A button gated on a `TextEditingController` never wakes up.** This
shape is a dead button:

```dart
late final _name = TextEditingController();
...
FilledButton(
  onPressed: _name.text.trim().isEmpty ? null : _save,
```

The gate is evaluated in `build`, and typing into a `TextField` does
not rebuild its parent. Nothing listens, so the button stays grey
however much is typed. It wakes only if something ELSE calls
`setState` — a switch, a picker — which is why it can look like it
works: on `stalls_screen.dart` the operator picker rebuilt the form, so
saving a stall worked if the operator was chosen LAST and not if it was
chosen first. On `provider_roster_screen.dart` nothing else was
required at all and adding a person was simply impossible.

`addListener` in `initState`, removed in `dispose`; or `onChanged: (_)
=> setState(() {})` on the field, which `company_card.dart` already
does.

A widget test catches this and nothing else does: the analyzer sees a
valid tree, and a static check over the eleven places this app reads
`controller.text` in a `build` gets nine of them wrong — the other nine
read it inside an `onPressed` closure, which runs later and is correct.
So the test is to TYPE into every box the gate names, one at a time,
and assert the button after each. The one that matters is the last
keystroke before it should go live.

## A surviving mutant can be a mutant of a different function

`scripts/mutate.py` applies each mutant with `text.replace(old, new, 1)`
— **once, at the first match**. So a pattern that matches two places in
the file mutates the one nearer the top, and if the test under it does
not cover that one, the mutant survives and the report names the
function you meant.

`statement_import.dart` holds two statement parsers, and both contain,
verbatim:

```dart
    if (date == null) {
      problems.add(
```

A mutant anchored on those two lines and aimed at `scannedStatement`
landed in `parseCsvStatement`, whose branch the test file does not
reach, and the harness printed

    a row with no date is skipped silently instead of reported  passed

for a function whose assertion was there and correct all along. **The
control cannot catch this**: the control applied cleanly and the
baseline passed. Nor does hand-applying the mutant to "check the
harness" — that means pasting the same ambiguous pattern into the same
editor and hitting the same first match, which reproduces the survival
and reads as confirmation.

The harness now refuses an ambiguous pattern rather than guessing:

    <name>   HARNESS ERROR: pattern matches 2 places; extend it until it matches one

and a run with any un-applied mutant says so under **NOT RUN** and
exits 1, because "every mutant killed" over a mutant that never ran is
the same lie the control exists to catch. `apply_once` and the four
assertions on it are in `scripts/mutate_test.py`.

The fix, when you hit it, is to extend the pattern by one line until it
is unique — not to mutate every match, which is a different and weaker
experiment.

## `check_narrow_rows.py` measures two things as zero, and it is not fixable in the estimate

That script exists because three overflows shipped, and it catches the
shape it was written for. It did not catch a fourth, on
`matters_screen.dart`, which went 37 pixels off a 412px phone while the
script called the row clean. Both halves of its estimate read zero:

- **A bare `Text(matter.matterNo)`** is neither a string literal nor an
  interpolation — no quotes, no `$` — so `text_width` counts nothing.
  `'${matter.matterNo}'` would have been counted at 64px.
- **A trailing `Column` whose second line is a bare `Text`** is counted
  by its `Money` alone. On this row that second line read
  `RM 2,400.00 unbilled` and was the WIDER of the two, so the thing
  deciding the trailing's width contributed nothing to the estimate.

Counting a bare expression as an unknown was tried and does not close
it: the title side then measures 152px against an estimated 202px of
room, and it still passes, because the room is the number that is
wrong. Making the trailing estimate honest means measuring arbitrary
Dart, which is where a rough static estimate stops being rough and
starts being a layout engine.

**It then happened again, identically.** `_RunTile` in
`payroll_screen.dart` — a run number and a status chip against a
net-pay figure with "net pay" under it — went 55 pixels off the same
phone, and the gate passed it for the same two reasons. Two instances
of one shape, both found by pumping and neither by the estimate, is
the argument this section is making.

So this is a limit to know rather than a bug to fix. **The thing that
catches it is building the screen at 412x900**, where a `RenderFlex`
overflow is a test failure with no assertion required. The gate narrows
the field; it does not replace the pump. Every screen that comes off
the `check_screens_built.py` backlog should come off it at phone width
for exactly this reason — two of the last three defects found that way
were overflows neither gate saw.
