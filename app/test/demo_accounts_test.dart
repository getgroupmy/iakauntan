import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/auth/demo_accounts.dart';

/// The demo picker signs somebody in with one tap, so the things worth
/// asserting are that it offers the accounts that actually exist, that a
/// tap reports the right one, and that it cannot start two sign-ins.
void main() {
  /// [settle] is off when a spinner is on screen: a progress indicator
  /// animates forever, so pumpAndSettle would simply time out.
  Future<void> pump(WidgetTester tester, Widget child,
      {Size size = const Size(412, 1400), bool settle = true}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  group('the account list', () {
    test('matches the seeded logins, exactly', () {
      // Checked against auth.users on the hosted project: these five
      // exist, are confirmed, and carry the demo password. An entry here
      // with no user behind it is a button that fails on tap.
      expect(demoAccounts.map((a) => a.email).toList(), [
        'demo@iakauntan.my',
        'clerk@iakauntan.my',
        'auditor@iakauntan.my',
        'secretary@iakauntan.my',
        'superadmin@iakauntan.my',
      ]);
    });

    test('every account says what it will show, not just its title', () {
      // "Auditor" alone tells somebody choosing a button nothing.
      for (final a in demoAccounts) {
        expect(a.role, isNotEmpty);
        expect(a.sees.length, greaterThan(20), reason: a.role);
      }
    });

    test('the addresses are all on the demo domain', () {
      // A stray real address here would sign a visitor into somebody's
      // books with a password printed in the bundle.
      for (final a in demoAccounts) {
        expect(a.email, endsWith('@iakauntan.my'), reason: a.role);
      }
    });
  });

  group('the picker', () {
    testWidgets('shows every account with its description', (tester) async {
      await pump(tester, DemoAccountPicker(onPick: (_) {}));
      for (final a in demoAccounts) {
        expect(find.text(a.role), findsOneWidget);
        expect(find.text(a.sees), findsOneWidget);
      }
    });

    testWidgets('a tap reports the account that was tapped', (tester) async {
      DemoAccount? picked;
      await pump(tester, DemoAccountPicker(onPick: (a) => picked = a));

      await tester.tap(find.text('Auditor'));
      await tester.pump();

      expect(picked?.email, 'auditor@iakauntan.my');
    });

    testWidgets('says the demo company is shared, before anyone changes it',
        (tester) async {
      await pump(tester, DemoAccountPicker(onPick: (_) {}));
      expect(find.textContaining('next visitor'), findsOneWidget);
    });

    testWidgets('a second tap cannot start a second sign-in', (tester) async {
      var taps = 0;
      await pump(
        tester,
        DemoAccountPicker(
          onPick: (_) => taps++,
          busyEmail: 'demo@iakauntan.my',
        ),
        settle: false,
      );

      await tester.tap(find.text('Auditor'));
      await tester.tap(find.text('Owner'));
      await tester.pump();

      expect(taps, 0, reason: 'every row is dead while one is signing in');
      // And the row that was tapped is the one that shows it.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('the form being busy disables it too', (tester) async {
      var taps = 0;
      await pump(
        tester,
        DemoAccountPicker(onPick: (_) => taps++, enabled: false),
      );
      await tester.tap(find.text('Owner'));
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('fits a phone without overflowing', (tester) async {
      await pump(tester, DemoAccountPicker(onPick: (_) {}),
          size: const Size(412, 1400));
      expect(tester.takeException(), isNull);
      for (final a in demoAccounts) {
        expect(tester.getRect(find.text(a.role)).right, lessThan(412));
      }
    });
  });
}
