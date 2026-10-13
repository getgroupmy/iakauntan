import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/reports/reports_screen.dart';

/// The bar above ten reports.
///
/// `report_view_test.dart` and `group_reports_test.dart` cover what the
/// reports say. What had nothing was the bar that chooses between them,
/// and it ran off the edge: 96 pixels on a 412px phone and 36 on a
/// 600px window with the group button showing. Flutter CLIPS an
/// overflowing toolbar in a release build rather than reporting it, so
/// what a phone actually lost was the right-hand end of the date range
/// — the control that says which period every figure underneath
/// belongs to.
///
/// THE RANGE IS THE ONE THING THAT CANNOT BE FOLDED OR SHORTENED.
/// "01/09/2026 – 30/09/2026" is twenty-three characters and it labels
/// every number on the screen. So on a phone it moves BELOW the tabs,
/// where there is a full row of width, rather than being abbreviated to
/// "01/09 – 30/09" — which would drop the year from a report somebody
/// is about to file.
///
/// AND NOTHING IS DROPPED. Downloading the report on screen is the
/// reason most people open it, and the group button is the only way to
/// reach the consolidated figures. Both fold into a menu rather than
/// disappearing.
void main() {
  Account account({
    String id = 'a1',
    String code = '4000',
    String name = 'Sales',
  }) => Account(
    id: id,
    code: code,
    name: name,
    accountType: 'revenue',
    accountSubtype: 'operating_revenue',
  );

  late GoRouter router;

  Widget wrap({
    bool inGroup = false,
    List<Account> accounts = const [],
    String role = 'owner',
    Repo? repo,
  }) {
    router = GoRouter(
      initialLocation: '/reports',
      routes: [
        GoRoute(path: '/reports', builder: (_, __) => const ReportsScreen()),
        GoRoute(
          path: '/reports/group',
          builder: (_, __) => const Scaffold(body: Text('group reports')),
        ),
        GoRoute(
          path: '/reports/layout/:kind',
          builder: (_, state) =>
              Scaffold(body: Text('layout ${state.pathParameters['kind']}')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        repoProvider.overrideWithValue(repo),
        memberRoleProvider.overrideWith((ref) async => role),
        groupCompaniesProvider.overrideWith(
          (ref) async => inGroup
              ? const [
                  {'id': 'o1', 'name': 'One Sdn Bhd'},
                  {'id': 'o2', 'name': 'Two Sdn Bhd'},
                ]
              : const [],
        ),
        accountsProvider.overrideWith((ref) async => accounts),
      ],
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    );
  }

  Future<void> show(
    WidgetTester tester, {
    bool inGroup = false,
    List<Account> accounts = const [],
    double width = 1400,
    String? tab,
    String role = 'owner',
    Repo? repo,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(inGroup: inGroup, accounts: accounts, role: role, repo: repo),
    );
    await tester.pumpAndSettle();
    if (tab != null) {
      // The bar scrolls, and the last tabs are past its edge.
      await tester.ensureVisible(find.text(tab));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
    }
  }

  /// Every width one of these is opened at, on the two tabs that carry
  /// an extra control, for a company in a group and one on its own.
  ///
  /// It asserts nothing but that the screen rendered, because a
  /// `RenderFlex` overflow IS a test failure in Flutter — and in a
  /// release build it is not an error at all, which is how this
  /// shipped.
  group('nothing runs off the edge', () {
    for (final width in [
      1400.0,
      1200.0,
      1000.0,
      900.0,
      800.0,
      700.0,
      600.0,
      412.0,
      360.0,
    ]) {
      for (final inGroup in [true, false]) {
        testWidgets('${width.toInt()} wide, group=$inGroup', (tester) async {
          await show(
            tester,
            inGroup: inGroup,
            width: width,
            // The General Ledger tab, which carries the account filter
            // on top of everything else. The P&L's two dimension
            // filters are swept below, with codes for them to offer.
            tab: 'General Ledger',
            accounts: [
              account(
                code: '6300',
                name: 'Professional fees and subscriptions',
              ),
              account(id: 'a2', code: '4000', name: 'Sales'),
            ],
          );

          expect(find.byType(ReportsScreen), findsOneWidget);
        });
      }
    }
  });

  /// The P&L's bar, with everything it can carry: the group button, the
  /// downloads, both dimension filters and the range. Its filters were
  /// once thought unreachable from a test, their provider being
  /// private; it asks the repo, and a repo can answer it. They ran the
  /// bar off the edge at 1000, 900, 412 and 360.
  group('nothing runs off the edge of the P&L', () {
    for (final width in [
      1400.0,
      1200.0,
      1100.0,
      1000.0,
      900.0,
      800.0,
      412.0,
      360.0,
    ]) {
      testWidgets('${width.toInt()} wide', (tester) async {
        await show(
          tester,
          inGroup: true,
          width: width,
          repo: _RecordingRepo(
            dimensions: const [
              {'kind': 'project', 'code': 'PRJ-KLANG-WAREHOUSE'},
              {'kind': 'department', 'code': 'FINANCE-AND-ADMIN'},
            ],
          ),
        );
        // The premise: the filters are drawn.
        expect(find.text('All projects'), findsOneWidget);
        expect(find.text('All departments'), findsOneWidget);

        // And measured, not counted: under the tabs, side by side, and
        // whole inside the window -- as is the range, wherever it is.
        final tabs = tester.getRect(find.byType(TabBar));
        final project = tester.getRect(
          find.byKey(const ValueKey('reports-filter-project')),
        );
        final department = tester.getRect(
          find.byKey(const ValueKey('reports-filter-department')),
        );
        final range = tester.getRect(
          find.byKey(const ValueKey('reports-range')),
        );
        for (final r in [project, department]) {
          expect(r.top, greaterThanOrEqualTo(tabs.bottom));
          expect(r.left, greaterThanOrEqualTo(0));
          expect(r.right, lessThanOrEqualTo(width));
        }
        expect(department.left, greaterThan(project.right));
        expect(range.right, lessThanOrEqualTo(width));
        // And the range keeps its height above the tabs, on the bar or
        // under it: a bar that under-declares its height squeezes the
        // toolbar to nothing rather than reporting an overflow.
        expect(range.top, greaterThanOrEqualTo(0));
        expect(range.bottom, lessThanOrEqualTo(tabs.top));
        expect(range.height, greaterThanOrEqualTo(36));
        // Nor do they cover the report: its body starts below them.
        expect(
          tester.getRect(find.byType(TabBarView)).top,
          greaterThanOrEqualTo(department.bottom),
        );
      });
    }
  });

  group('on a laptop', () {
    // It was only in the phone's menu, which a laptop never draws: the
    // P&L and balance sheet layouts could not be reached at 900 and up.
    for (final (tab, kind) in [
      ('Profit & Loss', 'profit_loss'),
      ('Balance Sheet', 'balance_sheet'),
    ]) {
      testWidgets('the $tab layout is a button on the bar', (tester) async {
        await show(
          tester,
          role: 'accounts_clerk',
          repo: _RecordingRepo(),
          tab: tab,
        );
        expect(find.byKey(const ValueKey('reports-more')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('report-edit-layout')));
        await tester.pumpAndSettle();
        expect(find.text('layout $kind'), findsOneWidget);
      });
    }

    testWidgets('and not on a report that has no layout', (tester) async {
      await show(
        tester,
        role: 'accounts_clerk',
        repo: _RecordingRepo(),
        tab: 'Trial Balance',
      );
      expect(find.byKey(const ValueKey('report-edit-layout')), findsNothing);
    });

    testWidgets('nor for a role that does not read the ledger', (tester) async {
      await show(tester, role: 'sales', repo: _RecordingRepo());
      expect(find.byKey(const ValueKey('report-edit-layout')), findsNothing);
    });

    testWidgets('the downloads and the group button are on the bar', (
      tester,
    ) async {
      await show(tester, inGroup: true);

      expect(find.byKey(const ValueKey('open-group-reports')), findsOneWidget);
      expect(find.byTooltip('Download PDF'), findsOneWidget);
      expect(find.byTooltip('Download CSV'), findsOneWidget);
      expect(find.byKey(const ValueKey('reports-more')), findsNothing);
    });

    testWidgets('and the group button is absent for a company on its own', (
      tester,
    ) async {
      // Group reports for one company would be this company's figures
      // under a heading claiming otherwise.
      await show(tester, inGroup: false);

      expect(find.byKey(const ValueKey('open-group-reports')), findsNothing);
      expect(find.byTooltip('Download PDF'), findsOneWidget);
    });
  });

  group('on a phone', () {
    testWidgets('the downloads fold into a menu rather than vanishing', (
      tester,
    ) async {
      await show(tester, inGroup: true, width: 412);

      expect(find.byTooltip('Download PDF'), findsNothing);
      expect(find.byKey(const ValueKey('open-group-reports')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('reports-more')));
      await tester.pumpAndSettle();

      expect(find.text('Download PDF'), findsOneWidget);
      expect(find.text('Download CSV'), findsOneWidget);
      expect(find.text('Group reports'), findsOneWidget);
    });

    testWidgets('and the menu holds no group entry for a company on its own', (
      tester,
    ) async {
      // The control. Without it, "the group entry is in the menu"
      // passes against a menu that offers it to everybody — which is
      // the same defect as the button, moved.
      await show(tester, inGroup: false, width: 412);

      await tester.tap(find.byKey(const ValueKey('reports-more')));
      await tester.pumpAndSettle();

      expect(find.text('Download PDF'), findsOneWidget);
      expect(find.text('Group reports'), findsNothing);
    });

    testWidgets('the range keeps its full dates, below the tabs', (
      tester,
    ) async {
      // Not abbreviated. The year is what tells somebody which
      // financial period they are about to file.
      await show(tester, width: 412);

      final range = find.byKey(const ValueKey('reports-range'));
      final tabs = find.byType(TabBar);
      expect(range, findsOneWidget);
      expect(tester.getCenter(range).dy, lessThan(tester.getCenter(tabs).dy));

      // Four digits of year, twice, on the one control.
      final label = tester
          .widget<Text>(find.descendant(of: range, matching: find.byType(Text)))
          .data!;
      expect(RegExp(r'\d{2}/\d{2}/\d{4}').allMatches(label), hasLength(2));
    });

    testWidgets('and sits on the bar, above the tabs, on a laptop', (
      tester,
    ) async {
      // The control for where it lives. Without it, "the range is above
      // the tabs" passes against a screen that always puts it there.
      await show(tester, width: 1400);

      final range = find.byKey(const ValueKey('reports-range'));
      final tabs = find.byType(TabBar);
      expect(tester.getCenter(range).dy, lessThan(tester.getCenter(tabs).dy));
      // On the toolbar proper, which is the top 56 logical pixels.
      expect(tester.getCenter(range).dy, lessThan(56));
    });
  });

  testWidgets('the group button goes to the group reports', (tester) async {
    await show(tester, inGroup: true);

    await tester.tap(find.byKey(const ValueKey('open-group-reports')));
    await tester.pumpAndSettle();

    expect(find.text('group reports'), findsOneWidget);
  });

  /// `0855`. The database refuses the ledger's reports to a role that
  /// does not read the ledger, and the ones written in SQL refuse by
  /// answering with nothing -- which this screen would have shown as
  /// "nothing posted in this period" and downloaded as an empty PDF.
  group('a role that does not read the ledger', () {
    const ledgerTabs = [
      'Profit & Loss',
      'Balance Sheet',
      'Trial Balance',
      'General Ledger',
      'Cash Flows',
      'Changes in Equity',
      'Deferred Revenue',
    ];
    const theirTabs = ['Aged Receivables', 'Aged Payables', 'SST Summary'];
    const ledgerCalls = {
      'report_with_layout',
      'trialBalance',
      'generalLedger',
      'cashFlow',
      'changesInEquity',
      'deferredRevenue',
      'ledgerDimensions',
    };

    for (final role in ['sales', 'hr_manager']) {
      testWidgets('$role: every ledger tab says why, and none is asked for', (
        tester,
      ) async {
        final repo = _RecordingRepo();
        await show(tester, role: role, repo: repo, inGroup: true);

        for (final tab in ledgerTabs) {
          await tester.tap(find.text(tab));
          await tester.pumpAndSettle();
          expect(
            find.text('Not part of your role'),
            findsOneWidget,
            reason: tab,
          );
          expect(find.text('Nothing posted in this period'), findsNothing);
        }
        for (final tab in theirTabs) {
          await tester.tap(find.text(tab));
          await tester.pumpAndSettle();
          expect(find.text('Not part of your role'), findsNothing, reason: tab);
        }

        expect(repo.asked.intersection(ledgerCalls), isEmpty);
        // The control: the screen did ask for the reports that are
        // theirs, so an empty set above is not a screen that asks for
        // nothing.
        expect(
          repo.asked,
          containsAll([
            'agedBalances(receivable)',
            'agedBalances(payable)',
            'sstSummary',
          ]),
        );
      });
    }

    testWidgets('nor is a ledger tab downloadable or filtered', (tester) async {
      await show(
        tester,
        role: 'sales',
        repo: _RecordingRepo(),
        inGroup: true,
        tab: 'General Ledger',
        accounts: [account()],
      );

      expect(find.text('All accounts'), findsNothing);
      final pdf = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.picture_as_pdf_outlined),
      );
      expect(pdf.onPressed, isNull);
    });

    // The layout is offered only from the phone's menu, so asked there,
    // with the clerk who is offered it as the control.
    for (final (role, offered) in [
      ('sales', false),
      ('accounts_clerk', true),
    ]) {
      testWidgets('$role is ${offered ? '' : 'not '}offered the P&L layout', (
        tester,
      ) async {
        await show(tester, role: role, repo: _RecordingRepo(), width: 412);
        await tester.tap(find.byKey(const ValueKey('reports-more')));
        await tester.pumpAndSettle();
        expect(
          find.text('Edit layout'),
          offered ? findsOneWidget : findsNothing,
        );
      });
    }

    testWidgets('and the group reports are not offered', (tester) async {
      await show(tester, role: 'sales', repo: _RecordingRepo(), inGroup: true);
      expect(find.byKey(const ValueKey('open-group-reports')), findsNothing);

      await show(
        tester,
        role: 'sales',
        repo: _RecordingRepo(),
        inGroup: true,
        width: 412,
      );
      await tester.tap(find.byKey(const ValueKey('reports-more')));
      await tester.pumpAndSettle();
      expect(find.text('Group reports'), findsNothing);
    });

    testWidgets('while an accounts clerk reads them all', (tester) async {
      // The control for every assertion above, which would also hold of
      // a screen that had stopped showing the ledger to anybody.
      final repo = _RecordingRepo();
      await show(
        tester,
        role: 'accounts_clerk',
        repo: repo,
        inGroup: true,
        tab: 'General Ledger',
        accounts: [account()],
      );
      expect(find.text('Not part of your role'), findsNothing);
      expect(find.text('All accounts'), findsOneWidget);
      expect(find.byKey(const ValueKey('open-group-reports')), findsOneWidget);
      for (final tab in ledgerTabs) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(find.text('Not part of your role'), findsNothing, reason: tab);
      }
      expect(repo.asked, containsAll(ledgerCalls));
    });
  });

  /// What the download button prints is what the tab shows. The button
  /// reads its own copy of the report on screen, chosen by the tab's
  /// place; the general ledger went in at 3 without one, and from there
  /// to the SST summary every download was the next tab's report. A tab
  /// that asks the database for anything but its own report is that
  /// mistake, whichever way round it next happens.
  group('each tab asks for its own report and no other', () {
    // What the screen asks for on the tab it opens on, the P&L.
    const opening = {'report_with_layout', 'ledgerDimensions'};
    const own = {
      'Profit & Loss': 'report_with_layout',
      'Balance Sheet': 'report_with_layout',
      'Trial Balance': 'trialBalance',
      'General Ledger': 'generalLedger',
      'Aged Receivables': 'agedBalances(receivable)',
      'Aged Payables': 'agedBalances(payable)',
      'Cash Flows': 'cashFlow',
      'Changes in Equity': 'changesInEquity',
      'SST Summary': 'sstSummary',
      'Deferred Revenue': 'deferredRevenue',
    };
    for (final MapEntry(key: tab, value: call) in own.entries) {
      testWidgets(tab, (tester) async {
        final repo = _RecordingRepo();
        await show(tester, role: 'accountant', repo: repo, tab: tab);
        expect(repo.asked, contains(call));
        expect(repo.asked.difference({...opening, call}), isEmpty);
      });
    }
  });
}

/// Answers every report with no rows, and remembers which were asked.
///
/// And the ledger's dimension codes, when given some: they are what the
/// P&L's two filters are drawn from, and with none the filters are not
/// drawn at all.
class _RecordingRepo implements Repo {
  _RecordingRepo({this.dimensions = const []});

  final List<Map<String, dynamic>> dimensions;
  final asked = <String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    final member = name.substring('Symbol("'.length, name.length - 2);
    if (member == 'orgId') return 'o1';
    // What goes through `callRpc` rather than a method of its own --
    // `reportWithLayout` is one -- is remembered by the function's name.
    asked.add(switch (member) {
      'callRpc' => invocation.positionalArguments.first as String,
      // Both aged listings are one method; which one is the argument.
      'agedBalances' =>
        invocation.namedArguments[#receivable] == true
            ? 'agedBalances(receivable)'
            : 'agedBalances(payable)',
      _ => member,
    });
    if (member == 'ledgerDimensions') return Future.value(dimensions);
    return Future.value(const <Map<String, dynamic>>[]);
  }
}
