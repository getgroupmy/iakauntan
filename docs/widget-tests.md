# Widget tests that actually ask something

Ten ways a Flutter widget test passes while asserting nothing. Every
one of them happened in this repository, was caught by mutation
testing, and is written down here so it is caught by reading next time.

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

## The ten

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

## Two more worth knowing

**Rendering at phone width is itself an overflow test.** A `RenderFlex`
overflow is a test failure in Flutter, so this needs no assertion:

```dart
await tester.binding.setSurfaceSize(const Size(393, 852));
addTearDown(() => tester.binding.setSurfaceSize(null));
```

The default surface is 800 wide and hides what a phone would show.
`check_narrow_rows.py` reads `trailing:` widgets only, so an
overflowing `title:` row is uncovered by it — `receipts_screen.dart`
had two.

**`Duration.inHours` truncates.** A fixture built exactly 70 hours out
is computed a moment later and arrives as 69. Build it 70 hours and a
half out, and say why.
