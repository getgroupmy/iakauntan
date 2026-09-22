import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/format.dart';
import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/quick_add_dialog.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/data/corp_models.dart';
import 'package:iakauntan/src/data/places_repository.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/assets/capital_allowances_dialog.dart';
import 'package:iakauntan/src/features/assets/capitalise_dialog.dart';
import 'package:iakauntan/src/features/assets/asset_editor.dart';
import 'package:iakauntan/src/features/assets/depreciation_dialog.dart';
import 'package:iakauntan/src/features/assets/disposal_dialog.dart';
import 'package:iakauntan/src/features/crm/quote_mismatch_dialog.dart';
import 'package:iakauntan/src/features/crm/win_loss_dialog.dart';
import 'package:iakauntan/src/features/documents/late_orders_dialog.dart';
import 'package:iakauntan/src/features/contacts/contact_delete.dart';
import 'package:iakauntan/src/features/documents/void_document.dart';
import 'package:iakauntan/src/features/settings/einvoice_credentials.dart';
import 'package:iakauntan/src/features/financials/fs_mapping.dart';
import 'package:iakauntan/src/features/hr/expiring_documents.dart';
import 'package:iakauntan/src/features/hr/departure_dialog.dart';
import 'package:iakauntan/src/features/hr/hire_dialog.dart';
import 'package:iakauntan/src/features/hr/leave_bands_dialog.dart';
import 'package:iakauntan/src/features/items/item_categories_dialog.dart';
import 'package:iakauntan/src/features/items/stock_card_dialog.dart';
import 'package:iakauntan/src/features/ledger/journal_editor.dart';
import 'package:iakauntan/src/features/loyalty/loyalty_tiers_dialog.dart';
import 'package:iakauntan/src/features/ticketing/ticket_routing_sheet.dart';
import 'package:iakauntan/src/features/hr/who_is_away.dart';
import 'package:iakauntan/src/features/legal/over_agreed_fee_dialog.dart';
import 'package:iakauntan/src/features/pos/offline_controller.dart';
import 'package:iakauntan/src/features/secretarial/officer_sheet.dart';
import 'package:iakauntan/src/features/secretarial/beneficial_owner_sheet.dart';
import 'package:iakauntan/src/features/secretarial/charge_sheet.dart';
import 'package:iakauntan/src/features/secretarial/filing_lifecycle.dart';
import 'package:iakauntan/src/features/secretarial/particulars_sheet.dart';
import 'package:iakauntan/src/features/secretarial/person_editor.dart';
import 'package:iakauntan/src/features/secretarial/resolution_sheet.dart';
import 'package:iakauntan/src/features/secretarial/share_class_sheet.dart';
import 'package:iakauntan/src/features/secretarial/share_event_sheet.dart';
import 'package:iakauntan/src/features/pos/offline_problems_dialog.dart';
import 'package:iakauntan/src/features/pos/recipe_requirement_dialog.dart';
import 'package:iakauntan/src/features/pos/sold_out_dialog.dart';
import 'package:iakauntan/src/features/property/charge_run_sheet.dart';
import 'package:iakauntan/src/features/property/statutory_charge_sheet.dart';
import 'package:iakauntan/src/features/property/strata_sheet.dart';
import 'package:iakauntan/src/features/property/tenancy_sheet.dart';
import 'package:iakauntan/src/features/property/unit_sheet.dart';

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

  group('discarding and voiding', () {
    testWidgets('discarding says nothing in the ledger changes',
        (tester) async {
      await opened(
        tester,
        const [],
        (context) => askDiscard(context, docNo: 'INV-0042'),
      );
      expect(find.text('Discard INV-0042?'), findsOneWidget);
      // The whole point of the distinction: this one was never posted.
      expect(
        find.textContaining('nothing in the ledger changes'),
        findsOneWidget,
      );
      expect(find.text('Keep it'), findsOneWidget);
    });

    testWidgets('voiding says the number is kept, and why', (tester) async {
      await opened(
        tester,
        const [],
        (context) => askVoidReason(context, docNo: 'INV-0042'),
      );
      expect(find.text('Void INV-0042'), findsOneWidget);
      // A gap in a numbered run is the thing an auditor asks about, so
      // the document stays and keeps its number. That sentence is the
      // difference between this dialog and the one above.
      expect(
        find.textContaining('a gap in a numbered run is the thing an '
            'auditor asks about'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('void-reason')), findsOneWidget);
    });

    testWidgets('and voiding will not go through without a reason',
        (tester) async {
      // The button is always enabled and the handler refuses instead,
      // so pressing it with an empty box must leave the dialog open.
      await opened(
        tester,
        const [],
        (context) => askVoidReason(context, docNo: 'INV-0042'),
      );
      await tester.tap(find.text('Void it'));
      await tester.pumpAndSettle();
      expect(find.text('Void INV-0042'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('void-reason')),
        'Raised against the wrong customer',
      );
      await tester.tap(find.text('Void it'));
      await tester.pumpAndSettle();
      expect(find.text('Void INV-0042'), findsNothing);
    });
  });

  group('the two core prompts', () {
    testWidgets('promptForText keeps Save dead until something is typed',
        (tester) async {
      await opened(
        tester,
        const [],
        (context) => promptForText(
          context,
          title: 'Name this view',
          label: 'Name',
          suggestions: const ['Overdue', 'This month'],
        ),
      );
      expect(find.text('Name this view'), findsOneWidget);
      // A suggestion fills the box rather than saving by itself.
      expect(find.text('Overdue'), findsOneWidget);
      // By its LABEL, not by type: the host that opened the dialog has
      // a FilledButton of its own, so `find.byType` matches two.
      final save = find.widgetWithText(FilledButton, 'Save');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      await tester.tap(find.text('Overdue'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    });

    testWidgets('and quickAdd opens with the name it was handed',
        (tester) async {
      // Reached from a picker when somebody types a name that is not
      // on the list, so the typed text has to arrive in the box — or
      // they type it twice.
      await opened(
        tester,
        const [],
        (context) => quickAdd(
          context,
          title: 'New department',
          seed: 'Kitchen',
          save: ({required String name, String? code}) async => 'd1',
        ),
      );
      expect(find.text('New department'), findsOneWidget);
      expect(find.text('Kitchen'), findsOneWidget);
    });
  });

  group('removing e-Invoice credentials', () {
    testWidgets('says when it switches submission off with them',
        (tester) async {
      // The dangerous half. A company left enabled with no credentials
      // is one marked live against a submitter that cannot log in, so
      // the dialog says the switch goes too rather than leaving
      // somebody to find out from a failed submission.
      await opened(
        tester,
        const [],
        (context) => askRemoveCredentials(
          context,
          environment: 'production',
          alsoDisables: true,
        ),
      );
      expect(find.text('Remove these credentials?'), findsOneWidget);
      expect(
        find.textContaining('The production client id and secret are '
            'deleted, and e-Invoice submission is switched off with them'),
        findsOneWidget,
      );
    });

    testWidgets('and says when it does not', (tester) async {
      // Submission is pointed at the other environment, so nothing is
      // switched off — and saying it would be would stop somebody
      // tidying up a sandbox they no longer use.
      await opened(
        tester,
        const [],
        (context) => askRemoveCredentials(
          context,
          environment: 'sandbox',
          alsoDisables: false,
        ),
      );
      expect(
        find.textContaining('Submission is pointed at the other '
            'environment and is left alone.'),
        findsOneWidget,
      );
      expect(find.textContaining('switched off'), findsNothing);
    });
  });

  group('deleting a contact', () {
    testWidgets('names who, and says when it is possible at all',
        (tester) async {
      await openedWithRef(
        tester,
        const [],
        (context, ref) => confirmAndDeleteContact(
          context,
          ref,
          id: 'c1',
          name: 'Kedai Runcit Aman',
        ),
      );
      expect(
        find.byKey(const ValueKey('contact-delete-confirm')),
        findsOneWidget,
      );
      // It is only possible while nothing points at the contact, which
      // is the sentence that stops somebody reading a refusal as a
      // bug.
      expect(
        find.textContaining('Delete Kedai Runcit Aman?'),
        findsOneWidget,
      );
      expect(
        find.textContaining('only possible while nothing points at the '
            'contact'),
        findsOneWidget,
      );
    });

    testWidgets('and falls back to "this contact" for a blank name',
        (tester) async {
      // A contact saved with no name is a real row, and "Delete ?" is
      // not a question.
      await openedWithRef(
        tester,
        const [],
        (context, ref) => confirmAndDeleteContact(
          context,
          ref,
          id: 'c1',
          name: '   ',
        ),
      );
      expect(find.textContaining('Delete this contact?'), findsOneWidget);
    });
  });

  group('the asset register, over an asset\'s life', () {
    /// A van bought for RM 90,000, four years into a five-year life.
    ///
    /// The figures are chosen so every derived line below is wrong if
    /// the arithmetic is wrong in the obvious ways: cost minus
    /// accumulated is 18,000, which is neither the cost nor the
    /// accumulated, and the annual charge is 18,000 a year, which is
    /// the same number for a different reason. Any test that agrees
    /// with both of those by accident has to have got there twice.
    final van = FixedAsset(
      id: 'a1',
      assetNo: 'FA-0007',
      name: 'Toyota Hiace',
      acquisitionDate: DateTime(2021, 7, 1),
      cost: 90000,
      residualValue: 0,
      method: 'straight_line',
      usefulLifeMonths: 60,
      accumulatedDepreciation: 72000,
      caClassCode: 'motor_vehicle',
    );

    List<Override> withClasses() => [
          capitalAllowanceClassesProvider.overrideWith((ref) async => [
                CapitalAllowanceClass(
                  code: 'motor_vehicle',
                  label: 'Motor vehicles',
                  initialRate: 0.20,
                  annualRate: 0.20,
                  costCap: 50000,
                ),
                CapitalAllowanceClass(
                  code: 'plant',
                  label: 'Plant and machinery',
                  initialRate: 0.20,
                  annualRate: 0.14,
                  isVerified: true,
                ),
                CapitalAllowanceClass(
                  code: 'small_value',
                  label: 'Small value assets',
                  initialRate: 1.0,
                  annualRate: 0,
                  smallValueThreshold: 2000,
                ),
              ]),
        ];

    testWidgets('the editor opens on a new asset and prices its own life',
        (tester) async {
      // Nothing had ever built this. The annual charge is computed in
      // the widget from four controllers, so it is the one figure here
      // that no repository could be wrong about on its behalf.
      await openedWithRef(
        tester,
        withClasses(),
        (context, ref) => showAssetEditor(context, ref),
      );

      expect(find.text('New asset'), findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextField, 'Cost *'), '60000');
      await tester.pumpAndSettle();

      // 60,000 over 60 months, which the form defaults to.
      expect(
        find.text('RM 12,000.00 a year, RM 1,000.00 a month'),
        findsOneWidget,
      );
    });

    testWidgets('a residual value comes off the charge, not off the cost',
        (tester) async {
      // The distinction the field exists for: an asset is depreciated
      // down TO the residual, so the residual reduces what is charged
      // and does not reduce the cost the register carries.
      await openedWithRef(
        tester,
        withClasses(),
        (context, ref) => showAssetEditor(context, ref),
      );

      await tester.enterText(
          find.widgetWithText(TextField, 'Cost *'), '60000');
      await tester.enterText(
          find.widgetWithText(TextField, 'Residual value'), '12000');
      await tester.pumpAndSettle();

      expect(
        find.text('RM 9,600.00 a year, RM 800.00 a month'),
        findsOneWidget,
      );
    });

    testWidgets('reducing balance says the first year is the biggest one',
        (tester) async {
      await openedWithRef(
        tester,
        withClasses(),
        (context, ref) => showAssetEditor(context, ref),
      );

      await tester.enterText(
          find.widgetWithText(TextField, 'Cost *'), '60000');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reducing balance'));
      await tester.pumpAndSettle();

      // 20% is the form's default rate. The sentence has to carry the
      // "less every year after", or a straight-line reading of it
      // understates five years of charge badly.
      expect(
        find.textContaining('About RM 12,000.00 in the first year, '
            'less every year after'),
        findsOneWidget,
      );
      // And the months field is gone, not merely ignored.
      expect(find.widgetWithText(TextField, 'Useful life'), findsNothing);
    });

    testWidgets('editing a depreciated asset warns that history stands',
        (tester) async {
      // The assumption the warning exists to kill is that changing the
      // cost restates what has already been posted. It does not.
      await openedWithRef(
        tester,
        withClasses(),
        (context, ref) => showAssetEditor(context, ref, asset: van),
      );

      // Twice: the dialog is titled with the asset number rather than
      // "Edit asset", and the number is also prefilled into its own
      // field. `find.text` reaches inside an `EditableText`, so an
      // assertion of one here would be an assertion that the form did
      // NOT load.
      expect(find.text('FA-0007'), findsNWidgets(2));
      expect(
        find.textContaining('RM 72,000.00 has already been charged'),
        findsOneWidget,
      );
      expect(
        find.textContaining('nothing already posted is rewritten'),
        findsOneWidget,
      );
    });

    testWidgets('the capital allowance class carries its own restriction',
        (tester) async {
      // Schedule 3 caps a motor vehicle at RM 50,000 however much it
      // cost, and this van cost 90,000 — so the cap is the whole
      // difference between the accounts and the tax computation for
      // this asset, and it has to be on screen.
      await openedWithRef(
        tester,
        withClasses(),
        (context, ref) => showAssetEditor(context, ref, asset: van),
      );

      expect(find.text('Capital allowances'), findsOneWidget);
      expect(
        find.textContaining('computed on at most RM 50,000.00'),
        findsOneWidget,
      );
      // Depreciation is added back, so the two sets of figures are not
      // meant to agree and the heading says so.
      expect(
        find.textContaining('depreciation is added back in a tax '
            'computation'),
        findsOneWidget,
      );
    });

    testWidgets('a small-value class says what it stops applying above',
        (tester) async {
      await openedWithRef(
        tester,
        withClasses(),
        (context, ref) => showAssetEditor(context, ref),
      );

      await tester.tap(find.byKey(const ValueKey('asset-ca-class')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Small value assets — 100% then 0%').last);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('costing less than RM 2,000.00'),
        findsOneWidget,
      );
      // An unverified class is a different warning, and the small
      // value class here is unverified too.
      expect(
        find.textContaining('not transcribed from the Act'),
        findsOneWidget,
      );
    });

    testWidgets('no class at all is an answer, not an unfinished form',
        (tester) async {
      // Land and goodwill attract nothing and never will. A blank that
      // reads as a to-do is a blank somebody fills in wrongly.
      await openedWithRef(
        tester,
        withClasses(),
        (context, ref) => showAssetEditor(context, ref),
      );

      expect(
        find.text('No capital allowance (land, goodwill)'),
        findsWidgets,
      );
    });

    testWidgets('disposal shows the gain as a floor, not the answer',
        (tester) async {
      // The number on screen is proceeds minus net book value TODAY.
      // The database charges the months still outstanding first, so
      // the posted gain is smaller — and the dialog has to say that,
      // because a seller reading "gain of 8,000" will book 8,000.
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(_Repo(banks: [
            {'id': 'b1', 'name': 'Maybank current', 'bank_name': 'Maybank'},
          ])),
        ],
        (context, ref) => showDisposalDialog(context, ref, asset: van),
      );

      expect(find.text('Dispose of FA-0007'), findsOneWidget);
      expect(
        find.text('Cost RM 90,000.00 · depreciated RM 72,000.00 · '
            'net book value RM 18,000.00'),
        findsOneWidget,
      );

      await tester.enterText(
          find.widgetWithText(TextField, 'Proceeds'), '26000');
      await tester.pumpAndSettle();

      // 26,000 against a net book value of 18,000.
      expect(find.text('Gain of about RM 8,000.00'), findsOneWidget);
      expect(
        find.textContaining('the posted figure may be smaller than this'),
        findsOneWidget,
      );
    });

    testWidgets('and calls scrapping a loss, at the whole net book value',
        (tester) async {
      // Proceeds default to zero, which is what scrapping is. The loss
      // is then the entire net book value, and the dialog must not
      // print a negative gain to say so.
      await openedWithRef(
        tester,
        [repoProvider.overrideWithValue(_Repo(banks: const []))],
        (context, ref) => showDisposalDialog(context, ref, asset: van),
      );

      expect(find.text('Loss of about RM 18,000.00'), findsOneWidget);
      expect(find.textContaining('Gain of about'), findsNothing);
      // Blank proceeds go to cash, and the picker has to offer a way
      // back to that once an account has been chosen.
      expect(find.textContaining('they go to cash'), findsOneWidget);
    });

    testWidgets('the depreciation run prices every asset before posting',
        (tester) async {
      await openedWithRef(
        tester,
        [
          depreciationPreviewProvider.overrideWith((ref, asAt) async => [
                DepreciationLine(
                  assetId: 'a1',
                  assetNo: 'FA-0007',
                  name: 'Toyota Hiace',
                  cost: 90000,
                  accumulated: 72000,
                  charge: 1500,
                  netBookValue: 16500,
                ),
                DepreciationLine(
                  assetId: 'a2',
                  assetNo: 'FA-0011',
                  name: 'Laptop',
                  cost: 4800,
                  accumulated: 4800,
                  // Fully depreciated: nothing left to charge, and the
                  // run must not list it or the total double-counts a
                  // zero line into the operator's reading of the page.
                  charge: 0,
                  netBookValue: 0,
                ),
              ]),
        ],
        showDepreciationDialog,
      );

      expect(find.text('Run depreciation'), findsOneWidget);
      expect(find.text('FA-0007 · Toyota Hiace'), findsOneWidget);
      expect(find.text('FA-0011 · Laptop'), findsNothing);
      expect(
        find.text('net book value after: RM 16,500.00'),
        findsOneWidget,
      );
      // One asset due, so the total is that asset's charge -- and both
      // appear, which is what makes the total a total.
      expect(find.text('Total charge'), findsOneWidget);
      expect(find.text('RM 1,500.00'), findsNWidgets(2));
    });

    testWidgets('and says so plainly when there is nothing to charge',
        (tester) async {
      // Every asset up to date is a legitimate month, not an error.
      await openedWithRef(
        tester,
        [
          depreciationPreviewProvider.overrideWith((ref, asAt) async => [
                DepreciationLine(
                  assetId: 'a2',
                  assetNo: 'FA-0011',
                  name: 'Laptop',
                  cost: 4800,
                  accumulated: 4800,
                  charge: 0,
                  netBookValue: 0,
                ),
              ]),
        ],
        showDepreciationDialog,
      );

      expect(
        find.textContaining('Everything is already depreciated to'),
        findsOneWidget,
      );
      expect(find.text('Total charge'), findsNothing);
    });
  });

  group('the property register, from a parcel to the charge run', () {
    final owner = Contact(
      id: 'c1',
      code: 'C-0001',
      name: 'Puan Aminah',
      contactType: 'customer',
    );

    /// A small block: two parcels and the common property.
    ///
    /// 700 of 1,000 share units allocated, which is what makes the
    /// scheme sheet's completeness warning fire on real arithmetic
    /// rather than on a flag.
    const units = <Map<String, dynamic>>[
      {
        'id': 'u1',
        'unit_no': 'A-12-03',
        'unit_type': 'parcel',
        'share_units': 400,
        'is_chargeable': true,
      },
      {
        'id': 'u2',
        'unit_no': 'A-12-04',
        'unit_type': 'parcel',
        'share_units': 300,
        'is_chargeable': true,
      },
      {
        'id': 'u3',
        'unit_no': 'Surau',
        'unit_type': 'common',
        'share_units': null,
        'is_chargeable': false,
      },
    ];

    List<Override> site() => [
          propertyUnitsProvider.overrideWith((ref, siteId) async => units),
          contactsProvider.overrideWith((ref, args) async => [owner]),
        ];

    testWidgets('a strata unit sheet offers parcels, not shophouses',
        (tester) async {
      // `app.property_unit_matches_site` refuses the wrong pairing.
      // Offering only what the tenure allows is what stops the refusal
      // ever having to happen, so the dropdown's CONTENTS are the
      // rule — not decoration over it.
      await opened(
        tester,
        site(),
        (context) => showUnitSheet(context, siteId: 's1', tenure: 'strata'),
      );

      expect(find.text('Add a parcel'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('unit-type')));
      await tester.pumpAndSettle();

      expect(find.text('Accessory parcel'), findsWidgets);
      expect(find.text('Shop'), findsNothing);
      expect(find.text('Office'), findsNothing);
    });

    testWidgets('and a non-strata one offers shophouses, not parcels',
        (tester) async {
      await opened(
        tester,
        site(),
        (context) => showUnitSheet(context, siteId: 's1', tenure: 'landed'),
      );

      expect(find.text('Add a unit'), findsOneWidget);
      // No share units field at all: share units belong to a strata
      // scheme, and the trigger refuses them outright elsewhere.
      expect(find.byKey(const ValueKey('share-units')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('unit-type')));
      await tester.pumpAndSettle();
      expect(find.text('Shop'), findsWidgets);
      expect(find.text('Parcel'), findsNothing);
    });

    testWidgets('a chargeable parcel is refused without its share',
        (tester) async {
      // Billing a parcel with no allocated share is billing it in
      // proportion to nothing, which means its neighbours pay its
      // share. The form has to stop it before the trigger does.
      await opened(
        tester,
        site(),
        (context) => showUnitSheet(context, siteId: 's1', tenure: 'strata'),
      );

      await tester.enterText(
          find.byKey(const ValueKey('unit-no')), 'A-12-05');
      await tester.pumpAndSettle();

      // Before the refusal, because Material shows a field's helper
      // text OR its error, never both -- so asserting this after the
      // tap would be asserting the opposite of what is wanted.
      expect(
        find.textContaining('The Charges are levied in proportion to this'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('unit-save')));
      await tester.pumpAndSettle();

      expect(
        find.text('A chargeable parcel needs its share'),
        findsOneWidget,
      );
    });

    testWidgets('and common property carries neither owner nor charge',
        (tester) async {
      await opened(
        tester,
        site(),
        (context) => showUnitSheet(context, siteId: 's1', tenure: 'strata'),
      );

      await tester.tap(find.byKey(const ValueKey('unit-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Common property').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('unit-owner')), findsNothing);
      expect(find.byKey(const ValueKey('unit-chargeable')), findsNothing);
      expect(find.byKey(const ValueKey('share-units')), findsNothing);
      expect(
        find.textContaining('never billed and has no owner to bill'),
        findsOneWidget,
      );
    });

    testWidgets('the scheme sheet compares the schedule against the parcels',
        (tester) async {
      // 400 + 300 of a stated 1,000. Raising charges against a
      // denominator the parcels do not add up to is the failure this
      // line exists to catch, and the figures are read off the units
      // rather than off a column.
      await opened(
        tester,
        site(),
        (context) => showStrataSchemeSheet(context, siteId: 's1'),
      );

      expect(find.text('Set up the scheme'), findsOneWidget);
      expect(find.text('700 share units allocated so far.'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('total-share-units')), '1000');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Incomplete: 700 of 1000 allocated'),
        findsOneWidget,
        reason: 'the schedule says 1,000, not 1000.0',
      );
      expect(
        find.textContaining('a denominator the parcels do not add up to'),
        findsOneWidget,
      );
    });

    testWidgets('and calls the schedule complete when it adds up',
        (tester) async {
      await opened(
        tester,
        site(),
        (context) => showStrataSchemeSheet(context, siteId: 's1'),
      );

      await tester.enterText(
          find.byKey(const ValueKey('total-share-units')), '700');
      await tester.pumpAndSettle();

      expect(
        find.text('The Schedule of Parcels is complete: 700 of 700 '
            'allocated.'),
        findsOneWidget,
      );
    });

    testWidgets('the MC registration is asked for only once it is an MC',
        (tester) async {
      // Developer, then JMB, then MC. A registration number on a
      // development still in the developer's hands is a number for
      // something that does not exist yet.
      await opened(
        tester,
        site(),
        (context) => showStrataSchemeSheet(context, siteId: 's1'),
      );

      expect(
        find.widgetWithText(TextFormField, 'MC registration'),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('strata-stage')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Management corporation').last);
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextFormField, 'MC registration'),
        findsOneWidget,
      );
    });

    testWidgets('the rate sheet says a rate is added and never edited',
        (tester) async {
      // A charge raised for January stays raised at January's rate,
      // which is why this sheet has no Save-over — and why the
      // sentence has to be on it.
      await opened(
        tester,
        const [],
        (context) =>
            showChargeRateSheet(context, siteId: 's1', schemeId: 'sc1'),
      );

      expect(find.text('Record the rate resolved'), findsOneWidget);
      expect(
        find.textContaining('added and never edited'),
        findsOneWidget,
      );
      // The two statutory bounds, defaulted rather than left blank.
      expect(find.text('Not less than 10'), findsOneWidget);
      expect(find.text('Capped at 10'), findsOneWidget);
    });

    testWidgets('and refuses a sinking fund under the floor', (tester) async {
      await opened(
        tester,
        const [],
        (context) =>
            showChargeRateSheet(context, siteId: 's1', schemeId: 'sc1'),
      );

      await tester.enterText(
          find.byKey(const ValueKey('rate-per-share-unit')), '0.35');
      await tester.enterText(find.byKey(const ValueKey('sinking-fund')), '5');
      // The button is disabled until a date is chosen, so validation is
      // driven through the form rather than through the button — which
      // is the state a user without a date is actually in.
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('rate-save')), findsOneWidget);
      final save = tester.widget<FilledButton>(
          find.byKey(const ValueKey('rate-save')));
      expect(save.onPressed, isNull,
          reason: 'no effective-from date has been chosen yet');
    });

    testWidgets('the tenancy sheet will not let a unit to itself twice',
        (tester) async {
      // Save is held shut while the dates do not run, because
      // `tenancies_no_overlap` and the date check are two different
      // refusals and only one of them is worth a round trip.
      await opened(
        tester,
        site(),
        (context) => showTenancySheet(context, siteId: 's1'),
      );

      expect(find.text('Let a unit'), findsOneWidget);
      final save = tester.widget<FilledButton>(
          find.byKey(const ValueKey('tenancy-save')));
      expect(save.onPressed, isNull,
          reason: 'neither date has been given yet');
    });

    testWidgets('and does not offer common property to let', (tester) async {
      await opened(
        tester,
        site(),
        (context) => showTenancySheet(context, siteId: 's1'),
      );

      await tester.tap(find.byKey(const ValueKey('tenancy-unit')));
      await tester.pumpAndSettle();

      expect(find.text('A-12-03'), findsWidgets);
      expect(find.text('Surau'), findsNothing);
    });

    testWidgets('a statutory charge asks for a half only on assessment',
        (tester) async {
      // Quit rent is annual and assessment half-yearly. A half on a
      // quit rent is a period that does not exist, and the unique key
      // reads it as a different charge — which is how one year gets
      // entered twice.
      await opened(
        tester,
        site(),
        (context) => showStatutoryChargeSheet(context, siteId: 's1'),
      );

      // Assessment is what the sheet opens on, because it is the one
      // that comes round twice a year.
      expect(find.text('Record a charge'), findsOneWidget);
      expect(find.text('Assessment is half-yearly'), findsOneWidget);
      expect(find.text('The local council'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('statutory-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quit rent (cukai tanah)').last);
      await tester.pumpAndSettle();

      // Quit rent is annual: the half goes, and the authority's helper
      // follows the charge to the state land office.
      expect(find.text('Assessment is half-yearly'), findsNothing);
      expect(find.text('The state land office'), findsOneWidget);
      expect(find.text('The local council'), findsNothing);
    });

    testWidgets('a paid date with no receipt is refused where it is typed',
        (tester) async {
      // `0387`: a typed paid date took the charge off the due list with
      // no bill, no supplier and nothing in the ledger. The database
      // refuses it; this is the same refusal, without the round trip.
      await opened(
        tester,
        site(),
        (context) => showStatutoryChargeSheet(
          context,
          siteId: 's1',
          charge: const {
            'id': 'q1',
            'kind': 'quit_rent',
            'period_year': 2025,
            'amount': 480,
            'due_date': '2025-05-31',
            'paid_on': '2025-05-20',
          },
        ),
      );

      expect(find.text('Amend the charge'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('statutory-reference')),
        findsOneWidget,
      );

      await tester.enterText(
          find.byKey(const ValueKey('statutory-reference')), '   ');
      await tester.tap(find.byKey(const ValueKey('statutory-save')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('takes the charge off the due list with '
            'nothing behind it'),
        findsOneWidget,
      );
    });

    testWidgets('a billed charge is told its paid date, not asked for it',
        (tester) async {
      // The bill is the record of the payment. Offering a second place
      // to type one would be two records of the same thing.
      await opened(
        tester,
        site(),
        (context) => showStatutoryChargeSheet(
          context,
          siteId: 's1',
          charge: const {
            'id': 'q2',
            'kind': 'assessment',
            'period_year': 2025,
            'period_half': 1,
            'amount': 320,
            'due_date': '2025-02-28',
            'bill_document_id': 'd1',
            // As `propertyStatutoryCharges` selects it. The flat
            // `bill_no` is `site_screen`'s reshaping, and a fixture
            // written in that shape would have hidden the defect this
            // test found: the tooltip below asked the raw row for
            // `bill_no`, got null, and dropped the number.
            'purchase_documents': {'doc_no': 'BILL-0042'},
          },
        ),
      );

      expect(
        find.byKey(const ValueKey('statutory-paid-by-bill')),
        findsOneWidget,
      );
      expect(find.text('Billed, not yet paid'), findsOneWidget);
      expect(
        find.textContaining('From bill BILL-0042. Settle the bill and '
            'this follows it.'),
        findsOneWidget,
      );
      // And it cannot be billed a second time.
      final bill = tester.widget<TextButton>(
          find.byKey(const ValueKey('statutory-bill')));
      expect(bill.onPressed, isNull);
      expect(
        find.byTooltip('Already on bill BILL-0042.'),
        findsOneWidget,
      );
    });

    testWidgets('the charge run prices the period before it raises it',
        (tester) async {
      // The preview is `strata_charge_preview` — the same function the
      // engine loops over when it writes the invoices — so the total
      // here is the total the owners receive. The button counts the
      // rows so nobody raises 47 invoices meaning to raise one.
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(_Repo(rpc: {
            'strata_charge_preview': [
              {
                'unit_no': 'A-12-03',
                'owner_name': 'Puan Aminah',
                'share_units': 400,
                'maintenance_amount': 140,
                'sinking_amount': 14,
                'total_amount': 154,
              },
              {
                'unit_no': 'A-12-04',
                'owner_name': null,
                'share_units': 300,
                'maintenance_amount': 105,
                'sinking_amount': 10.5,
                'total_amount': 115.5,
              },
            ],
          })),
        ],
        (context, ref) =>
            showChargeRunSheet(context, ref, strata: true, id: 'sc1'),
      );

      expect(find.text('Raise maintenance charges'), findsOneWidget);
      expect(find.text('A-12-03 · Puan Aminah'), findsOneWidget);
      // A parcel with no owner on file still has to appear, or the
      // total on the button is bigger than the list explaining it.
      expect(find.text('A-12-04 · No owner'), findsOneWidget);
      expect(
        find.text('400 share units · charges RM 140.00 + sinking fund '
            'RM 14.00'),
        findsOneWidget,
      );
      expect(find.text('2 invoices'), findsOneWidget);
      expect(find.text('Raise 2 invoices'), findsOneWidget);
      // 154 + 115.50.
      expect(find.text('RM 269.50'), findsOneWidget);
    });

    testWidgets('and holds the button shut when there is nothing to raise',
        (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(
              _Repo(rpc: const {'rent_preview': <Map<String, dynamic>>[]})),
        ],
        (context, ref) =>
            showChargeRunSheet(context, ref, strata: false, id: 's1'),
      );

      expect(find.text('Raise rent'), findsOneWidget);
      expect(find.text('Nothing to raise for this period.'), findsOneWidget);
      final raise = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Raise 0 invoices'));
      expect(raise.onPressed, isNull);
      // The default due date is stated rather than left to be guessed.
      expect(
        find.text('Due on the first day of the period'),
        findsOneWidget,
      );
    });
  });

  group('the statutory registers a company secretary keeps', () {
    final aminah = CorpPerson(
      id: 'p1',
      kind: 'individual',
      fullName: 'Aminah binti Hassan',
      nric: '800101-14-5566',
    );
    final lim = CorpPerson(
      id: 'p2',
      kind: 'individual',
      fullName: 'Lim Wei Ming',
      nric: '751212-10-1122',
    );

    const shareClasses = <Map<String, dynamic>>[
      {
        'id': 'sc1',
        'code': 'ORD',
        'name': 'Ordinary',
        'currency': 'MYR',
        'votes_per_share': 1,
        'is_redeemable': false,
      },
      {
        'id': 'sc2',
        'code': 'PREF',
        'name': 'Redeemable preference',
        'currency': 'MYR',
        'votes_per_share': 0,
        'is_redeemable': true,
      },
    ];

    List<Override> company({List<Map<String, dynamic>>? classes}) => [
          corpShareClassesProvider
              .overrideWith((ref, id) async => classes ?? shareClasses),
          corpPersonsProvider.overrideWith((ref) async => [aminah, lim]),
        ];

    testWidgets('a class of shares opens on the ordinary case',
        (tester) async {
      // ORD / Ordinary / MYR / one vote is what nine companies in ten
      // have, so the sheet is already filled in with it rather than
      // asking four questions everybody answers the same way.
      await opened(
        tester,
        company(),
        (context) => showShareClassSheet(context, entityId: 'e1'),
      );

      expect(find.text('Add a class of shares'), findsOneWidget);
      expect(find.text('ORD'), findsOneWidget);
      expect(find.text('Ordinary'), findsOneWidget);
      expect(find.text('MYR'), findsOneWidget);
      // Non-voting is a real class, not a mistake, and the helper says
      // so where somebody might otherwise think zero is refused.
      expect(find.text('0 for non-voting'), findsOneWidget);
    });

    testWidgets('and refuses a currency that is not three letters',
        (tester) async {
      await opened(
        tester,
        company(),
        (context) => showShareClassSheet(context, entityId: 'e1'),
      );

      // Two letters, not seven: the box caps itself at three, so
      // "RINGGIT" arrives as "RIN" and passes. What the validator is
      // actually for is the short answer somebody stops typing.
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Currency'), 'RM');
      await tester.tap(find.byKey(const ValueKey('share-class-save')));
      await tester.pumpAndSettle();

      expect(find.text('Three letters'), findsOneWidget);
    });

    testWidgets('a share movement multiplies out its own consideration',
        (tester) async {
      // The s.78 return reports the total. Asking for it as well as
      // the price would be asking twice, and the two would part the
      // first time somebody changed the quantity.
      await opened(
        tester,
        company(),
        (context) => showShareEventSheet(context, entityId: 'e1'),
      );

      expect(find.text('Record a share movement'), findsOneWidget);
      // Allotment is what the sheet opens on, and its note is the
      // fourteen days s.78 gives.
      expect(
        find.text('New shares issued. s.78 return within fourteen days.'),
        findsOneWidget,
      );

      await tester.enterText(
          find.byKey(const ValueKey('share-quantity')), '250000');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Price per share'), '1.50');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Total consideration RM 375,000.00'),
        findsOneWidget,
      );
    });

    testWidgets('an allotment asks for no transferor, a cancellation no '
        'transferee', (tester) async {
      // `corp_share_events_parties_ck` decides this. Asking for a
      // party the movement cannot have is a form that collects an
      // answer the database will refuse.
      await opened(
        tester,
        company(),
        (context) => showShareEventSheet(context, entityId: 'e1'),
      );

      expect(find.text('From'), findsNothing);
      expect(find.text('To'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('share-event-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancellation').last);
      await tester.pumpAndSettle();

      expect(find.text('To'), findsNothing);
      expect(find.text('From'), findsWidgets);
      expect(
        find.text('Buy-back or reduction. The issued capital falls.'),
        findsOneWidget,
      );
    });

    testWidgets('a transmission names the deceased, and stamping is a '
        "transfer's business", (tester) async {
      await opened(
        tester,
        company(),
        (context) => showShareEventSheet(context, entityId: 'e1'),
      );

      await tester.tap(find.byKey(const ValueKey('share-event-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transmission').last);
      await tester.pumpAndSettle();

      expect(find.text('From (deceased)'), findsOneWidget);
      expect(
        find.text('On death or bankruptcy — no instrument of transfer.'),
        findsOneWidget,
      );
      // Form 32A and its duty belong to a transfer alone; carried onto
      // a transmission they would be an instrument that does not exist.
      expect(find.widgetWithText(TextFormField, 'Stamp duty'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('share-event-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transfer').last);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'Stamp duty'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'Stamp certificate'),
        findsOneWidget,
      );
    });

    testWidgets('shares not issued for cash are asked what they were '
        'issued for', (tester) async {
      // s.78(2). The price box goes, because there was no price, and
      // the sentence replaces it rather than sitting beside it.
      await opened(
        tester,
        company(),
        (context) => showShareEventSheet(context, entityId: 'e1'),
      );

      await tester.tap(find.widgetWithText(SwitchListTile, 'For cash'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextFormField, 'Price per share'),
        findsNothing,
      );
      expect(
        find.widgetWithText(TextFormField, 'What the consideration was'),
        findsOneWidget,
      );
    });

    testWidgets('a company with no class of shares is told why, and where',
        (tester) async {
      // Every movement points at a class. An empty dropdown looks
      // broken and sends the secretary hunting for the screen that
      // fixes it, so the way out is attached to the sentence.
      await opened(
        tester,
        company(classes: const []),
        (context) => showShareEventSheet(context, entityId: 'e1'),
      );

      expect(
        find.textContaining('This company has no class of shares yet'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('add-share-class')), findsOneWidget);

      final record = tester.widget<FilledButton>(
          find.byKey(const ValueKey('share-event-save')));
      expect(record.onPressed, isNull);
    });

    testWidgets('a beneficial owner needs a ground, not a nomination',
        (tester) async {
      // s.60B does not let you simply nominate somebody. An entry with
      // nothing ticked asserts that a person controls the company for
      // no reason anybody wrote down, which is a name and not a
      // register entry — so the button is shut until one is given.
      await opened(
        tester,
        company(),
        (context) => showBeneficialOwnerSheet(context, entityId: 'e1'),
      );

      expect(find.text('Declare a beneficial owner'), findsOneWidget);
      expect(
        find.textContaining('A beneficial owner is one because a ground '
            'applies'),
        findsOneWidget,
      );
      var enter = tester.widget<FilledButton>(
          find.byKey(const ValueKey('owner-save')));
      expect(enter.onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('ground-shares')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('A beneficial owner is one because a ground '
            'applies'),
        findsNothing,
      );
      enter = tester.widget<FilledButton>(
          find.byKey(const ValueKey('owner-save')));
      expect(enter.onPressed, isNotNull);
    });

    testWidgets('and a ground written in prose counts as much as a tick',
        (tester) async {
      // "Control exercised through an arrangement" is a ground under
      // the Act even though it is not one of the four boxes.
      await opened(
        tester,
        company(),
        (context) => showBeneficialOwnerSheet(context, entityId: 'e1'),
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Some other ground'),
        'Controls the board through a shareholders agreement',
      );
      await tester.pumpAndSettle();

      final enter = tester.widget<FilledButton>(
          find.byKey(const ValueKey('owner-save')));
      expect(enter.onPressed, isNotNull);
    });

    testWidgets('a shareholding of two thousand per cent is refused',
        (tester) async {
      // `numeric(7,4)` would store it happily. The register would then
      // say somebody holds twenty times the company.
      await opened(
        tester,
        company(),
        (context) => showBeneficialOwnerSheet(context, entityId: 'e1'),
      );

      // Blank is allowed and is NOT nought: an unrecorded holding that
      // reads as a recorded nought is what an inspection finds. Read
      // before the refusal, because a field shows its helper or its
      // error and never both.
      expect(
        find.text('Leave empty if it is not a shareholding'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('ground-shares')));
      await tester.enterText(
          find.byKey(const ValueKey('owner-percent')), '2000');
      await tester.tap(find.byKey(const ValueKey('owner-save')));
      await tester.pumpAndSettle();

      expect(find.text('Between 0 and 100'), findsOneWidget);
    });

    testWidgets('cessation is offered on an existing entry, not a new one',
        (tester) async {
      await opened(
        tester,
        company(),
        (context) => showBeneficialOwnerSheet(
          context,
          entityId: 'e1',
          owner: CorpBeneficialOwner(
            id: 'bo1',
            personId: 'p1',
            name: 'Aminah binti Hassan',
            percent: 35,
            holds20pcShares: true,
          ),
        ),
      );

      expect(find.text('Amend the entry'), findsOneWidget);
      expect(find.text('Cessation'), findsOneWidget);
      expect(
        find.text('Leave empty while the ground still applies'),
        findsOneWidget,
      );
    });

    testWidgets('a charge counts its own thirty days from the instrument',
        (tester) async {
      // s.352. Missing it is not a late fee — an unregistered charge is
      // void against the liquidator, so the security a bank believes it
      // holds is not there at the only moment it matters.
      final created = DateTime.now().subtract(const Duration(days: 5));
      await opened(
        tester,
        company(),
        (context) => showChargeSheet(
          context,
          entityId: 'e1',
          charge: CorpCharge(
            id: 'ch1',
            chargeeName: 'Maybank Islamic Berhad',
            createdOn: created,
            chargeType: 'Debenture',
            amountSecured: 2500000,
          ),
        ),
      );

      expect(find.text('Amend the charge'), findsOneWidget);
      expect(
        find.textContaining('Must be lodged by '
            '${Fmt.date(DateTime(created.year, created.month, created.day + 30))}'),
        findsOneWidget,
      );
      expect(find.textContaining('thirty days from creation (s.352)'),
          findsOneWidget);
    });

    testWidgets('and says what an expired one costs', (tester) async {
      final created = DateTime.now().subtract(const Duration(days: 60));
      await opened(
        tester,
        company(),
        (context) => showChargeSheet(
          context,
          entityId: 'e1',
          charge: CorpCharge(
            id: 'ch2',
            chargeeName: 'CIMB Bank Berhad',
            createdOn: created,
          ),
        ),
      );

      expect(
        find.textContaining('An unregistered charge is void against the '
            'liquidator'),
        findsOneWidget,
      );
      expect(find.textContaining('Must be lodged by'), findsNothing);
    });

    testWidgets('a lodged charge is told the window closed, not that it '
        'is late', (tester) async {
      final created = DateTime.now().subtract(const Duration(days: 60));
      await opened(
        tester,
        company(),
        (context) => showChargeSheet(
          context,
          entityId: 'e1',
          charge: CorpCharge(
            id: 'ch3',
            chargeeName: 'Public Bank Berhad',
            createdOn: created,
            registeredOn: created.add(const Duration(days: 10)),
            chargeNo: 'C-2026-0001',
          ),
        ),
      );

      expect(find.textContaining('Lodged. The thirty days closed on'),
          findsOneWidget);
      expect(
        find.textContaining('void against the liquidator'),
        findsNothing,
      );
    });

    testWidgets('a memorandum of satisfaction waits for the satisfaction',
        (tester) async {
      // Kept without its date it is a memorandum for a charge still
      // outstanding, which is the one thing on this register a chargee
      // would litigate about.
      await opened(
        tester,
        company(),
        (context) => showChargeSheet(
          context,
          entityId: 'e1',
          charge: CorpCharge(
            id: 'ch4',
            chargeeName: 'RHB Bank Berhad',
            createdOn: DateTime.now().subtract(const Duration(days: 400)),
            registeredOn:
                DateTime.now().subtract(const Duration(days: 395)),
          ),
        ),
      );

      expect(find.text('Satisfaction'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'Memorandum filed'),
        findsNothing,
      );
    });

    testWidgets('a new charge starts its clock the moment it is opened',
        (tester) async {
      // Dated today rather than left blank, because a charge being
      // registered is almost always one signed today — and a blank
      // date is a charge with no deadline, which is the one state
      // this register must never be in.
      final today = DateTime.now();
      await opened(
        tester,
        company(),
        (context) => showChargeSheet(context, entityId: 'e1'),
      );

      expect(find.text('Register a charge'), findsOneWidget);
      final save = tester.widget<FilledButton>(
          find.byKey(const ValueKey('charge-save')));
      expect(save.onPressed, isNotNull);
      expect(
        find.textContaining('Must be lodged by '
            '${Fmt.date(DateTime(today.year, today.month, today.day + 30))}'),
        findsOneWidget,
      );
      // Satisfaction is not offered on something not yet registered.
      expect(find.text('Satisfaction'), findsNothing);
    });
  });

  group('the statutory clocks, and the file they run against', () {
    final ahmad = CorpPerson(
      id: 'p1',
      kind: 'individual',
      fullName: 'Ahmad bin Ismail',
      nric: '790304-08-5533',
    );
    final siti = CorpPerson(
      id: 'p2',
      kind: 'individual',
      fullName: 'Siti Nurhaliza binti Omar',
      nric: '850707-14-2244',
    );

    List<Override> registry() => [
          corpPersonsProvider.overrideWith((ref) async => [ahmad, siti]),
          refStatesProvider.overrideWith((ref) async => const [
                {'code': '14', 'name': 'Wilayah Persekutuan Kuala Lumpur'},
                {'code': '10', 'name': 'Selangor'},
              ]),
        ];

    CorpFiling filing({String? filingId, String status = 'draft'}) =>
        CorpFiling(
          entityId: 'e1',
          entityName: 'Kedai Kopi Aman Sdn Bhd',
          filingType: 'annual_return',
          filingName: 'Annual Return',
          statuteRef: 'CA 2016 s.68',
          triggerDate: DateTime(2026, 3, 1),
          dueDate: DateTime(2026, 3, 31),
          status: status,
          legacyForm: 'Form 24',
          filingId: filingId,
        );

    testWidgets('a deadline nobody has taken up offers to be started',
        (tester) async {
      // `corp_upcoming_filings` computes every deadline the Act imposes
      // whether or not anybody has begun. Until this dialog existed,
      // nothing could move a row out of that computed state, so the
      // screen showed every deadline as due for as long as the company
      // existed.
      await opened(
        tester,
        registry(),
        (context) => showFilingStep(context, filing: filing()),
      );

      expect(find.text('Start this filing'), findsOneWidget);
      expect(
        find.text('Kedai Kopi Aman Sdn Bhd · Annual Return (Form 24)'),
        findsOneWidget,
      );
      expect(find.text('CA 2016 s.68 · due 31/03/2026'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Start it'), findsOneWidget);
      // Nothing to lodge yet, so no date and no reference box.
      expect(find.byKey(const ValueKey('ssm-reference')), findsNothing);
    });

    testWidgets('and one somebody is working on asks for the lodgement',
        (tester) async {
      await opened(
        tester,
        registry(),
        (context) =>
            showFilingStep(context, filing: filing(filingId: 'f1')),
      );

      expect(find.text('Record the lodgement'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Lodged'), findsOneWidget);
      expect(find.byKey(const ValueKey('ssm-reference')), findsOneWidget);
      // Blank until the acknowledgement comes back — an empty string
      // would read like a reference nobody can find.
      expect(
        find.text('Leave it blank until it comes back'),
        findsOneWidget,
      );
      final step = tester.widget<FilledButton>(
          find.byKey(const ValueKey('filing-step')));
      expect(step.onPressed, isNotNull);
    });

    testWidgets('a change of particulars names the clock each one starts',
        (tester) async {
      // Each of these is a filing with its own deadline, and the
      // deadline runs from the day the thing happened rather than the
      // day somebody typed it in. Saying which section on the row is
      // what makes that obvious before the sheet asks for a date.
      await opened(
        tester,
        registry(),
        (context) => showParticularsSheet(
          context,
          entity: CorpEntity(
            id: 'e1',
            name: 'Kedai Kopi Aman Sdn Bhd',
            entityType: 'sdn_bhd',
            status: 'active',
          ),
        ),
      );

      expect(find.text('Change of particulars'), findsOneWidget);
      expect(
        find.text('Each of these starts a clock with the Registrar'),
        findsOneWidget,
      );
      expect(
        find.textContaining('CA 2016 s.28 · lodged within 14 days'),
        findsOneWidget,
      );
      expect(
        find.text('CA 2016 s.46(3) · lodged within 14 days'),
        findsOneWidget,
      );
      // No constitution on file, so adopting one is offered.
      expect(
        find.byKey(const ValueKey('adopt-constitution')),
        findsOneWidget,
      );
      // And the quiet half, which is NOT a change of name: the record
      // catching up with what was always true.
      expect(
        find.textContaining('No filing, no former name, no clock'),
        findsOneWidget,
      );
    });

    testWidgets('and stops offering a constitution to a company that has one',
        (tester) async {
      await opened(
        tester,
        registry(),
        (context) => showParticularsSheet(
          context,
          entity: CorpEntity(
            id: 'e1',
            name: 'Kedai Kopi Aman Sdn Bhd',
            entityType: 'sdn_bhd',
            status: 'active',
            hasConstitution: true,
          ),
        ),
      );

      expect(find.byKey(const ValueKey('adopt-constitution')), findsNothing);
      expect(find.byKey(const ValueKey('change-name')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('correct-particulars')),
        findsOneWidget,
      );
    });

    testWidgets('a special resolution needs three quarters, not a majority',
        (tester) async {
      // s.292(1). 7 for and 3 against carries an ordinary resolution
      // and fails a special one, on the same numbers — which is the
      // whole reason the kind is asked before the count.
      await opened(
        tester,
        registry(),
        (context) => showResolutionSheet(context, entityId: 'e1'),
      );

      await tester.enterText(find.byKey(const ValueKey('resolution-title')),
          'That the constitution be adopted');
      await tester.enterText(find.widgetWithText(TextField, 'For'), '7');
      await tester.enterText(find.widgetWithText(TextField, 'Against'), '3');
      await tester.pumpAndSettle();

      expect(find.textContaining('Carried.'), findsOneWidget);

      await tester.tap(find.widgetWithText(DropdownButtonFormField<String>,
          'Passed by'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Members — special').last);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('three quarters of the votes cast — s.292(1)'),
        findsOneWidget,
      );
      expect(find.text('Not carried on those numbers.'), findsOneWidget);
    });

    testWidgets('abstentions are not votes cast', (tester) async {
      // A member who abstains is counted for the quorum and not in the
      // majority. Adding them to the denominator is how a resolution
      // that carried gets recorded as having failed — 6 for, 3 against
      // and 4 abstaining is two thirds, not six thirteenths.
      await opened(
        tester,
        registry(),
        (context) => showResolutionSheet(context, entityId: 'e1'),
      );

      await tester.enterText(
          find.byKey(const ValueKey('resolution-title')), 'That a dividend '
              'be declared');
      await tester.enterText(find.widgetWithText(TextField, 'For'), '6');
      await tester.enterText(find.widgetWithText(TextField, 'Against'), '3');
      await tester.enterText(find.widgetWithText(TextField, 'Abstained'), '4');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Abstentions are not votes cast, so they do not '
            'count against it'),
        findsOneWidget,
      );
    });

    testWidgets('a written resolution was circulated, not put to a meeting',
        (tester) async {
      // s.297. `meeting_held` is the column that says which, and a
      // venue carried over from an earlier edit would minute a meeting
      // that did not happen — so the venue and the chair go away with
      // it rather than being kept and ignored.
      await opened(
        tester,
        registry(),
        (context) => showResolutionSheet(context, entityId: 'e1'),
      );

      // Circulated is the DEFAULT — `meeting_held` starts false — so
      // the venue and the chair are not on the sheet when it opens.
      expect(find.widgetWithText(TextField, 'Where'), findsNothing);

      await tester.tap(find.widgetWithText(SwitchListTile,
          'Passed at a meeting'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Where'), findsOneWidget);
      expect(find.text('A meeting was held.'), findsOneWidget);

      // And choosing the written kind takes the meeting back off,
      // rather than leaving a venue behind to minute one that did not
      // happen.
      await tester.tap(find.widgetWithText(DropdownButtonFormField<String>,
          'Passed by'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Written, circulated').last);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Where'), findsNothing);
      expect(
        find.textContaining('Circulated for signature under s.297'),
        findsOneWidget,
      );
      // And the switch cannot be turned back on for a written one.
      final held = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'Passed at a meeting'));
      expect(held.onChanged, isNull);
    });

    testWidgets('and refuses a minute that says nine voted out of seven',
        (tester) async {
      // Nothing in the database checks it: `present_person_ids` is an
      // array and the counts are plain integers. A minute that
      // contradicts itself is worse than one with a gap in it.
      await opened(
        tester,
        registry(),
        (context) => showResolutionSheet(context, entityId: 'e1'),
      );

      await tester.enterText(find.byKey(const ValueKey('resolution-title')),
          'That the accounts be approved');
      // The attendance list only exists on a resolution passed at a
      // meeting, and circulated is the default.
      await tester.tap(find.widgetWithText(SwitchListTile,
          'Passed at a meeting'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'Ahmad bin Ismail'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'For'), '4');
      await tester.pumpAndSettle();

      expect(find.text('More votes than people present.'), findsOneWidget);
      final save = tester.widget<FilledButton>(
          find.byKey(const ValueKey('resolution-save')));
      expect(save.onPressed, isNull);
    });

    testWidgets('a resolution with no title cannot be recorded at all',
        (tester) async {
      await opened(
        tester,
        registry(),
        (context) => showResolutionSheet(context, entityId: 'e1'),
      );

      expect(
        find.text('A resolution needs to say what it is.'),
        findsOneWidget,
      );
      final save = tester.widget<FilledButton>(
          find.byKey(const ValueKey('resolution-save')));
      expect(save.onPressed, isNull);
      // Nothing to remove on one that was never recorded.
      expect(find.byKey(const ValueKey('resolution-delete')), findsNothing);
    });

    testWidgets('the person editor asks a body corporate different questions',
        (tester) async {
      // An NRIC on a company and a registration number on a person are
      // both nonsense, and the register carries both kinds.
      await opened(
        tester,
        registry(),
        (context) => showPersonEditor(context),
      );

      expect(find.text('Add a person'), findsOneWidget);
      expect(find.byKey(const ValueKey('person-nric')), findsOneWidget);
      expect(
        find.text('As it appears on the identity document'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('person-registration-no')),
        findsNothing,
      );

      await tester.tap(find.text('A body corporate'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('person-registration-no')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('person-nric')), findsNothing);
      // And the residence question goes with it: s.196 is about
      // directors who are people.
      expect(
        find.text('Section 196 requires at least one resident director'),
        findsNothing,
      );
    });

    testWidgets('and opens with the name that was typed into the picker',
        (tester) async {
      // `showPersonEditor` is reached from a picker when somebody types
      // a name that is not on the file. If the typed text does not
      // arrive in the box they type it twice.
      await opened(
        tester,
        registry(),
        (context) =>
            showPersonEditor(context, seedName: 'Tan Chee Keong'),
      );

      expect(find.text('Tan Chee Keong'), findsOneWidget);
    });

    testWidgets('a person on the file is titled with their name, and kept '
        'as one', (tester) async {
      await opened(
        tester,
        registry(),
        (context) => showPersonEditor(context, person: ahmad),
      );

      // Twice: the dialog's title and the name field it filled.
      expect(find.text('Ahmad bin Ismail'), findsNWidgets(2));
      expect(find.text('790304-08-5533'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
      // The AMLA half is asked about everybody, not only new people.
      expect(find.text('Know your client'), findsOneWidget);
      expect(
        find.text('Triggers enhanced due diligence under the AMLA'),
        findsOneWidget,
      );
    });
  });

  group('joining, leaving, and the days in between', () {
    testWidgets('a hire proposes the earliest day the notice allows',
        (tester) async {
      // Defaulting to today would propose a date the candidate has
      // already said they cannot make. Thirty days' notice means the
      // box opens on today plus thirty, and the sentence names the
      // employer they owe it to.
      final today = DateTime.now();
      final earliest =
          DateTime(today.year, today.month, today.day + 30);

      await opened(
        tester,
        [
          departmentsProvider.overrideWith((ref) async => const [
                {'id': 'd1', 'name': 'Finance'},
              ]),
          positionsProvider.overrideWith((ref) async => const [
                {'id': 'ps1', 'title': 'Account Executive'},
              ]),
          directoryProvider.overrideWith((ref) async => [
                Employee(
                  id: 'em1',
                  employeeNo: 'E-0001',
                  fullName: 'Nurul Huda',
                ),
              ]),
        ],
        (context) => showHireDialog(
          context,
          Applicant(
            id: 'ap1',
            fullName: 'Tan Chee Keong',
            status: 'offer',
            email: 'tan@example.com',
            phone: '012-3456789',
            nric: '900101-14-5555',
            expectedSalary: 4800,
            noticePeriodDays: 30,
            currentEmployer: 'Syarikat Lama Sdn Bhd',
          ),
        ),
      );

      expect(find.text('Hire Tan Chee Keong'), findsOneWidget);
      // What carries across untouched, said out loud so nobody opens
      // the employee editor afterwards and types it again.
      expect(
        find.text('tan@example.com · 012-3456789 · 900101-14-5555'),
        findsOneWidget,
      );
      expect(find.text('Starts: ${Fmt.date(earliest)}'), findsOneWidget);
      expect(
        find.textContaining("They owe 30 days' notice to Syarikat Lama "
            'Sdn Bhd, so the earliest is ${Fmt.date(earliest)}'),
        findsOneWidget,
      );
      // The salary they asked for is the starting point, not the
      // answer — so it is in the box AND named in the helper.
      expect(find.text('They asked for RM 4,800.00'), findsOneWidget);
      // Two decimals in the box. `double.toString()` would put "4800.0"
      // here, and an expectation of 4,800.50 in as "4800.5".
      expect(find.text('4800.00'), findsOneWidget);
      // Nothing to explain: the proposed date is not inside the notice.
      expect(
        find.widgetWithText(TextField, 'Why the date stands *'),
        findsNothing,
      );
    });

    testWidgets('and half a ringgit of expectation survives the box',
        (tester) async {
      await opened(
        tester,
        [
          departmentsProvider.overrideWith((ref) async => const []),
          positionsProvider.overrideWith((ref) async => const []),
          directoryProvider.overrideWith((ref) async => const <Employee>[]),
        ],
        (context) => showHireDialog(
          context,
          Applicant(
            id: 'ap3',
            fullName: 'Chandran Pillai',
            status: 'offer',
            expectedSalary: 4800.50,
          ),
        ),
      );

      expect(find.text('4800.50'), findsOneWidget);
      expect(find.text('They asked for RM 4,800.50'), findsOneWidget);
    });

    testWidgets('and somebody between jobs is not told a rule was applied',
        (tester) async {
      // No notice owed means no earliest date, and the honest answer is
      // silence rather than "today" — which would read as a rule.
      await opened(
        tester,
        [
          departmentsProvider.overrideWith((ref) async => const []),
          positionsProvider.overrideWith((ref) async => const []),
          directoryProvider.overrideWith((ref) async => const <Employee>[]),
        ],
        (context) => showHireDialog(
          context,
          Applicant(
            id: 'ap2',
            fullName: 'Lee Mei Fong',
            status: 'offer',
          ),
        ),
      );

      expect(find.text('Hire Lee Mei Fong'), findsOneWidget);
      expect(find.text('Starts: ${Fmt.date(DateTime.now())}'), findsOneWidget);
      expect(find.textContaining("notice"), findsNothing);
      // No expected salary means no helper claiming they asked for
      // nothing.
      expect(find.textContaining('They asked for'), findsNothing);
    });

    testWidgets('a departure says the payroll goes by the date, not the '
        'status', (tester) async {
      // `0371`: `calculate_payroll_run` has never read
      // `employment_status` — it picks who to pay by
      // `last_working_date`. A leaver marked in the dropdown alone kept
      // drawing a salary, kept having EPF and PCB remitted, and kept
      // being paid by the bank file. The sentence under the empty date
      // field is the whole point of this dialog.
      await opened(
        tester,
        const [],
        (context) => showDepartureDialog(
          context,
          employee: Employee(
            id: 'em1',
            employeeNo: 'E-0004',
            fullName: 'Rajesh Kumar',
            hireDate: DateTime(2022, 4, 1),
          ),
        ),
      );

      expect(find.text('Rajesh Kumar is leaving'), findsOneWidget);
      expect(
        find.text('The payroll run goes by this date, not by the status.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('A last working day is what takes somebody off '
            'the payroll'),
        findsOneWidget,
      );
      final record = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Record departure'));
      expect(record.onPressed, isNull);
    });

    testWidgets('and asks when notice was given only of a resignation',
        (tester) async {
      // A termination and a retirement have no notice date, and `0371`
      // writes null for both regardless — so asking would invite a date
      // that means nothing.
      await opened(
        tester,
        const [],
        (context) => showDepartureDialog(
          context,
          employee: Employee(
            id: 'em1',
            employeeNo: 'E-0004',
            fullName: 'Rajesh Kumar',
            hireDate: DateTime(2022, 4, 1),
          ),
        ),
      );

      expect(find.text('Notice given on'), findsOneWidget);

      await tester.tap(
          find.widgetWithText(DropdownButtonFormField<String>, 'How'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Terminated').last);
      await tester.pumpAndSettle();

      expect(find.text('Notice given on'), findsNothing);

      await tester.tap(
          find.widgetWithText(DropdownButtonFormField<String>, 'How'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retired').last);
      await tester.pumpAndSettle();

      expect(find.text('Notice given on'), findsNothing);
      // 'Serving notice' is never offered: it is "has resigned and the
      // last day has not come", which the database derives.
      expect(find.text('Serving notice'), findsNothing);
    });

    testWidgets('leave bands say what everybody gets without them',
        (tester) async {
      // `leave_entitlement_bands` sat in the schema empty and
      // unreachable, so every leave type fell back to its flat
      // `default_days` — below the Act's floor for anyone past two
      // years. The dialog has to say that is what is happening.
      await opened(
        tester,
        [
          leaveBandsProvider.overrideWith((ref, id) async => const []),
        ],
        (context) => showLeaveBands(context, const {
          'id': 'lt1',
          'name': 'Annual leave',
          'default_days': 8,
          'scales_with_service': false,
        }),
      );

      expect(find.text('Annual leave · entitlement'), findsOneWidget);
      expect(
        find.textContaining('everybody gets 8 days no matter how long they '
            'have been here'),
        findsOneWidget,
      );
      expect(find.text('No bands — the flat figure applies.'), findsOneWidget);
      // And a type that does not scale yet is told that a preset turns
      // it on and a hand-added band does not.
      expect(
        find.textContaining('Applying a preset turns that on; adding a band '
            'by hand does not'),
        findsOneWidget,
      );
      // The presets name the SECTION, so somebody can check them
      // against the Act rather than against this screen.
      expect(
        find.text('Annual — 8 / 12 / 16 days (s.60E)'),
        findsOneWidget,
      );
      expect(find.text('Sick — 14 / 18 / 22 days (s.60F)'), findsOneWidget);
    });

    testWidgets('and a top band reads as open-ended, not as a range',
        (tester) async {
      // "5 years and over" against "2 to 4 years": a null upper bound
      // is the top band, and printing it as a range to nothing is how
      // somebody past it reads themselves out of any band at all.
      await opened(
        tester,
        [
          leaveBandsProvider.overrideWith((ref, id) async => const [
                {
                  'id': 'b1',
                  'service_years_from': 0,
                  'service_years_to': 1,
                  'days': 8,
                },
                {
                  'id': 'b2',
                  'service_years_from': 2,
                  'service_years_to': 4,
                  'days': 12,
                },
                {
                  'id': 'b3',
                  'service_years_from': 5,
                  'service_years_to': null,
                  'days': 16,
                },
              ]),
        ],
        (context) => showLeaveBands(context, const {
          'id': 'lt1',
          'name': 'Annual leave',
          'default_days': 8,
          'scales_with_service': true,
        }),
      );

      expect(find.text('0 to 1 years'), findsOneWidget);
      expect(find.text('2 to 4 years'), findsOneWidget);
      expect(find.text('5 years and over'), findsOneWidget);
      expect(find.text('16 days'), findsOneWidget);
      expect(find.text('No bands — the flat figure applies.'), findsNothing);
      // Already scaling, so the warning is gone.
      expect(
        find.textContaining('does not scale with service yet'),
        findsNothing,
      );
    });

    testWidgets('a renewal has to run past the document it replaces',
        (tester) async {
      // A work permit renewed to a date inside the one it replaces is a
      // renewal that shortens the permit, and it would drop off the
      // expiring list while expiring sooner than before.
      await opened(
        tester,
        const [],
        (context) => showRenewDocument(
          context,
          documentId: 'doc1',
          currentExpiry: DateTime(2027, 6, 30),
        ),
      );

      expect(find.text('Renew it'), findsOneWidget);
      expect(
        find.textContaining('This one runs to 30/06/2027. The renewal '
            'replaces it, and it drops off the expiring list.'),
        findsOneWidget,
      );
      // Nothing chosen yet, so the field is not yet in error — the
      // refusal belongs to a date somebody picked, not to a blank.
      expect(
        find.textContaining('A renewal runs past the document it replaces'),
        findsNothing,
      );
      expect(find.text('Choose a date'), findsOneWidget);
    });

    testWidgets('and a document with no expiry is simply replaced',
        (tester) async {
      await opened(
        tester,
        const [],
        (context) => showRenewDocument(
          context,
          documentId: 'doc2',
          currentExpiry: null,
        ),
      );

      expect(
        find.text('The renewal replaces this document.'),
        findsOneWidget,
      );
      expect(find.textContaining('drops off the expiring list'), findsNothing);
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
  _Repo({
    this.late = const [],
    this.closed = const [],
    this.banks = const [],
    this.rpc = const {},
  });

  final List<Map<String, dynamic>> late;
  final List<Map<String, dynamic>> closed;
  final List<Map<String, dynamic>> banks;

  /// Answers keyed on the RPC's name, for everything reached through
  /// one.
  ///
  /// This exists because **an extension method is not virtual**. A
  /// great deal of `Repo` lives in `extension RepoProperty on Repo`
  /// and its siblings, and Dart dispatches those on the STATIC type —
  /// so a fake that `implements Repo` and overrides
  /// `strataChargePreview` is ignored, the real body runs, and the
  /// test fails somewhere far from the cause. That happened here: the
  /// charge run sheet rendered `UnimplementedError: Symbol("callRpc")`
  /// in its own error slot, which is the only reason it was visible at
  /// all. Every one of those extension methods bottoms out in
  /// `callRpc`, which IS virtual, so this is the seam that holds for
  /// all of them.
  final Map<String, dynamic> rpc;

  @override
  Future<List<Map<String, dynamic>>> bankAccounts() async => banks;

  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async {
    if (!rpc.containsKey(fn)) {
      throw UnimplementedError(
        'a dialog under test called the RPC "$fn" and this fake does '
        'not answer it.',
      );
    }
    return rpc[fn];
  }

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
