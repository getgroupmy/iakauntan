import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/hr/leave_screen.dart';

/// A line on the leave list, and the decision at the end of it.
///
/// `4bd1d7e` changed this row's trailing to `RowActions` on the
/// ARITHMETIC in `check_narrow_rows.py` rather than by rendering, and
/// said so. This is the confirmation that was owed.
///
/// "Reject" and "Approve" together are 168 pixels of labelled button.
/// A `ListTile` does not overflow when that leaves nothing for the
/// request's own line — it GIVES the title what is left and wraps it
/// one letter per line, a tall column of single characters pushing the
/// next row most of a screen down. That is the shape `row_actions.dart`
/// exists for, and its own header is about the items list where it
/// shipped.
void main() {
  LeaveRequest request({
    String id = 'lr1',
    String status = 'submitted',
    String employee = 'Puan Aminah',
    String type = 'Annual leave',
  }) => LeaveRequest(
    id: id,
    requestNo: 'LV-0001',
    startDate: DateTime(2026, 9, 14),
    endDate: DateTime(2026, 9, 18),
    totalDays: 5,
    status: status,
    employeeName: employee,
    leaveTypeName: type,
    reason: 'Balik kampung for the school holidays',
  );

  Widget harness(List<LeaveRequest> requests) => ProviderScope(
    overrides: [
      leaveRequestsProvider('submitted').overrideWith((ref) async => requests),
      leaveTypesProvider.overrideWith((ref) async => const []),
      myLeaveBalancesProvider.overrideWith((ref) async => const []),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const LeaveScreen()),
  );

  Future<void> show(
    WidgetTester tester,
    List<LeaveRequest> requests, {
    double width = 1400,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(requests));
    await tester.pumpAndSettle();
  }

  group('a leave line fits', () {
    for (final width in [1400.0, 1000.0, 800.0, 700.0, 600.0, 412.0, 360.0]) {
      testWidgets('at ${width.toInt()} wide', (tester) async {
        await show(tester, [request()], width: width);

        expect(find.byType(LeaveScreen), findsOneWidget);
      });
    }
  });

  group('deciding a request', () {
    testWidgets('is offered as buttons on a laptop', (tester) async {
      await show(tester, [request()]);

      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      expect(find.byKey(const ValueKey('leave-actions')), findsNothing);
    });

    testWidgets('and as one menu on a phone, with both still in it',
        (tester) async {
      // Folded, not dropped. Both halves of the decision have to remain
      // reachable, or a manager on a phone can only ever say yes.
      await show(tester, [request()], width: 412);

      expect(find.text('Approve'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('leave-actions')));
      await tester.pumpAndSettle();

      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
    });

    testWidgets('and is not offered at all on a decided request',
        (tester) async {
      // The control. `canDecide` is `status == 'submitted'`, and
      // offering Approve on something already approved is a second
      // decision the database would refuse.
      await show(tester, [request(status: 'approved')]);

      expect(find.text('Approve'), findsNothing);
      expect(find.byKey(const ValueKey('leave-actions')), findsNothing);
    });
  });
}
