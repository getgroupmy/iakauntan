import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/corp_models.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/assets/capital_allowances_dialog.dart';
import 'package:iakauntan/src/features/assets/capitalise_dialog.dart';
import 'package:iakauntan/src/features/crm/quote_mismatch_dialog.dart';
import 'package:iakauntan/src/features/crm/win_loss_dialog.dart';
import 'package:iakauntan/src/features/documents/late_orders_dialog.dart';
import 'package:iakauntan/src/features/financials/fs_mapping.dart';
import 'package:iakauntan/src/features/hr/expiring_documents.dart';
import 'package:iakauntan/src/features/items/item_categories_dialog.dart';
import 'package:iakauntan/src/features/items/stock_card_dialog.dart';
import 'package:iakauntan/src/features/ledger/journal_editor.dart';
import 'package:iakauntan/src/features/loyalty/loyalty_tiers_dialog.dart';
import 'package:iakauntan/src/features/ticketing/ticket_routing_sheet.dart';
import 'package:iakauntan/src/features/hr/who_is_away.dart';
import 'package:iakauntan/src/features/legal/over_agreed_fee_dialog.dart';
import 'package:iakauntan/src/features/pos/offline_controller.dart';
import 'package:iakauntan/src/features/secretarial/officer_sheet.dart';
import 'package:iakauntan/src/features/pos/offline_problems_dialog.dart';
import 'package:iakauntan/src/features/pos/recipe_requirement_dialog.dart';
import 'package:iakauntan/src/features/pos/sold_out_dialog.dart';

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

  /// The same, for an opener that wants a `WidgetRef` too.
  ///
  /// `showJournalEditor` takes one. A `Builder` cannot supply it, so
  /// the button lives inside a `Consumer` instead — which is what the
  /// screens that open it do.
  Future<void> openedWithRef(
    WidgetTester tester,
    List<Override> overrides,
    void Function(BuildContext context, WidgetRef ref) open,
  ) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const ValueKey('open'),
                  onPressed: () => open(context, ref),
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

  group('the forecast and the quotations', () {
    testWidgets('opens, and totals what the pipeline is out by',
        (tester) async {
      await opened(
        tester,
        [
          pipelineQuoteMismatchProvider.overrideWith(
            (ref) async => [
              {
                'opportunity_id': 'o1',
                'opportunity_no': 'OPP-001',
                'deal_name': 'Kedai Kopi fit-out',
                'contact_name': 'Encik Rahim',
                'deal_amount': 45000,
                'document_id': 'q1',
                'doc_no': 'QUO-0011',
                'quoted_amount': 38000,
                'difference': -7000,
              },
              {
                'opportunity_id': 'o2',
                'opportunity_no': 'OPP-002',
                'deal_name': 'Warehouse racking',
                'deal_amount': 20000,
                'document_id': 'q2',
                'doc_no': 'QUO-0012',
                'quoted_amount': 23500,
                'difference': 3500,
              },
            ],
          ),
        ],
        showPipelineQuoteMismatch,
      );
      expect(find.text('The forecast and the quotations'), findsOneWidget);
      // Summed by the dialog over both rows, and signed -- over is not
      // better than under, because both mean the forecast is reporting
      // a number nobody quoted.
      expect(find.text('The pipeline is out by'), findsOneWidget);
      // `Fmt.money` puts the minus AFTER the prefix -- "RM -7,000.00"
      // -- while the row prepends its own "+" for the other direction.
      // Both shapes on the page at once, which is the thing to pin.
      expect(find.text('RM -3,500.00'), findsOneWidget);
      expect(find.text('+RM 3,500.00'), findsOneWidget);
      expect(find.text('RM -7,000.00'), findsOneWidget);
      // On a phone the "Use quoted" button is a menu, because a figure
      // plus a labelled button is more than a ListTile has left --
      // this row used to trip Flutter's own "Trailing widget consumes
      // the entire tile width".
      expect(
        find.byKey(const ValueKey<String>('mismatch-menu-o1')),
        findsOneWidget,
      );
      expect(find.text('Use quoted'), findsNothing);
      // A deal with no customer name still reads.
      expect(
        find.text('— · deal RM 20,000.00 · QUO-0012 RM 23,500.00'),
        findsOneWidget,
      );
    });

    testWidgets('and an empty list says which deals are not counted',
        (tester) async {
      await opened(
        tester,
        [pipelineQuoteMismatchProvider.overrideWith((ref) async => [])],
        showPipelineQuoteMismatch,
      );
      // The sentence that stops somebody trusting a clean result they
      // should not: a deal with no quotation is not agreement.
      expect(
        find.textContaining('there is nothing to compare them to'),
        findsOneWidget,
      );
    });
  });

  group('who is away', () {
    testWidgets('opens, and marks the person nobody can reach',
        (tester) async {
      final soon = DateTime.now().add(const Duration(days: 3));
      await opened(
        tester,
        [
          // Opens on thirty days: far enough to see the trip somebody
          // has not left a number for while there is still time to ask.
          whoIsAwayProvider(30).overrideWith(
            (ref) async => [
              {
                'employee_name': 'Ahmad Faiz',
                'leave_type': 'Annual',
                'start_date': soon.toIso8601String(),
                'end_date': soon.toIso8601String(),
                'contact_while_away': '012-3456789',
                'has_contact': true,
              },
              {
                'employee_name': 'Nurul Huda',
                'leave_type': 'Annual',
                'start_date': soon.toIso8601String(),
                'end_date': soon.toIso8601String(),
                'has_contact': false,
              },
            ],
          ),
        ],
        showWhoIsAway,
      );
      expect(find.text('Who is away'), findsOneWidget);
      expect(find.text('012-3456789'), findsOneWidget);
      // `has_contact` is read off the report rather than recomputed
      // from the text, so an empty string cannot count as a contact on
      // this side after the database stored it as null.
      expect(find.text('No contact given'), findsOneWidget);
      // A date turned into words relative to today.
      expect(find.textContaining('Annual — Away from'), findsWidgets);
    });

    testWidgets('and says what would appear when nobody is', (tester) async {
      await opened(
        tester,
        [whoIsAwayProvider(30).overrideWith((ref) async => [])],
        showWhoIsAway,
      );
      expect(find.text('Nobody is away'), findsOneWidget);
    });
  });

  group('documents expiring', () {
    testWidgets('opens, and an expired pass says what the law calls it',
        (tester) async {
      await opened(
        tester,
        [
          // SIXTY, not thirty. `0025`'s comment named that window and
          // it is the right default — a work permit renewal takes
          // weeks, so a fortnight's notice is notice of something
          // already too late to do calmly. Keying the fixture on 30
          // leaves the real provider in place and the dialog renders
          // an error view instead of rows.
          expiringDocumentsProvider(60).overrideWith(
            (ref) async => [
              {
                'document_id': 'd1',
                'employee_name': 'Bikash Rai',
                'title': 'Work permit',
                'doc_type': 'work_permit',
                'consequence': 'offence',
                'days_until': -14,
                'is_expired': true,
                'expires_date': '2026-09-08',
              },
            ],
          ),
        ],
        showExpiringDocuments,
      );
      expect(find.text('Documents expiring'), findsOneWidget);
      // Negative days become words.
      expect(
        find.textContaining('Work Permit · Expired 14 days ago'),
        findsOneWidget,
      );
      // The note appears ONLY on the offence, and says what it is
      // rather than "renew soon" — which on a pass that lapsed a
      // fortnight ago understates it to the point of being wrong.
      expect(
        find.textContaining('an offence by the company under s.55B'),
        findsOneWidget,
      );
    });

    testWidgets('and the day before is its own sentence', (tester) async {
      // A row of its own rather than a second row above: the offence
      // note runs to four lines in a dialog this narrow, and a
      // `ListView` does not build what the viewport cannot reach.
      await opened(
        tester,
        [
          expiringDocumentsProvider(60).overrideWith(
            (ref) async => [
              {
                'document_id': 'd2',
                'employee_name': 'Siti Aminah',
                'title': 'Driving licence',
                'doc_type': 'licence',
                'consequence': 'renewal',
                'days_until': 1,
                'is_expired': false,
                'expires_date': '2026-09-23',
              },
            ],
          ),
        ],
        showExpiringDocuments,
      );
      expect(
        find.textContaining('Licence · Expires tomorrow'),
        findsOneWidget,
      );
      // No offence, so no note. A renewal is not a crime.
      expect(find.textContaining('s.55B'), findsNothing);
    });

    testWidgets('and a document with no date on it says that', (tester) async {
      await opened(
        tester,
        [
          expiringDocumentsProvider(60).overrideWith(
            (ref) async => [
              {
                'document_id': 'd3',
                'employee_name': 'Lim Wei Ling',
                'title': 'Degree certificate',
                'doc_type': 'certificate',
                'consequence': 'renewal',
              },
            ],
          ),
        ],
        showExpiringDocuments,
      );
      // Null days is not zero days. "Expires today" on a certificate
      // with no expiry would be a fabricated deadline.
      expect(find.textContaining('No expiry date'), findsOneWidget);
    });
  });

  group('purchases that were never capitalised', () {
    testWidgets('opens, and each row offers to capitalise it',
        (tester) async {
      await opened(
        tester,
        [
          uncapitalisedPurchasesProvider.overrideWith(
            (ref) async => [
              {
                'document_id': 'b1',
                'line_id': 'l1',
                'doc_no': 'BILL-0031',
                'doc_date': '2026-08-14',
                'description': 'Dell workstation',
                'supplier_name': 'Tech Supply Sdn Bhd',
                'account_code': '6300',
                'account_name': 'Office equipment',
                'amount': 6800,
              },
            ],
          ),
        ],
        showUncapitalisedPurchases,
      );
      expect(find.text('Dell workstation'), findsOneWidget);
      expect(
        find.text('BILL-0031 · 14/08/2026 · Tech Supply Sdn Bhd · '
            '6300 Office equipment'),
        findsOneWidget,
      );
      expect(find.text('RM 6,800.00'), findsOneWidget);
    });

    testWidgets('and a line with no description falls back to its number',
        (tester) async {
      await opened(
        tester,
        [
          uncapitalisedPurchasesProvider.overrideWith(
            (ref) async => [
              {
                'document_id': 'b2',
                'line_id': 'l2',
                'doc_no': 'BILL-0032',
                'doc_date': '2026-08-20',
                'description': '',
                'supplier_name': 'Tech Supply Sdn Bhd',
                'account_code': '6300',
                'account_name': 'Office equipment',
                'amount': 1200,
              },
            ],
          ),
        ],
        showUncapitalisedPurchases,
      );
      // An empty description is not a title. Without the fallback the
      // row would have a blank first line.
      expect(find.text('BILL-0032'), findsOneWidget);
    });
  });

  group('assigning a ticket', () {
    TeamMember member(String id, String name, {String status = 'active'}) =>
        TeamMember(
          memberId: 'm-$id',
          userId: id,
          fullName: name,
          role: 'member',
          status: status,
        );

    testWidgets('opens, and warns that giving it away opens it',
        (tester) async {
      await opened(
        tester,
        [
          teamProvider.overrideWith(
            (ref) async => [member('u1', 'Siti'), member('u2', 'Ravi')],
          ),
        ],
        (context) => showAssignTicketSheet(
          context,
          ticketId: 't1',
          status: 'new',
        ),
      );
      expect(find.text('Assign this ticket'), findsOneWidget);
      // `assign_ticket` carries the clause, and the form says so
      // BEFORE it happens rather than letting the status change under
      // the reader.
      expect(
        find.text('This ticket is still new. Giving it to somebody opens it.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('assign-person')), findsOneWidget);
    });

    testWidgets('and says nothing about opening one already open',
        (tester) async {
      await opened(
        tester,
        [teamProvider.overrideWith((ref) async => [member('u1', 'Siti')])],
        (context) => showAssignTicketSheet(
          context,
          ticketId: 't1',
          status: 'open',
        ),
      );
      expect(find.textContaining('still new'), findsNothing);
    });

    testWidgets('and an invitation nobody accepted leaves nobody to assign',
        (tester) async {
      // A pending member has no `user_id` the database would take, so
      // the list is empty and the form says why — rather than showing
      // an empty picker that looks like a loading failure.
      await opened(
        tester,
        [
          teamProvider.overrideWith(
            (ref) async => [member('u1', 'Siti', status: 'invited')],
          ),
        ],
        (context) => showAssignTicketSheet(
          context,
          ticketId: 't1',
          status: 'open',
        ),
      );
      expect(
        find.textContaining('Nobody here has accepted their invitation yet'),
        findsOneWidget,
      );
    });

    testWidgets('and a team roster narrows who it may go to', (tester) async {
      // `0355` refuses somebody who is not on the team the ticket is
      // with, so the list offered has to be the set the server will
      // take.
      await opened(
        tester,
        [
          teamProvider.overrideWith(
            (ref) async => [member('u1', 'Siti'), member('u2', 'Ravi')],
          ),
          ticketTeamRosterProvider('team-1').overrideWith(
            (ref) async => [
              {'user_id': 'u2'},
            ],
          ),
        ],
        (context) => showAssignTicketSheet(
          context,
          ticketId: 't1',
          status: 'open',
          teamId: 'team-1',
        ),
      );
      await tester.tap(find.byKey(const ValueKey('assign-person')));
      await tester.pumpAndSettle();
      expect(find.text('Ravi'), findsWidgets);
      expect(find.text('Siti'), findsNothing);
    });
  });

  group('escalating a ticket', () {
    testWidgets('opens, and is honest that the clock does not reset',
        (tester) async {
      await opened(
        tester,
        [
          ticketTeamsProvider.overrideWith(
            (ref) async => [
              {'id': 'team-1', 'name': 'Second line'},
            ],
          ),
          teamProvider.overrideWith(
            (ref) async => [
              TeamMember(
                memberId: 'm1',
                userId: 'u1',
                fullName: 'Siti',
                role: 'member',
                status: 'active',
              ),
            ],
          ),
        ],
        (context) => showEscalateTicketSheet(
          context,
          ticketId: 't1',
          status: 'open',
        ),
      );
      // Twice: the title and the button that does it.
      expect(find.text('Escalate'), findsNWidgets(2));
      // The SLA that was promised is still the one being measured, and
      // saying otherwise would be the one thing somebody escalating
      // wants to believe.
      expect(
        find.textContaining('It does not reset the clock'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('escalate-kind')), findsOneWidget);
    });
  });

  group('item categories', () {
    testWidgets('opens, and nests a child under its parent', (tester) async {
      await opened(
        tester,
        [
          itemCategoriesProvider.overrideWith(
            (ref) async => [
              {'id': 'c1', 'name': 'Drinks', 'code': 'DRK'},
              {
                'id': 'c2',
                'name': 'Hot drinks',
                'code': 'DRK-H',
                'parent_id': 'c1',
              },
            ],
          ),
        ],
        showItemCategories,
      );
      expect(find.text('Categories'), findsOneWidget);
      expect(find.text('Drinks'), findsOneWidget);
      expect(find.text('Hot drinks'), findsOneWidget);
      // The child is indented by its depth. Both rows are ListTiles in
      // one list, so the only thing that says one is under the other
      // is where it starts.
      final parent = tester.getRect(find.text('Drinks')).left;
      final child = tester.getRect(find.text('Hot drinks')).left;
      expect(child, greaterThan(parent));
    });

    testWidgets('and a category whose parent is missing still appears',
        (tester) async {
      // The walk down from the top cannot reach it, and a category
      // that vanishes from this list is one nobody can fix. It comes
      // back at depth 0 instead.
      await opened(
        tester,
        [
          itemCategoriesProvider.overrideWith(
            (ref) async => [
              {'id': 'c1', 'name': 'Drinks', 'code': 'DRK'},
              {
                'id': 'c9',
                'name': 'Orphaned',
                'code': 'ORP',
                'parent_id': 'gone',
              },
            ],
          ),
        ],
        showItemCategories,
      );
      expect(find.text('Orphaned'), findsOneWidget);
      expect(
        tester.getRect(find.text('Orphaned')).left,
        tester.getRect(find.text('Drinks')).left,
      );
    });

    testWidgets('and an empty list says what a category is for',
        (tester) async {
      await opened(
        tester,
        [itemCategoriesProvider.overrideWith((ref) async => [])],
        showItemCategories,
      );
      expect(find.text('Nothing is filed yet'), findsOneWidget);
    });
  });

  group('loyalty tiers', () {
    testWidgets('opens, and a threshold says how many are in it',
        (tester) async {
      await opened(
        tester,
        [
          loyaltyProgramProvider.overrideWith((ref) async => null),
          loyaltyTiersProvider.overrideWith(
            (ref) async => [
              {
                'id': 't1',
                'program_id': 'p1',
                'name': 'Emas',
                'min_points': 2000,
                'multiplier': 1.5,
                'members': 1,
                'is_active': true,
              },
              {
                'id': 't2',
                'program_id': 'p1',
                'name': 'Perak',
                'min_points': 500,
                'multiplier': 1,
                'members': 42,
                'is_active': false,
              },
            ],
          ),
        ],
        showLoyaltyTiers,
      );
      // A member is in the highest band their EARNED points reach, and
      // spending never costs a tier — the sentence that stops somebody
      // reading the threshold as a balance.
      expect(
        find.textContaining('Spending points never costs anybody a tier'),
        findsOneWidget,
      );
      // The multiplier is only mentioned when it is not 1, and the
      // member count is the number that says whether the threshold
      // means anything at all.
      expect(
        find.text('from 2000 points · earns 1.5× · 1 member'),
        findsOneWidget,
      );
      expect(
        find.text('retired · from 500 points · 42 members'),
        findsOneWidget,
      );
      // A retired tier offers no Retire button; a live one does.
      expect(find.byTooltip('Retire'), findsOneWidget);
    });

    testWidgets('and an empty list proposes a scheme', (tester) async {
      await opened(
        tester,
        [
          loyaltyProgramProvider.overrideWith((ref) async => null),
          loyaltyTiersProvider.overrideWith((ref) async => []),
        ],
        showLoyaltyTiers,
      );
      expect(find.textContaining('"Ahli" at nought'), findsOneWidget);
    });
  });

  group('the stock card', () {
    final item = Item(
      id: 'i1',
      code: 'KOPI-01',
      name: 'Kopi beans 1kg',
      itemType: 'inventory',
      uomCode: 'KGM',
    );

    // Opens on the whole company and the whole of time, which is what
    // the family key has to say.
    const query = (
      itemId: 'i1',
      from: null,
      to: null,
      warehouseId: null,
    );

    testWidgets('opens, and derives the average rather than reading one',
        (tester) async {
      await opened(
        tester,
        [
          warehousesProvider.overrideWith((ref) async => []),
          stockCardProvider(query).overrideWith(
            (ref) async => [
              {
                'moved_on': '2026-09-01',
                'quantity': 10,
                'balance_quantity': 10,
                'balance_value': 380,
              },
              {
                'moved_on': '2026-09-10',
                'quantity': 5,
                'balance_quantity': 15,
                'balance_value': 600,
              },
            ],
          ),
        ],
        (context) => showStockCard(context, item),
      );
      expect(find.text('Kopi beans 1kg · stock card'), findsOneWidget);
      // 600 over 15 is 40. The movement carries `average_cost_after`
      // per WAREHOUSE, so a card spanning several of them has no
      // single one — value over quantity is the only average that is
      // true of whatever was actually asked for.
      expect(
        find.textContaining('Closing 15 KGM at RM 600.00, an average of '
            'RM 40.00 each.'),
        findsOneWidget,
      );
    });

    testWidgets('and closing at nothing does not divide by it',
        (tester) async {
      // Everything sold. The average clause is dropped rather than
      // computed, which is the difference between a full stop and an
      // Infinity on the screen.
      await opened(
        tester,
        [
          warehousesProvider.overrideWith((ref) async => []),
          stockCardProvider(query).overrideWith(
            (ref) async => [
              {
                'moved_on': '2026-09-01',
                'quantity': -10,
                'balance_quantity': 0,
                'balance_value': 0,
              },
            ],
          ),
        ],
        (context) => showStockCard(context, item),
      );
      expect(
        find.textContaining('Closing 0 KGM at RM 0.00.'),
        findsOneWidget,
      );
      expect(find.textContaining('an average of'), findsNothing);
    });

    testWidgets('and a period with no movements says so', (tester) async {
      await opened(
        tester,
        [
          warehousesProvider.overrideWith((ref) async => []),
          stockCardProvider(query).overrideWith((ref) async => []),
        ],
        (context) => showStockCard(context, item),
      );
      // The empty branch has its own sentence and never reaches
      // `stockCardClosing` — and it names the three ways stock moves,
      // because "nothing here" invites the question "should there be".
      expect(
        find.textContaining('Stock arrives on a bill, leaves on a delivery, '
            'and is corrected by a stock take'),
        findsOneWidget,
      );
    });
  });

  group('the journal editor', () {
    testWidgets('opens, and stacks each line on a phone', (tester) async {
      await openedWithRef(
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
              Account(
                id: 'a2',
                code: '4000',
                name: 'Sales',
                accountType: 'revenue',
                accountSubtype: 'sales',
              ),
            ],
          ),
          departmentsProvider.overrideWith((ref) async => []),
          projectsProvider.overrideWith((ref) async => []),
        ],
        showJournalEditor,
      );
      // Debit and Credit are on their own row under the account and
      // the narrative, rather than beside them in two 110px boxes —
      // `MediaQuery.sizeOf` in a dialog reports the SCREEN, so the
      // `< 700` branch is about the phone and engages here. This
      // dialog is the one that already got that right, which is why it
      // is worth a test rather than a fix.
      expect(find.text('Debit'), findsWidgets);
      expect(find.text('Credit'), findsWidgets);
      final debit = tester.getRect(find.text('Debit').first);
      final credit = tester.getRect(find.text('Credit').first);
      expect(debit.top, credit.top);
      expect(debit.right, lessThanOrEqualTo(412));
      expect(credit.right, lessThanOrEqualTo(412));
    });
  });

  group('what the tills could not land', () {
    testWidgets('opens, and counts only the sales that took money',
        (tester) async {
      // The distinction the dialog exists for: a refused payload with
      // nothing on it is a bug in the till, not a hole in the takings.
      // Both are shown; only one is counted into the figure a manager
      // acts on.
      await opened(
        tester,
        [
          posOfflineProblemsProvider.overrideWith(
            (ref) async => [
              {
                'register': 'Counter 1',
                'taken_at': '2026-09-20T03:15:00Z',
                'total': 128.50,
                'message': 'Item KOPI-01 is not on this outlet\'s menu.',
              },
              {
                'register': 'Counter 2',
                'taken_at': '2026-09-20T04:00:00Z',
                'total': 61.00,
                'error_code': '23503',
              },
              {
                'register': 'Counter 2',
                'taken_at': '2026-09-20T04:05:00Z',
                'total': 0,
                'message': 'Empty basket.',
              },
            ],
          ),
        ],
        showOfflineProblems,
      );
      expect(find.text('What the tills could not land'), findsOneWidget);
      // Two of the three took money: 128.50 + 61.00.
      expect(
        find.text('2 sales worth RM 189.50 never landed.'),
        findsOneWidget,
      );
      // The server's own sentence where there is one...
      expect(
        find.text('Item KOPI-01 is not on this outlet\'s menu.'),
        findsOneWidget,
      );
      // ...and the SQLSTATE only where there is not. A code tells a
      // shop manager nothing, but it beats a blank line.
      expect(find.text('Refused: 23503'), findsOneWidget);
      // A till with no name still identifies its row by time.
      expect(find.textContaining('Counter 1 · '), findsOneWidget);
    });

    testWidgets('and a list where nothing took money says that',
        (tester) async {
      await opened(
        tester,
        [
          posOfflineProblemsProvider.overrideWith(
            (ref) async => [
              {'register': 'Counter 1', 'total': 0, 'message': 'Empty.'},
            ],
          ),
        ],
        showOfflineProblems,
      );
      // Not "0 sales worth RM 0.00", which reads as a hole of nothing
      // rather than as no hole at all.
      expect(find.text('Nothing took money.'), findsOneWidget);
      // And the row is LISTED rather than hidden: a till sending an
      // empty basket is a bug worth seeing, just not worth counting.
      // Asserted here rather than beside the other two, because the
      // paragraph above the list pushes a third row past the viewport
      // and a `ListView` does not build what it cannot reach.
      expect(find.text('nothing on it'), findsOneWidget);
    });

    testWidgets('and an empty list says every sale has since landed',
        (tester) async {
      await opened(
        tester,
        [posOfflineProblemsProvider.overrideWith((ref) async => [])],
        showOfflineProblems,
      );
      expect(find.text('Everything landed'), findsOneWidget);
    });
  });

  group('sold out', () {
    testWidgets('opens', (tester) async {
      await opened(
        tester,
        [
          posStoppedItemsProvider('o1').overrideWith((ref) async => []),
          canWriteProvider.overrideWithValue(true),
        ],
        (context) => showSoldOut(context, 'o1'),
      );
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });

  group('appointing an officer', () {
    List<Override> register() => [
          corpPersonsProvider.overrideWith(
            (ref) async => [
              CorpPerson(
                id: 'p1',
                kind: 'individual',
                fullName: 'Dato Sri Azman bin Hassan',
                nric: '650412-10-5533',
              ),
            ],
          ),
          corpPrincipalsProvider('e1').overrideWith((ref) async => []),
          canWriteProvider.overrideWithValue(true),
        ];

    Future<void> asRole(WidgetTester tester, String label) async {
      await tester.tap(find.byKey(const ValueKey('officer-role')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    testWidgets('opens on a director, with no licence and no principal',
        (tester) async {
      await opened(
        tester,
        register(),
        (context) => showOfficerSheet(context, entityId: 'e1'),
      );
      expect(find.text('Appoint an officer'), findsOneWidget);
      // The date on the s.58 notification, which is the form's own
      // words for what this date IS.
      expect(find.text('The date on the s.58 notification'), findsOneWidget);
      // A director needs no licence and stands in for nobody, so
      // neither section is on the form.
      expect(find.text('Licence'), findsNothing);
      expect(find.byKey(const ValueKey('officer-alternate-for')),
          findsNothing);
    });

    testWidgets('and a secretary is the only role asked for a licence',
        (tester) async {
      // s.20G of the Companies Commission Act requires one of a
      // secretary and of no other officer. Nobody else is asked, and
      // `officerValues` CLEARS it when the role moves away — a
      // director carrying a licence number is a register asserting a
      // qualification about a role that does not have one.
      await opened(
        tester,
        register(),
        (context) => showOfficerSheet(context, entityId: 'e1'),
      );
      await asRole(tester, 'Secretary');
      expect(find.text('Licence'), findsOneWidget);
      expect(
        find.text('Companies Commission Act, section 20G'),
        findsOneWidget,
      );
    });

    testWidgets('and an auditor is the only role checked against MIA',
        (tester) async {
      // s.263 of the Companies Act 2016 wants an approved company
      // auditor. A secretary is deliberately NOT asked here even
      // though MIA is a prescribed body under s.20G — that
      // appointment already carries a licence number above, and a
      // second card asking for an overlapping one is two places to
      // record one fact.
      await opened(
        tester,
        register(),
        (context) => showOfficerSheet(context, entityId: 'e1'),
      );
      await asRole(tester, 'Auditor');
      expect(find.byKey(const ValueKey('officer-mia-later')), findsOneWidget);
      // And the auditor is not asked for a s.20G licence.
      expect(find.text('Licence'), findsNothing);
    });

    testWidgets('and an alternate director is asked whose place they take',
        (tester) async {
      // s.208: an alternate acts in a PARTICULAR director's place,
      // with that director's vote and not as well as it. A chairman
      // stands in for nobody, so the field is not offered there.
      await opened(
        tester,
        register(),
        (context) => showOfficerSheet(context, entityId: 'e1'),
      );
      await asRole(tester, 'Alternate director');
      expect(
        find.byKey(const ValueKey('officer-alternate-for')),
        findsOneWidget,
      );

      await asRole(tester, 'Chairman');
      expect(
        find.byKey(const ValueKey('officer-alternate-for')),
        findsNothing,
      );
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
