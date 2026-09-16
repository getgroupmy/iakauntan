import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/hr/employee_records.dart';

/// A dependant's share of a tax relief.
///
/// `relief_claim_percent` is a multiplier on somebody's income tax.
/// `calc_pcb` — in `0030` and unchanged in shape through `0446` —
/// computes a child's relief as
///
///     sum(case
///           when d.is_disabled and d.in_higher_education then 8000
///           when d.is_disabled then 6000
///           when d.in_higher_education then 8000
///           else 2000
///         end * d.relief_claim_percent / 100)
///
/// The column is `numeric(5, 2) not null default 100` with no check
/// constraint, so the database takes 150 or -50 without a word.
///
/// The box had no validator at all: a bare `TextField`, in a dialog
/// with no `Form`, read at save time as `double.tryParse(text) ?? 100`.
/// So a parent claiming half who typed "50%" — into a box whose own
/// suffix is `%` — got ONE HUNDRED. The whole relief instead of half,
/// silently, and PCB under-withheld for the rest of the year.
///
/// Under-withholding is the direction that matters: it is discovered by
/// the employee, at the end of the year, as a bill.
void main() {
  group('the rule', () {
    test('an ordinary share is accepted', () {
      expect(dependantReliefProblem('50'), isNull);
      expect(dependantReliefProblem('100'), isNull);
      expect(dependantReliefProblem('33.33'), isNull);
      expect(dependantReliefProblem('0'), isNull);
    });

    test('and so is one typed with the sign the box itself shows', () {
      // The reported shape. The field's suffix is `%`, so typing it is
      // the obvious thing to do.
      expect(dependantReliefProblem('50%'), isNull);
      expect(dependantReliefProblem(' 50 % '), isNull);
    });

    test('text that is not a figure is refused, not read as the whole '
        'claim', () {
      expect(dependantReliefProblem('half'), isNotNull);
      expect(dependantReliefProblem('5O'), isNotNull); // letter O
      expect(dependantReliefProblem('50,5'), isNotNull);
    });

    test('an empty box is refused rather than assumed', () {
      // It is always pre-filled, so an empty one is somebody who
      // cleared it and meant to type something. Reading that as 100 is
      // the same silent substitution by another route.
      expect(dependantReliefProblem(''), isNotNull);
      expect(dependantReliefProblem('   '), isNotNull);
    });

    test('a share outside nought to a hundred is refused', () {
      // Two parents split one child's relief. More than the whole claim
      // is not a share, and the column would take it.
      expect(dependantReliefProblem('150'), contains('more than'));
      expect(dependantReliefProblem('100.01'), isNotNull);
      expect(dependantReliefProblem('-50'), contains('below zero'));
    });

    test('the refusal says what a share looks like', () {
      // Somebody who has just been refused needs an example, not a
      // restatement of the rule.
      expect(dependantReliefProblem('half'), contains('50'));
    });
  });

  group('the figure that reaches the database', () {
    Map<String, dynamic> row(String reliefTyped, {bool claimed = true}) =>
        dependantValues(
          employeeId: 'e1',
          name: '  Nur Aisyah  ',
          relationship: 'child',
          nric: '',
          dateOfBirth: null,
          isDisabled: false,
          inHigherEducation: false,
          isTaxDependant: claimed,
          reliefTyped: reliefTyped,
        );

    test('is the share that was typed', () {
      expect(row('50')['relief_claim_percent'], 50);
      expect(row('33.33')['relief_claim_percent'], 33.33);
      expect(row('0')['relief_claim_percent'], 0);
    });

    test('including one with the per-cent sign, which the box allows', () {
      // The two parsers DISAGREE here, which is why this is asserted on
      // the payload and not only on the validator.
      // `dependantReliefProblem` accepts "50%" — the box's own suffix is
      // a per-cent sign — and `double.tryParse('50%')` is null, which
      // the `?? 100` behind it would turn into the whole claim.
      expect(row('50%')['relief_claim_percent'], 50);
      expect(double.tryParse('50%'), isNull);
    });

    test('and the rest of the row is what was typed too', () {
      final r = row('50');

      expect(r['name'], 'Nur Aisyah');
      expect(r['nric'], isNull);
      expect(r['is_tax_dependant'], isTrue);
      expect(r['relationship'], 'child');
    });
  });

  group('and the dialog uses it', () {
    // The mutant a test of the rule alone cannot kill: the function can
    // be perfect and the box can still have no validator on it, which
    // is the defect exactly as it shipped.

    Widget wrap(List<Map<String, dynamic>> dependants) => ProviderScope(
      overrides: [
        employeeRowsProvider((
          table: 'employee_dependants',
          employeeId: 'e1',
          select: '*',
          orderBy: 'name',
        )).overrideWith((ref) async => dependants),
        repoProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(child: EmployeeRecords(employeeId: 'e1')),
        ),
      ),
    );

    Future<void> openDependant(WidgetTester tester, String name) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap([
        {
          'id': 'd1',
          'name': name,
          'relationship': 'child',
          'is_tax_dependant': true,
          'relief_claim_percent': 50,
        },
      ]));
      await tester.pumpAndSettle();
      // The row loaded, rather than an error panel behind it.
      expect(find.text(name), findsOneWidget);
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    testWidgets('a share it cannot read is refused on the screen',
        (tester) async {
      await openDependant(tester, 'Nur Aisyah');

      final box = find.ancestor(
        of: find.text('Share of the claim'),
        matching: find.byType(TextFormField),
      );
      expect(box, findsOneWidget, reason: 'the box is a form field');

      await tester.enterText(box, 'half');
      await tester.pump();

      expect(find.text('Enter a percentage, such as 50.'), findsOneWidget);
    });

    testWidgets('and one with the per-cent sign on it is not', (tester) async {
      await openDependant(tester, 'Nur Aisyah');

      await tester.enterText(
        find.ancestor(
          of: find.text('Share of the claim'),
          matching: find.byType(TextFormField),
        ),
        '50%',
      );
      await tester.pump();

      expect(find.text('Enter a percentage, such as 50.'), findsNothing);
    });

    testWidgets('and Save does not go through with a share it refused',
        (tester) async {
      // The validation GATE, not the message. Without
      // `_formKey.currentState!.validate()` in `_save`, the dialog
      // reports the problem in red and saves anyway.
      //
      // Observed through the repository being null in this harness: a
      // save that proceeds reaches `ref.read(repoProvider)!`, throws,
      // and `runWithFeedback` puts the failure in a snackbar. A save
      // that was refused returns before any of that.
      await openDependant(tester, 'Nur Aisyah');

      await tester.enterText(
        find.ancestor(
          of: find.text('Share of the claim'),
          matching: find.byType(TextFormField),
        ),
        'half',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(SnackBar), findsNothing,
          reason: 'the save never started');
      expect(find.text('Enter a percentage, such as 50.'), findsOneWidget);
    });

    testWidgets('the stored share is what the box opens on', (tester) async {
      // Not the 100 the old code fell back to.
      await openDependant(tester, 'Nur Aisyah');

      final field = tester.widget<TextFormField>(
        find.ancestor(
          of: find.text('Share of the claim'),
          matching: find.byType(TextFormField),
        ),
      );
      expect(field.controller!.text, '50');
    });
  });
}
