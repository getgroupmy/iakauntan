import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/time_terminals_repository.dart';
import 'package:iakauntan/src/features/hr/time_terminals_tab.dart';

/// The clocks on the walls, from HR's side.
///
/// `terminal_punches.sql` asserts what happens to a punch. This asserts
/// the two things this screen exists to say out loud, both of which are
/// quiet failures otherwise:
///
///   * a terminal nobody has enrolled anybody on will match every punch
///     it sends to nobody;
///   * punches that matched nobody are a day somebody is about to be
///     short, and the moment they find out is their payslip.
void main() {
  TimeTerminal terminal({
    String id = 't1',
    String name = 'Front door',
    bool active = true,
    int enrolments = 3,
    DateTime? lastSeen,
    DateTime? lastPunch,
  }) => TimeTerminal(
    id: id,
    name: name,
    isActive: active,
    enrolments: enrolments,
    lastSeenAt: lastSeen,
    lastPunchAt: lastPunch,
  );

  Widget harness({
    List<TimeTerminal> terminals = const [],
    List<UnmatchedPunch> unmatched = const [],
    List<TerminalEnrolment> enrolments = const [],
  }) => ProviderScope(
    overrides: [
      timeTerminalsProvider.overrideWith((ref) async => terminals),
      unmatchedPunchesProvider.overrideWith((ref) async => unmatched),
      terminalEnrolmentsProvider.overrideWith((ref, id) async => enrolments),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const TimeTerminalsTab(),
    ),
  );

  Future<void> wide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('reading a row', () {
    test('a terminal that has never spoken to us says so', () {
      // The figure that says a clock has stopped reporting before
      // anybody notices a missing day.
      expect(terminal().lastSeenAt, isNull);
    });

    test('last seen and last punch are different questions', () {
      // A device that reconnects after a weekend reports Friday's
      // punches today. Showing one as the other would say the clock is
      // three days behind when it is working perfectly.
      final t = TimeTerminal(
        id: 't',
        name: 'Gate',
        lastSeenAt: DateTime(2026, 3, 9, 9),
        lastPunchAt: DateTime(2026, 3, 6, 18),
      );
      expect(t.lastSeenAt, isNot(t.lastPunchAt));
    });

    test('an enrolment number keeps its padding', () {
      // Text, not an integer: the device wrote 0042 and that is what
      // somebody will be looking for on the device's own screen. The
      // DATABASE treats 0042 and 42 as one person; the display does not
      // have to invent a normalisation of its own.
      final e = TerminalEnrolment.fromJson({
        'id': 'e',
        'employee_id': 'x',
        'enrolment_no': '0042',
      });
      expect(e.enrolmentNo, '0042');
    });

    test('and an employee name comes through the embed', () {
      final e = TerminalEnrolment.fromJson({
        'id': 'e',
        'employee_id': 'x',
        'enrolment_no': '42',
        'employees': {'full_name': 'Aminah', 'employee_no': 'E1'},
      });
      expect(e.employeeName, 'Aminah');
      expect(e.employeeNo, 'E1');
    });
  });

  group('the screen', () {
    testWidgets('with no clocks, says what adding one gets you', (
      tester,
    ) async {
      await wide(tester);
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      expect(find.text('No clocks yet'), findsOneWidget);
      // The one thing somebody has to know before they press the
      // button, said before they press it.
      expect(find.textContaining('shown once'), findsOneWidget);
    });

    testWidgets('lists a terminal with what it has done', (tester) async {
      await wide(tester);
      await tester.pumpWidget(
        harness(
          terminals: [terminal(lastPunch: DateTime(2026, 3, 6, 18))],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Front door'), findsOneWidget);
      expect(find.textContaining('3 enrolled'), findsOneWidget);
    });

    testWidgets('and one that has never reported a punch says so', (
      tester,
    ) async {
      await wide(tester);
      await tester.pumpWidget(harness(terminals: [terminal()]));
      await tester.pumpAndSettle();

      // "no punches yet" beside a clock that was set up this morning is
      // ordinary; beside one set up last week it is the whole problem.
      expect(find.textContaining('no punches yet'), findsOneWidget);
      expect(find.text('Never Seen'), findsOneWidget);
    });

    testWidgets('a switched-off terminal is marked', (tester) async {
      await wide(tester);
      await tester.pumpWidget(harness(terminals: [terminal(active: false)]));
      await tester.pumpAndSettle();

      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('a terminal with nobody on it is told what that means', (
      tester,
    ) async {
      await wide(tester);
      await tester.pumpWidget(
        harness(
          terminals: [terminal(enrolments: 0, lastSeen: DateTime(2026, 3, 9))],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('terminal-t1')));
      await tester.pumpAndSettle();

      // Not "no enrolments" — what follows from it.
      expect(
        find.textContaining('every punch it sends will match nobody'),
        findsOneWidget,
      );
    });
  });

  group('punches that matched nobody', () {
    UnmatchedPunch punch(String no) => UnmatchedPunch(
      id: 'p$no',
      enrolmentNo: no,
      punchedAt: DateTime(2026, 3, 6, 8, 55),
      terminalName: 'Front door',
    );

    testWidgets('are their own card, not a footnote', (tester) async {
      await wide(tester);
      await tester.pumpWidget(
        harness(terminals: [terminal()], unmatched: [punch('99')]),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('unmatched-punches')), findsOneWidget);
      expect(
        find.textContaining('One punch in the last month matched nobody'),
        findsOneWidget,
      );
      expect(find.textContaining('user 99'), findsOneWidget);
    });

    testWidgets('and say what it costs the person', (tester) async {
      await wide(tester);
      await tester.pumpWidget(
        harness(terminals: [terminal()], unmatched: [punch('99')]),
      );
      await tester.pumpAndSettle();

      // The point of the card: somebody's day is short and they will
      // find out on their payslip unless this says so first.
      expect(find.textContaining('their day is short'), findsOneWidget);
    });

    testWidgets('with nothing to report the card is absent', (tester) async {
      await wide(tester);
      await tester.pumpWidget(harness(terminals: [terminal()]));
      await tester.pumpAndSettle();

      // Not an empty card saying "none". A card that is always there
      // is one nobody reads.
      expect(find.byKey(const ValueKey('unmatched-punches')), findsNothing);
    });

    testWidgets('a long list is trimmed and says how many are left', (
      tester,
    ) async {
      await wide(tester);
      await tester.pumpWidget(
        harness(
          terminals: [terminal()],
          unmatched: [for (var i = 0; i < 14; i++) punch('$i')],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('14 punches'), findsOneWidget);
      expect(find.textContaining('and 4 more'), findsOneWidget);
    });
  });
}
