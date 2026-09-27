import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/financials/form_b_screen.dart';
import 'package:iakauntan/src/features/financials/form_p_screen.dart';
import 'package:iakauntan/src/features/financials/tax_calendar_screen.dart';
import 'package:iakauntan/src/features/financials/tax_computation_screen.dart';
import 'package:iakauntan/src/features/financials/tax_estimate_screen.dart';

/// Whether the tax screens BUILD.
///
/// Every other test on this work is on the models, and models are not
/// screens. `docs/widget-tests.md` lists ten ways a green test covers
/// a broken screen, and the one this file exists for is the plainest:
/// a screen nothing ever constructs cannot be known to construct at
/// all. This session has already paid for that once — sixteen tests
/// passed over a report button that threw on every tap, because
/// nothing put it where the real app puts it.
///
/// So these are deliberately shallow and deliberately broad. They feed
/// each screen one realistic answer through its own providers and
/// assert that a figure it was given appears. What they would catch is
/// the class of fault that makes a screen useless rather than wrong: a
/// null it did not expect, a layout that throws, a section that reads
/// a field nobody set.
void main() {
  Widget wrap(Widget screen, List<Override> overrides) {
    final router = GoRouter(
      initialLocation: '/x',
      routes: [
        GoRoute(path: '/x', builder: (_, __) => screen),
        GoRoute(
          path: '/tax-computation/:id',
          builder: (_, __) => const Scaffold(body: Text('a computation')),
        ),
        GoRoute(
          path: '/tax-estimate/:id',
          builder: (_, __) => const Scaffold(body: Text('an estimate')),
        ),
      ],
    );
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    );
  }

  // A phone, because these screens are columns of figures with labels
  // beside them and that is where a row runs out of width.
  Future<void> onAPhone(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  group('the tax calendar', () {
    TaxFiling filing({
      String type = 'form_c',
      int daysLeft = 90,
      bool overdue = false,
      String status = 'not_started',
    }) => TaxFiling(
      filingType: type,
      name: 'Return of a company',
      formLabel: 'C',
      statuteRef: 'ITA 1967 s.77A(1)',
      periodFrom: DateTime(2025, 7, 1),
      periodTo: DateTime(2026, 6, 30),
      yearOfAssessment: 2026,
      dueDate: DateTime(2027, 1, 31),
      efilingDueDate: DateTime(2027, 2, 28),
      daysLeft: daysLeft,
      isOverdue: overdue,
      status: status,
      description: 'Seven months from the day following the close.',
      fiscalYearId: 'fy1',
      computationId: 'comp-1',
      estimateId: null,
    );

    testWidgets('builds and shows an obligation', (tester) async {
      await onAPhone(
        tester,
        wrap(const TaxCalendarScreen(), [
          taxFilingCalendarProvider.overrideWith((ref) async => [filing()]),
        ]),
      );
      expect(find.text('Return of a company'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      // BOTH dates, and this is the assertion the screen exists for:
      // the e-filing concession is shown BESIDE the statutory date,
      // never instead of it. Asserting only that the concession
      // appears would pass on a screen that had replaced the deadline
      // with it — which is the failure that costs somebody a penalty
      // on a date they were told was theirs.
      expect(find.text('31/01/2027'), findsOneWidget);
      expect(find.text('e-Filing to 28/02/2027'), findsOneWidget);
      expect(find.textContaining('days left'), findsOneWidget);
    });

    testWidgets('and an overdue one counts days PAST', (tester) async {
      await onAPhone(
        tester,
        wrap(const TaxCalendarScreen(), [
          taxFilingCalendarProvider.overrideWith(
            (ref) async => [filing(daysLeft: -12, overdue: true)],
          ),
        ]),
      );
      expect(find.text('12 days late'), findsOneWidget);
    });

    testWidgets('an empty calendar says so rather than drawing nothing',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const TaxCalendarScreen(), [
          taxFilingCalendarProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('Nothing falling due'), findsOneWidget);
    });

    testWidgets('the recorded side builds too', (tester) async {
      await onAPhone(
        tester,
        wrap(const TaxCalendarScreen(), [
          taxFilingCalendarProvider.overrideWith((ref) async => []),
          taxFilingHistoryProvider.overrideWith(
            (ref) async => [
              TaxFilingRecord(
                id: 'r1',
                filingType: 'form_c',
                name: 'Return of a company',
                formLabel: 'C',
                periodFrom: DateTime(2025, 7, 1),
                periodTo: DateTime(2026, 6, 30),
                yearOfAssessment: 2026,
                dueDate: DateTime(2027, 1, 31),
                status: 'filed',
                filedOn: DateTime(2027, 3, 5),
                reference: 'ACK-1',
                notes: null,
                wasLate: true,
              ),
            ],
          ),
        ]),
      );
      // Switch to the recorded side and see the record.
      await tester.tap(find.text('Recorded'));
      await tester.pumpAndSettle();
      expect(find.textContaining('ACK-1'), findsOneWidget);
      expect(find.text('After the deadline'), findsOneWidget);
    });
  });

  group('the estimate screen', () {
    TaxEstimateExposure exposure({String form = 'CP204'}) =>
        TaxEstimateExposure(
          form: form,
          estimatedTax: 60000,
          priorEstimate: form == 'CP204' ? 70000 : null,
          floorRequired: form == 'CP204' ? 59500 : null,
          meetsFloor: form == 'CP204',
          floorKnown: form == 'CP204',
          floorApplies: form == 'CP204',
          actualTax: null,
          actualKnown: false,
          shortfall: null,
          toleranceAmount: null,
          excessOverTolerance: null,
          penalty: null,
          revisionOpen: false,
          revisionMonths: const [6, 9],
        );

    List<Override> estimateOverrides({String form = 'CP204'}) => [
      taxEstimateExposureProvider(
        (estimate: 'e1', computation: null),
      ).overrideWith((ref) async => exposure(form: form)),
      taxFirstPeriodProvider('e1').overrideWith(
        (ref) async => TaxFirstPeriod(
          isFirstPeriod: false,
          form: form,
          filingDueKnown: false,
          exemptInstalments: false,
          exemptionKnown: false,
        ),
      ),
      taxEstimateScheduleProvider('e1').overrideWith(
        (ref) async => [
          TaxInstalment(
            number: 1,
            dueOn: DateTime(2026, 2, 15),
            amount: 5000,
            outstanding: 5000,
          ),
          TaxInstalment(
            number: 2,
            dueOn: DateTime(2026, 3, 15),
            amount: 5000,
            paidOn: DateTime(2026, 3, 10),
            paidAmount: 5000,
            outstanding: 0,
          ),
        ],
      ),
      taxInstalmentSummaryProvider('e1').overrideWith(
        (ref) async => TaxInstalmentSummary(
          scheduledTotal: 60000,
          paidTotal: 5000,
          outstandingTotal: 55000,
          instalments: 12,
          instalmentsPaid: 1,
          overdueCount: 0,
          overdueTotal: 0,
          lateCount: 0,
          latePenalty: 0,
          nextDueOn: DateTime(2026, 4, 15),
          nextDueAmount: 5000,
        ),
      ),
    ];

    testWidgets('a CP204 builds with its floor', (tester) async {
      await onAPhone(
        tester,
        wrap(
          const TaxEstimateScreen(estimateId: 'e1'),
          estimateOverrides(),
        ),
      );
      expect(find.text('CP204 estimate'), findsOneWidget);
      expect(find.textContaining('The least this year may be'),
          findsOneWidget);
      // One paid, one not, and the summary above them.
      expect(find.textContaining('1 of 12 recorded as paid'), findsOneWidget);
      expect(find.textContaining('paid 10/03/2026'), findsOneWidget);
      // And the UNPAID one is not marked. Asserting only that the paid
      // row says so passes on a screen that marks every row paid —
      // which would tell somebody nine instalments behind that they
      // were up to date.
      expect(find.text('paid'), findsNothing);
    });

    testWidgets('a CP500 says it has no floor rather than failing one',
        (tester) async {
      await onAPhone(
        tester,
        wrap(
          const TaxEstimateScreen(estimateId: 'e1'),
          estimateOverrides(form: 'CP500'),
        ),
      );
      expect(find.text('CP500 estimate'), findsOneWidget);
      expect(find.textContaining('has no floor against last year'),
          findsOneWidget);
      // And does NOT show the floor line, which would be a rule that
      // does not exist.
      expect(find.textContaining('The least this year may be'), findsNothing);
    });
  });

  group('the computation screens', () {
    TaxComputation comp() => TaxComputation.fromMap(const {
      'year_of_assessment': 2026,
      'profit_before_tax': 200000,
      'adjusted_income': 209800,
      'statutory_business': 175800,
      'chargeable_income': 175800,
      'tax_charged': 29886,
      'tax_payable': 29886,
    });

    IndividualTaxComputation individual() =>
        IndividualTaxComputation.fromMap(const {
          'year_of_assessment': 2026,
          'profit_before_tax': 200000,
          'adjusted_income': 200000,
          'statutory_business': 200000,
          'aggregate_income': 200000,
          'total_income': 200000,
          'chargeable_income': 190000,
          'tax_charged': 34225,
          'tax_payable': 34225,
        });

    testWidgets('Form C builds', (tester) async {
      await onAPhone(
        tester,
        wrap(const TaxComputationScreen(computationId: 'c1'), [
          taxComputationProvider('c1').overrideWith((ref) async => comp()),
          taxComputationLinesProvider('c1').overrideWith((ref) async => []),
          taxComputationRowProvider('c1')
              .overrideWith((ref) async => <String, dynamic>{}),
          taxMisfiledAccountsProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.textContaining('Chargeable income'), findsOneWidget);
    });

    testWidgets('Form B builds', (tester) async {
      await onAPhone(
        tester,
        wrap(const FormBScreen(computationId: 'c1'), [
          individualTaxProvider('c1').overrideWith((ref) async => individual()),
          taxComputationLinesProvider('c1').overrideWith((ref) async => []),
          taxComputationRowProvider('c1')
              .overrideWith((ref) async => <String, dynamic>{}),
          taxMisfiledAccountsProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.textContaining('Chargeable income'), findsOneWidget);
    });

    testWidgets('Form P builds and shows no tax figure at all',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const FormPScreen(computationId: 'c1'), [
          partnershipSummaryProvider('c1').overrideWith(
            (ref) async => PartnershipSummary(
              adjustedIncome: 200000,
              appropriations: 63000,
              divisibleIncome: 200000,
              partnershipAdjusted: 263000,
              totalAllocated: 263000,
              sharesTotal: 100,
              partnerCount: 2,
            ),
          ),
          partnershipAllocationProvider('c1').overrideWith((ref) async => []),
          taxComputationRowProvider('c1')
              .overrideWith((ref) async => <String, dynamic>{}),
        ]),
      );
      // A partnership is not a taxable person. A Form P that produced
      // a tax figure would be wrong in the most expensive direction.
      expect(find.textContaining('Tax payable'), findsNothing);
    });
  });
}
