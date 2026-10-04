import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
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
                ),
              ]),
        ],
        (context) => showAppraisalCycles(context),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('and who a referral brought in', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          referralHiresProvider.overrideWith((_) async => const [
                {
                  'applicant_name': long,
                  'referrer_name': long,
                  'hired_on': '2026-03-01',
                  'bonus_amount': 1500.0,
                  'status': 'paid',
                },
              ]),
        ],
        (context) => showReferralHires(context),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('point of sale', () {
    testWidgets('the modifier groups dialog opens', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          posModifierGroupsProvider.overrideWith((_) async => const [
                {'id': 'g1', 'name': long, 'min_select': 0, 'max_select': 3},
              ]),
          posModifierOptionsProvider.overrideWith((_, __) async => const [
                {'id': 'o1', 'name': long, 'price_delta': 2.5},
              ]),
        ],
        (context) => showModifierGroups(context),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the delivery day dialog opens', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          posDeliveryDayProvider.overrideWith((_, __) async => const [
                {
                  'id': 'd1',
                  'sale_no': 'POS-0001',
                  'customer_name': long,
                  'address': long,
                  'total': 42.5,
                  'status': 'pending',
                },
              ]),
          posDriverRunsProvider.overrideWith((_, __) async => const [
                {'id': 'r1', 'driver_name': long, 'stops': 4},
              ]),
        ],
        (context) => showDeliveryDay(context),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('and the queue day dialog', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          posQueueDayProvider.overrideWith((_, __) async => const [
                {
                  'id': 'q1',
                  'ticket_no': 'Q-001',
                  'customer_name': long,
                  'party_size': 4,
                  'status': 'waiting',
                },
              ]),
        ],
        (context) => showQueueDay(context),
      );
      expect(tester.takeException(), isNull);
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

    testWidgets('and the MSIC picker', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          msicCodesProvider.overrideWith((_) async => const [
                {'code': '62011', 'description': 'Computer programming'},
              ]),
        ],
        (context) => pickMsicCode(context),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('timesheets', () {
    testWidgets('the billing rate sheet opens', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          projectsProvider.overrideWith((_) async => const []),
          teamProvider.overrideWith((_) async => const []),
        ],
        (context) => showBillingRateSheet(context),
      );
      expect(tester.takeException(), isNull);
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

    testWidgets('and the project editor', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showProjectEditor(context),
      );
      expect(tester.takeException(), isNull);
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

    testWidgets('and the e-mail dialog', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) =>
            showEmailDialog(context, documentId: 'd1', docNo: 'INV-0001'),
      );
      expect(tester.takeException(), isNull);
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

    testWidgets('and the recurring template dialog', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          documentsProvider.overrideWith((_, __) async => const []),
        ],
        (context) => showRecurringTemplateDialog(context, schedule: const {
          'id': 's1',
          'doc_type': 'invoice',
          'frequency': 'monthly',
          'next_run': '2026-10-01',
          'is_active': true,
        }),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('and one settlement in detail', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          settlementProvider.overrideWith((_, __) async => const {
                'id': 'r1',
                'receipt_no': 'RCPT-0001',
                'total': 100.0,
                'allocations': <Map<String, dynamic>>[],
              }),
        ],
        (context) => showSettlementDetail(context, id: 'r1', isSales: true),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('and the receipt e-mail dialog', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showReceiptEmailDialog(
          context,
          receiptId: 'r1',
          receiptNo: 'RCPT-0001',
          buildPdf: () async => Uint8List(0),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('financials', () {
    testWidgets('one filing in detail opens', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showFilingDetails(context, filing: const {
          'id': 'f1',
          'form': 'CP204',
          'due_on': '2026-10-31',
          'status': 'due',
        }),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('reports', () {
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
          lines: const [],
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the rest of HR', () {
    testWidgets('the applicant editor opens', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          directoryProvider.overrideWith((_) async => const <Employee>[]),
          requisitionsProvider
              .overrideWith((_) async => const <JobRequisition>[]),
        ],
        (context) => showApplicantEditor(context),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('and the requisition editor', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          directoryProvider.overrideWith((_) async => const <Employee>[]),
          departmentsProvider.overrideWith((_) async => const []),
        ],
        (context) => showRequisitionEditor(context),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('and the appraisal goals dialog', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          appraisalGoalsProvider.overrideWith((_, __) async => const [
                {
                  'id': 'g1',
                  'title': long,
                  'description': long,
                  'weight': 25,
                  'status': 'open',
                },
              ]),
        ],
        (context) => showAppraisalGoals(context, 'a1', 'Aisyah'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('and the interviews dialog', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          employeesProvider.overrideWith((_, __) async => const <Employee>[]),
          interviewsProvider.overrideWith((_, __) async => const [
                {
                  'id': 'iv1',
                  'scheduled_at': '2026-10-01T02:00:00Z',
                  'stage': 'first',
                  'interviewer_name': long,
                  'notes': long,
                },
              ]),
        ],
        (context) => showInterviews(context, 'ap1', 'Aisyah'),
      );
      expect(tester.takeException(), isNull);
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

    testWidgets('and a month of attendance', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          canManageHrProvider.overrideWithValue(true),
          attendanceProvider
              .overrideWith((_, __) async => const <AttendanceRecord>[]),
        ],
        (context) => showAttendanceMonth(context),
      );
      expect(tester.takeException(), isNull);
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
    testWidgets('the rule editor opens', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          teamProvider.overrideWith((_) async => const <TeamMember>[]),
        ],
        (context, ref) => showApprovalRuleEditor(context, ref),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('pickers that can make what is missing', () {
    testWidgets('a new account from the picker', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => createAccountFromPicker(context, typed: 'Courier'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a new bank account from the picker', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          unregisteredBankAccountsProvider.overrideWith((_) async => const []),
        ],
        (context) => createBankAccountFromPicker(context, typed: 'Maybank'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a new contact from the picker', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => createContactFromPicker(
            context, contactType: 'customer', typed: 'Sinar'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a sub-account under one account', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showSubAccountDialog(
          context,
          parent: Account(
            id: 'a1',
            code: '1000',
            name: 'Cash at bank',
            accountType: 'asset',
            accountSubtype: 'cash',
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tax code that was typed rather than picked',
        (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          taxCodesProvider.overrideWith((_) async => const <TaxCode>[]),
          exemptionReasonsProvider.overrideWith((_) async => const []),
        ],
        (context, ref) => pickedTaxCode(context, ref, 'SR-6'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a supplier made out of what was scanned', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
        ],
        (context, ref) => createSupplierFromScan(
            context, ref, const OcrExtraction(supplierName: 'Sinar Supplies')),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('and resolving one against what is already here',
        (tester) async {
      await openedWithRef(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context, ref) => resolveSupplier(
            context, ref, const OcrExtraction(supplierName: 'Sinar Supplies')),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the rest of point of sale', () {
    testWidgets('assigning a table', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          posFloorPlanProvider.overrideWith((_, __) async => const []),
        ],
        (context, ref) =>
            assignTable(context, ref, saleId: 's1', outletId: 'o1'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the delivery fee dialog', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          orgCountryAlpha2Provider.overrideWithValue('MY'),
        ],
        (context) => showDeliveryFeeDialog(context, current: 5),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the tender sheet', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          posSaleProvider.overrideWith((_, __) async => const {
                'id': 's1',
                'total': 42.0,
                'paid': 0.0,
              }),
          posTenderTypesProvider.overrideWith((_) async => const [
                {'code': 'cash', 'name': long, 'opens_drawer': true},
              ]),
          posMembershipsProvider.overrideWith((_) async => const [
                {'id': 'm1', 'member_name': long, 'points': 120},
              ]),
        ],
        (context) => showTenderSheet(context, saleId: 's1'),
      );
      expect(tester.takeException(), isNull);
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
    testWidgets('one forecast line', (tester) async {
      await opened(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          forecastLinesProvider.overrideWith((_, __) async => const [
                {
                  'id': 'fl1',
                  'item_id': 'i1',
                  'item_name': long,
                  'suggested_qty': 10,
                  'on_hand': 2,
                },
              ]),
        ],
        (context) => showForecastLineSheet(
          context,
          const {'item_id': 'i1', 'item_name': 'Widget', 'suggested_qty': 10},
          warehouseId: null,
          onChanged: () {},
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the forecast settings', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          forecastSettingsProvider.overrideWith((_) async => const {}),
        ],
        (context, ref) => showForecastSettings(context, ref),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('and one item’s own parameters', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          itemForecastParamsProvider.overrideWith((_, __) async => const {}),
          contactsProvider.overrideWith((_, __) async => const <Contact>[]),
        ],
        (context, ref) => showItemForecastParams(
          context,
          ref,
          itemId: 'i1',
          itemLabel: 'Widget',
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the last few', () {
    testWidgets('an appraisal under review', (tester) async {
      await opened(
        tester,
        [repoProvider.overrideWithValue(repo)],
        (context) => showAppraisalReview(
          context,
          Appraisal(id: 'ap1', status: 'self_review', employeeId: 'e1'),
          AppraisalPart.subject,
        ),
      );
      expect(tester.takeException(), isNull);
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
    });

    testWidgets('the notifications sheet', (tester) async {
      await openedWithRef(
        tester,
        [
          repoProvider.overrideWithValue(repo),
          myNotificationsProvider.overrideWith((_, __) async => const [
                {
                  'id': 'n1',
                  'title': long,
                  'body': long,
                  'created_at': '2026-09-01T02:00:00Z',
                  'read_at': null,
                },
              ]),
          unreadNotificationsProvider.overrideWith((_) async => 0),
        ],
        (context, ref) => showNotificationsSheet(context, ref),
      );
      expect(tester.takeException(), isNull);
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
