import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/features/hr/statutory_remittances_screen.dart';

/// What a posted payroll leaves owing, and to whom, as the screen shows it.
///
/// The arithmetic is the database's and is asserted there. What is only
/// here is the PRESENTATION of it, and this screen presents four things
/// that a person acts on with a bank transfer:
///
///   * one card per month the wages were PAID, because a single payment
///     to each body covers a month. Two months merged into one card is
///     a transfer for the wrong amount.
///   * the employee and employer halves, both of them. The screen's own
///     comment names the failure: "the deducted half on its own is the
///     amount that gets a company short-paid every month".
///   * the total, which is what gets typed into the bank.
///   * whether it is overdue, and whether it has already been sent.
///
/// None of that is reachable from the SQL suite, and a widget that
/// quietly showed one half of a contribution would look entirely
/// normal.
void main() {
  // Two bodies in one month and one in the next, so grouping is tested
  // by a fixture that would collapse if it were done on the wrong key.
  Map<String, dynamic> row({
    required String period,
    required String name,
    required String authority,
    num employee = 0,
    num employer = 0,
    num total = 0,
    String payDate = '2026-01-05',
    String? dueDate = '2026-02-15',
    String? paidOn,
    String? reference,
    bool overdue = false,
  }) => {
    'period_id': period,
    'period_code': period,
    'pay_date': payDate,
    'due_date': dueDate,
    'is_overdue': overdue,
    'name': name,
    'authority': authority,
    'employee_amount': employee,
    'employer_amount': employer,
    'total_amount': total,
    'paid_on': paidOn,
    'reference': reference,
  };

  Widget wrap(List<Map<String, dynamic>> rows, {bool canRun = true}) =>
      ProviderScope(
        overrides: [
          statutoryRemittancesProvider.overrideWith((ref) async => rows),
          canRunPayrollProvider.overrideWithValue(canRun),
        ],
        child: const MaterialApp(home: StatutoryRemittancesScreen()),
      );

  testWidgets('nothing owed says a calculated run is not a posted one', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const []));
    await tester.pumpAndSettle();

    expect(find.text('Nothing owed yet'), findsOneWidget);
    expect(find.textContaining('has to be posted'), findsOneWidget);
  });

  testWidgets('one card per month the wages were paid', (tester) async {
    await tester.pumpWidget(
      wrap([
        row(period: '2026-01', name: 'EPF', authority: 'KWSP', total: 1100),
        row(period: '2026-01', name: 'SOCSO', authority: 'PERKESO', total: 90),
        row(
          period: '2026-02',
          name: 'EPF',
          authority: 'KWSP',
          total: 1200,
          payDate: '2026-02-05',
          dueDate: '2026-03-15',
        ),
      ]),
    );
    await tester.pumpAndSettle();

    // Two months, two cards. Grouped on the wrong key this is one card
    // reading RM 2,390.00 -- a single transfer covering two months,
    // sent to a body that reconciles them separately.
    expect(find.textContaining('2026-01 ·'), findsOneWidget);
    expect(find.textContaining('2026-02 ·'), findsOneWidget);
    expect(find.textContaining('Total RM 1,190.00'), findsOneWidget);
    expect(find.textContaining('Total RM 1,200.00'), findsOneWidget);
  });

  testWidgets('both halves of a contribution, not just the deducted one', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap([
        row(
          period: '2026-01',
          name: 'EPF',
          authority: 'KWSP',
          employee: 400,
          employer: 700,
          total: 1100,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    // The named failure: showing RM 400.00 alone is the figure that
    // short-pays KWSP by seven hundred ringgit every month.
    expect(
      find.textContaining('employee RM 400.00 + employer RM 700.00'),
      findsOneWidget,
    );
    expect(find.textContaining('RM 1,100.00'), findsWidgets);
  });

  testWidgets('a body with no statutory date says so rather than inventing one',
      (tester) async {
    await tester.pumpWidget(
      wrap([
        row(
          period: '2026-01',
          name: 'HRD Corp',
          authority: 'HRDF',
          total: 50,
          dueDate: null,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('no statutory date — by arrangement'),
      findsOneWidget,
    );
  });

  testWidgets('one late body marks the whole month', (tester) async {
    await tester.pumpWidget(
      wrap([
        row(period: '2026-01', name: 'EPF', authority: 'KWSP', total: 1100),
        row(
          period: '2026-01',
          name: 'SOCSO',
          authority: 'PERKESO',
          total: 90,
          overdue: true,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    // The month is where a person acts, so one late body has to raise
    // the whole card: a chip on a row nobody scrolled to is not a
    // warning.
    expect(find.text('Overdue'), findsOneWidget);
  });

  testWidgets('and a month with nothing late is not marked', (tester) async {
    // The control, in its own tree. Pumping a second ProviderScope into
    // the same one keeps the first card's element and finds the chip
    // that is no longer in the data -- which would have made the
    // assertion above pass whatever the widget did.
    await tester.pumpWidget(
      wrap([
        row(period: '2026-01', name: 'EPF', authority: 'KWSP', total: 1100),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Overdue'), findsNothing);
  });

  testWidgets('one already sent offers no button to send it again', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap([
        row(
          period: '2026-01',
          name: 'EPF',
          authority: 'KWSP',
          total: 1100,
          paidOn: '2026-02-10',
          reference: 'FPX 99',
        ),
        row(period: '2026-01', name: 'SOCSO', authority: 'PERKESO', total: 90),
      ]),
    );
    await tester.pumpAndSettle();

    // Two rows, one sent: exactly one button, and the sent one says
    // when and under what reference.
    expect(find.text('Mark sent'), findsOneWidget);
    expect(find.textContaining('FPX 99'), findsOneWidget);
  });

  testWidgets('and somebody who cannot run payroll is offered none at all', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap([
        row(period: '2026-01', name: 'EPF', authority: 'KWSP', total: 1100),
      ], canRun: false),
    );
    await tester.pumpAndSettle();

    // The figures are still readable -- knowing what the company owes
    // is not the same permission as recording that it was paid.
    expect(find.text('Mark sent'), findsNothing);
    expect(find.textContaining('RM 1,100.00'), findsWidgets);
  });
}
