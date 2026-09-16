import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
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
  }) {
    router = GoRouter(
      initialLocation: '/reports',
      routes: [
        GoRoute(path: '/reports', builder: (_, __) => const ReportsScreen()),
        GoRoute(
          path: '/reports/group',
          builder: (_, __) => const Scaffold(body: Text('group reports')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        repoProvider.overrideWithValue(null),
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
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    );
  }

  Future<void> show(
    WidgetTester tester, {
    bool inGroup = false,
    List<Account> accounts = const [],
    double width = 1400,
    String? tab,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(inGroup: inGroup, accounts: accounts));
    await tester.pumpAndSettle();
    if (tab != null) {
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
            // on top of everything else. The two dimension filters on
            // the P&L cannot be reached from here — their provider is
            // private — so that combination is NOT covered and is the
            // one to watch if this bar grows again.
            tab: 'General Ledger',
            accounts: [
              account(code: '6300', name: 'Professional fees and subscriptions'),
              account(id: 'a2', code: '4000', name: 'Sales'),
            ],
          );

          expect(find.byType(ReportsScreen), findsOneWidget);
        });
      }
    }
  });

  group('on a laptop', () {
    testWidgets('the downloads and the group button are on the bar',
        (tester) async {
      await show(tester, inGroup: true);

      expect(find.byKey(const ValueKey('open-group-reports')), findsOneWidget);
      expect(find.byTooltip('Download PDF'), findsOneWidget);
      expect(find.byTooltip('Download CSV'), findsOneWidget);
      expect(find.byKey(const ValueKey('reports-more')), findsNothing);
    });

    testWidgets('and the group button is absent for a company on its own',
        (tester) async {
      // Group reports for one company would be this company's figures
      // under a heading claiming otherwise.
      await show(tester, inGroup: false);

      expect(find.byKey(const ValueKey('open-group-reports')), findsNothing);
      expect(find.byTooltip('Download PDF'), findsOneWidget);
    });
  });

  group('on a phone', () {
    testWidgets('the downloads fold into a menu rather than vanishing',
        (tester) async {
      await show(tester, inGroup: true, width: 412);

      expect(find.byTooltip('Download PDF'), findsNothing);
      expect(find.byKey(const ValueKey('open-group-reports')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('reports-more')));
      await tester.pumpAndSettle();

      expect(find.text('Download PDF'), findsOneWidget);
      expect(find.text('Download CSV'), findsOneWidget);
      expect(find.text('Group reports'), findsOneWidget);
    });

    testWidgets('and the menu holds no group entry for a company on its own',
        (tester) async {
      // The control. Without it, "the group entry is in the menu"
      // passes against a menu that offers it to everybody — which is
      // the same defect as the button, moved.
      await show(tester, inGroup: false, width: 412);

      await tester.tap(find.byKey(const ValueKey('reports-more')));
      await tester.pumpAndSettle();

      expect(find.text('Download PDF'), findsOneWidget);
      expect(find.text('Group reports'), findsNothing);
    });

    testWidgets('the range keeps its full dates, below the tabs',
        (tester) async {
      // Not abbreviated. The year is what tells somebody which
      // financial period they are about to file.
      await show(tester, width: 412);

      final range = find.byKey(const ValueKey('reports-range'));
      final tabs = find.byType(TabBar);
      expect(range, findsOneWidget);
      expect(
        tester.getCenter(range).dy,
        lessThan(tester.getCenter(tabs).dy),
      );

      // Four digits of year, twice, on the one control.
      final label = tester
          .widget<Text>(find.descendant(of: range, matching: find.byType(Text)))
          .data!;
      expect(RegExp(r'\d{2}/\d{2}/\d{4}').allMatches(label), hasLength(2));
    });

    testWidgets('and sits on the bar, above the tabs, on a laptop',
        (tester) async {
      // The control for where it lives. Without it, "the range is above
      // the tabs" passes against a screen that always puts it there.
      await show(tester, width: 1400);

      final range = find.byKey(const ValueKey('reports-range'));
      final tabs = find.byType(TabBar);
      expect(
        tester.getCenter(range).dy,
        lessThan(tester.getCenter(tabs).dy),
      );
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
}
