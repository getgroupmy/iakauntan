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
      // These are the logins `app.demo_rebuild()` creates, in the order
      // the picker offers them. An entry here with no user behind it is
      // a button that fails on tap, so the list and the seed have to
      // move together — and the seed goes first. `property@` was added
      // to both in the same change that built the property tenant, and
      // `warung@` in the one that built the café the till sells from.
      //
      // This assertion has now caught the same omission twice, which is
      // the argument for pinning the whole list rather than checking
      // that each entry looks plausible: a seeded login the picker does
      // not offer is invisible, and an offered login with no seed
      // behind it is a button that fails in front of a visitor.
      expect(demoAccounts.map((a) => a.email).toList(), [
        'demo@iakauntan.com',
        'clerk@iakauntan.com',
        'auditor@iakauntan.com',
        'secretary@iakauntan.com',
        'property@iakauntan.com',
        'warung@iakauntan.com',
      ]);
    });

    test('the platform operator is not offered', () {
      // It is the one account that is not scoped to the demo company:
      // the console lists every tenant on the deployment, including any
      // real one. A visitor should not be handed that.
      expect(demoAccounts.map((a) => a.email), isNot(contains('superadmin@iakauntan.com')));
      expect(demoAccounts.map((a) => a.role), isNot(contains('Platform operator')));
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
        expect(a.email, endsWith('@iakauntan.com'), reason: a.role);
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

      expect(picked?.email, 'auditor@iakauntan.com');
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
          busyEmail: 'demo@iakauntan.com',
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

  group('the credentials are not changeable', () {
    // Enforced by a trigger on auth.users (0076) and covered by
    // supabase/tests/demo_accounts.sql — the change is a call to GoTrue
    // that never passes through this app, so nothing here could stop it.
    // What these assert is that the app does not offer a door it knows
    // is locked.
    test('the reset guard matches on address, whatever the casing', () {
      bool blocked(String typed) => demoAccounts
          .any((a) => a.email.toLowerCase() == typed.toLowerCase());

      expect(blocked('demo@iakauntan.com'), isTrue);
      expect(blocked('DEMO@IAkauntan.COM'), isTrue,
          reason: 'an address is not case sensitive, so neither is the guard');
      expect(blocked('  demo@iakauntan.com'.trim()), isTrue);
      expect(blocked('someone@example.com'), isFalse,
          reason: 'a real user must still be able to reset their password');
    });
  });
}
