import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/admin/platform_console_screen.dart';

/// The console's ten sections, reachable from a phone.
///
/// They used to be a scrolling `TabBar`. On a 412-pixel screen that
/// showed "Overview", "Organizations" and most of "Scanning credit" —
/// and gave no sign at all that seven more existed behind the right
/// edge. Nobody reported it as missing features, which is the worst
/// kind of navigation bug: the sections were there, reachable by a
/// drag nothing suggested.
void main() {
  const phone = Size(412, 830);
  const laptop = Size(1280, 900);

  /// Every section the menu can open, in the order it offers them.
  const labels = [
    'Overview',
    'Organizations',
    'Scanning credit',
    'Readers',
    'Service settings',
    'Statutory rates',
    'Landing page',
    'Branding',
    'Modules & pricing',
    'Payment gateways',
  ];

  Future<void> pump(
    WidgetTester tester, {
    Size size = phone,
    bool admin = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isPlatformAdminProvider.overrideWith((ref) async => admin),
          // Section 0 draws on open, so it needs an answer or the
          // screen is a spinner and nothing below is reachable.
          platformStatsProvider.overrideWith((ref) async => const {}),
          // And section 1, which is what the tap opens.
          platformOrgsProvider.overrideWith((ref) async => const []),
          platformModulesProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PlatformConsoleScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The menu itself, rather than anything else on the screen that
  /// happens to use the same word — the platform health grid has a
  /// card labelled "Organizations" too.
  Finder inMenu(String label) => find.descendant(
        of: find.byKey(const Key('console-menu')),
        matching: find.text(label),
      );

  testWidgets('a laptop sees every section without opening anything',
      (tester) async {
    await pump(tester, size: laptop);

    for (final label in labels) {
      expect(inMenu(label), findsOneWidget, reason: '$label is in the menu');
    }
    // Beside the section, not over it: the menu and the body share the
    // width rather than one covering the other.
    expect(find.byType(Drawer), findsNothing);

    // And the section fills the height it is given. A `Row` hands its
    // children loose vertical constraints, which left the whole of
    // "Platform health" hanging in the middle of a 900-pixel window
    // with nothing above or below it.
    final phone = tester.getRect(find.text('Platform health'));
    expect(phone.top, lessThan(200),
        reason: 'the section starts under the app bar, not halfway down');
  });

  testWidgets('the menu changes shape where the account menu does',
      (tester) async {
    // Between the two breakpoints the app's own rail is a column of
    // icons, and the console's is too — one menu behaving one way, not
    // two menus side by side behaving differently.
    await pump(tester, size: const Size(1000, 900));
    final menu = find.byKey(const Key('console-menu'));
    expect(menu, findsOneWidget, reason: 'beside the section, not hidden');
    expect(tester.getSize(menu).width, 80,
        reason: "the shell's collapsed rail width");
    expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isFalse, reason: 'icons, with no room for the words');

    // Wide enough and the names are spelled out.
    await pump(tester, size: laptop);
    expect(tester.getSize(find.byKey(const Key('console-menu'))).width, 256,
        reason: "the shell's extended rail width");
    expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isTrue);
  });

  testWidgets('a phone reaches all ten from the menu button', (tester) async {
    await pump(tester);

    // Closed, the menu says nothing but where you are.
    expect(find.byKey(const Key('console-menu')), findsNothing);
    expect(find.text('Overview'), findsOneWidget,
        reason: 'the app bar names the open section');
    expect(find.text('Payment gateways'), findsNothing);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();

    for (final label in labels) {
      expect(inMenu(label), findsOneWidget, reason: '$label is reachable');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the last section is on screen, not past the right edge',
      (tester) async {
    // The failure the tab strip had: built, laid out, and off the side
    // of the screen with nothing to say so.
    await pump(tester);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();

    final box = tester.getRect(inMenu('Payment gateways'));
    expect(box.right, lessThanOrEqualTo(phone.width));
    expect(box.bottom, lessThanOrEqualTo(phone.height));
  });

  testWidgets('choosing a section closes the menu and opens it',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();

    await tester.tap(inMenu('Organizations'));
    await tester.pumpAndSettle();

    expect(find.byType(Drawer), findsNothing, reason: 'the menu got out');
    // The empty state of the organizations section, which is only built
    // once that section is the one showing.
    expect(find.text('No organizations yet'), findsOneWidget);
    // And the app bar has moved with it.
    expect(find.text('Organizations'), findsOneWidget);
    expect(find.text('Platform console'), findsOneWidget);
  });

  testWidgets('a section keeps its place once opened', (tester) async {
    await pump(tester, size: laptop);

    await tester.tap(inMenu('Organizations'));
    await tester.pumpAndSettle();
    expect(find.text('No organizations yet'), findsOneWidget);

    await tester.tap(inMenu('Overview'));
    await tester.pumpAndSettle();
    // Still in the tree behind the one on top, so a half-typed form in
    // a section survives a look at another one.
    expect(find.text('No organizations yet', skipOffstage: false),
        findsOneWidget);
  });

  testWidgets('somebody who is not platform staff gets no menu',
      (tester) async {
    await pump(tester, size: laptop, admin: false);

    expect(find.text('Not a platform administrator'), findsOneWidget);
    expect(find.byKey(const Key('console-menu')), findsNothing);
    for (final label in labels.skip(1)) {
      expect(find.text(label), findsNothing, reason: '$label must not show');
    }
  });
}
