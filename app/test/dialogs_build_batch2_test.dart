import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/format.dart';
import 'package:iakauntan/src/core/searchable_picker.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/places_repository.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';
import 'package:iakauntan/src/features/approvals/rule_editor.dart';
import 'package:iakauntan/src/features/banking/new_bank_account_dialog.dart';
import 'package:iakauntan/src/features/collections/log_attempt_sheet.dart';
import 'package:iakauntan/src/features/contacts/new_contact_dialog.dart';
import 'package:iakauntan/src/features/crm/close_deal_dialog.dart';
import 'package:iakauntan/src/features/forecasting/forecast_screen.dart';
import 'package:iakauntan/src/features/forecasting/forecast_settings_dialog.dart';
import 'package:iakauntan/src/features/forecasting/item_params_dialog.dart';
import 'package:iakauntan/src/features/hr/appraisal_part.dart';
import 'package:iakauntan/src/features/hr/hiring.dart';
import 'package:iakauntan/src/features/hr/appraisal_review.dart';
import 'package:iakauntan/src/features/hr/who_is_away.dart';
import 'package:iakauntan/src/features/pos/stall_items_dialog.dart';
import 'package:iakauntan/src/features/legal/matter_billing.dart';
import 'package:iakauntan/src/features/mail/compose_dialog.dart';
import 'package:iakauntan/src/features/mia/mia_credential.dart';
import 'package:iakauntan/src/features/mia/mia_verify_dialog.dart';
import 'package:iakauntan/src/features/pos/assign_table.dart';
import 'package:iakauntan/src/features/pos/delivery_sheet.dart';
import 'package:iakauntan/src/features/pos/tender_sheet.dart';
import 'package:iakauntan/src/features/settings/new_account_dialog.dart';
import 'package:iakauntan/src/features/settings/sub_account_dialog.dart';
import 'package:iakauntan/src/features/settings/tax_code_dialog.dart';
import 'package:iakauntan/src/features/shared/supplier_from_scan.dart';
import 'package:iakauntan/src/features/shell/notification_bell.dart';
import 'package:iakauntan/src/features/ticketing/ticket_share_dialog.dart';
import 'package:iakauntan/src/features/timesheets/time_entry_sheet.dart';
import 'package:iakauntan/src/features/documents/email_dialog.dart';
import 'package:iakauntan/src/features/documents/receipts_screen.dart';
import 'package:iakauntan/src/features/documents/recurring_template_dialog.dart';
import 'package:iakauntan/src/features/documents/share_dialog.dart';
import 'package:iakauntan/src/features/financials/filing_details.dart';
import 'package:iakauntan/src/features/financials/tax_computation_screen.dart';
import 'package:iakauntan/src/features/hr/applicant_editor.dart';
import 'package:iakauntan/src/features/hr/appraisal_cycles_dialog.dart';
import 'package:iakauntan/src/features/hr/appraisal_goals_dialog.dart';
import 'package:iakauntan/src/features/hr/attendance_month.dart';
import 'package:iakauntan/src/features/hr/interviews_dialog.dart';
import 'package:iakauntan/src/features/hr/onboarding_template_dialog.dart';
import 'package:iakauntan/src/features/hr/requisition_editor.dart';
import 'package:iakauntan/src/features/reports/budget_line_editor.dart';
import 'package:iakauntan/src/features/hr/referrals_dialog.dart';
import 'package:iakauntan/src/features/items/modifier_groups_dialog.dart';
import 'package:iakauntan/src/features/pos/delivery_day_dialog.dart';
import 'package:iakauntan/src/features/pos/queue_day_dialog.dart';
import 'package:iakauntan/src/features/settings/credit_ledger_dialog.dart';
import 'package:iakauntan/src/features/settings/msic_picker.dart';
import 'package:iakauntan/src/features/timesheets/billing_rate_sheet.dart';
import 'package:iakauntan/src/features/timesheets/project_budget.dart';

