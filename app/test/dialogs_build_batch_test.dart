import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/assets/capital_allowances_dialog.dart';
import 'package:iakauntan/src/features/crm/win_loss_dialog.dart';
import 'package:iakauntan/src/features/documents/late_orders_dialog.dart';
import 'package:iakauntan/src/features/financials/fs_mapping.dart';
import 'package:iakauntan/src/features/legal/over_agreed_fee_dialog.dart';
import 'package:iakauntan/src/features/pos/recipe_requirement_dialog.dart';

/// Dialogs and sheets that nothing had ever opened.
///
/// `scripts/check_screens_built.py` took the screens from 38 unbuilt to
/// 0 and found seven real defects doing it. This is the same method
/// pointed at the other half of the app: 272 dialog and sheet classes,
/// which that gate never asked about because a dialog body is not a
/// `*Screen`.
///
/// 242 of those classes are PRIVATE, so they cannot be named from here
/// at all. The way in is the way the app goes in — the public opener
/// function — which is why `check_dialogs_built.py` is keyed on those
/// and why every test below calls one rather than constructing a
/// widget.
///
/// Opened at PHONE width on purpose. A dialog is the likeliest place
/// in this codebase to find a fixed pixel width, because the author is
/// thinking about a desktop modal while writing one.
void main() {
  /// Pump a host with a button, press it, and let the dialog settle.
  ///
  /// The button is the point: `showDialog` needs a `BuildContext` under
  /// a `MaterialApp`, and the context a test holds before pumping is
  /// not one. Taking the opener as a callback rather than a widget is
  /// what lets this reach a private dialog class.
  Future<void> opened(
    WidgetTester tester,
    List<Override> overrides,
    void Function(BuildContext context) open,
  ) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const ValueKey('open'),
                  onPressed: () => open(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
  }

  group('how the chart reports', () {
    testWidgets('opens, and lists the accounts that can be mapped',
        (tester) async {
      await opened(
        tester,
        [
          accountsProvider.overrideWith(
            (ref) async => [
              Account(
                id: 'a1',
                code: '1000',
                name: 'Cash at bank',
                accountType: 'asset',
                accountSubtype: 'cash',
              ),
              // A heading carries no balance of its own, so it is not
              // mappable and must not appear.
              Account(
                id: 'a2',
                code: '1',
                name: 'ASSETS',
                accountType: 'asset',
                accountSubtype: '',
                isGroup: true,
              ),
            ],
          ),
          fsAccountMapProvider.overrideWith((ref) async => []),
          canWriteProvider.overrideWithValue(true),
        ],
        showFsMapping,
      );
      expect(find.text('How the chart reports'), findsOneWidget);
      expect(find.textContaining('Cash at bank'), findsOneWidget);
      expect(find.text('ASSETS'), findsNothing);
      expect(find.byKey(const ValueKey('fs-search')), findsOneWidget);
    });

    testWidgets('and the "changed only" filter says why it is empty',
        (tester) async {
      await opened(
        tester,
        [
          accountsProvider.overrideWith(
            (ref) async => [
              Account(
                id: 'a1',
                code: '1000',
                name: 'Cash at bank',
                accountType: 'asset',
                accountSubtype: 'cash',
              ),
            ],
          ),
          fsAccountMapProvider.overrideWith((ref) async => []),
          canWriteProvider.overrideWithValue(true),
        ],
        showFsMapping,
      );
      await tester.tap(find.byKey(const ValueKey('fs-only-overridden')));
      await tester.pumpAndSettle();
      // Not "no results": a standard chart legitimately has none, and
      // saying so is different from saying the search failed.
      expect(
        find.textContaining('A standard chart needs no override'),
        findsOneWidget,
      );
    });
  });

  group('matters over the agreed fee', () {
    testWidgets('opens, and drops the "still to bill" clause at zero',
        (tester) async {
      await opened(
        tester,
        [
          mattersOverAgreedFeeProvider.overrideWith(
            (ref) async => [
              {
                'matter_id': 'm1',
                'matter_no': 'MAT-001',
                'matter_name': 'Sale of shophouse',
                'client_name': 'Tan Sri Lim',
                'agreed_fee': 8000,
                'billed': 9500,
                'unbilled': 1200,
              },
              {
                'matter_id': 'm2',
                'matter_no': 'MAT-002',
                'matter_name': 'Tenancy dispute',
                'client_name': 'Kedai Runcit Aman',
                'agreed_fee': 3000,
                'billed': 3400,
                'unbilled': 0,
              },
            ],
          ),
        ],
        showMattersOverAgreedFee,
      );
      expect(find.text('Over the agreed fee'), findsOneWidget);
      expect(
        find.text('Tan Sri Lim · agreed RM 8,000.00 · billed RM 9,500.00 · '
            'RM 1,200.00 still to bill'),
        findsOneWidget,
      );
      // Nothing left to bill, so the clause is absent rather than
      // reading "RM 0.00 still to bill" on every settled matter.
      expect(
        find.text('Kedai Runcit Aman · agreed RM 3,000.00 · '
            'billed RM 3,400.00'),
        findsOneWidget,
      );
    });

    testWidgets('and says why an empty list is not a mistake', (tester) async {
      await opened(
        tester,
        [mattersOverAgreedFeeProvider.overrideWith((ref) async => [])],
        showMattersOverAgreedFee,
      );
      // "Files with no agreed fee are not counted" is the sentence
      // that stops somebody trusting a zero they should not.
      expect(
        find.textContaining('there is nothing to be over'),
        findsOneWidget,
      );
    });
  });

  group('what one dish takes', () {
    testWidgets('opens, and names the ingredient that is the limit',
        (tester) async {
      await opened(
        tester,
        [
          posRecipeRequirementProvider('i1').overrideWith(
            (ref) async => [
              {
                'component_item_id': 'c1',
                'component_name': 'Ayam',
                'quantity': 0.25,
                'uom_code': 'kg',
                'on_hand': 3,
              },
              {
                'component_item_id': 'c2',
                'component_name': 'Nasi',
                'quantity': 0.2,
                'uom_code': 'kg',
                'on_hand': 40,
              },
            ],
          ),
        ],
        (context) => showRecipeRequirement(
          context,
          itemId: 'i1',
          name: 'Nasi lemak ayam',
        ),
      );
      expect(find.text('What one Nasi lemak ayam takes'), findsOneWidget);
      // 3kg of chicken at 0.25 each is 12; 40kg of rice at 0.2 is 200.
      // The chicken is the answer, and the dialog exists to say WHICH
      // rather than just how many.
      expect(
        find.textContaining('The store allows about 12 more, and Ayam is why'),
        findsOneWidget,
      );
    });

    testWidgets('and a dish that draws nothing tracked says so',
        (tester) async {
      await opened(
        tester,
        [posRecipeRequirementProvider('i9').overrideWith((ref) async => [])],
        (context) => showRecipeRequirement(
          context,
          itemId: 'i9',
          name: 'Teh tarik',
        ),
      );
      expect(find.text('Nothing counted'), findsOneWidget);
    });
  });

  group('capital allowances', () {
    CapitalAllowanceLine line({
      required String no,
      required String name,
      String classCode = 'plant',
      String classLabel = 'Plant and machinery',
      double cost = 10000,
      double? qualifying,
      double initial = 2000,
      double annual = 1400,
      double priorClaimed = 0,
      double balancingAllowance = 0,
      double balancingCharge = 0,
      double claimed = 3400,
      double residual = 6600,
    }) =>
        CapitalAllowanceLine(
          assetId: no,
          assetNo: no,
          name: name,
          classCode: classCode,
          classLabel: classLabel,
          acquired: DateTime(2024, 4, 1),
          cost: cost,
          qualifying: qualifying ?? cost,
          initial: initial,
          annual: annual,
          priorClaimed: priorClaimed,
          balancingAllowance: balancingAllowance,
          balancingCharge: balancingCharge,
          claimed: claimed,
          residual: residual,
        );

    // The dialog opens on LAST year: a year of assessment is worked on
    // after it has finished, so opening on this one would show a
    // schedule nobody is filing yet, every time.
    final ya = DateTime.now().year - 1;

    testWidgets('opens, and the schedule scrolls sideways on a phone',
        (tester) async {
      await opened(
        tester,
        [
          capitalAllowancesProvider(ya).overrideWith(
            (ref) async => [line(no: 'FA-001', name: 'Delivery van')],
          ),
        ],
        showCapitalAllowances,
      );
      expect(find.text('Capital allowances'), findsOneWidget);
      expect(find.byKey(const ValueKey('ca-year')), findsOneWidget);
      // `DataRow.key` is not a widget key -- a DataRow is a
      // configuration object, not a widget -- so the row is found by
      // what it renders.
      expect(find.text('FA-001 · Delivery van'), findsOneWidget);
      expect(find.text('Plant and machinery'), findsOneWidget);
      // Eight columns at 220 + 7x96 = 892 logical pixels, on a screen
      // 412 wide. It is meant to scroll rather than wrap, because a
      // schedule that wraps mid-figure is one nobody can cast — and
      // the whole table is built either way, so the far column is
      // present without being visible.
      expect(find.text('Qualifying'), findsOneWidget);
      expect(find.text('Residual'), findsOneWidget);
    });

    testWidgets('and an asset that attracted nothing is called out',
        (tester) async {
      // The dangerous one. An asset filed in a small-value class that
      // is not small-value gets NOTHING rather than being written off
      // in full — the safe direction, and invisible unless somebody is
      // told. Its residual sitting at the whole cost is the giveaway.
      await opened(
        tester,
        [
          capitalAllowancesProvider(ya).overrideWith(
            (ref) async => [
              line(
                no: 'FA-002',
                name: 'Server rack',
                classCode: 'small_value',
                classLabel: 'Small value',
                cost: 8000,
                initial: 0,
                annual: 0,
                claimed: 0,
                residual: 8000,
              ),
            ],
          ),
        ],
        showCapitalAllowances,
      );
      expect(find.byKey(const ValueKey('ca-misfiled')), findsOneWidget);
      expect(
        find.textContaining('attracted nothing at all'),
        findsOneWidget,
      );
      expect(find.textContaining('FA-002'), findsWidgets);
    });

    testWidgets('and a restricted asset says what it was computed on',
        (tester) async {
      // A vehicle above the cap is allowed on the cap, not on what was
      // paid. Silent otherwise, and the figure would simply look wrong.
      await opened(
        tester,
        [
          capitalAllowancesProvider(ya).overrideWith(
            (ref) async => [
              line(
                no: 'FA-003',
                name: 'Director car',
                classCode: 'motor_vehicle',
                classLabel: 'Motor vehicle',
                cost: 220000,
                qualifying: 50000,
                initial: 10000,
                annual: 10000,
                claimed: 20000,
                residual: 30000,
              ),
            ],
          ),
        ],
        showCapitalAllowances,
      );
      expect(find.byKey(const ValueKey('ca-restricted')), findsOneWidget);
      expect(
        find.textContaining('computed on RM 50,000.00 rather than on what '
            'was paid'),
        findsOneWidget,
      );
      // And no misfiled notice: this asset attracted plenty.
      expect(find.byKey(const ValueKey('ca-misfiled')), findsNothing);
    });

    testWidgets('and a year with nothing in it explains why', (tester) async {
      await opened(
        tester,
        [capitalAllowancesProvider(ya).overrideWith((ref) async => [])],
        showCapitalAllowances,
      );
      // Land and goodwill never attract one, which is the answer to
      // "why is my asset not here".
      expect(
        find.textContaining('land and goodwill never do'),
        findsOneWidget,
      );
    });
  });

  group('past the date we promised', () {
    testWidgets('opens, and says how much of the order is still to go',
        (tester) async {
      // This one reads the repository directly rather than through a
      // provider, so the fixture is a fake `Repo` — and its
      // `noSuchMethod` names any method the dialog calls that this
      // fake has not answered, which is how you find out what one
      // needs without reading all of it.
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(_Repo(
            late: [
              {
                'document_id': 'd1',
                'doc_no': 'SO-0042',
                'contact_name': 'Kedai Runcit Aman',
                'delivery_date': '2026-09-01',
                'outstanding': 4,
                'ordered': 10,
                'days_late': 21,
                'amount': 1800,
              },
            ],
          )),
        ],
        showLateOrders,
      );
      expect(find.text('Past the date we promised'), findsOneWidget);
      expect(find.text('SO-0042 · Kedai Runcit Aman'), findsOneWidget);
      // Four of ten, not "4 outstanding" — the fraction is the thing
      // somebody chasing an order needs.
      expect(
        find.text('Promised 01/09/2026 · 4 of 10 still to go'),
        findsOneWidget,
      );
      expect(find.text('21 days late'), findsOneWidget);
    });

    testWidgets('and a customer with no name on the row still reads',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(_Repo(
            late: [
              {
                'document_id': 'd1',
                'doc_no': 'SO-0043',
                'delivery_date': '2026-09-10',
                'outstanding': 1,
                'ordered': 1,
                'days_late': 3,
                'amount': 90,
              },
            ],
          )),
        ],
        showLateOrders,
      );
      // An em dash rather than "null", which is what an unguarded
      // interpolation would have put on the row.
      expect(find.text('SO-0043 · —'), findsOneWidget);
    });

    testWidgets('and nothing late says what would appear here',
        (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(_Repo(late: []))],
        showLateOrders,
      );
      expect(find.text('Nothing is late'), findsOneWidget);
    });
  });

  group('why deals closed', () {
    testWidgets('opens, and gives each reason its share of the total',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(_Repo(
            closed: [
              {
                'outcome': 'lost',
                'reason': 'Price',
                'competitors': 'Sistem Kira, AutoCount',
                'amount': 75000,
                'deals': 3,
              },
              {
                'outcome': 'won',
                'reason': 'Existing relationship',
                'amount': 25000,
                'deals': 1,
              },
            ],
          )),
        ],
        showWinLoss,
      );
      expect(find.text('Why deals closed'), findsOneWidget);
      // The share is worked out here from a total the dialog sums
      // itself; nothing hands it a percentage.
      expect(find.textContaining('RM 100,000.00 closed'), findsOneWidget);
      expect(find.text('3 deals · 75%'), findsOneWidget);
      // One deal, singular, and the other quarter.
      expect(find.text('1 deal · 25%'), findsOneWidget);
      // Competitors are NAMED rather than counted: "three competitors"
      // tells nobody who to go and look at.
      expect(find.text('vs Sistem Kira, AutoCount'), findsOneWidget);
    });

    testWidgets('and a year with nothing closed says so', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(_Repo(closed: []))],
        showWinLoss,
      );
      expect(find.text('Nothing closed in the last year'), findsOneWidget);
    });
  });
}

/// Answers only what the dialogs under test ask for.
///
/// `noSuchMethod` throws with the method's name rather than returning
/// null, so a dialog that reaches for something this does not answer
/// says which thing — which is how the fixture above was written
/// without reading all of `Repo`.
class _Repo implements Repo {
  _Repo({this.late = const [], this.closed = const []});

  final List<Map<String, dynamic>> late;
  final List<Map<String, dynamic>> closed;

  @override
  Future<List<Map<String, dynamic>>> lateOrders({DateTime? asAt}) async =>
      late;

  @override
  Future<List<Map<String, dynamic>>> winLoss({
    required DateTime from,
    required DateTime to,
  }) async =>
      closed;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'a dialog under test called Repo.'
        '${invocation.memberName} and this fake does not answer it.',
      );
}
