import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/hr/talent_screen.dart';

/// The hiring pipeline, and the step that is not on it.
///
/// One decision lives only in this widget, and the source states it:
/// `hired` is deliberately NOT a stage. `0381` refuses a status of
/// hired with nobody on the payroll, because that is what used to
/// happen -- the label moved, and somebody typed the person into the
/// employee editor again from the record in front of them.
///
/// So the row offers ONE of two things and never both: "Move to
/// [next]" while there is a next stage, and "Hire" at the end, which
/// makes the employee record out of the candidate and links the two.
/// Offer "Move to hired" and the pipeline is back to where 0381 found
/// it; offer both and somebody presses the wrong one.
void main() {
  Applicant applicant({
    String id = 'a1',
    String name = 'Nurul Huda binti Rahman',
    String status = 'applied',
    String? hiredEmployeeId,
  }) => Applicant(
    id: id,
    fullName: name,
    status: status,
    hiredEmployeeId: hiredEmployeeId,
  );

  Widget wrap(List<Applicant> applicants, {String role = 'owner'}) =>
      ProviderScope(
        overrides: [
          applicantsProvider.overrideWith((ref) async => applicants),
          requisitionsProvider.overrideWith((ref) async => const []),
          appraisalsProvider.overrideWith((ref) async => const []),
          myAppraisalPartsProvider.overrideWith((ref) async => const {}),
          appraisalsDueProvider.overrideWith((ref) async => const []),
          memberRoleProvider.overrideWith((ref) async => role),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const TalentScreen(),
        ),
      );

  Future<void> show(
    WidgetTester tester,
    List<Applicant> applicants, {
    String role = 'owner',
  }) async {
    await tester.pumpWidget(wrap(applicants, role: role));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Candidates'));
    await tester.pumpAndSettle();
  }

  group('the next stage, and only the next one', () {
    testWidgets('every stage offers the one after it', (tester) async {
      // All five on screen at once rather than pumped in a loop: a
      // re-pumped ProviderScope reuses its elements and the second case
      // can show the first one's text.
      await show(tester, [
        applicant(id: 'a', name: 'A', status: 'applied'),
        applicant(id: 'b', name: 'B', status: 'screening'),
        applicant(id: 'c', name: 'C', status: 'interview'),
        applicant(id: 'd', name: 'D', status: 'assessment'),
      ]);

      expect(find.text('Move to Screening'), findsOneWidget);
      expect(find.text('Move to Interview'), findsOneWidget);
      expect(find.text('Move to Assessment'), findsOneWidget);
      expect(find.text('Move to Offer'), findsOneWidget);
    });

    testWidgets('a status of hired offers nothing, on or off the list',
        (tester) async {
      // 0381 refuses this row in SQL -- hired with nobody on the
      // payroll -- but the screen has to cope with one that predates
      // it, and it does: `indexOf` returns -1, so there is no next
      // stage and no Hire either.
      //
      // Deliberately NOT asserted as `textContaining('Move to Hired')
      // findsNothing`. That assertion cannot fail: adding 'hired' to
      // `_stages` is an EQUIVALENT mutant, because a candidate at
      // 'offer' takes the Hire branch first and never reaches the
      // advance one. What actually holds 0381's line is the branch
      // ORDER, asserted by "a candidate at offer is hired, not moved"
      // below.
      await show(tester, [applicant(status: 'hired')]);

      expect(find.textContaining('Move to'), findsNothing);
      expect(find.byKey(const ValueKey('hire-a1')), findsNothing);
      expect(find.text('Nurul Huda binti Rahman'), findsOneWidget);
    });

    testWidgets('a candidate at offer is hired, not moved', (tester) async {
      // The end of the pipeline. Hiring makes the employee record out
      // of this one and links the two, which advancing a label does
      // not.
      await show(tester, [applicant(status: 'offer')]);

      expect(find.byKey(const ValueKey('hire-a1')), findsOneWidget);
      expect(find.textContaining('Move to'), findsNothing);
    });

    testWidgets('and is offered one or the other, never both',
        (tester) async {
      // Two buttons side by side is how somebody presses the wrong one.
      await show(tester, [
        applicant(id: 'a', name: 'A', status: 'interview'),
        applicant(id: 'b', name: 'B', status: 'offer'),
      ]);

      expect(find.byKey(const ValueKey('advance-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('hire-a')), findsNothing);
      expect(find.byKey(const ValueKey('hire-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('advance-b')), findsNothing);
    });

    testWidgets('somebody already hired is offered neither', (tester) async {
      // `isHired` is `hiredEmployeeId != null` -- the link to the
      // payroll record, not the label. Offering Hire again makes a
      // second employee out of one person.
      await show(tester, [
        applicant(status: 'offer', hiredEmployeeId: 'emp-1'),
      ]);

      expect(find.byKey(const ValueKey('hire-a1')), findsNothing);
      expect(find.byKey(const ValueKey('advance-a1')), findsNothing);
      // The candidate is still listed: the record is what the employee
      // was made from.
      expect(find.text('Nurul Huda binti Rahman'), findsOneWidget);
    });

    testWidgets('and one hired mid-pipeline is not offered a move either',
        (tester) async {
      // A status that never reached 'offer' but a payroll link that
      // exists. The `!a.isHired` on the advance branch is what stops
      // the label walking on underneath a real employee.
      await show(tester, [
        applicant(status: 'interview', hiredEmployeeId: 'emp-1'),
      ]);

      expect(find.textContaining('Move to'), findsNothing);
      expect(find.byKey(const ValueKey('hire-a1')), findsNothing);
    });

    testWidgets('a status off the pipeline offers no move at all',
        (tester) async {
      // 'rejected' and 'withdrawn' are real statuses and are not
      // stages. `indexOf` returns -1, and a nudge from -1 would land on
      // 'applied' -- putting a rejected candidate back at the top of
      // the pipeline.
      await show(tester, [
        applicant(id: 'a', name: 'A', status: 'rejected'),
        applicant(id: 'b', name: 'B', status: 'withdrawn'),
      ]);

      expect(find.textContaining('Move to'), findsNothing);
      expect(find.byKey(const ValueKey('hire-a')), findsNothing);
    });
  });

  group('an empty pipeline', () {
    testWidgets('says what recording a candidate is worth', (tester) async {
      await show(tester, const []);

      expect(find.text('No candidates yet'), findsOneWidget);
      // The reason to fill it in: it is not re-keyed at the other end.
      expect(
        find.textContaining('comes across when they are hired'),
        findsOneWidget,
      );
    });
  });
}