/// The rest of the dialogs nothing had ever opened.
///
/// `dialogs_build_batch_test.dart` cleared the first half of
/// `check_dialogs_built.py`'s backlog; this is the other fifty. Same
/// method, same reason, and the same phone-width surface: a dialog is
/// the likeliest place in this codebase to find a fixed pixel width,
/// because the author is thinking about a desktop modal while writing
/// one.
void main() {
  /// NOTE FOR ANYONE ASSERTING ON A BUTTON. The opener below is a
  /// `FilledButton`, and it is FIRST in the tree — so
  /// `find.byType(FilledButton).first` reads this button and not the
  /// dialog's. It is always enabled, so a `savable()` written that way
  /// returns true before and after the thing it is testing and the
  /// assertion passes in both directions. That happened once while this
  /// file was being filled in. Anchor from the label upwards:
  /// `find.ancestor(of: find.text('Add'), matching: find.byType(...))`,
  /// or give the dialog's button a key and find that.
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

  /// A name long enough to overflow a Row that forgot to flex, and a
  /// real shape rather than a contrived one: Malaysian company names run
  /// like this, and every one of the seven defects the screens gate found
  /// was long content in a Row nobody had constrained.
  const long = 'Perniagaan Sinar Teknologi Maju Bersatu Sdn Bhd';

  /// A repository whose reads answer nothing and whose writes are never
  /// reached: these tests open a dialog, they do not press Save.
  ///
  /// `noSuchMethod` THROWS rather than answering null, so a dialog that
  /// calls something during build fails loudly here instead of drawing a
  /// blank and passing.
  final repo = _FakeRepo();

  group('HR', () {
    // Two cycles rather than one, because the row's only conditional is
    // whether `Open` is pressable: `onPressed` is null on a completed
    // cycle and a disabled button looks exactly like an enabled one to
    // `findsOneWidget`.
    testWidgets('the appraisal cycles dialog opens', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          appraisalCyclesProvider.overrideWith((_) async => [
                AppraisalCycle(
                  id: 'c1',
                  name: 'Annual review $long',
                  periodStart: DateTime.utc(2026, 1, 1),
                  periodEnd: DateTime.utc(2026, 12, 31),
                  status: 'open',
                  ratingScaleMax: 5,
                  opened: 4,
                ),
                AppraisalCycle(
                  id: 'c2',
                  name: 'Mid-year 2025',
                  periodStart: DateTime.utc(2025, 1, 1),
                  periodEnd: DateTime.utc(2025, 6, 30),
                  status: 'completed',
                  ratingScaleMax: 4,
                  selfReviewDue: DateTime.utc(2025, 7, 15),
                  managerReviewDue: DateTime.utc(2025, 7, 31),
                ),
              ]),
        ],
        (context) => showAppraisalCycles(context),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Annual review $long'), findsOneWidget);
      expect(find.text('Mid-year 2025'), findsOneWidget);
      // The whole subtitle, joined, rather than a `textContaining` on one
      // clause: the separator and the order are what a reader of the
      // screen sees, and a clause that moves into the wrong position
      // passes a containment check.
      expect(find.text('01/01/2026 – 31/12/2026 · out of 5 · 4 open'),
          findsOneWidget);
      expect(
          find.text('01/01/2025 – 30/06/2025 · out of 4 · '
              'self by 15/07/2025 · manager by 31/07/2025 · 0 open'),
          findsOneWidget);
      // `StatusChip` draws through `Fmt.label`, so these are capitalised
      // and the raw column value would NOT be found.
      expect(find.text('Open'), findsNWidgets(3));
      expect(find.text('Completed'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);

      // Three `Open`s above: one chip per cycle plus the live cycle's
      // button. The completed cycle's button is the one that must not be
      // pressable, and that is not something text can say.
      final buttons = tester
          .widgetList<TextButton>(find.byType(TextButton))
          .where((b) => b.child is Text && (b.child as Text).data == 'Open')
          .toList();
      expect(buttons, hasLength(2));
      expect(buttons.where((b) => b.onPressed == null), hasLength(1));
    });

    // `report_referral_hires` (0381) returns
    //
    //     referrer_id, referrer_no, referrer_name, hires, candidates
    //
    // one row per REFERRER, and the fixture described one HIRE:
    // `applicant_name, hired_on, bonus_amount, status`, none of which
    // anything reads. `referrer_name` was the only key that landed, so the
    // row read "null introduced" and "null hired".
    testWidgets('and who a referral brought in, per referrer as 0381 has it',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          referralHiresProvider.overrideWith((_) async => const [
                {
                  'referrer_id': 'e1',
                  'referrer_no': 'EMP-0007',
                  'referrer_name': long,
                  'candidates': 5,
                  'hires': 2,
                },
                // Somebody who introduced people and none of them was
                // hired: the colour on the trailing figure turns on
                // `hires > 0`, so a zero is the other half of it.
                {
                  'referrer_id': 'e2',
                  'referrer_no': 'EMP-0011',
                  'referrer_name': 'Aisyah binti Rahman',
                  'candidates': 3,
                  'hires': 0,
                },
              ]),
        ],
        (context) => showReferralHires(context),
      );
      expect(tester.takeException(), isNull);

      expect(find.text(long), findsOneWidget);
      expect(find.text('Aisyah binti Rahman'), findsOneWidget);
      // `candidates` and `hires`, which the old fixture supplied under
      // neither name -- both lines read "null".
      expect(find.text('5 introduced'), findsOneWidget);
      expect(find.text('2 hired'), findsOneWidget);
      expect(find.text('3 introduced'), findsOneWidget);
      expect(find.text('0 hired'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });
  });

  group('point of sale', () {
    // `pos_modifier_groups_admin` (0251) returns
    //
    //     id, code, name, min_select, max_select, sort_order, is_active,
    //     allows_free_text, option_count, item_count
    //
    // and `pos_modifier_options_admin` (0250)
    //
    //     id, code, name, price_delta, is_default, sort_order, is_active
    //
    // The fixture supplied four of the ten and three of the seven, and
    // the three it left out of each are the ones the row BRANCHES on:
    // `is_active` absent reads as `== true` false, so the live group drew
    // itself retired and in the disabled colour; `option_count` and
    // `item_count` absent made every group say "0 answers · asked about 0
    // dishes"; and the answer row's subtitle is `'${option['code']}'`,
    // which with no `code` is the four characters n-u-l-l on the screen.
    //
    // None of it threw, which is the whole point of this file's rewrite.
    testWidgets('the modifier groups dialog opens', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          posModifierGroupsProvider.overrideWith((_) async => const [
                {
                  'id': 'g1',
                  'code': 'MG-SPICE',
                  'name': long,
                  'min_select': 0,
                  'max_select': 3,
                  'sort_order': 1,
                  'is_active': true,
                  'allows_free_text': true,
                  'option_count': 2,
                  'item_count': 7,
                },
                // Retired, and the only one: `is_active` false is what
                // puts "retired" at the front of the subtitle and takes
                // the "Stop asking it" button away, and a fixture in
                // which every row is live cannot tell either apart.
                {
                  'id': 'g2',
                  'code': 'MG-ICE',
                  'name': 'How much ice',
                  'min_select': 1,
                  'max_select': 1,
                  'sort_order': 2,
                  'is_active': false,
                  'allows_free_text': false,
                  'option_count': 1,
                  'item_count': 1,
                },
              ]),
          posModifierOptionsProvider.overrideWith((_, __) async => const [
                {
                  'id': 'o1',
                  'code': 'MOD-HOT',
                  'name': long,
                  'price_delta': 2.5,
                  'is_default': true,
                  'sort_order': 1,
                  'is_active': true,
                },
                // Nought, and off the menu: the trailing figure says "no
                // charge" rather than RM 0.00, which is a sentence
                // somebody wrote on purpose.
                {
                  'id': 'o2',
                  'code': 'MOD-NOCUC',
                  'name': 'No cucumber',
                  'price_delta': 0,
                  'is_default': false,
                  'sort_order': 2,
                  'is_active': false,
                },
              ]),
        ],
        (context) => showModifierGroups(context),
      );
      expect(tester.takeException(), isNull);

      expect(find.text(long), findsOneWidget);
      expect(find.text('How much ice'), findsOneWidget);
      expect(
          find.text('up to 3 · 2 answers · or anything typed · '
              'asked about 7 dishes'),
          findsOneWidget);
      expect(find.text('retired · choose one · 1 answer · asked about 1 dish'),
          findsOneWidget);
      // Singular and plural both, from the same join: "1 answer" above
      // and "2 answers" on the live one.

      // The answers live in the `ExpansionTile`'s children, which are
      // offstage until it is opened -- so a test that never taps asserts
      // nothing about them, and `find.text` would not see them either.
      await tester.tap(find.text(long));
      await tester.pumpAndSettle();

      expect(find.text(long), findsNWidgets(2));
      expect(find.text('MOD-HOT · ticked by default'), findsOneWidget);
      expect(find.text('No cucumber'), findsOneWidget);
      expect(find.text('MOD-NOCUC · off the menu'), findsOneWidget);
      expect(find.text('+RM 2.50'), findsOneWidget);
      expect(find.text('no charge'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // The fixture fed this dialog ORDERS and the dialog reads a per-outlet
    // SUMMARY. `pos_delivery_day` (0259) returns
    //
    //     outlet_id, outlet_name, runs, delivered, failed, still_out,
    //     fees, free_rides, median_minutes
    //
    // and the fixture sent `sale_no, customer_name, address, total,
    // status` -- not one of which anything reads. So the row's title was
    // `null`, `runsLine` said "0 out", `medianLabel` said "nothing has
    // arrived yet", and the fees column read RM 0.00. `pos_driver_runs`
    // was fed `driver_name` and `stops`, and `stops` is not a column it
    // returns either.
    testWidgets('the delivery day dialog opens, per outlet as 0259 returns it',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          posDeliveryDayProvider.overrideWith((_, __) async => const [
                {
                  'outlet_id': 'o1',
                  'outlet_name': 'Kedai Nasi Lemak Aman',
                  'runs': 12,
                  'delivered': 9,
                  'failed': 1,
                  'still_out': 2,
                  'fees': 54.0,
                  'free_rides': 3,
                  'median_minutes': 28,
                },
              ]),
          // DIFFERENT numbers from the outlet above, deliberately. Both
          // sections draw `runsLine`, so with the same figures one
          // sentence appears twice and a `findsWidgets` on it pins
          // neither -- which is how dropping the outlet's `runs` survived
          // as a mutant on the first attempt. One driver of several does
          // not match the outlet's total anyway.
          posDriverRunsProvider.overrideWith((_, __) async => const [
                {
                  'driver_id': 'dr1',
                  'driver_name': long,
                  'outlet_name': 'Kedai Nasi Lemak Aman',
                  'runs': 7,
                  'delivered': 6,
                  'still_out': 1,
                  'fees': 31.0,
                  'goods': 480.0,
                  'median_minutes': 22,
                },
              ]),
        ],
        (context) => showDeliveryDay(context),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Kedai Nasi Lemak Aman'), findsWidgets);
      // The OUTLET's line. `runsLine` leaves a zero out, so every one of
      // these numbers has to be non-zero for the whole sentence to appear
      // -- and `findsOneWidget` rather than `findsWidgets`, so it is this
      // row's figures and not the driver's that satisfy it.
      expect(
        find.textContaining('12 out · 9 delivered · 1 failed · 2 still out'),
        findsOneWidget,
      );
      // And the DRIVER's, which are different figures.
      expect(find.textContaining('7 out · 6 delivered · 1 still out'),
          findsOneWidget);

      // `median_minutes`, which the old fixture left at "nothing has
      // arrived yet". Different per section, for the same reason.
      expect(find.textContaining('about 28 minutes, typically'),
          findsOneWidget);
      expect(find.textContaining('about 22 minutes, typically'),
          findsOneWidget);
      // `free_rides`, said only when the promise cost something.
      expect(find.textContaining('3 rides given away'), findsOneWidget);
      // And `fees`, which was RM 0.00.
      expect(find.textContaining('54.00'), findsWidgets);
      expect(find.textContaining('nothing has arrived yet'), findsNothing);
    });

    // Same mistake as the delivery day above: the fixture fed TICKETS and
    // the dialog reads a per-outlet SUMMARY. `pos_queue_day` (0257)
    // returns
    //
    //     outlet_id, outlet_name, joined, seated, gave_up, no_shows,
    //     still_waiting, median_wait, longest_wait
    //
    // and the fixture sent `ticket_no, customer_name, party_size, status`.
    // With `joined` absent `queueDayLine` returned its first arm --
    // **"Nobody queued"** -- and `waitLabel` said "nobody was seated", on
    // a day the fixture was describing as somebody waiting.
    testWidgets('and the queue day dialog, per outlet as 0257 returns it',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          posQueueDayProvider.overrideWith((_, __) async => const [
                {
                  'outlet_id': 'o1',
                  'outlet_name': 'Kedai Nasi Lemak Aman',
                  'joined': 40,
                  'seated': 31,
                  'gave_up': 5,
                  'no_shows': 2,
                  'still_waiting': 2,
                  'median_wait': 18,
                  'longest_wait': 55,
                },
              ]),
        ],
        (context) => showQueueDay(context),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Kedai Nasi Lemak Aman'), findsWidgets);
      // `joined`, which decided between this and "Nobody queued".
      expect(
        find.textContaining('40 joined · 31 seated · 2 still in the line'),
        findsWidgets,
      );
      expect(find.textContaining('Nobody queued'), findsNothing);
      // `gave_up` and `no_shows`, which 0257 insists on keeping apart
      // because only one of them is a reason to open another section.
      expect(
        find.textContaining(
            '5 gave up waiting, 2 did not come when called'),
        findsWidgets,
      );
      // `median_wait` with a `longest_wait` above it.
      expect(find.textContaining('about 18 min, longest 55'), findsWidgets);
      expect(find.textContaining('nobody was seated'), findsNothing);
    });
  });

  group('settings', () {
    // `kind` was the fixture's word and `entry_type` is the dialog's, so
    // `creditMovement(null)` fell to its `_` arm and every row in this
    // test said "Adjustment" where a real usage row says "A scan".
    // `balance_after` was absent too, so the figure under each amount was
    // always `left RM 0.00`. Neither is anything the database sends.
    //
    // This is the dialog widget-tests.md trap 11 was written about -- its
    // totals line overflowed by 46 pixels, and the `Flexible` that fixed
    // it carries a comment naming "RM 12,345.67 in · RM 9,876.54 out" as
    // the case. Those are the figures below, so the assertion is on the
    // sentence that comment is about.
    //
    // TWO rows, not three. A third is below the fold at 412x900 and a
    // `ListView` builds lazily, so an assertion about it counts a widget
    // that is not in the tree -- which is how the first version of this
    // test failed, looking for two "A scan" rows and finding one.
    testWidgets('the scanning credit ledger opens, in the shape it is sent',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          creditLedgerProvider.overrideWith((_) async => const [
                {
                  'id': 'cl1',
                  'entry_type': 'topup',
                  'amount': 12345.67,
                  'balance_after': 12345.67,
                  'description': 'Credit bought',
                  'created_at': '2026-09-01T02:00:00Z',
                },
                {
                  'id': 'cl2',
                  'entry_type': 'usage',
                  'amount': -9876.54,
                  'balance_after': 2469.13,
                  'description': 'Scan of $long.pdf',
                  'created_at': '2026-09-30T03:00:00Z',
                },
              ]),
        ],
        (context) => showCreditLedger(context),
      );
      expect(tester.takeException(), isNull);

      // `entry_type`, read through `creditMovement`. Under the old
      // fixture both rows said "Adjustment".
      expect(find.textContaining('A scan · '), findsOneWidget);
      expect(find.textContaining('Credit bought · '), findsOneWidget);
      expect(find.textContaining('Adjustment'), findsNothing);

      // `balance_after`, which the old fixture never supplied: the figure
      // under each amount was `left RM 0.00` on every row.
      expect(find.text('left RM 12,345.67'), findsOneWidget);
      expect(find.text('left RM 2,469.13'), findsOneWidget);
      expect(find.text('left RM 0.00'), findsNothing);

      // Money in carries a `+` the widget adds; money out carries the
      // minus the amount already has. `Fmt.money(-9876.54)` is
      // `RM -9,876.54`, not `-RM 9,876.54` -- the currency prefix goes in
      // front of whatever the number formatter produced, sign included.
      expect(find.text('+RM 12,345.67'), findsOneWidget);
      expect(find.text('RM -9,876.54'), findsOneWidget);

      // And the totals line the `Flexible` exists for, with the two
      // five-figure sums its comment names. Nothing overflowed at 412.
      expect(find.text('Over the last 2 movements'), findsOneWidget);
      expect(find.text('RM 12,345.67 in · RM 9,876.54 out'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // One code in the fixture could not reach anything this dialog does.
    // `msicMatches` ranks in three buckets -- the code typed in full,
    // then codes that START with what was typed, then descriptions and
    // CATEGORIES that contain it -- and a one-row list with no `category`
    // leaves the third bucket's second half unreachable, the ordering
    // unobservable, and the empty state (where the only way to enter a
    // real code the seed does not carry lives) never drawn.
    //
    // `ref_msic_codes` is selected as `code, description, category`; the
    // fixture named two of the three.
    testWidgets('and the MSIC picker', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          msicCodesProvider.overrideWith((_) async => const [
                {
                  'code': '10710',
                  'description': 'Manufacture of bread and bakery products',
                  'category': 'Manufacturing',
                },
                {
                  'code': '62011',
                  'description': 'Computer programming activities',
                  'category': 'Information and communication',
                },
                {
                  'code': '62019',
                  'description': 'Other computer programming activities',
                  'category': 'Information and communication',
                },
              ]),
        ],
        (context) => pickMsicCode(context),
      );
      expect(tester.takeException(), isNull);

      Iterable<String> titles() => tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title as Text).data!);

      // Nothing typed: the whole list, in the order the query gave it.
      expect(titles(), [
        'Manufacture of bread and bakery products',
        'Computer programming activities',
        'Other computer programming activities',
      ]);
      expect(find.text('10710 · Manufacturing'), findsOneWidget);
      expect(find.text('62011 · Information and communication'),
          findsOneWidget);

      Future<void> type(String q) async {
        await tester.enterText(find.byKey(const ValueKey('msic-search')), q);
        await tester.pumpAndSettle();
      }

      // Bucket two: a code PREFIX, which is how somebody half-remembering
      // it looks. Both 62s, neither 10710, and in code order.
      await type('620');
      expect(titles(), [
        'Computer programming activities',
        'Other computer programming activities',
      ]);

      // Bucket three, first half: a word in the description.
      await type('bread');
      expect(titles(), ['Manufacture of bread and bakery products']);

      // Bucket three, SECOND half: a word in the category, which no
      // fixture without a `category` column can reach at all.
      await type('manufacturing');
      expect(titles(), ['Manufacture of bread and bakery products']);

      // Bucket one. '62011' is a prefix of nothing else here, so what
      // this says is that the exact row is the only row.
      //
      // The ORDER of buckets two and three against each other is not
      // asserted, and that is not an omission. Swapping them --
      // `[...exact, ...byWords, ...byCode]` -- was run as a mutant and
      // SURVIVED, because with real MSIC data no query can land in both:
      // a code is digits and a description and a category are words, so a
      // digit query only ever reaches the code buckets and a word query
      // only ever the word one. The mutant is equivalent on this data,
      // and a fixture built to kill it would have to carry a description
      // with another row's code inside it, which `0011`'s seed does not
      // and MSIC 2008 does not either.
      await type('62011');
      expect(titles(), ['Computer programming activities']);

      // The empty state, and the escape hatch inside it: the seed is a
      // subset of MSIC 2008, so a real five-digit code the list does not
      // carry has to be enterable.
      await type('99999');
      expect(find.byType(ListTile), findsNothing);
      expect(find.text('Nothing in the list matches that.'), findsOneWidget);
      expect(find.text('Use 99999 anyway'), findsOneWidget);

      // And it is offered ONLY for something shaped like a code --
      // `msicLooksValid` is five digits, and four is not four-fifths of a
      // code.
      await type('9999');
      expect(find.text('Nothing in the list matches that.'), findsOneWidget);
      expect(find.byKey(const ValueKey('msic-use-typed')), findsNothing);

      expect(find.textContaining('null'), findsNothing);
    });
  });

  group('timesheets', () {
    // Two empty lists make two empty pickers, and an empty picker has no
    // rows to be right or wrong about. The one rule in this sheet lives
    // in the Person picker's comprehension --
    //
    //     for (final m in team.where((m) => m.userId != null))
    //
    // because only somebody who has ACCEPTED the invitation has a user to
    // hang a rate on -- and a fixture with no team cannot tell whether
    // that `where` is there.
    testWidgets('the billing rate sheet opens', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          projectsProvider.overrideWith((_) async => const [
                {'id': 'p1', 'name': 'Menara Hijau fit-out', 'code': 'MH-01'},
              ]),
          teamProvider.overrideWith((_) async => [
                TeamMember(
                  memberId: 'm1',
                  userId: 'u1',
                  role: 'staff',
                  status: 'active',
                  fullName: 'Nurul Huda binti Ismail',
                  email: 'nurul@example.com',
                ),
                // Accepted, and with no name of their own yet: the label
                // falls to the e-mail and the sublabel is suppressed, so
                // the address is not printed twice.
                TeamMember(
                  memberId: 'm2',
                  userId: 'u2',
                  role: 'staff',
                  status: 'active',
                  email: 'ahmad@example.com',
                ),
                // INVITED, so no `user_id`: this one must not be
                // offerable, and under the old empty fixture nothing
                // said so.
                TeamMember(
                  memberId: 'm3',
                  role: 'staff',
                  status: 'invited',
                  fullName: 'Siti Aminah',
                  email: 'siti@example.com',
                ),
              ]),
        ],
        (context) => showBillingRateSheet(context),
      );
      expect(tester.takeException(), isNull);

      // `Record` is dead until a date is chosen, and `_from` starts null
      // -- so the sheet opens with its own save button disabled, which is
      // deliberate and nothing checked.
      expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('rate-save')))
              .onPressed,
          isNull);

      await tester.tap(find.byKey(const ValueKey('rate-person')));
      await tester.pumpAndSettle();

      expect(find.text('Nurul Huda binti Ismail'), findsOneWidget);
      expect(find.text('nurul@example.com'), findsOneWidget);
      // Name absent: the address is the label, and appears ONCE.
      expect(find.text('ahmad@example.com'), findsOneWidget);
      // And the invited one is not on offer at all.
      expect(find.text('Siti Aminah'), findsNothing);

      await tester.tap(find.text('Nurul Huda binti Ismail'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rate-project')));
      await tester.pumpAndSettle();

      // `allowEmpty`, so the first row is the default rather than a blank:
      // a rate that applies to every project is the common case and has
      // to be sayable.
      expect(find.text('Every project — the default rate'), findsOneWidget);
      expect(find.text('Menara Hijau fit-out'), findsOneWidget);
      expect(find.text('MH-01'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // The fixture here was a shape the database never sends, and the
    // dialog drew `null · <name>` under a key of `budget-null` without
    // complaining. `report_project_budget` (0389) returns
    //
    //     project_id, code, name, customer, start_date, end_date,
    //     is_active, budget_amount, cost_to_date, revenue_to_date,
    //     unbilled_time, variance, percent_spent
    //
    // and the fixture sent `id` for `project_id`, no `code` at all, and
    // invented `budget_hours`, `actual_hours` and `actual_amount` --
    // three columns that function does not return. With `percent_spent`
    // absent, `budgetStateOf` fell to `BudgetState.none`, so the dialog
    // drew its least interesting branch: no progress bar, no overrun, no
    // unbilled-time warning. The single `expect(takeException(), isNull)`
    // noticed none of it.
    //
    // That is widget-tests.md trap 11's second half -- "the column names
    // the repository actually selects; read the method, do not guess from
    // the screen" -- caught in the tree rather than in the doc.
    testWidgets('and the project budgets dialog, in the shape 0389 returns',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          canPostProvider.overrideWithValue(true),
          projectBudgetProvider.overrideWith((_, __) async => [
                {
                  'project_id': 'p1',
                  'code': 'PRJ-0007',
                  'name': long,
                  'customer': 'Kedai Runcit Aman',
                  'start_date': '2026-01-01',
                  'end_date': '2026-12-31',
                  'is_active': true,
                  'budget_amount': 25000.0,
                  'cost_to_date': 28400.0,
                  'revenue_to_date': 18000.0,
                  'unbilled_time': 4200.0,
                  'variance': -3400.0,
                  'percent_spent': 113.6,
                },
              ]),
        ],
        (context) => showProjectBudgets(context),
      );
      expect(tester.takeException(), isNull);

      // The key is built from `project_id`. Under the old fixture this
      // was `budget-null`, which is the whole finding in one line.
      expect(find.byKey(const ValueKey('budget-p1')), findsOneWidget);

      // The title is `code · name`, so a missing `code` reads as "null ·".
      expect(find.text('PRJ-0007 · $long'), findsOneWidget);

      // Over budget, which needs `percent_spent` and `variance` -- the
      // branch the old fixture could not reach at all.
      expect(find.text('RM 28,400.00 spent · RM 3,400.00 over budget'),
          findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('RM 4,200.00 recorded and not invoiced'),
          findsOneWidget);

      // `is_active` decides which button is offered, and the button's own
      // key carries `project_id` as well.
      expect(find.byKey(const ValueKey('budget-close-p1')), findsOneWidget);
      // By the button's own key: the dialog's action bar has a `Close`
      // too, so `find.text('Close')` finds two and a bare findsOneWidget
      // fails on the wrong one of them.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('budget-close-p1')),
          matching: find.text('Close'),
        ),
        findsOneWidget,
      );
      expect(find.text('closed'), findsNothing);
    });

    // The other side of `is_active`, which the old fixture never set.
    testWidgets('and a closed job says so and offers Reopen',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          canPostProvider.overrideWithValue(true),
          projectBudgetProvider.overrideWith((_, __) async => [
                {
                  'project_id': 'p2',
                  'code': 'PRJ-0008',
                  'name': 'Bayu Digital, incorporation',
                  'is_active': false,
                  'budget_amount': 8000.0,
                  'cost_to_date': 6900.0,
                  'variance': 1100.0,
                  'percent_spent': 86.25,
                },
              ]),
        ],
        (context) => showProjectBudgets(context),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('closed'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('budget-close-p2')),
          matching: find.text('Reopen'),
        ),
        findsOneWidget,
      );
      // 86.25 per cent is `close`, not `within` and not `over`: the
      // sentence says what is left rather than what is over.
      expect(find.text('RM 6,900.00 spent · RM 1,100.00 left'),
          findsOneWidget);
    });

    // Every rule in this editor is one function -- `projectBlockedBecause`
    // -- whose answer is both the red line under the form and whether
    // `Save` is pressable. Opening it and asserting nothing exercised the
    // first of its four branches and read neither.
    //
    // Walked forward rather than asserted at one state, because the point
    // of the thing is that it CHANGES: a form that says "Give it a code."
    // for ever is as broken as one that never says it.
    testWidgets('and the project editor', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          contactsProvider.overrideWith((_, __) async => [
                Contact(
                  id: 'c1',
                  code: 'C-0001',
                  name: 'Puan Aminah',
                  contactType: 'customer',
                ),
              ]),
        ],
        (context) => showProjectEditor(context),
      );
      expect(tester.takeException(), isNull);

      bool savable() => tester
              .widget<FilledButton>(find.byKey(const ValueKey('project-save')))
              .onPressed !=
          null;

      expect(find.text('New project'), findsOneWidget);
      expect(find.text('Give it a code.'), findsOneWidget);
      expect(savable(), isFalse);

      await tester.enterText(
          find.byKey(const ValueKey('project-code')), 'MH-01');
      await tester.pump();
      expect(find.text('Give it a name.'), findsOneWidget);
      expect(savable(), isFalse);

      await tester.enterText(
          find.byKey(const ValueKey('project-name')), 'Menara Hijau fit-out');
      await tester.pump();
      expect(find.text('Give it a name.'), findsNothing);
      expect(savable(), isTrue);

      // A budget is optional, so this is the one branch that needs a
      // value present AND wrong rather than absent.
      await tester.enterText(
          find.byKey(const ValueKey('project-budget')), '-100');
      await tester.pump();
      expect(find.text('A budget is not negative.'), findsOneWidget);
      expect(savable(), isFalse);

      await tester.enterText(
          find.byKey(const ValueKey('project-budget')), '250000');
      await tester.pump();
      expect(savable(), isTrue);

      // The customer is allowed to be nobody -- internal work is real --
      // and the helper says what that costs rather than refusing it.
      await tester.tap(find.byKey(const ValueKey('project-customer')));
      await tester.pumpAndSettle();
      expect(find.text('Puan Aminah'), findsOneWidget);
      expect(find.text('C-0001'), findsOneWidget);
      expect(find.text('Time on a project with no customer cannot be invoiced'),
          findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });
  });

  group('documents', () {
    // `document_activity` (0495) returns
    //
    //     at, kind, recipient, status, detail, note
    //
    // and the fixture sent `id, kind, to_address, subject, created_at,
    // status`. Two of six landed. So the row drew "Emailed" with a "sent"
    // badge and NOTHING else: no address, no detail, no note, and no
    // timestamp -- `_ActivityTile` reads `entry['at']`, not `created_at`.
    // Which is every part of the line a person is reading it for.
    testWidgets('the activity dialog opens, in the shape 0495 returns',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          documentActivityProvider.overrideWith((_, __) async => const [
                {
                  'at': '2026-09-01T02:00:00Z',
                  'kind': 'email',
                  'recipient': 'akaun@sinar.com.my',
                  'status': 'sent',
                  'detail': 'sent now · PDF attached',
                  'note': 'delivered to the provider',
                },
                // A second kind, because `ActivityLine.from` switches on
                // it and one kind proves one arm.
                {
                  'at': '2026-09-02T02:00:00Z',
                  'kind': 'share link',
                  'recipient': 'pelanggan@sinar.com.my',
                  'status': 'opened',
                  'detail': 'opened twice',
                  'note': null,
                },
              ]),
        ],
        (context) => showActivityDialog(context, 'd1', 'INV-0001'),
      );
      expect(tester.takeException(), isNull);

      // The labels `ActivityLine.from` builds from `kind`.
      expect(find.text('Emailed'), findsOneWidget);
      expect(find.text('Link shared'), findsOneWidget);
      // `status`, which is the badge.
      expect(find.text('sent'), findsOneWidget);
      expect(find.text('opened'), findsOneWidget);
      // `recipient` and `detail` and `note`, none of which the old
      // fixture supplied under a name anything read.
      expect(find.text('akaun@sinar.com.my'), findsOneWidget);
      expect(find.text('sent now · PDF attached'), findsOneWidget);
      expect(find.text('delivered to the provider'), findsOneWidget);
      expect(find.text('opened twice'), findsOneWidget);

      // `at`, which `_ActivityTile` reads and the old fixture supplied as
      // `created_at`. Feeding it is what found the overflow: the
      // timestamp used to sit in the outer Row as an unflexed `Text`, and
      // with it present the label, the badge and the detail had about 60
      // logical pixels between them. 110 and 187 pixels over, at 412
      // wide, on a dialog nothing had ever drawn with a timestamp in it.
      expect(find.textContaining('2026'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    // Opened WITHOUT a `defaultTo` and without a `buildPdf`, which is the
    // dialog's thinnest configuration -- and is also the one where the
    // helper line has to tell somebody that the customer has no address
    // on file, because there is nothing to fall back to. The old test
    // asserted neither that nor the address check, which governs both
    // send buttons at once.
    testWidgets('and the e-mail dialog', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          documentActivityProvider.overrideWith((_, __) async => const []),
        ],
        (context) =>
            showEmailDialog(context, documentId: 'd1', docNo: 'INV-0001'),
      );
      expect(tester.takeException(), isNull);

      // `OutlinedButton.icon` and `FilledButton.icon` are both
      // `ButtonStyleButton`s, and `find.byType` matches the exact runtime
      // type -- so the button is reached from its LABEL upwards.
      bool sendable(String label) => tester
              .widgetList<ButtonStyleButton>(find.ancestor(
                of: find.text(label),
                matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
              ))
              .first
              .onPressed !=
          null;

      expect(find.text('Email INV-0001'), findsOneWidget);
      expect(find.text('This customer has no address saved — type one'),
          findsOneWidget);
      // `buildPdf` is null here, so there is nothing to attach and the
      // checkbox must not be offered at all.
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('Nothing has been sent, shared or downloaded.'),
          findsOneWidget);

      // Empty is allowed -- it means "the address on the customer" -- so
      // the buttons are live before anything is typed.
      expect(sendable('Queue it'), isTrue);
      expect(sendable('Send now'), isTrue);

      await tester.enterText(find.byType(TextField).first, 'not-an-address');
      await tester.pump();
      expect(find.text('That does not look like an email address'),
          findsOneWidget);
      expect(sendable('Queue it'), isFalse);
      expect(sendable('Send now'), isFalse);

      await tester.enterText(
          find.byType(TextField).first, 'accounts@example.com');
      await tester.pump();
      expect(find.text('That does not look like an email address'),
          findsNothing);
      expect(sendable('Send now'), isTrue);
      expect(find.textContaining('null'), findsNothing);
    });

    // `token` and `views` were the fixture's words. `document_share_links`
    // (0094) has `token_hash` and `open_count`, and the query is a bare
    // `.select()`, so a real row carries every column in that table. With
    // `sent_to_email` and `open_count` absent the row read
    //
    //     No address recorded
    //     issued — · until 31 Dec 2026 · never opened
    //
    // which is the opposite of a link that was emailed and opened three
    // times, and `views: 3` sat in the fixture saying so to nobody.
    testWidgets('and the share dialog, in the shape the table holds',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          documentShareLinksProvider.overrideWith((_, __) async => const [
                {
                  'id': 'sl1',
                  'token_hash': 'abcdef0123456789abcdef0123456789',
                  'expires_at': '2026-12-31T00:00:00Z',
                  'sent_to_email': 'akaun@sinar.com.my',
                  'created_at': '2026-09-01T02:00:00Z',
                  'open_count': 3,
                  'last_opened_at': '2026-09-28T04:00:00Z',
                  'revoked_at': null,
                },
                // Revoked, and never opened: the other end of both
                // branches the row draws.
                {
                  'id': 'sl2',
                  'token_hash': '0123456789abcdef0123456789abcdef',
                  'expires_at': '2026-12-31T00:00:00Z',
                  'sent_to_email': 'lama@sinar.com.my',
                  'created_at': '2026-08-01T02:00:00Z',
                  'open_count': 0,
                  'revoked_at': '2026-08-15T02:00:00Z',
                },
              ]),
        ],
        (context) => showShareDialog(context, 'd1', 'INV-0001'),
      );
      expect(tester.takeException(), isNull);

      // `sent_to_email`, which the old fixture never supplied.
      expect(find.text('akaun@sinar.com.my'), findsOneWidget);
      expect(find.text('lama@sinar.com.my'), findsOneWidget);
      expect(find.text('No address recorded'), findsNothing);

      // `open_count` and `last_opened_at`. The old fixture's `views: 3`
      // left this at "never opened".
      expect(find.textContaining('opened 3 times, last '), findsOneWidget);
      expect(find.textContaining('never opened'), findsOneWidget);

      // `revoked_at` decides the chip, and it is the one thing that stops
      // somebody trusting a link that no longer works. `StatusChip` draws
      // its status through `Fmt.label`, which capitalises -- so the text
      // on screen is `Active`, not the `active` the widget was handed.
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Revoked'), findsOneWidget);
    });

    // A SIXTEENTH WRONG-SHAPE FIXTURE, and the same hunt found it: the
    // dialog's title is `'What ${widget.schedule['name']} bills'` and
    // `recurring_documents` (0097) has a `name text not null`, which the
    // fixture did not supply -- so the heading read "What null bills".
    // It also invented `doc_type` and `next_run`; the table's columns are
    // `kind` ('sales' or 'purchase') and `next_run_date`, and `kind` is
    // the one that decides whether the picker offers invoices or bills.
    // `templateKindOf(null)` happens to answer sales, so a PURCHASE
    // schedule under this fixture would have been offered invoices and
    // `update_recurring_template` would have raised on the save.
    //
    // And `documentsProvider` answered `[]`, so the dialog drew its empty
    // state and `templateCandidates`, `templateLabel` and the save
    // button's one condition were all unreachable.
    testWidgets('and the recurring template dialog', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          documentsProvider.overrideWith((_, __) async => [
                BusinessDocument(
                  id: 'd1',
                  docType: 'invoice',
                  docNo: 'INV-0101',
                  docDate: DateTime.utc(2026, 9, 1),
                  contactId: 'c1',
                  contactName: long,
                  status: 'posted',
                  totalAmount: 1250.5,
                ),
                // A DRAFT, which `templateCandidates` drops: a schedule
                // built on a draft bills what somebody was still typing.
                BusinessDocument(
                  id: 'd2',
                  docType: 'invoice',
                  docNo: 'INV-0102',
                  docDate: DateTime.utc(2026, 9, 15),
                  contactId: 'c1',
                  status: 'draft',
                  totalAmount: 400,
                ),
                // And a voided one, dropped for the same reason the other
                // way round.
                BusinessDocument(
                  id: 'd3',
                  docType: 'invoice',
                  docNo: 'INV-0103',
                  docDate: DateTime.utc(2026, 9, 20),
                  contactId: 'c1',
                  status: 'void',
                  totalAmount: 900,
                ),
              ]),
        ],
        (context) => showRecurringTemplateDialog(context, schedule: const {
          'id': 's1',
          'name': 'Menara Hijau monthly retainer',
          'kind': 'sales',
          'frequency': 'monthly',
          'next_run_date': '2026-10-01',
          'is_active': true,
        }),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('What Menara Hijau monthly retainer bills'),
          findsOneWidget);
      expect(find.text('INV-0101 · $long · 01/09/2026 · RM 1,250.50'),
          findsOneWidget);
      // Neither the draft nor the voided one is offerable.
      expect(find.byKey(const ValueKey('template-d1')), findsOneWidget);
      expect(find.byKey(const ValueKey('template-d2')), findsNothing);
      expect(find.byKey(const ValueKey('template-d3')), findsNothing);
      expect(find.textContaining('null'), findsNothing);

      // Nothing chosen, nothing to save -- and then the one choice there
      // is turns the button on.
      bool savable() => tester
              .widget<FilledButton>(find.byKey(const ValueKey('template-save')))
              .onPressed !=
          null;
      expect(savable(), isFalse);
      await tester.tap(find.byKey(const ValueKey('template-d1')));
      await tester.pumpAndSettle();
      expect(savable(), isTrue);
    });

    // The other half of `templateKindOf`, and it needed its own test: with
    // a sales schedule in the fixture above, forcing the function to
    // answer `DocKind.sales` always was run as a mutant and SURVIVED,
    // because nothing on the screen differs. What differs is the QUERY --
    // `update_recurring_template` looks for a bill on a purchase schedule
    // and raises if it is handed an invoice -- so the argument the
    // provider was asked for is the thing to assert.
    testWidgets('and a purchase schedule asks for bills, not invoices',
        (tester) async {
      final asked = <({DocKind kind, String docType, String status,
          String search})>[];
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          documentsProvider.overrideWith((_, args) async {
            asked.add(args);
            return [
              BusinessDocument(
                id: 'b1',
                docType: 'bill',
                docNo: 'BILL-0044',
                docDate: DateTime.utc(2026, 9, 1),
                contactId: 'c9',
                contactName: 'Pembekal Alat Tulis',
                status: 'posted',
                totalAmount: 320,
              ),
            ];
          }),
        ],
        (context) => showRecurringTemplateDialog(context, schedule: const {
          'id': 's2',
          'name': 'Monthly stationery',
          'kind': 'purchase',
          'frequency': 'monthly',
          'next_run_date': '2026-10-01',
          'is_active': true,
        }),
      );
      expect(tester.takeException(), isNull);

      expect(asked, hasLength(1));
      expect(asked.single.kind, DocKind.purchase);
      expect(asked.single.docType, 'bill');
      expect(find.text('What Monthly stationery bills'), findsOneWidget);
      expect(find.text('BILL-0044 · Pembekal Alat Tulis · 01/09/2026 · '
          'RM 320.00'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // `total` was the fixture's word and `Repo.settlement` returns the
    // receipt row itself, whose money column is `amount` -- so the figure
    // beside the receipt number read RM 0.00 while the fixture said 100.
    // `contacts` (an embed, `contacts(name, …)`), `receipt_date` and
    // `unapplied_amount` were all absent too, so the header had a blank
    // name and no date, and the one sentence about money left on account
    // could not appear.
    testWidgets('and one settlement in detail, in the shape it is read',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          settlementProvider.overrideWith((_, __) async => const {
                'id': 'r1',
                'receipt_no': 'RCPT-0001',
                'receipt_date': '2026-09-18',
                'amount': 1200.0,
                'unapplied_amount': 400.0,
                'currency': 'MYR',
                'contacts': {'name': 'Kedai Runcit Aman', 'code': 'C-0007'},
                'allocations': <Map<String, dynamic>>[
                  {
                    'amount': 800.0,
                    'discount_amount': 0,
                    'sales_documents': {
                      'doc_no': 'INV-0007',
                      'doc_type': 'invoice',
                      'doc_date': '2026-09-01',
                      'total_amount': 800.0,
                    },
                  },
                ],
              }),
        ],
        (context) => showSettlementDetail(context, id: 'r1', isSales: true),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('RCPT-0001'), findsOneWidget);
      // The embed, read as `(s['contacts'] as Map?)?['name']`.
      expect(find.text('Kedai Runcit Aman'), findsOneWidget);
      // `amount`, not `total`.
      expect(find.textContaining('1,200.00'), findsWidgets);
      // The allocation, through `_doc(a)?['doc_no']`.
      expect(find.text('INV-0007'), findsOneWidget);
      expect(find.text('RM 800.00'), findsOneWidget);
      expect(find.textContaining('the whole amount is on account'),
          findsNothing);
      // And `unapplied_amount`, which is the sentence somebody needs:
      // money taken that is not against anything yet.
      expect(
        find.textContaining('RM 400.00 is still on account'),
        findsOneWidget,
      );
    });

    // The same dialog as above with its other half supplied: a
    // `buildPdf`, so the attach checkbox exists. Its SUBTITLE is the
    // point -- it argues the case either way, and which argument is on
    // the screen depends on the box, so a test that never ticks it reads
    // one of two sentences and cannot tell it is the right one.
    testWidgets('and the receipt e-mail dialog', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          documentActivityProvider.overrideWith((_, __) async => const []),
        ],
        (context) => showReceiptEmailDialog(
          context,
          receiptId: 'r1',
          receiptNo: 'RCPT-0001',
          buildPdf: () async => Uint8List(0),
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Email RCPT-0001'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(find.text('Attach the receipt'), findsOneWidget);
      expect(find.text('This customer has no address saved — type one'),
          findsOneWidget);

      // On by default here, and that is the difference from the document
      // dialog above rather than an oversight: a receipt is the thing the
      // customer files, so the PDF travels unless somebody says not to.
      expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isTrue);
      expect(find.text('The customer gets a PDF they can file.'),
          findsOneWidget);

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();

      expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isFalse);
      expect(find.text('Just the message — nothing to keep.'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });
  });

  group('financials', () {
    // A SEVENTEENTH WRONG-SHAPE FIXTURE, and this one was a row from
    // ANOTHER TABLE. This dialog edits `fs_filings` (0171) and saves
    // through `updateFsFiling`; `form` and `due_on` belong to the LHDN
    // filing calendar, and `status: 'due'` is not one of
    // `app.fs_filing_status`, whose three values are draft, frozen and
    // lodged. So:
    //
    //   * `fy_start` and `fy_end` were absent, `filingPeriodRuns` was
    //     false, Save was dead, and the warning "The year has to end
    //     after it begins." was the one thing on the screen the fixture
    //     did reach -- by accident.
    //   * nothing was ever LODGED, so `kLodgedLockedFields` and the
    //     paragraph explaining it drew for nobody. That set follows
    //     `app.fs_refuse_lodged_edit` field for field, and a UI that
    //     leaves a locked field editable sends an update the trigger
    //     refuses -- which is the whole reason the set is duplicated in
    //     Dart at all.
    //
    // Lodged here, therefore, because that is the branch with a rule in
    // it.
    testWidgets('one filing in detail opens', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showFilingDetails(context, filing: const {
          'id': 'f1',
          'fy_start': '2025-01-01',
          'fy_end': '2025-12-31',
          'framework': 'mfrs',
          'audit_status': 'unaudited',
          'opinion': 'qualified',
          'auditor_name': 'Tetuan Audit Bersatu',
          'auditor_firm_no': 'AF 1234',
          'auditor_signatory': 'Lim Wei Jian',
          'audit_report_date': '2026-04-30',
          'going_concern_emphasis': true,
          'employee_count': 42,
          'directors_approval_date': '2026-05-15',
          'circulated_on': '2026-05-20',
          'notes': 'Lodged late; penalty paid.',
          'lodged_on': '2026-06-30',
          'mbrs_reference': 'MBRS-2026-0001',
          'status': 'lodged',
        }),
      );
      expect(tester.takeException(), isNull);

      // The period runs, so the warning is gone and Save is alive.
      expect(find.text('The year has to end after it begins.'), findsNothing);
      expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('filing-save')))
              .onPressed,
          isNotNull);

      // The lodged paragraph, which no fixture had ever produced.
      expect(find.textContaining('These have been lodged with SSM'),
          findsOneWidget);

      // Every field the row supplied is on the screen, under the column
      // name the table uses. `Fmt.label` capitalises, so the dropdowns
      // read 'Unaudited' and 'Qualified' rather than the enum values, and
      // the framework is upper-cased rather than labelled.
      expect(find.text('MFRS'), findsOneWidget);
      expect(find.text('Unaudited'), findsOneWidget);
      expect(find.text('Qualified'), findsOneWidget);
      expect(find.text('Tetuan Audit Bersatu'), findsOneWidget);
      expect(find.text('AF 1234'), findsOneWidget);
      expect(find.text('Lim Wei Jian'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('Lodged late; penalty paid.'), findsOneWidget);
      expect(
          tester
              .widget<SwitchListTile>(
                  find.byKey(const ValueKey('filing-going-concern')))
              .value,
          isTrue);
      expect(find.textContaining('null'), findsNothing);

      // AND THE LOCK ITSELF, field by field against `kLodgedLockedFields`
      // -- which is the point of lodging the fixture. A `null` `onChanged`
      // is what makes a dropdown unusable, and it looks identical to a
      // live one on the screen.
      expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                  find.byKey(const ValueKey('filing-framework')))
              .onChanged,
          isNull);
      expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                  find.byKey(const ValueKey('filing-audit-status')))
              .onChanged,
          isNull);
      expect(
          tester
              .widget<DropdownButtonFormField<String?>>(
                  find.byKey(const ValueKey('filing-opinion')))
              .onChanged,
          isNull);
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('filing-auditor')))
              .enabled,
          isFalse);

      // And what the lock does NOT cover: the headcount is not in the
      // set, because `app.fs_refuse_lodged_edit` does not name it, and
      // the Dart set follows the trigger rather than the sentence beside
      // it. A test that only checked the locked fields would pass over a
      // set that locked everything.
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('filing-headcount')))
              .enabled,
          isTrue);
    });
  });

  group('reports', () {
    // `lines: const []` drew "Nothing budgeted yet.", 0 lines and a nought
    // total, which is every part of this dialog except the part with a
    // rule in it. The rule is `lineSurvives(amount)`, i.e. `amount != 0`,
    // and it does three things at once: the row is struck through, its
    // subtitle changes to say the line will be REMOVED, and the line
    // drops out of both the count and the total. `set_budget_lines`
    // deletes the budget and re-inserts the payload, so a nought is not a
    // nought -- it is a deletion, and the row has to say so before
    // somebody presses Save.
    //
    // Lines in the shape `budget_lines_for` (0274) returns:
    // account_id, code, name, account_type, period_id, period_no,
    // period_name, amount.
    testWidgets('the budget line editor opens', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          accountsProvider.overrideWith((_) async => const <Account>[]),
          fiscalYearsProvider.overrideWith((_) async => const <FiscalYear>[]),
        ],
        (context) => showBudgetLineEditor(
          context,
          budget: const {'id': 'b1', 'name': '2026', 'fiscal_year_id': 'y1'},
          lines: const [
            {
              'account_id': 'a1',
              'code': '5000',
              'name': 'Salaries and wages',
              'account_type': 'expense',
              'period_id': 'p1',
              'period_no': 1,
              'period_name': 'January 2026',
              'amount': 12000,
            },
            {
              'account_id': 'a2',
              'code': '5100',
              'name': 'Rent',
              'account_type': 'expense',
              'period_id': 'p1',
              'period_no': 1,
              'period_name': 'January 2026',
              'amount': 3500.5,
            },
            // Nought, which is a DELETION rather than a nought.
            {
              'account_id': 'a3',
              'code': '5200',
              'name': 'Entertainment',
              'account_type': 'expense',
              'period_id': 'p1',
              'period_no': 1,
              'period_name': 'January 2026',
              'amount': 0,
            },
          ],
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('2026'), findsOneWidget);
      expect(find.text('Nothing budgeted yet.'), findsNothing);
      expect(find.text('5000 Salaries and wages'), findsOneWidget);
      expect(find.text('5100 Rent'), findsOneWidget);
      expect(find.text('5200 Entertainment'), findsOneWidget);

      // Two of the three subtitles are the bare period; the nought's says
      // what pressing Save would do.
      expect(find.text('January 2026'), findsNWidgets(2));
      expect(find.text('January 2026 — will be removed'), findsOneWidget);

      // And it is struck through, which the sentence beside it cannot
      // say for a row somebody is scrolling past.
      final gone = tester.widget<Text>(find.text('5200 Entertainment'));
      expect(gone.style?.decoration, TextDecoration.lineThrough);
      final kept = tester.widget<Text>(find.text('5100 Rent'));
      expect(kept.style?.decoration, isNull);

      // The count and the total both exclude it. 12,000 + 3,500.50.
      expect(find.text('2 lines'), findsOneWidget);
      expect(find.text('RM 15,500.50'), findsOneWidget);
      expect(find.text('RM 12,000.00'), findsOneWidget);
      expect(find.text('RM 0.00'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });
  });

  group('the rest of HR', () {
    // Two empty lists again, so two empty pickers -- and worse, the one
    // conditional in the form needs something TYPED to appear at all.
    // `earliestStartDate` turns a notice period into "Earliest start
    // <date>" under the field, and that line is not a reminder:
    // `hire_applicant` refuses a start inside the notice period unless
    // somebody says why, so the date is the rule showing itself early.
    // Nothing was typed, so the helper was null on every frame.
    testWidgets('the applicant editor opens', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          directoryProvider.overrideWith((_) async => [
                Employee(
                  id: 'em1',
                  employeeNo: 'E-0001',
                  fullName: 'Nurul Huda binti Ismail',
                  departmentName: 'Finance',
                ),
                // No department, which the sublabel joins around rather
                // than printing an empty half.
                Employee(
                  id: 'em2',
                  employeeNo: 'E-0002',
                  fullName: 'Ahmad Faizal',
                ),
              ]),
          requisitionsProvider.overrideWith((_) async => [
                JobRequisition(
                  id: 'r1',
                  requisitionNo: 'REQ-0001',
                  title: 'Senior accounts executive',
                  status: 'open',
                ),
              ]),
        ],
        (context) => showApplicantEditor(context),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Add a candidate'), findsOneWidget);
      expect(find.text('Earliest start'), findsNothing);
      expect(find.textContaining('Earliest start'), findsNothing);

      // 30 days' notice typed in: the rule appears, computed off today
      // rather than off a constant, so the expectation is computed the
      // same way.
      final notice = find.widgetWithText(TextField, 'Notice owed (days)');
      await tester.enterText(notice, '30');
      await tester.pump();
      final earliest = earliestStartDate(
        noticePeriodDays: 30,
        today: DateTime.now(),
      );
      expect(find.text('Earliest start ${Fmt.date(earliest)}'), findsOneWidget);

      // Nought is not a notice period, and neither is a word -- both read
      // as "nobody has said", which is why the helper goes away rather
      // than saying today.
      await tester.enterText(notice, '0');
      await tester.pump();
      expect(find.textContaining('Earliest start'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('applicant-requisition')));
      await tester.pumpAndSettle();
      expect(find.text('Senior accounts executive'), findsOneWidget);
      expect(find.text('REQ-0001'), findsOneWidget);

      // Escape first, because the overlay just opened is a `TapRegion`
      // and a tap on the next field reads as a dismissal of this one
      // rather than as a tap on that one. Then scroll: eleven fields do
      // not fit 900 logical pixels, and `find` locates a child of a
      // `SingleChildScrollView` that is outside the viewport while
      // `tap` cannot hit it.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey(
        'applicant-referrer',
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('applicant-referrer')));
      await tester.pumpAndSettle();
      // `allowEmpty` with a NAMED empty row: "Nobody" is a real answer
      // here, and a blank row would read as the list still loading.
      expect(find.text('Nobody'), findsOneWidget);
      expect(find.text('Nurul Huda binti Ismail'), findsOneWidget);
      expect(find.text('E-0001 · Finance'), findsOneWidget);
      // No department, so no trailing separator.
      expect(find.text('E-0002'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // `requisitionBlockedBecause` has five branches and the empty form
    // reaches the first; the rest need typing. The salary one is the
    // interesting one, because it is the only branch that needs two
    // fields to be present AND in the wrong order -- an empty band is
    // allowed, so it cannot be reached by leaving things blank.
    testWidgets('and the requisition editor', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          directoryProvider.overrideWith((_) async => [
                Employee(
                  id: 'em1',
                  employeeNo: 'E-0001',
                  fullName: 'Nurul Huda binti Ismail',
                  departmentName: 'Finance',
                ),
              ]),
          departmentsProvider.overrideWith((_) async => const [
                {'id': 'd1', 'name': 'Finance', 'code': 'FIN'},
                {'id': 'd2', 'name': 'Operations', 'code': 'OPS'},
              ]),
        ],
        (context) => showRequisitionEditor(context),
      );
      expect(tester.takeException(), isNull);

      bool savable() => tester
              .widget<FilledButton>(find.byKey(const ValueKey('req-save')))
              .onPressed !=
          null;

      expect(find.text('Raise a vacancy'), findsOneWidget);
      expect(find.text('Give it a number.'), findsOneWidget);
      expect(savable(), isFalse);

      await tester.enterText(
          find.byKey(const ValueKey('req-no')), 'REQ-0007');
      await tester.pump();
      expect(find.text('Give the role a title.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('req-title')),
          'Senior accounts executive');
      await tester.pump();
      // `Places` is seeded with 1 rather than left empty, so with a
      // number and a title the form is already savable -- which is worth
      // pinning, because an empty seed would have read as nought and
      // blocked every new vacancy until somebody typed the 1 themselves.
      expect(find.text('Give the role a title.'), findsNothing);
      expect(savable(), isTrue);

      // Nought places is not a vacancy, and `_count` parses the box
      // rather than holding a number -- so a cleared box is a nought too.
      await tester.enterText(find.byKey(const ValueKey('req-headcount')), '0');
      await tester.pump();
      expect(find.text('A vacancy is for at least one person.'),
          findsOneWidget);
      expect(savable(), isFalse);

      await tester.enterText(find.byKey(const ValueKey('req-headcount')), '');
      await tester.pump();
      expect(find.text('A vacancy is for at least one person.'),
          findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('req-headcount')), '2');
      await tester.pump();
      expect(savable(), isTrue);

      // A band the wrong way up.
      await tester.enterText(find.widgetWithText(TextField, 'Salary from'),
          '8000');
      await tester.enterText(find.widgetWithText(TextField, 'to'), '5000');
      await tester.pump();
      expect(find.text('The salary band runs upwards.'), findsOneWidget);
      expect(savable(), isFalse);

      await tester.enterText(find.widgetWithText(TextField, 'to'), '12000');
      await tester.pump();
      expect(savable(), isTrue);

      await tester.tap(find.byKey(const ValueKey('req-manager')));
      await tester.pumpAndSettle();
      // "Nobody yet" rather than a blank: the helper says a vacancy
      // cannot be OPENED without a manager, and `openBlockedBecause` is
      // the rule it is pointing at -- so leaving it unset has to be
      // sayable rather than merely possible.
      expect(find.text('Nobody yet'), findsOneWidget);
      expect(find.text('Nurul Huda binti Ismail'), findsOneWidget);
      expect(find.text('A vacancy cannot be opened without one'),
          findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // `weight` was the fixture's word and the dialog reads
    // `weight_percent` -- in two places, the row's subtitle and the
    // running total. So every goal read "0%", the total read "0%", and the
    // dialog sat on its "Short of 100%" warning while the fixture said 25.
    // `target`, `actual`, `category`, `self_rating` and `manager_rating`
    // were all absent, which is the rest of what a goal row says.
    testWidgets('and the appraisal goals dialog, with weights that add up',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          appraisalGoalsProvider.overrideWith((_, __) async => const [
                {
                  'id': 'g1',
                  'title': long,
                  'description': long,
                  'category': 'Delivery',
                  'weight_percent': 60,
                  'target': '12 filings',
                  'actual': '11 filings',
                  'self_rating': 4,
                  'manager_rating': 3,
                  'sort_order': 1,
                },
                {
                  'id': 'g2',
                  'title': 'Answer every client within a day',
                  'weight_percent': 40,
                  'sort_order': 2,
                },
              ]),
        ],
        (context) => showAppraisalGoals(context, 'a1', 'Aisyah'),
      );
      expect(tester.takeException(), isNull);

      // The subtitle, which is `weight_percent` and then whatever else the
      // goal records.
      expect(find.text('60% · Delivery · target 12 filings · actual '
          '11 filings'), findsOneWidget);
      // The second goal records none of those, so it is the bare weight.
      expect(find.text('40%'), findsOneWidget);

      // Both ratings side by side -- the gap between them is the
      // conversation -- and an em dash where a rating is not in yet.
      expect(find.text('4 / 3'), findsOneWidget);
      expect(find.text('— / —'), findsOneWidget);

      // And the total, which adds up: no warning either way.
      expect(find.text('Total weight'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.textContaining('Short of 100%'), findsNothing);
      expect(find.textContaining('Over 100%'), findsNothing);
    });

    // And the warning, which is the thing the dialog is for: a rating
    // whose parts do not account for the whole job.
    testWidgets('and it says so when the weights do not reach 100',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          appraisalGoalsProvider.overrideWith((_, __) async => const [
                {'id': 'g1', 'title': 'One thing', 'weight_percent': 70},
              ]),
        ],
        (context) => showAppraisalGoals(context, 'a1', 'Aisyah'),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('70%'), findsNWidgets(2));
      expect(find.textContaining('Short of 100%'), findsOneWidget);
    });

    // `stage`, `interviewer_name` and `notes` were the fixture's words.
    // The dialog reads `round_no`, `mode`, `score`, `outcome`, `feedback`
    // and the interviewer as an EMBED -- `round['employees']` with a
    // `full_name` inside it, not a flat name column. So the row read
    // "Round 0" with a date and nothing else: no mode, no interviewer, no
    // score, no outcome chip and no feedback, which is every part of it.
    testWidgets('and the interviews dialog, in the shape it is read',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          employeesProvider.overrideWith((_, __) async => const <Employee>[]),
          interviewsProvider.overrideWith((_, __) async => const [
                {
                  'id': 'iv1',
                  'round_no': 1,
                  'scheduled_at': '2026-10-01T02:00:00Z',
                  'mode': 'in_person',
                  'duration_minutes': 45,
                  'employees': {'full_name': long},
                  'score': 4,
                  'outcome': 'passed',
                  'feedback': 'Knows the statutory deadlines cold.',
                },
                // A round not held yet: no outcome, no score, no feedback,
                // and nothing scheduled either.
                {
                  'id': 'iv2',
                  'round_no': 2,
                  'scheduled_at': null,
                  'mode': 'video',
                },
              ]),
        ],
        (context) => showInterviews(context, 'ap1', 'Aisyah'),
      );
      expect(tester.takeException(), isNull);

      // `round_no`, which the old fixture never supplied -- every row read
      // "Round 0".
      expect(find.text('Round 1'), findsOneWidget);
      expect(find.text('Round 2'), findsOneWidget);
      expect(find.text('Round 0'), findsNothing);

      // `mode` through `Fmt.label`, the interviewer out of the embed, and
      // `score`.
      // `Fmt.label` splits on `_` and capitalises EVERY word, so
      // `in_person` is `In Person` -- not `In person`, which is what I
      // wrote first.
      expect(find.textContaining('In Person · with $long · scored 4/5'),
          findsOneWidget);
      // `outcome` is the chip, and `Fmt.label` capitalises it.
      expect(find.text('Passed'), findsOneWidget);
      // `feedback`, which is the third line.
      expect(find.text('Knows the statutory deadlines cold.'),
          findsOneWidget);

      // And the round with nothing in it yet says so rather than showing
      // a date it does not have.
      expect(find.textContaining('not scheduled · Video'), findsOneWidget);
    });

    // `due_days` was the fixture's word and the dialog reads
    // `due_offset_days`, so `Fmt.toInt(null)` gave 0 and every row said
    // "on the start date" whatever its real offset. `is_mandatory` was
    // absent, and the subtitle appends "optional" whenever it is not
    // `true` -- so this test drew a MANDATORY task labelled optional.
    testWidgets('and one onboarding template, in the shape it is stored',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          templateItemsProvider.overrideWith((_, __) async => const [
                {
                  'id': 'ti1',
                  'title': long,
                  'description': long,
                  'category': 'Paperwork',
                  'due_offset_days': 7,
                  'owner_role': 'hr_manager',
                  'is_mandatory': true,
                },
                // One of each, because "optional" is only meaningful
                // against a row that is not.
                {
                  'id': 'ti2',
                  'title': 'Order a laptop',
                  'due_offset_days': -3,
                  'is_mandatory': false,
                },
              ]),
        ],
        (context) => showTemplateItems(
            context, const {'id': 't1', 'name': 'New joiner'}),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('New joiner · items'), findsOneWidget);
      expect(find.text(long), findsOneWidget);

      // `due_offset_days` through `_dayLabel`, `owner_role`, and
      // `is_mandatory` by its absence from this line.
      expect(find.text('Paperwork · day 7 · for hr_manager'),
          findsOneWidget);
      // And the other row, where the offset is before the start date and
      // "optional" belongs.
      expect(find.text('3 days before · optional'), findsOneWidget);
    });

    // An empty month drew "Nothing recorded" and nothing else. The test
    // below it already covers a populated month with every flag set, so
    // this one takes the branches THAT one cannot reach:
    //
    //   * `attendanceLine`'s other two shapes -- a day clocked into and
    //     not out of, and a row with no `clockIn` at all, where the line
    //     is the STATUS rather than a pair of times.
    //   * `attendanceTotals` counting days off `clockIn` and not off
    //     rows, so three rows make two days.
    //   * the totals line with NO late and NO overtime, which is the
    //     `if (totals.late > 0)` suppression the other fixture always
    //     satisfies and therefore never tests.
    //
    // Local `DateTime`s and not `utc`, deliberately: `Fmt.time` formats
    // `value.toLocal()`, so a UTC fixture reads as a different clock time
    // wherever the test happens to run.
    testWidgets('and a month of attendance', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          canManageHrProvider.overrideWithValue(true),
          attendanceProvider.overrideWith((_, __) async => [
                // A plain day: in, out, no lateness, no overtime.
                AttendanceRecord(
                  id: 'a1',
                  workDate: DateTime(2026, 10, 1),
                  status: 'present',
                  employeeName: 'Nurul Huda binti Ismail',
                  clockIn: DateTime(2026, 10, 1, 9, 0),
                  clockOut: DateTime(2026, 10, 1, 18, 0),
                  workedMinutes: 540,
                ),
                // Clocked in and not out.
                AttendanceRecord(
                  id: 'a2',
                  workDate: DateTime(2026, 10, 2),
                  status: 'present',
                  employeeName: 'Ahmad Faizal',
                  clockIn: DateTime(2026, 10, 2, 8, 55),
                ),
                // An absence: no `clockIn`, so the line is the status and
                // the day does not count toward the total.
                AttendanceRecord(
                  id: 'a3',
                  workDate: DateTime(2026, 10, 3),
                  status: 'on_leave',
                  employeeName: 'Ahmad Faizal',
                ),
              ]),
        ],
        (context) => showAttendanceMonth(context),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Attendance this month'), findsOneWidget);
      expect(find.text('Nothing recorded'), findsNothing);

      // `employeeId` is null here -- HR looking at everybody -- so the
      // name joins the date.
      expect(find.text('01/10/2026 · Nurul Huda binti Ismail'),
          findsOneWidget);

      expect(find.text('In 09:00 · out 18:00'), findsOneWidget);
      expect(find.text('In 08:55 · still open'), findsOneWidget);
      // `Fmt.label` on the status, so 'on_leave' reads as a sentence.
      expect(find.text('On Leave'), findsOneWidget);
      // No flags on any of the three, so nothing is coloured and nothing
      // says "corrected".
      expect(find.textContaining('late'), findsNothing);
      expect(find.textContaining('overtime'), findsNothing);
      expect(find.textContaining('corrected'), findsNothing);

      expect(find.text('9.00h'), findsNWidgets(2));
      expect(find.text('0.00h'), findsNWidgets(2));

      // TWO days from three rows, and a totals line with neither optional
      // clause in it.
      expect(find.text('2 days'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // Trap 11, on the test directly above it. An empty list draws an
    // `EmptyState` -- one icon and two centred sentences -- so the row
    // builder and the totals line, which are the whole dialog, never ran.
    // `expect(takeException(), isNull)` over an EmptyState is a claim
    // about nothing.
    //
    // Fed: a long employee name, because with no employeeId the title
    // carries one; a day with lateness, overtime AND a correction, which
    // is the longest subtitle the flags can build; and a month's worth of
    // totals, because the totals line is an `Expanded(Text)` beside an
    // unflexed `Text` and that is the arrangement that overflowed in
    // `credit_ledger_dialog.dart`.
    testWidgets('and a month of attendance with something in it',
        (tester) async {
      final day = DateTime(2026, 3, 17);
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          canManageHrProvider.overrideWithValue(true),
          attendanceProvider.overrideWith((_, __) async => <AttendanceRecord>[
                AttendanceRecord(
                  id: 'a1',
                  workDate: day,
                  status: 'present',
                  employeeName: long,
                  clockIn: DateTime(2026, 3, 17, 9, 35),
                  clockOut: DateTime(2026, 3, 17, 19, 20),
                  workedMinutes: 585,
                  lateMinutes: 95,
                  otMinutes: 185,
                  isAdjusted: true,
                ),
                AttendanceRecord(
                  id: 'a2',
                  workDate: day.add(const Duration(days: 1)),
                  status: 'present',
                  employeeName: long,
                  clockIn: DateTime(2026, 3, 18, 8, 58),
                  clockOut: DateTime(2026, 3, 18, 18, 2),
                  workedMinutes: 544,
                ),
              ]),
        ],
        (context) => showAttendanceMonth(context),
      );
      expect(tester.takeException(), isNull);

      // The row builder ran, which the empty case cannot show.
      expect(find.textContaining(long), findsWidgets);
      expect(find.textContaining('corrected'), findsOneWidget);
      // `95 min late` is on the row AND in the totals, which is the
      // point of the next assertion rather than a surprise -- the first
      // version of this asked for exactly one and found two.
      expect(find.textContaining('95 min late'), findsNWidgets(2));

      // The totals line, which does not exist in the empty state at all,
      // pinned WHOLE rather than by two assertions either side of it.
      expect(find.text('2 days · 95 min late · 3.08h overtime'),
          findsOneWidget);
      expect(find.text('18.82h'), findsOneWidget);

      // And nothing overflowed at 412 wide with the longest subtitle the
      // flags can build. That totals line is an `Expanded(Text)` beside
      // an unflexed `Text`, which is the arrangement that overflowed by
      // 46 pixels in `credit_ledger_dialog.dart` -- it holds here because
      // the unflexed side is one short label and the `Expanded` takes the
      // squeeze. Asserted rather than assumed.
      expect(tester.takeException(), isNull);
    });
  });

  group('approvals', () {
    // This editor states the rule it is about to write in English, in a
    // highlighted box, built out of four moving parts -- the step, what it
    // covers, the band, and who approves. That sentence is the whole
    // safety of the screen: an approval rule is read once when it is
    // written and then silently blocks postings for ever. An empty team
    // and no assertions left it unread.
    //
    // AND READING IT FOUND A DEFECT, which is the reason this one is
    // worth more than the rest of the batch. `_sentence` picked the
    // approver with
    //
    //     team.where((m) => m.userId == _userId)
    //
    // and `_byRole` is `_userId == null`, so the moment somebody switched
    // to "A named person" with nobody chosen, `_userId` was null -- and
    // so is the `user_id` of any member who has been INVITED and not
    // accepted. The comparison matched that member. The sentence then
    // read "cannot be posted until Siti Aminah has approved" over a rule
    // that named nobody, about a person the picker two widgets above
    // deliberately refuses to offer. Fixed in `rule_editor.dart`; the
    // "nobody yet" assertion below is what holds it.
    testWidgets('the rule editor opens', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          teamProvider.overrideWith((_) async => [
                TeamMember(
                  memberId: 'm1',
                  userId: 'u1',
                  role: 'accountant',
                  status: 'active',
                  fullName: 'Nurul Huda binti Ismail',
                  email: 'nurul@example.com',
                ),
                // INVITED, so no `user_id`: a rule whose approver does
                // not exist yet is a rule nobody can satisfy, and the
                // comprehension drops them. An empty team said nothing
                // about that either way.
                TeamMember(
                  memberId: 'm2',
                  role: 'admin',
                  status: 'invited',
                  fullName: 'Siti Aminah',
                  email: 'siti@example.com',
                ),
              ]),
        ],
        (context, ref) => showApprovalRuleEditor(context, ref),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('New approval rule'), findsOneWidget);

      // The default rule, whole. PURCHASE documents, which is the
      // default `entity_kind` and is worth pinning rather than assuming
      // -- a rule editor that opened on sales would have somebody writing
      // an approval step over their own invoices by accident.
      expect(
          find.text('Step 1: every purchase document cannot be posted until '
              'Company Admin has approved. Nobody may approve a document '
              'they raised themselves.'),
          findsOneWidget);

      // A band. Nought means every one, which is why the clause is absent
      // above and present here.
      await tester.enterText(
          find.widgetWithText(TextFormField, 'From amount'), '5000');
      await tester.pump();
      expect(
          find.textContaining('every purchase document of RM5000 or more '
              'cannot be posted'),
          findsOneWidget);

      // A NAMED PERSON instead of a role, and before one is chosen the
      // sentence says "nobody yet" rather than trailing off -- which is
      // the branch that matters, because a rule saved in that state would
      // name an approver who is not there.
      await tester.tap(find.text('A named person'));
      await tester.pumpAndSettle();
      expect(find.textContaining('until nobody yet has approved'),
          findsOneWidget);

      await tester.tap(find.widgetWithText(TextFormField, 'Approved by'));
      await tester.pumpAndSettle();
      expect(find.text('Nurul Huda binti Ismail'), findsOneWidget);
      expect(find.text('Siti Aminah'), findsNothing);

      await tester.tap(find.text('Nurul Huda binti Ismail'));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('until Nurul Huda binti Ismail has approved'),
          findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });
  });

  group('pickers that can make what is missing', () {
    // The seed goes into ONE of two boxes and which one is a decision:
    // `looksLikeAccountCode` sends "6210" to Number and "Courier" to
    // Name. Opening it with a name and asserting nothing exercised
    // neither side of that, nor the cascade that follows a number typed
    // afterwards -- the kind follows the first digit, 1xxx asset through
    // 6xxx expense, and resets the subtype under it.
    testWidgets('a new account from the picker', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => createAccountFromPicker(context, typed: 'Courier'),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('New account'), findsOneWidget);
      // A name, so Name is seeded and Number is left empty for them to
      // choose. The other way round for a number, which is the sibling
      // assertion below.
      expect(
          tester
              .widget<TextFormField>(
                  find.widgetWithText(TextFormField, 'Name'))
              .controller
              ?.text,
          'Courier');
      expect(
          tester
              .widget<TextFormField>(
                  find.widgetWithText(TextFormField, 'Number'))
              .controller
              ?.text,
          '');
      // No number to guess from, so the kind falls back to expense --
      // which is the commonest reason somebody is on this dialog at all.
      expect(find.text('Expense'), findsOneWidget);
      expect(find.text('Cost Of Sales'), findsOneWidget);

      // The number is what the reports are ordered by, so it is not
      // optional however much of a hurry the picker was in.
      await tester.tap(find.text('Create and use'));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('Every account needs a number'), findsOneWidget);

      // 1xxx is an asset, and the subtype under it resets to that type's
      // first rather than keeping an expense subtype on an asset.
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Number'), '1000');
      await tester.pumpAndSettle();
      expect(find.text('Asset'), findsOneWidget);
      expect(find.text('Current Asset'), findsOneWidget);
      expect(find.text('Cost Of Sales'), findsNothing);
      expect(find.textContaining('null'), findsNothing);
    });

    // The seed going the OTHER way, which is the half the name case
    // cannot show: a number lands in Number, Name is left empty, and the
    // kind is guessed from the first digit before anything is typed.
    testWidgets('and a number typed into it seeds the other box',
        (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => createAccountFromPicker(context, typed: '4100'),
      );
      expect(tester.takeException(), isNull);

      expect(
          tester
              .widget<TextFormField>(
                  find.widgetWithText(TextFormField, 'Number'))
              .controller
              ?.text,
          '4100');
      expect(
          tester
              .widget<TextFormField>(
                  find.widgetWithText(TextFormField, 'Name'))
              .controller
              ?.text,
          '');
      expect(find.text('Revenue'), findsOneWidget);
      expect(find.text('Sales'), findsOneWidget);

      // And the name is not optional either.
      await tester.tap(find.text('Create and use'));
      await tester.pumpAndSettle();
      expect(find.text('And a name.'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // An empty `unregisteredBankAccountsProvider` makes
    // `_AlreadyOnTheChart` return `SizedBox.shrink()`, so the whole of
    // 0689 -- the fix for a report that read "BANK ACCOUNT NOT SHOWING",
    // where a bank account is two records and nothing connected the two
    // -- drew nothing and was asserted about by nothing.
    //
    // Rows in the shape `unregistered_bank_accounts` (0689) returns:
    // account_id, code, name, account_subtype, balance.
    testWidgets('a new bank account from the picker', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          unregisteredBankAccountsProvider.overrideWith((_) async => const [
                {
                  'account_id': 'a1',
                  'code': '1050',
                  'name': 'Maybank current account',
                  'account_subtype': 'bank',
                  'balance': 12450.75,
                },
                {
                  'account_id': 'a2',
                  'code': '1090',
                  'name': 'Petty cash',
                  'account_subtype': 'cash',
                  'balance': 300,
                },
              ]),
        ],
        (context) => createBankAccountFromPicker(context, typed: 'Maybank'),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('New bank account'), findsOneWidget);
      expect(find.text('Already on your chart'), findsOneWidget);
      expect(find.text('1050 — Maybank current account'), findsOneWidget);
      expect(find.text('1090 — Petty cash'), findsOneWidget);
      // The blurb while nothing is chosen: a NEW chart account will be
      // opened. Which is the thing the section above exists to talk
      // somebody out of.
      expect(find.textContaining('Not on file yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('chart-account-clear')), findsNothing);

      // Register one of them. The dialog stops offering the list, says
      // which code it is registering, and promises not to open another --
      // because whatever is already posted to that account has to stay
      // where it is.
      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('chart-account-1050')),
        matching: find.text('Register'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Already on your chart'), findsNothing);
      expect(find.textContaining('Registering 1050, which is already on '
          'your chart'), findsOneWidget);
      expect(find.textContaining('Not on file yet'), findsNothing);
      expect(
          find.byKey(const ValueKey('chart-account-clear')), findsOneWidget);
      // The seed was 'Maybank', so the name box was NOT empty and the
      // chart account's name must not overwrite it.
      expect(
          tester
              .widget<TextFormField>(
                  find.widgetWithText(TextFormField, 'Name'))
              .controller
              ?.text,
          'Maybank');

      // And backing out of it puts the list back.
      await tester.tap(find.byKey(const ValueKey('chart-account-clear')));
      await tester.pumpAndSettle();
      expect(find.text('Already on your chart'), findsOneWidget);
      expect(find.textContaining('Not on file yet'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // The noun in the heading is a three-way switch on `contactType`, and
    // the TIN's helper line is the one piece of advice on the dialog that
    // is about something else entirely -- an e-Invoice cannot be filed
    // without it, said here because at posting time it is too late to be
    // useful. Opening it and asserting nothing read neither.
    testWidgets('a new contact from the picker', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => createContactFromPicker(
            context, contactType: 'customer', typed: 'Sinar'),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('New customer'), findsOneWidget);
      expect(
          tester
              .widget<TextFormField>(
                  find.widgetWithText(TextFormField, 'Name'))
              .controller
              ?.text,
          'Sinar');
      expect(find.text('Needed before an e-Invoice can be filed for them.'),
          findsOneWidget);
      expect(
          find.textContaining('A code is drawn from the series '
              'automatically'),
          findsOneWidget);

      // A name is the one thing it cannot be saved without, and the
      // message says why rather than saying "required".
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Name'), '   ');
      await tester.tap(find.text('Create and use'));
      await tester.pumpAndSettle();
      expect(find.text('A name. It is what the invoice is addressed to.'),
          findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // The other two nouns, which one call cannot show. A prospect is not
    // a customer and a supplier is not either; the heading is what tells
    // somebody which list they are about to add a row to.
    testWidgets('and it is named for what it is being added to',
        (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => createContactFromPicker(
            context, contactType: 'supplier', typed: 'Pembekal'),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('New supplier'), findsOneWidget);
      expect(find.text('New customer'), findsNothing);
    });

    // "The warning is the point of the screen", says the library comment,
    // and the warning says one of two OPPOSITE things: the parent becomes
    // a heading and stops being postable, or -- since 0693 -- it stays
    // postable and the child is filed under it anyway. Which one depends
    // on an answer the dialog fetches before it draws, so a test that
    // never supplies one reads whichever branch the fake falls into and
    // cannot tell it from the other.
    testWidgets('a sub-account under one account', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(_AnsweringRepo(null))],
        (context) => showSubAccountDialog(
          context,
          parent: Account(
            id: 'a1',
            code: '1120',
            name: 'Travel',
            accountType: 'expense',
            accountSubtype: 'operating_expense',
          ),
          seed: 'Airfares',
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.byKey(const ValueKey('sub-account-dialog')), findsOneWidget);
      expect(find.text('Filed under 1120 Travel.'), findsOneWidget);

      // Nothing refused it, so the parent is about to stop being an
      // account anybody can post to -- which is the consequence somebody
      // needs BEFORE pressing Add.
      expect(
          find.byKey(const ValueKey('sub-account-promotion')), findsOneWidget);
      expect(find.textContaining('1120 Travel becomes a heading'),
          findsOneWidget);
      expect(find.textContaining('stays an account you can post to'),
          findsNothing);

      // The seed lands in the name; the number is left empty and its hint
      // names the parent rather than an example, because the number is
      // generated from it.
      expect(
          tester
              .widget<TextFormField>(
                  find.byKey(const ValueKey('sub-account-name')))
              .controller
              ?.text,
          'Airfares');
      expect(find.text('Left empty, the next number under 1120 is used'),
          findsOneWidget);

      // The type is not asked at all -- it is the parent's -- and the
      // subtype DEFAULTS to the parent's rather than to the first in the
      // list.
      expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                  find.byKey(const ValueKey('sub-account-subtype')))
              .initialValue,
          'operating_expense');
      expect(find.text('Operating Expense'), findsOneWidget);
      expect(find.text('Kind'), findsNothing);
      expect(find.textContaining('null'), findsNothing);
    });

    // The other branch, which is the one 0693 added: the server says the
    // parent may NOT be promoted, and that is no longer a reason the child
    // cannot exist. Both sentences had to be read off the screen, because
    // telling somebody their account is about to stop taking postings when
    // it is not is as wrong as the other way round.
    testWidgets('and one whose parent goes on posting', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(
              _AnsweringRepo('1120 Travel has posted lines.')),
        ],
        (context) => showSubAccountDialog(
          context,
          parent: Account(
            id: 'a1',
            code: '1120',
            name: 'Travel',
            accountType: 'expense',
            accountSubtype: 'operating_expense',
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      expect(
          find.textContaining('1120 Travel stays an account you can post to'),
          findsOneWidget);
      expect(find.textContaining('becomes a heading'), findsNothing);

      // And a parent that is ALREADY a heading gets no note either way,
      // because taking another child changes nothing about it -- which is
      // asserted here rather than in a third test because it is the same
      // function answering.
      expect(
          promotionNote(
            Account(
              id: 'a2',
              code: '1100',
              name: 'Expenses',
              accountType: 'expense',
              accountSubtype: 'operating_expense',
              isGroup: true,
            ),
          ),
          isNull);
      expect(find.textContaining('null'), findsNothing);
    });

    // "Getting the rate wrong is a wrong number on every document from
    // here on", says this dialog's own library comment, and the rate is
    // what the whole screen turns on: the inclusive checkbox's subtitle
    // WORKS OUT what RM 100 would be net at that rate, so somebody can
    // see which of the two numbers moves before saving. An empty
    // `exemptionReasonsProvider` also left the exemption dropdown with
    // nothing but "Not said" in it, and `exemptionBlockedBecause` -- an
    // exempt code that does not say what exempts it is an e-Invoice LHDN
    // cannot check -- unreachable.
    testWidgets('a tax code that was typed rather than picked',
        (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          taxCodesProvider.overrideWith((_) async => const <TaxCode>[]),
          exemptionReasonsProvider.overrideWith((_) async => const [
                {'code': 'E001', 'description': 'Exempt under Schedule A'},
                {'code': 'E002', 'description': 'Exempt under Schedule B'},
              ]),
        ],
        (context, ref) => pickedTaxCode(context, ref, 'SR-6'),
      );
      expect(tester.takeException(), isNull);

      // From the label upwards, NOT `find.byType(FilledButton).first` --
      // the harness's own "open" button is a `FilledButton` too and is
      // first in the tree, so `.first` read an always-enabled button and
      // this assertion passed in both directions before it was fixed.
      bool savable() => tester
              .widget<FilledButton>(find.ancestor(
                of: find.text('Add'),
                matching: find.byType(FilledButton),
              ))
              .onPressed !=
          null;

      expect(find.text('New tax code'), findsOneWidget);
      // The seed goes into the CODE box, upper-cased, because "SR8" is
      // what somebody types when they are looking for a rate.
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('tax-code-code')))
              .controller
              ?.text,
          'SR-6');
      // No name and no rate yet, so there is nothing to add.
      expect(savable(), isFalse);

      // With no rate the inclusive subtitle cannot work anything out and
      // says the general thing.
      expect(
          find.text('A price typed on a line already contains the tax, and '
              'the line shows what is left as net.'),
          findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('tax-code-name')), 'Sales tax 6%');
      await tester.enterText(find.byKey(const ValueKey('tax-code-rate')), '6');
      await tester.pump();
      expect(savable(), isTrue);

      // And with one it does the arithmetic, rounded the way
      // `app.calc_document_line` rounds it: 100 / 1.06 is 94.3396, which
      // is 94.34 and leaves 5.66.
      expect(
          find.text('A price typed on a line already contains the 6% — so '
              'RM 100 is RM 94.34 plus RM 5.66 tax.'),
          findsOneWidget);

      // A rate outside 0..100 is not a rate.
      await tester.enterText(
          find.byKey(const ValueKey('tax-code-rate')), '101');
      await tester.pump();
      expect(savable(), isFalse);
      await tester.enterText(find.byKey(const ValueKey('tax-code-rate')), '6');
      await tester.pump();
      expect(savable(), isTrue);

      // Exempt, and nothing said about why: the dropdown appears and the
      // code cannot be saved until it answers.
      expect(find.byKey(const ValueKey('tax-exemption-reason')), findsNothing);
      await tester.tap(find.text('Exempt'));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('tax-exemption-reason')), findsOneWidget);
      expect(savable(), isFalse);

      await tester.tap(find.byKey(const ValueKey('tax-exemption-reason')));
      await tester.pumpAndSettle();
      expect(find.text('E001 · Exempt under Schedule A'), findsWidgets);
      expect(find.text('E002 · Exempt under Schedule B'), findsWidgets);
      await tester.tap(find.text('E001 · Exempt under Schedule A').last);
      await tester.pumpAndSettle();
      expect(savable(), isTrue);
      expect(find.textContaining('null'), findsNothing);
    });

    // This is the dialog that stands between a misread letterhead and a
    // PERMANENT CONTACT, and its blurb says so in one of two opposite
    // ways depending on whether anything was read at all. Nothing
    // asserted either, nor the two validators, nor that the reading
    // reaches the boxes -- which is the dialog's entire purpose.
    //
    // (The "nothing was read" blurb needs a second call with a null
    // reading and is not covered here; `createSupplierFromScan` is
    // reached that way from the plain picker, where somebody is holding a
    // bill from a supplier who is not on file.)
    testWidgets('a supplier made out of what was scanned', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
        ],
        (context, ref) => createSupplierFromScan(
          context,
          ref,
          const OcrExtraction(
            supplierName: 'Sinar Supplies Sdn Bhd',
            supplierRegistrationNo: '202201001234',
            supplierTaxId: 'C12345678901',
            supplierEmail: 'accounts@sinar.example.com',
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      // The noun comes from `ScanContactKind`, which is what stopped this
      // whole file asking somebody "which supplier?" about their own
      // customer (0682).
      expect(find.text('Create this supplier'), findsOneWidget);

      // The blurb for a reading that HAPPENED, and it is doing two jobs:
      // correct it now because this is permanent, and the SSM number is
      // the field people leave until later and then never fill in.
      expect(
          find.textContaining('Correct anything wrong before it is saved'),
          findsOneWidget);
      expect(find.textContaining('Nothing was read from the document'),
          findsNothing);

      // Every field the reading supplied is in a box, which is the one
      // claim the old assertion could not make.
      String boxed(Key key) =>
          tester.widget<TextFormField>(find.byKey(key)).controller!.text;
      expect(boxed(const ValueKey('scan-supplier-name')),
          'Sinar Supplies Sdn Bhd');
      expect(boxed(const ValueKey('scan-supplier-reg')), '202201001234');
      expect(find.text('Identifies the supplier on an e-Invoice'),
          findsOneWidget);

      // The register lookup is offered right here, because a number about
      // to seed `id_value` has come off a letterhead through a reader --
      // two chances to lose a digit.
      expect(find.byKey(const ValueKey('scan-supplier-ssm')), findsOneWidget);
      expect(find.text('Entity Search'), findsOneWidget);
      // Nothing asked yet, so no "From the register" line.
      expect(find.textContaining('From the register:'), findsNothing);

      // A name is the one thing it cannot be saved without, and the
      // e-mail check is a SHAPE check that only fires on something typed.
      await tester.enterText(
          find.byKey(const ValueKey('scan-supplier-name')), '  ');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Email'), 'not-an-address');
      await tester.tap(find.byKey(const ValueKey('scan-supplier-save')));
      await tester.pumpAndSettle();

      expect(find.text('A supplier needs a name.'), findsOneWidget);
      expect(find.text('That does not look like an email address.'),
          findsOneWidget);

      // Cleared, not wrong: an empty address is a real answer, so the
      // shape check has to stop complaining.
      await tester.enterText(find.widgetWithText(TextFormField, 'Email'), '');
      await tester.tap(find.byKey(const ValueKey('scan-supplier-save')));
      await tester.pumpAndSettle();
      expect(find.text('That does not look like an email address.'),
          findsNothing);
      expect(find.text('A supplier needs a name.'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // THIS TEST OPENED NOTHING. `resolveSupplier` calls `repo.contacts`
    // before it draws, `_FakeRepo` raises, and the `catch (_)` arm returns
    // `SupplierOutcome.ask` -- so the dialog never appeared and
    // `expect(tester.takeException(), isNull)` was asserted over an empty
    // `Scaffold`. `check_dialogs_built.py` counted the opener as covered
    // the whole time, because it looks for the CALL.
    //
    // With a repository that answers, the two-stage lookup runs: a narrow
    // search on `_searchable(name)`, and -- when that finds nothing good
    // enough -- `rankedLikeName` over everything on file. The second stage
    // is the expensive mistake this screen exists to prevent: "Supplier
    // not found" next to a Create button, when the company is already
    // there under a slightly different spelling.
    testWidgets('and resolving one against what is already here',
        (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(_ContactsRepo([
            // Spelled differently enough that the substring search misses
            // it, and alike enough that `rankedLikeName` should not.
            Contact(
              id: 'c1',
              code: 'S-0001',
              name: 'Sinar Teknologi Maju Bersatu Sdn Bhd',
              contactType: 'supplier',
            ),
            // Nothing to do with it, and must not be suggested.
            Contact(
              id: 'c2',
              code: 'S-0002',
              name: 'Pembekal Alat Tulis Berhad',
              contactType: 'supplier',
            ),
          ])),
        ],
        (context, ref) => resolveSupplier(
          context,
          ref,
          const OcrExtraction(
            supplierName: 'SINAR TEKNOLOGI SDN BHD',
            supplierTaxId: 'C12345678901',
            supplierEmail: 'accounts@sinar.example.com',
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      // The heading is NOT "Supplier not found", because something very
      // like it is listed underneath -- a heading that contradicts its own
      // dialog is how somebody presses Create without reading further.
      expect(find.text('Is it one of these?'), findsOneWidget);
      expect(find.text('Supplier not found'), findsNothing);
      expect(
          find.text('This one is already on file and looks like the same '
              'company:'),
          findsOneWidget);

      // Ranked, and only the likely one. The unrelated supplier is on
      // file and is not offered.
      expect(find.byKey(const ValueKey('scan-supplier-near-c1')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('scan-supplier-near-c2')), findsNothing);

      // What the document says, as read, with the rows it has and not the
      // ones it hasn't: no SSM number, no phone, no address were supplied,
      // so those labels are absent rather than blank.
      expect(find.text('SINAR TEKNOLOGI SDN BHD'), findsOneWidget);
      expect(find.text('Tax number'), findsOneWidget);
      expect(find.text('C12345678901'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('SSM no'), findsNothing);
      expect(find.text('Phone'), findsNothing);
      expect(find.text('Address'), findsNothing);
      expect(find.textContaining('null'), findsNothing);
    });

    // And when there is genuinely nothing like it, the heading says so
    // and no suggestion box is drawn. Both sentences had to be read off
    // the screen: the whole point of the pair is that they differ.
    testWidgets('and says so plainly when nothing on file is like it',
        (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(_ContactsRepo([
            Contact(
              id: 'c2',
              code: 'S-0002',
              name: 'Pembekal Alat Tulis Berhad',
              contactType: 'supplier',
            ),
          ])),
        ],
        (context, ref) => resolveSupplier(
          context,
          ref,
          const OcrExtraction(
            supplierName: 'Kedai Besi Hong Seng',
            supplierRegistrationNo: '200201003726',
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Supplier not found'), findsOneWidget);
      expect(find.text('Is it one of these?'), findsNothing);
      expect(
          find.text('Nothing on file matches this document. It can be '
              'created from what was read:'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('scan-supplier-near-c2')), findsNothing);
      expect(find.text('SSM no'), findsOneWidget);
      expect(find.text('200201003726'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });
  });

  group('the rest of point of sale', () {
    // `posFloorPlanProvider` answered `[]`, so the sheet drew "No tables
    // yet" and the row builder never ran -- and the row builder is where
    // the one piece of arithmetic on this screen lives. The plan returns
    // ONE ROW PER BILL, so a table carrying a split bill appears twice;
    // the builder folds by `table_id` and keeps the COUNT, because two
    // bills on one table is legitimate and is said rather than prevented.
    //
    // Rows in the shape `pos_floor_plan` (0213) returns: table_id,
    // table_code, table_name, area, seats, pos_x, pos_y, shape, sale_id,
    // sale_no, covers, opened_at, minutes_seated, total_amount, line_count.
    testWidgets('assigning a table', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(_NoSuchTableRepo()),
          posFloorPlanProvider.overrideWith((_, __) async => const [
                {
                  'table_id': 't1',
                  'table_code': 'T-01',
                  'table_name': 'Table 1',
                  'area': 'Indoor',
                  'seats': 4,
                  'sale_id': 's1',
                  'sale_no': 'POS-0001',
                  'covers': 2,
                  'total_amount': 48.5,
                  'line_count': 3,
                },
                // THE SAME TABLE AGAIN, which is what a split bill looks
                // like on this plan. One row per bill, so folding is the
                // whole of the row builder.
                {
                  'table_id': 't1',
                  'table_code': 'T-01',
                  'table_name': 'Table 1',
                  'area': 'Indoor',
                  'seats': 4,
                  'sale_id': 's2',
                  'sale_no': 'POS-0002',
                  'covers': 2,
                  'total_amount': 19.0,
                  'line_count': 1,
                },
                // Nobody on it, and NO AREA -- the subtitle joins around
                // the missing clause rather than printing an empty one.
                {
                  'table_id': 't2',
                  'table_code': 'T-02',
                  'table_name': 'Table 2',
                  'area': null,
                  'seats': 6,
                  'sale_id': null,
                },
              ]),
        ],
        (context, ref) =>
            assignTable(context, ref, saleId: 's1', outletId: 'o1'),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Which table?'), findsOneWidget);
      expect(find.text('No tables yet'), findsNothing);

      // THREE rows in, TWO tables out.
      expect(find.byType(ListTile), findsNWidgets(2));
      expect(find.text('Table 1'), findsOneWidget);
      expect(find.text('Table 2'), findsOneWidget);

      // The separator here is two spaces either side of the dot, which is
      // worth pinning exactly rather than by containment -- it is what
      // makes a crowded subtitle legible on a till.
      expect(find.text('Indoor  ·  4 seats  ·  2 open'), findsOneWidget);
      expect(find.text('6 seats'), findsOneWidget);
      expect(find.textContaining('0 open'), findsNothing);
      expect(find.textContaining('null'), findsNothing);

      // A card no table answers to. The complaint goes on the SHEET,
      // because a snack bar would slide away underneath it where a
      // cashier holding a card would never see it -- and the box clears
      // and keeps focus, because the next thing that happens is another
      // scan.
      await tester.enterText(find.byType(TextField), 'T-99');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('No table here answers to "T-99".'), findsOneWidget);
      expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          '');
    });

    // The smallest dialog in the file and it still has a rule in it:
    //
    //     pop(double.tryParse(controller.text.trim()) ?? current)
    //
    // A fee typed as a word comes back as the fee that was already
    // charged, NOT as nought -- which on a till is the difference between
    // a typo and a free delivery. The old test asserted neither the seed
    // nor the fallback, and the fallback is only observable through the
    // returned Future, so the opener's answer is captured.
    testWidgets('the delivery fee dialog', (tester) async {
      double? returned;
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          orgCountryAlpha2Provider.overrideWithValue('MY'),
        ],
        (context) => showDeliveryFeeDialog(context, current: 5)
            .then((v) => returned = v),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Charge something else'), findsOneWidget);
      // Seeded through `Fmt.plain`, which is '#,##0.00' -- so a fee of 5
      // reads as 5.00 and somebody editing it is editing a money amount
      // rather than an integer.
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
          '5.00');
      expect(find.text('Less than the zone charges needs a manager'),
          findsOneWidget);

      await tester.enterText(find.byType(TextField), 'free');
      await tester.tap(find.text('Charge this'));
      await tester.pumpAndSettle();

      // The fee that was already charged, not nought.
      expect(returned, 5);
      expect(find.textContaining('null'), findsNothing);
    });

    // The widest shape mismatch of the set, across all three providers.
    //
    //   * the sale's money column is `total_amount`, not `total` -- the
    //     sheet reads `posNum(row?['total_amount'])`;
    //   * a tender type is chosen by `id` and its cash-ness comes from
    //     `kind` (`pos_tender_types` has `id, code, name, kind, …`). With
    //     no `id` the sheet's `_tenderTypeId ??= rows.first['id']` left it
    //     null, and `opens_drawer` is not a column at all;
    //   * memberships are filtered by `o['is_active'] == true` and drawn
    //     from `name`, `period` and `sessions_included`. The fixture sent
    //     `member_name` and `points`, so `is_active` was absent, the live
    //     list came out EMPTY, and the whole section drew nothing.
    testWidgets('the tender sheet, in the shapes the till reads',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          posSaleProvider.overrideWith((_, __) async => const {
                'id': 's1',
                'invoice_no': 'POS-0042',
                'total_amount': 42.0,
                'rounding': -0.02,
                'cash_due': 41.98,
              }),
          posTenderTypesProvider.overrideWith((_) async => const [
                {
                  'id': 'tt1',
                  'code': 'cash',
                  'name': 'Cash',
                  'kind': 'cash',
                },
                {
                  'id': 'tt2',
                  'code': 'card',
                  'name': 'Card (Maybank terminal)',
                  'kind': 'card',
                },
              ]),
          posMembershipsProvider.overrideWith((_) async => const [
                {
                  'id': 'm1',
                  'code': 'GOLD',
                  'name': 'Gold, twelve months',
                  'period': 'yearly',
                  'sessions_included': null,
                  'is_active': true,
                },
                // Retired, so `o['is_active'] == true` must leave it out.
                {
                  'id': 'm2',
                  'code': 'OLD',
                  'name': 'The old scheme',
                  'period': 'monthly',
                  'sessions_included': 8,
                  'is_active': false,
                },
              ]),
        ],
        (context) => showTenderSheet(context, saleId: 's1'),
      );
      expect(tester.takeException(), isNull);

      // `total_amount`, which the old fixture called `total`.
      expect(find.textContaining('42.00'), findsWidgets);
      // Both ways of paying, named -- the old fixture's single type had no
      // `id` for the sheet to select it by.
      expect(find.text('Cash'), findsWidgets);
      expect(find.text('Card (Maybank terminal)'), findsWidgets);
    });

    // `item_id` and `item_name` were the fixture's words.
    // `Repo.itemStalls()` selects `id, code, name, stall_id`, and the
    // dialog draws `'${it['code']} ${it['name']}'` -- so every row in
    // this test read "null null", under a button keyed `off-stall-null`.
    testWidgets('and which items a stall sells, in the shape it selects',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          canWriteProvider.overrideWithValue(true),
          itemStallsProvider.overrideWith((_) async => const [
                {'id': 'i1', 'code': 'NL-01', 'name': long,
                  'stall_id': 'st1'},
                // On no stall, so `itemsOnStall` must leave it out: this
                // dialog lists what THIS stall sells, and an unfiltered
                // list is the defect the filter exists to prevent.
                {'id': 'i2', 'code': 'TEH-01', 'name': 'Teh tarik',
                  'stall_id': null},
                // And one that belongs to somebody else.
                {'id': 'i3', 'code': 'MG-01', 'name': 'Mee goreng',
                  'stall_id': 'st2'},
              ]),
        ],
        (context) => showStallItems(
          context,
          stall: const {'id': 'st1', 'name': 'Nasi Lemak'},
          stalls: const [
            {'id': 'st1', 'name': 'Nasi Lemak'},
            {'id': 'st2', 'name': 'Mee Goreng Corner'},
          ],
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('What Nasi Lemak sells'), findsOneWidget);
      // `code` and `name`, which the old fixture supplied under neither
      // name.
      expect(find.text('NL-01 $long'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
      // `id`, which the remove button's key is built from.
      expect(find.byKey(const ValueKey('off-stall-i1')), findsOneWidget);
      // The other two are this stall's business only when they are on it.
      expect(find.textContaining('Teh tarik'), findsNothing);
      expect(find.textContaining('Mee goreng'), findsNothing);
      expect(find.textContaining('Nothing is this stall'), findsNothing);
    });
  });

  group('forecasting', () {
    // A NINETEENTH WRONG-SHAPE FIXTURE, and the sheet's whole content is the
    // map it is HANDED -- `forecastLinesProvider` is decoration here, which
    // is the first thing that misleads. `forecast_suggestions` (0205)
    // returns twenty-three columns and the fixture passed three, so the
    // header read "null · Widget", the state chip read `Fmt.label(null)`,
    // and all eleven figures read nought. Every row the sheet exists to
    // show was absent or zero.
    //
    // The lead-time ROW is the reason this sheet exists at all: "a buyer
    // asked to spend money on a figure a model produced is entitled to see
    // where it came from", and 'measured from deliveries' against 'the
    // company default' are worth very different amounts of trust.
    testWidgets('one forecast line', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showForecastLineSheet(
          context,
          const {
            'id': 'fl1',
            'item_id': 'i1',
            'item_code': 'ITM-0042',
            'item_name': long,
            'uom_code': 'UNIT',
            'warehouse_id': null,
            'state': 'order_now',
            'on_hand': 12,
            'reserved': 4,
            'on_order': 6,
            'available': 8,
            'mean_daily_demand': 2.5,
            'lead_time_days': 14,
            'lead_time_source': 'measured',
            'safety_stock': 18,
            'reorder_point': 53,
            'days_cover': 3.2,
            'stockout_on': '2026-10-15',
            'suggested_qty': 60,
            'already_drafted': 20,
            'outstanding': 40,
            'supplier_id': 'c1',
            'supplier_name': 'Pembekal Alat Tulis',
          },
          warehouseId: null,
          onChanged: () {},
        ),
      );
      expect(tester.takeException(), isNull);

      // The header: code AND name, with the supplier under it rather than
      // "No supplier set", and the state through `Fmt.label`.
      expect(find.text('ITM-0042 · $long'), findsOneWidget);
      expect(find.text('Pembekal Alat Tulis'), findsOneWidget);
      expect(find.text('No supplier set'), findsNothing);
      expect(find.text('Order Now'), findsOneWidget);

      // The three order figures, which are a subtraction a buyer has to be
      // able to check: 60 suggested less 20 already on a draft leaves 40.
      expect(find.text('Suggested order'), findsOneWidget);
      expect(find.text('60'), findsOneWidget);
      expect(find.text('20'), findsOneWidget);
      expect(find.text('40'), findsOneWidget);

      // And the position, where `available` is its own number rather than
      // on-hand less reserved -- the server works it out and the sheet
      // shows what the server said.
      expect(find.text('12'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);

      expect(find.text('2.50 a day'), findsOneWidget);
      expect(find.text('14.00 days (measured from deliveries)'),
          findsOneWidget);
      expect(find.text('18'), findsOneWidget);
      expect(find.text('53'), findsOneWidget);

      // Both conditional rows, which a fixture without `days_cover` or
      // `stockout_on` cannot draw at all.
      expect(find.text('Days of cover'), findsOneWidget);
      expect(find.text('3.20'), findsOneWidget);
      expect(find.text('Runs out about'), findsOneWidget);
      expect(find.text('15 Oct 2026'), findsOneWidget);

      expect(find.text('Parameters for this item'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // `forecastSettingsProvider` answered `const {}`, so every one of the
    // eight boxes and both switches fell back to its DEFAULT -- and a form
    // showing its defaults looks exactly like a form showing a company's
    // saved settings. Which is the whole point of the dialog: these are
    // numbers a reorder suggestion will later be defended with.
    //
    // Fed a real row, therefore, with every value DIFFERENT from its
    // default, so the assertions distinguish "read from the row" from
    // "fell back".
    testWidgets('the forecast settings', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          forecastSettingsProvider.overrideWith((_) async => const {
                'bucket': 'month',
                'default_method': 'exponential_smoothing',
                'history_days': 730,
                'horizon_buckets': 12,
                'default_window': 6,
                'default_alpha': 0.45,
                'service_level': 0.99,
                'default_lead_time_days': 21,
                'min_periods': 3,
                'count_transfers_out': true,
                'count_shrinkage': true,
              }),
        ],
        (context, ref) => showForecastSettings(context, ref),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Forecast settings'), findsOneWidget);

      String boxed(String label) => tester
          .widget<TextFormField>(find.widgetWithText(TextFormField, label))
          .controller!
          .text;

      // Every default this is NOT: week, moving_average, 365, 8, 4, 0.300,
      // 0.9500, 14, 4, false, false.
      //
      // `default_method` has to be one of the three the dropdown lists --
      // `DropdownButtonFormField` ASSERTS that its initial value is among
      // its items, so a fourth value raises rather than drawing blank. It
      // cannot happen from the database (`app.forecast_method` is an enum
      // of exactly those three, 0197) but it happened from this fixture,
      // which is how the assertion got found.
      expect(find.text('Months'), findsOneWidget);
      expect(find.text('Weeks'), findsNothing);
      expect(find.text('Exponential smoothing'), findsOneWidget);
      expect(find.text('Moving average'), findsNothing);
      expect(boxed('Days of history to read'), '730');
      expect(boxed('Buckets to forecast ahead'), '12');
      expect(boxed('Averaging window'), '6');
      expect(boxed('Smoothing factor'), '0.45');
      expect(boxed('Service level'), '0.99');
      expect(boxed('Lead time when it cannot be measured'), '21');
      expect(boxed('Fewest periods worth forecasting'), '3');

      final switches = tester.widgetList<SwitchListTile>(
          find.byType(SwitchListTile));
      expect(switches, hasLength(2));
      expect(switches.every((w) => w.value), isTrue,
          reason: 'both count-as-demand switches default to false, so a '
              'fixture that fed true is the only way to see them read');

      // THE BOUNDS, which nothing had ever tripped. `_int` and `_decimal`
      // each refuse two different ways, and the message names the range
      // rather than saying "invalid".
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Averaging window'), '100');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Between 2 and 52'), findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Averaging window'), 'six');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('A whole number'), findsOneWidget);

      // And the decimal one refuses in its own words, because "a whole
      // number" would be wrong advice about a smoothing factor.
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Averaging window'), '6');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Smoothing factor'), '2');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Between 0.001 and 0.999'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    // `const {}` for the parameters and `const []` for the suppliers, so
    // every box was empty, the picker had nothing in it, and the switch
    // was off -- which is the state of an item nobody has touched, and
    // indistinguishable on screen from one whose saved parameters failed
    // to load. The blurb also has two forms and only one was ever drawn:
    // "Company-wide" against "This location only", which is the whole of
    // what `warehouseId` means here.
    testWidgets('and one item’s own parameters', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          itemForecastParamsProvider.overrideWith((_, __) async => const {
                'min_quantity': 5,
                'max_quantity': 400,
                'min_order_quantity': 12,
                'order_multiple': 6,
                'lead_time_days': 21,
                'supplier_id': 'c1',
                'is_excluded': true,
              }),
          contactsProvider.overrideWith((_, __) async => [
                Contact(
                  id: 'c1',
                  code: 'S-0001',
                  name: 'Pembekal Alat Tulis',
                  contactType: 'supplier',
                ),
              ]),
        ],
        (context, ref) => showItemForecastParams(
          context,
          ref,
          itemId: 'i1',
          itemLabel: 'ITM-0042 · Widget',
          warehouseId: 'w1',
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('ITM-0042 · Widget'), findsOneWidget);
      // `warehouseId` is not null, so it is the LOCATION form of the
      // blurb. The company-wide one is the other half.
      expect(
          find.text('This location only. Leave a field empty to use the '
              'default.'),
          findsOneWidget);
      expect(find.textContaining('Company-wide'), findsNothing);

      String boxed(String label) => tester
          .widget<TextFormField>(find.widgetWithText(TextFormField, label))
          .controller!
          .text;
      expect(boxed('Minimum on the shelf'), '5');
      expect(boxed('Most to hold'), '400');
      expect(boxed('Supplier minimum order'), '12');
      expect(boxed('Order multiple'), '6');
      expect(boxed('Lead time override, in days'), '21');

      // The switch is on, which is its non-default -- and its subtitle is
      // the sentence that keeps "we forecast 12 of 400 items" answerable.
      expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);

      // The picker RESOLVES the saved supplier against the list it was
      // given -- `list.any((c) => c.id == _supplier) ? _supplier : null` --
      // so an id whose contact is not on the list shows nothing rather
      // than somebody else's row. With the contact present it shows.
      expect(find.text('Pembekal Alat Tulis'), findsOneWidget);

      // THE BOUNDS. Empty is a real answer and must not be refused; a
      // negative and an over-365 lead time must be.
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Most to hold'), '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('A number'), findsNothing);
      expect(find.text('Not negative'), findsNothing);

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Most to hold'), '-1');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Not negative'), findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Most to hold'), '400');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Lead time override, in days'),
          '400');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('At most 365'), findsOneWidget);

      // And the whole-number box refuses a decimal in its own words,
      // which the decimal boxes do not.
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Lead time override, in days'),
          '21.5');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('A whole number'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });
  });

  group('the last few', () {
    // A bare `Appraisal(id, status, employeeId)` leaves everything null, so
    // the title read 'Appraisal' rather than a person, the rating scale read
    // its default 5, and the form opened empty -- which is the one state
    // that cannot show the thing `initState` is for: the half already
    // written is the STARTING POINT, so a reopened review is edited rather
    // than retyped from nothing.
    //
    // `appraisalAction` decides everything else from four flags, and this
    // call is the subject's part on an unsubmitted self review, so it is
    // `writeSelf`: their rating, their words, and the button in the first
    // person.
    testWidgets('an appraisal under review', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showAppraisalReview(
          context,
          Appraisal(
            id: 'ap1',
            status: 'self_review',
            employeeId: 'e1',
            employeeName: 'Nurul Huda binti Ismail',
            reviewerName: 'Ahmad Faizal',
            cycleName: 'Annual review 2026',
            ratingScaleMax: 10,
            selfRating: 7,
            selfComments: 'Closed the year-end on time, twice.',
            // The manager half is filled in too, and must NOT leak into
            // the subject's boxes -- `initState` switches on the ACTION,
            // not on what happens to be present.
            managerRating: 4,
            managerComments: 'Needs to delegate more.',
            recommendedIncrement: 6,
            recommendedBonus: 1200,
            developmentPlan: 'Lead the audit file.',
            promotionRecommended: true,
          ),
          AppraisalPart.subject,
        ),
      );
      expect(tester.takeException(), isNull);

      // The person, not the word 'Appraisal'.
      expect(find.text('Nurul Huda binti Ismail'), findsOneWidget);
      expect(find.text('Appraisal'), findsNothing);

      // The scale is the CYCLE's, not a default: "a 4 out of 5 and a 4 out
      // of 10 are different judgements, and the box has to say which".
      expect(find.text('Out of 10'), findsOneWidget);
      expect(find.text('Out of 5'), findsNothing);

      String boxed(String label) => tester
          .widget<TextField>(find.widgetWithText(TextField, label))
          .controller!
          .text;

      // Seeded from the SELF half, in the first person, and the button
      // says so.
      // '7.0' and not '7': `selfRating` is a `num` and the box is seeded
      // with `toString()`. The field takes decimals, so it is consistent
      // rather than wrong -- but it is what the person sees, so it is what
      // the assertion says.
      expect(boxed('Rating *'), '7.0');
      expect(boxed('What you did, in your words *'),
          'Closed the year-end on time, twice.');
      expect(find.text('Submit my review'), findsOneWidget);

      // And the manager's half is nowhere in the form, which is the part a
      // single-flag fixture cannot show: no increment, no bonus, no plan,
      // no promotion switch on the subject's screen.
      expect(find.text('Your assessment *'), findsNothing);
      expect(find.text('Increment (%)'), findsNothing);
      expect(find.text('Bonus'), findsNothing);
      expect(find.text('Development plan'), findsNothing);
      expect(find.text('Recommend for promotion'), findsNothing);

      // The manager's words ARE on screen -- as the record of what has been
      // written, which is the three-section summary above the form -- and
      // that is right. What must not happen is their appearing in an
      // EDITABLE box on the subject's screen, which the absent 'Your
      // assessment *' label above says. Asserted both ways round because
      // the first draft of this test assumed the wrong one.
      expect(find.text('Needs to delegate more.'), findsOneWidget);
      expect(
          find.widgetWithText(TextField, 'Your assessment *'), findsNothing);

      // Not waiting, so no explanation of why there is nothing to do.
      expect(find.textContaining('This is the record of a conversation'),
          findsNothing);
      expect(find.textContaining('null'), findsNothing);
    });

    // The `whoIsAwayProvider` override this test used to carry was DEAD
    // WEIGHT, and the keys in it (`request_id`, `leave_type_name`) were
    // the wrong ones -- but it did not matter, because
    // `_EditContactDialog` takes a `LeaveRequest` and reads
    // `widget.request.contactWhileAway`. It never looks at that provider;
    // the rows with those keys belong to the who-is-away LIST in the same
    // file. A key sweep that compares a fixture against every `row['...']`
    // in a file flags that as a wrong shape, and reading it says
    // otherwise. Dropped rather than corrected.
    //
    // What the test was missing is the dialog's one job: the field opens
    // carrying the contact there already is, so somebody amending it is
    // not retyping it.
    testWidgets('changing where somebody is reachable while away',
        (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showEditLeaveContact(
          context,
          LeaveRequest(
            id: 'l1',
            requestNo: 'LV-0001',
            startDate: DateTime.utc(2026, 10, 1),
            endDate: DateTime.utc(2026, 10, 3),
            totalDays: 3,
            status: 'approved',
            contactWhileAway: '+60 12-345 6789',
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Where to reach you'), findsOneWidget);
      // The leave it is about, named, and the dates read through
      // `describeAbsence` rather than printed raw.
      expect(find.textContaining('Leave LV-0001'), findsOneWidget);
      // Prefilled, which is the whole point of the dialog.
      expect(find.text('+60 12-345 6789'), findsOneWidget);
      expect(find.text('Leave it empty to remove the contact.'),
          findsOneWidget);
    });

    // And the other side of it: nothing recorded yet, so the field is
    // empty and the helper still says how to clear one.
    testWidgets('and it opens empty when there is no contact yet',
        (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showEditLeaveContact(
          context,
          LeaveRequest(
            id: 'l2',
            requestNo: 'LV-0002',
            startDate: DateTime.utc(2026, 11, 2),
            endDate: DateTime.utc(2026, 11, 2),
            totalDays: 1,
            status: 'submitted',
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Leave LV-0002'), findsOneWidget);
      expect(find.text('+60 12-345 6789'), findsNothing);
    });

    testWidgets('billing a matter', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          timeEntriesProvider.overrideWith((_, __) async => const <TimeEntry>[]),
        ],
        (context) => showBillMatterSheet(context, matterId: 'm1'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('closing a deal', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showCloseDealDialog(
          context,
          deal: Opportunity(
            id: 'op1',
            opportunityNo: 'OPP-0001',
            name: 'Sinar renewal',
            stageId: 'st1',
            pipelineId: 'p1',
          ),
          stageType: 'won',
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('logging a chase on a debt', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          collectionHistoryProvider.overrideWith((_, __) async => const [
                {
                  'id': 'h1',
                  // `attempted_on` and `notes`, which is what
                  // `collectionHistory` selects. The first version of
                  // this said `attempted_at`/`note` and the sheet threw
                  // `Null is not a subtype of String` on the cast — a
                  // test that fed a dialog a shape the database never
                  // sends.
                  'attempted_on': '2026-09-01',
                  'outcome': 'promised',
                  'notes': long,
                },
              ]),
        ],
        (context, ref) => showLogAttemptSheet(
          context,
          ref,
          contactId: 'c1',
          contactName: 'Sinar Teknologi',
          outstanding: 1200,
        ),
      );
      expect(tester.takeException(), isNull);
    });

    // The "Read it" button runs a REAL parser -- `MiaResultParser.parse` is
    // pure, so no fake is needed -- and it has two outcomes that say
    // opposite things. Neither was asserted, nor that a parsed row reaches
    // the boxes, nor the save rule, which is the whole point of the
    // screen: the number is the credential, and a row with a name and no
    // number would put a green "checked on" stamp beside nothing anybody
    // can look up again.
    //
    // `kinds: [MiaKind.member]` here, so the Member/Firm segmented button
    // is NOT drawn -- `if (widget.kinds.length > 1)` -- which is itself
    // worth asserting: an employee cannot be a firm.
    testWidgets('verifying somebody against the MIA register',
        (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showMiaVerifyDialog(
          context,
          subjectType: 'employee',
          subjectId: 'e1',
          subjectName: 'Aisyah Rahman',
          kinds: const [MiaKind.member],
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Check Aisyah Rahman on MIA'), findsOneWidget);
      expect(find.byKey(const ValueKey('mia-open-register')), findsOneWidget);
      // One kind offered, so no choice is drawn.
      expect(find.byKey(const ValueKey('mia-kind')), findsNothing);
      // Nothing read yet, so no note either way.
      expect(find.byKey(const ValueKey('mia-parse-note')), findsNothing);

      String boxed(String key) => tester
          .widget<TextField>(find.byKey(ValueKey('mia-field-$key')))
          .controller!
          .text;

      // RUBBISH FIRST, because a parser that refuses is the branch
      // somebody works around by typing a number into the wrong box, and
      // the note has to say what to do instead.
      await tester.enterText(
          find.byKey(const ValueKey('mia-paste')), 'who even knows');
      await tester.tap(find.byKey(const ValueKey('mia-read')));
      await tester.pumpAndSettle();

      expect(
          find.text('That does not look like a row from the register. Copy '
              'the whole row, or fill the boxes in by hand.'),
          findsOneWidget);
      expect(boxed('member_no'), '');

      // A real row, tab separated, which is what copying out of MIA's
      // server-rendered table actually gives.
      await tester.enterText(
        find.byKey(const ValueKey('mia-paste')),
        '12345\tAisyah binti Rahman\tca\tSelangor\tYes',
      );
      await tester.tap(find.byKey(const ValueKey('mia-read')));
      await tester.pumpAndSettle();

      expect(find.text('Read as a member. Check it, then save.'),
          findsOneWidget);
      expect(boxed('member_no'), '12345');
      expect(boxed('member_name'), 'Aisyah binti Rahman');
      // Upper-cased by the parser, because the register is inconsistent
      // about it and the column is not.
      expect(boxed('member_type'), 'CA');
      expect(boxed('state'), 'Selangor');
      expect(
          tester
              .widget<DropdownButtonFormField<bool?>>(
                  find.byKey(const ValueKey('mia-pc-holder')))
              .initialValue,
          isTrue);
      expect(find.textContaining('null'), findsNothing);

      // THE SAVE RULE. Clear the number and the dialog refuses in words
      // that say why rather than "required".
      await tester.enterText(
          find.byKey(const ValueKey('mia-field-member_no')), '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
          find.text('A member number is what the register is searched by. '
              'Fill it in.'),
          findsOneWidget);
    });

    // One unread row with no `severity` and no `kind`, so the tile drew its
    // fallback colour and fallback icon and nothing said which. The row
    // also branches on `read_at` (the title's WEIGHT, which no text finder
    // can see) and on whether there is a body at all.
    //
    // And `myNotificationsProvider` is a FAMILY on `includeRead`, which is
    // the point of the "Show read" button: flipping it must change which
    // provider is watched, not merely the label. Overridden per argument
    // so the two lists differ and the flip is observable.
    testWidgets('the notifications sheet', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          myNotificationsProvider.overrideWith((_, includeRead) async =>
              includeRead
                  ? const [
                      {
                        'id': 'n9',
                        'kind': 'fs_lodgement_due',
                        'severity': 'warning',
                        'title': 'Accounts lodged',
                        'body': 'MBRS accepted them.',
                        'created_at': '2026-08-01T02:00:00Z',
                        'read_at': '2026-08-02T02:00:00Z',
                      },
                    ]
                  : const [
                      {
                        'id': 'n1',
                        'kind': 'einvoice_rejected',
                        'severity': 'urgent',
                        'title': 'An e-Invoice was rejected',
                        'body': long,
                        'created_at': '2026-09-01T02:00:00Z',
                        'read_at': null,
                      },
                      // No body and no timestamp: both subtitle lines are
                      // conditional, and a fixture that always supplies
                      // them cannot tell whether they are.
                      {
                        'id': 'n2',
                        'kind': 'ticket_overdue',
                        'severity': 'info',
                        'title': 'A ticket is overdue',
                        'read_at': null,
                      },
                    ]),
          unreadNotificationsProvider.overrideWith((_) async => 2),
        ],
        (context, ref) => showNotificationsSheet(context, ref),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Waiting for you'), findsOneWidget);
      expect(find.text('Nothing is waiting for you.'), findsNothing);

      // Unread only to start with, so the read one is not here.
      expect(find.text('An e-Invoice was rejected'), findsOneWidget);
      expect(find.text('A ticket is overdue'), findsOneWidget);
      expect(find.text('Accounts lodged'), findsNothing);

      // The body and the timestamp, and their absence on the second row.
      // The expected time goes through `Fmt.dateTime` rather than being
      // written out, because that function formats `value.toLocal()` --
      // a hard-coded '10:00' passes only where the machine running the
      // test is on +08. The claim here is that the row is DRAWN for the
      // entry that has a `created_at` and not for the one that does not;
      // how it is formatted is `Fmt`'s own business.
      expect(find.text(long), findsOneWidget);
      expect(find.text(Fmt.dateTime(DateTime.parse('2026-09-01T02:00:00Z'))),
          findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(2));

      // An icon PER KIND, which is the whole of what the leading column
      // says and is invisible to a text finder.
      expect(find.byIcon(Icons.gpp_bad_outlined), findsOneWidget);
      expect(find.byIcon(Icons.timer_off_outlined), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsNothing);

      // Unread is BOLD. A read row looks identical to `findsOneWidget`.
      expect(
          tester
              .widget<Text>(find.text('An e-Invoice was rejected'))
              .style
              ?.fontWeight,
          FontWeight.w600);

      // The flip. The label changes AND the list does, because the
      // provider is keyed on the flag.
      expect(find.text('Show read'), findsOneWidget);
      await tester.tap(find.text('Show read'));
      await tester.pumpAndSettle();

      expect(find.text('Unread only'), findsOneWidget);
      expect(find.text('Accounts lodged'), findsOneWidget);
      expect(find.text('An e-Invoice was rejected'), findsNothing);
      expect(find.byType(ListTile), findsNWidgets(1));

      // And the read row is NOT bold, which is the other half of the
      // weight branch.
      expect(
          tester.widget<Text>(find.text('Accounts lodged')).style?.fontWeight,
          FontWeight.w400);
      expect(find.textContaining('null'), findsNothing);
    });

    // Two things were wrong here and the second is the bigger one.
    //
    // The link fixture said `token` and carried neither `open_count` nor
    // `reply_count` nor `sent_to_email`, so `describeTicketLink` fell to
    // its "Not opened yet" arm and the row had no subtitle.
    //
    // And the TICKET had no `requester_contact_id`, which is what
    // `shareBlockedBecause` reads first -- so the dialog this test opened
    // was in its REFUSING state the whole time, explaining that a staff
    // ticket is not shared. It exercised the branch it was not about, and
    // asserted nothing either way.
    testWidgets('sharing a ticket that can be shared', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          ticketShareLinksProvider.overrideWith((_, __) async => const [
                {
                  'id': 'tsl1',
                  'token_hash': 'abcdef0123456789abcdef0123456789',
                  'expires_at': '2026-12-31T00:00:00Z',
                  'sent_to_email': 'pelanggan@sinar.com.my',
                  'open_count': 4,
                  'reply_count': 2,
                  'revoked_at': null,
                },
              ]),
        ],
        (context) => showTicketShareDialog(context, const {
          'id': 't1',
          'ticket_no': 'TK-0001',
          'status': 'open',
          // The one thing that makes a link worth offering: a requester
          // with no login of their own.
          'requester_contact_id': 'c1',
        }),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Share TK-0001'), findsOneWidget);
      // Not the refusal, which is where the old fixture left it.
      expect(find.textContaining('raised by a member of staff'),
          findsNothing);

      // `open_count` and `reply_count`, neither of which the old fixture
      // supplied -- so the row said "Not opened yet".
      expect(find.textContaining('opened 4 times · 2 replies'),
          findsOneWidget);
      expect(find.textContaining('Not opened yet'), findsNothing);
      // `sent_to_email`, which decides whether there is a subtitle at all.
      expect(find.text('pelanggan@sinar.com.my'), findsOneWidget);
    });

    // And the branch the old test was accidentally in, on purpose this
    // time. Worth pinning: the sentence is the whole reason the button
    // explains itself instead of failing at the server.
    testWidgets('and one raised by staff says why it is not shared',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          ticketShareLinksProvider
              .overrideWith((_, __) async => const <Map<String, dynamic>>[]),
        ],
        (context) => showTicketShareDialog(context, const {
          'id': 't2',
          'ticket_no': 'TK-0002',
          'status': 'open',
          'requester_contact_id': null,
        }),
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('A link is for a requester with no login'),
          findsOneWidget);
    });

    testWidgets('one time entry', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          currentUserProvider.overrideWithValue(null),
          mattersProvider.overrideWith((_, __) async => const <Matter>[]),
          projectsProvider.overrideWith((_) async => const []),
          teamProvider.overrideWith((_) async => const <TeamMember>[]),
        ],
        (context) => showTimeEntrySheet(context),
      );
      expect(tester.takeException(), isNull);
    });

    // `address` was the fixture's word. `my_mailboxes` (0560) returns
    // `setof public.org_mailboxes`, which has no such column -- it has
    // `local_part`, and `mailboxAddress` builds the address from it:
    //
    //     '${mailbox['local_part']}@$domain'
    //
    // So this test drew `From null@iakauntan.com` and asserted that
    // nothing threw. `is_personal` was absent too, which is what
    // `mailboxKind` reads to say "Yours" rather than "Shared with the
    // company" -- the one distinction the picker exists to carry.
    testWidgets('composing a mail, from the one address there is',
        (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          orgIdProvider.overrideWithValue('o1'),
          myMailboxesProvider.overrideWith((_) async => const [
                {'id': 'mb1', 'local_part': 'hello', 'is_personal': true},
              ]),
          mailDomainProvider.overrideWith((_) async => 'iakauntan.com'),
        ],
        (context, ref) => showCompose(context, ref),
      );
      expect(tester.takeException(), isNull);
      // One address, so it is stated rather than offered.
      expect(find.text('From hello@iakauntan.com'), findsOneWidget);
      expect(find.textContaining('null@'), findsNothing);
    });

    // Two, which is the branch a single mailbox cannot reach: the picker,
    // with `mailboxKind` saying which of them colleagues can read.
    testWidgets('and from a choice of two, saying which is shared',
        (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          orgIdProvider.overrideWithValue('o1'),
          myMailboxesProvider.overrideWith((_) async => const [
                {'id': 'mb1', 'local_part': 'aminah', 'is_personal': true},
                {'id': 'mb2', 'local_part': 'accounts', 'is_personal': false},
              ]),
          mailDomainProvider.overrideWith((_) async => 'iakauntan.com'),
        ],
        (context, ref) => showCompose(context, ref),
      );
      expect(tester.takeException(), isNull);

      // Two addresses, so the picker is offered rather than the single
      // address stated. A widget test cannot read a `SearchablePicker`'s
      // displayed value, so it is opened -- which is where the labels and
      // the sublabels live, and `mailboxKind` is the sublabel.
      expect(find.byType(SearchablePicker<String>), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(SearchablePicker<String>),
        matching: find.byType(TextFormField),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('aminah@iakauntan.com'), findsWidgets);
      expect(find.textContaining('accounts@iakauntan.com'), findsWidgets);
      // The distinction the picker exists to carry, and the one the old
      // fixture could not draw at all: `is_personal`.
      expect(find.text('Yours'), findsOneWidget);
      expect(find.text('Shared with the company'), findsOneWidget);
      expect(find.textContaining('null@'), findsNothing);
    });

    testWidgets('and the figures a tax computation is built on',
        (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          taxComputationRowProvider.overrideWith((_, __) async => const {
                'id': 'tc1',
                'year_of_assessment': 2026,
                'status': 'draft',
              }),
        ],
        (context) => showTaxInputs(context, 'tc1'),
      );
      expect(tester.takeException(), isNull);
    });
  });
}

