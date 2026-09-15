import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/hr/payslip_screen.dart';

/// The payslip, as the employee reads it.
///
/// The arithmetic behind these figures is asserted in SQL, where it
/// belongs. What only this widget decides is how the figures are
/// PRESENTED, and two of those decisions are ones an employee acts on.
///
/// The first is the sign. Deductions are rendered negative and employer
/// contributions are not, because the employer's EPF share is not money
/// the employee lost. Render that card with `negative: true` -- one
/// argument -- and a payslip tells somebody their employer took
/// RM 1,300 off their pay. Nothing below the widget can see it: the
/// numbers in the row are identical either way.
///
/// The second is the contribution wages card. SOCSO and EIS cap at the
/// insured ceiling, so for a higher earner they do NOT equal gross pay,
/// and the screen's own comment says this is "exactly the number people
/// ring up about". A card that showed gross five times over would look
/// perfectly reasonable.
///
/// Also here: the unverified banner, which is the difference between a
/// figure calculated from published percentages and one from the
/// gazetted table, on a document somebody may file a return from.
void main() {
  PayslipLine line(String kind, String description, double amount,
          {double? quantity}) =>
      PayslipLine(
        kind: kind,
        code: description.toLowerCase().replaceAll(' ', '_'),
        description: description,
        amount: amount,
        quantity: quantity,
      );

  /// A higher earner: gross above every insured ceiling, so the wages
  /// card cannot pass by accident.
  Payslip slip({
    bool verified = true,
    List<PayslipLine>? lines,
    double grossPay = 10000,
    double totalDeductions = 1815,
    double netPay = 8185,
  }) =>
      Payslip(
        id: 'p1',
        employeeName: 'Nurul Huda binti Rahman',
        employeeNo: 'E-0042',
        positionTitle: 'Site Engineer',
        departmentName: 'Projects',
        periodCode: '2026-08',
        grossPay: grossPay,
        totalDeductions: totalDeductions,
        netPay: netPay,
        epfWage: 10000,
        // The ceilings. Both below gross, and equal to each other, which
        // is the ordinary case above the cap.
        socsoWage: 6000,
        eisWage: 6000,
        hrdfWage: 9000,
        taxableIncome: 9400,
        schedulesVerified: verified,
        lines: lines ??
            [
              line('earning', 'Basic salary', 9000),
              line('earning', 'Overtime', 1000, quantity: 8),
              line('deduction', 'EPF employee', 1100),
              line('deduction', 'SOCSO employee', 29.75),
              line('deduction', 'EIS employee', 11.90),
              line('deduction', 'PCB', 673.35),
              line('employer_contribution', 'EPF employer', 1300),
              line('employer_contribution', 'SOCSO employer', 104.15),
              line('employer_contribution', 'EIS employer', 11.90),
            ],
      );

  Widget wrap(Payslip? payslip) {
    final router = GoRouter(
      initialLocation: '/hr/payslip/p1',
      routes: [
        GoRoute(
          path: '/hr/payslip/:id',
          builder: (_, __) => const PayslipScreen(payslipId: 'p1'),
        ),
        GoRoute(
          path: '/hr/me',
          builder: (_, __) => const Scaffold(body: Text('my hr')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        payslipProvider('p1').overrideWith((ref) async => payslip),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    );
  }

  Future<void> show(WidgetTester tester, {Payslip? payslip}) async {
    await tester.pumpWidget(wrap(payslip ?? slip()));
    await tester.pumpAndSettle();
  }

  /// Every `Money` on screen, as the text it rendered.
  List<String> money(WidgetTester tester) => tester
      .widgetList<Money>(find.byType(Money))
      .map((m) => (m.amount ?? 0).toStringAsFixed(2))
      .toList();

  group('what came off the pay, and what did not', () {
    testWidgets('a deduction is shown as money taken away', (tester) async {
      await show(tester);

      // The row and the total both carry the minus. The currency
      // prefix comes before the sign -- `Fmt.money` prefixes the
      // formatted number -- so it reads "RM -1,100.00", not an unsigned
      // figure in a list headed "Deductions" that somebody may be
      // scanning quickly.
      expect(find.text('RM -1,100.00'), findsOneWidget);
      expect(find.text('RM -1,815.00'), findsOneWidget,
          reason: 'the deductions total is negative too');
    });

    testWidgets('an employer contribution is not', (tester) async {
      await show(tester);

      // RM 1,300 of EPF paid BY the company. Positive, under a heading
      // that says so, because it never touched the employee's pay.
      expect(find.text('RM 1,300.00'), findsOneWidget);
      expect(find.text('RM -1,300.00'), findsNothing,
          reason: "the employer's share was never deducted from the pay");
      expect(find.text('Paid by the company'), findsOneWidget);
      expect(find.textContaining('Never deducted from your pay'),
          findsOneWidget);
    });

    testWidgets('and the employer total is the employer lines, not the '
        'deductions', (tester) async {
      await show(tester);

      // 1300 + 104.15 + 11.90. If the fold ran over the wrong list the
      // figure would be the deduction total, which is a different number
      // and a serious one: it is what the company reports as its cost.
      expect(find.text('RM 1,416.05'), findsOneWidget);
      expect(find.text('Employer cost'), findsOneWidget);
    });

    testWidgets('the three kinds land in three cards', (tester) async {
      await show(tester);

      // A line that is not an earning must not be counted under Gross
      // pay. The sign test above would still pass if `employer` lines
      // leaked into `deductions`, so the partition is asserted by the
      // count: 2 earnings + 4 deductions + 3 employer = 9 rows, plus 3
      // totals and 5 contribution wages. Net pay is NOT among them --
      // it is a plain Text, being the one figure on the page that gets
      // its own type scale.
      expect(money(tester).length, 9 + 3 + 5);
      expect(find.text('Gross pay'), findsOneWidget);
      expect(find.text('RM 10,000.00'), findsWidgets);
      expect(find.text('Net pay'), findsOneWidget);
    });

    testWidgets('a payslip with no employer contributions hides that card',
        (tester) async {
      // The control for the card above: it is conditional, so a test
      // that only ever sees it present cannot tell it from one that is
      // always drawn.
      await show(
        tester,
        payslip: slip(lines: [
          line('earning', 'Basic salary', 3000),
          line('deduction', 'EPF employee', 330),
        ]),
      );

      expect(find.text('Paid by the company'), findsNothing);
      expect(find.text('Employer cost'), findsNothing);
      expect(find.text('RM -330.00'), findsOneWidget);
    });
  });

  group('the wage each authority charged on', () {
    testWidgets('SOCSO and EIS show the ceiling, not the gross',
        (tester) async {
      await show(tester);

      expect(find.text('Contribution wages'), findsOneWidget);
      for (final label in const [
        'EPF wage',
        'SOCSO insured wage',
        'EIS insured wage',
        'HRD Corp levy wage',
        'Taxable income',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '$label is missing');
      }

      // The point of the card. Gross is 10,000; the insured wage is
      // 6,000, and it appears twice because SOCSO and EIS share the
      // ceiling. A card wired to gross would show 10,000 five times and
      // look entirely plausible.
      expect(find.text('RM 6,000.00'), findsNWidgets(2));
      // HRD Corp is narrower than the EPF wage and the gap is the bonus.
      expect(find.text('RM 9,000.00'), findsWidgets);
      expect(find.text('RM 9,400.00'), findsOneWidget);
    });
  });

  group('whether the figures may be filed from', () {
    testWidgets('an unverified schedule says so on the payslip',
        (tester) async {
      await show(tester, payslip: slip(verified: false));

      expect(find.textContaining('published statutory percentages'),
          findsOneWidget);
      expect(find.textContaining('gazetted contribution table'),
          findsOneWidget);
      // It says what to do before filing, not merely that something is
      // unverified.
      expect(find.textContaining('before filing returns'), findsOneWidget);
    });

    testWidgets('and a verified one does not', (tester) async {
      await show(tester);

      expect(find.textContaining('gazetted contribution table'), findsNothing);
    });
  });

  group('the page itself', () {
    testWidgets('names the employee and the period', (tester) async {
      await show(tester);

      expect(find.text('Nurul Huda binti Rahman'), findsOneWidget);
      // Employee number, position, department and period, in one line.
      expect(
        find.text('E-0042 · Site Engineer · Projects · 2026-08'),
        findsOneWidget,
      );
    });

    testWidgets('a payslip that is not there says so rather than showing '
        'zeroes', (tester) async {
      // An empty payslip reads as a real one worth nothing, and somebody
      // would ring up about the RM 0.00 net pay.
      await tester.pumpWidget(wrap(null));
      await tester.pumpAndSettle();

      expect(find.text('Payslip not found'), findsOneWidget);
      expect(find.byType(Money), findsNothing);
    });
  });
}
