import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/reports/report_spec.dart';
import 'package:iakauntan/src/features/reports/reports_screen.dart';

/// The screen and the PDF render the same spec, and the four reports do
/// not share a block shape between them. A widget that throws on one of
/// them shows up in release as a blank page, not as an error, so each
/// shape gets pumped.
void main() {
  final range = DateTimeRange(
    start: DateTime(2026, 1, 1),
    end: DateTime(2026, 8, 11),
  );

  Future<void> show(WidgetTester tester, ReportSpec spec,
      {bool wide = false}) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(child: ReportView(spec: spec, wide: wide)),
      ),
    ));
  }

  testWidgets('a profit and loss shows its sections, totals and result',
      (tester) async {
    await show(
        tester,
        profitLossSpec([
          {
            'code': '4000',
            'name': 'Sales',
            'account_type': 'revenue',
            'amount': 100000.0,
          },
          {
            'code': '5000',
            'name': 'Purchases',
            'account_type': 'expense',
            'account_subtype': 'cost_of_sales',
            'amount': 60000.0,
          },
          {
            'code': '6000',
            'name': 'Salaries',
            'account_type': 'expense',
            'amount': 25000.0,
          },
        ], range));

    expect(find.text('Profit & Loss'), findsOneWidget);
    expect(find.text('REVENUE'), findsOneWidget);
    expect(find.text('Total Revenue'), findsOneWidget);
    expect(find.text('Gross profit'), findsOneWidget);
    expect(find.text('Net profit'), findsOneWidget);
    expect(find.text('Sales'), findsOneWidget);
  });

  testWidgets('an empty section is not drawn as a heading over nothing',
      (tester) async {
    // No cost of sales at all: printing "COST OF SALES / Total 0.00"
    // makes a reader wonder what went missing.
    await show(
        tester,
        profitLossSpec([
          {
            'code': '4000',
            'name': 'Sales',
            'account_type': 'revenue',
            'amount': 100.0,
          },
        ], range));

    expect(find.text('REVENUE'), findsOneWidget);
    expect(find.text('COST OF SALES'), findsNothing);
  });

  testWidgets('a trial balance renders its grid and totals', (tester) async {
    await show(
        tester,
        trialBalanceSpec([
          {
            'code': '1000',
            'name': 'Bank',
            'debit': 500.0,
            'credit': 0.0,
            'closing_balance': 500.0,
          },
          {
            'code': '4000',
            'name': 'Sales',
            'debit': 0.0,
            'credit': 500.0,
            'closing_balance': -500.0,
          },
        ]),
        wide: true);

    expect(find.text('Trial Balance'), findsOneWidget);
    expect(find.text('In balance'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.byType(DataTable), findsOneWidget);
  });

  testWidgets('an SST summary renders both directions and the note',
      (tester) async {
    await show(
        tester,
        sstSummarySpec([
          {
            'direction': 'output',
            'tax_type_code': 'SV',
            'tax_type_name': 'Service tax',
            'taxable_amount': 1000.0,
            'tax_amount': 80.0,
          },
        ], range));

    expect(find.text('Output tax (sales)'), findsOneWidget);
    // No purchases with tax: the section says so rather than vanishing,
    // because an absent input-tax table reads as a missing figure.
    expect(find.text('Input tax (purchases)'), findsOneWidget);
    expect(find.text('None'), findsOneWidget);
    expect(find.text('Tax payable'), findsOneWidget);
  });

  testWidgets('a balance sheet carries its caveat', (tester) async {
    await show(
        tester,
        balanceSheetSpec([
          {
            'code': '1000',
            'name': 'Bank',
            'account_type': 'asset',
            'balance': 50.0,
          },
        ], range.end));

    expect(find.text('Balance Sheet'), findsOneWidget);
    expect(find.textContaining('retained earnings'), findsOneWidget);
  });
}