class _FakeRepo implements Repo {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'a dialog called Repo.${invocation.memberName} while building, '
        'which this fake does not answer',
      );
}

/// A fake whose `contacts` ANSWERS, because `resolveSupplier` asks it
/// before it draws anything and a throw there is an early return.
///
/// Under `_FakeRepo` the call raises, `resolveSupplier` catches it and
/// returns `SupplierOutcome.ask` without opening a dialog at all -- so a
/// test of that function under the throwing fake asserts
/// `takeException(), isNull` over an empty screen, and
/// `check_dialogs_built.py` counts the opener as covered.
///
/// The substring filter mirrors what the real query does -- the database
/// search is `or(name.ilike.%q%, ...)` -- so `_bestMatches` and
/// `rankedLikeName` see the same two-stage shape they see in production:
/// a narrow search first, then everything on file.
class _ContactsRepo extends _FakeRepo {
  _ContactsRepo(this.all);

  final List<Contact> all;

  @override
  Future<List<Contact>> contacts({String? type, String? search}) async {
    final q = (search ?? '').trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((c) => c.name.toLowerCase().contains(q)).toList();
  }
}

/// A fake that answers `pos_table_by_code` with NOTHING FOUND.
///
/// `AssignTableSheet._scan` awaits `posTableByCode` inside a `try/finally`
/// with no `catch`, so under `_FakeRepo` the raise propagates out of the
/// test instead of reaching the branch worth testing: a card scanned that
/// no table answers to, which puts the complaint ON THE SHEET rather than
/// in a snack bar that would slide away underneath it.
///
/// `callRpc` and not `posTableByCode`, and that is not a style choice:
/// `posTableByCode` lives on the `RepoPos` extension, so an `@override` of
/// it on a subclass of `Repo` is a NEW METHOD that nothing calls -- the
/// extension's own body runs and reaches `callRpc` underneath. Overriding
/// one step lower means the real `posTableByCode` runs, including its
/// `rows.isEmpty ? null : rows.first`, which is the line the branch turns
/// on.
class _NoSuchTableRepo extends _FakeRepo {
  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async {
    if (fn == 'pos_table_by_code') return const <Map<String, dynamic>>[];
    return super.noSuchMethod(
      Invocation.method(Symbol(fn), [params]),
    );
  }
}

/// The one fake that ANSWERS, for the one dialog that asks the server a
/// question before it draws anything.
///
/// `SubAccountDialog` calls `subAccountRefusal` from `initState` and
/// shows a spinner until it comes back, and `promotionNote` then says one
/// of two opposite things depending on the answer. Under `_FakeRepo` the
/// call throws, which the dialog treats as "no refusal" -- so the
/// refusing branch is unreachable without this.
class _AnsweringRepo extends _FakeRepo {
  _AnsweringRepo(this.refusal);

  final String? refusal;

  @override
  Future<String?> subAccountRefusal(String accountId) async => refusal;
}
