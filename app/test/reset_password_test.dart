import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/auth/reset_password_screen.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

void main() {
  group('password rules', () {
    test('a short password is refused before it reaches the server', () {
      expect(validatePassword('short12'), isNotNull);
      expect(validatePassword(''), isNotNull);
      expect(validatePassword(null), isNotNull);
    });

    test('spaces are not a password', () {
      expect(validatePassword('        '), isNotNull);
    });

    test('eight characters is enough', () {
      expect(validatePassword('correct-horse'), isNull);
      expect(validatePassword('12345678'), isNull);
    });
  });

  group('the reset screen', () {
    // The screen is deliberately reachable with no organization and no
    // repository, so it is pumped with nothing but an auth user and the
    // platform's own brand. Anything beyond that would be a bug:
    // somebody arriving here has forgotten their password, not chosen a
    // company.
    //
    // The brand is not a company. It is anon-readable, it is what the
    // operator calls the product, and this page puts it on screen twice
    // — so the page waits for it rather than drawing the name we ship
    // with and swapping it a moment later.
    Widget harness() => ProviderScope(
          overrides: [
            currentUserProvider.overrideWithValue(null),
            authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
            // Returned rather than awaited: a `FutureOr` that is
            // already a value settles on the first frame, so these
            // tests keep asserting what one `pumpWidget` draws.
            landingContentProvider.overrideWith(
              (ref) => const LandingContent(published: true),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const ResetPasswordScreen(),
          ),
        );

    testWidgets('asks for a new password and never for the old one',
        (tester) async {
      await tester.pumpWidget(harness());

      expect(find.text('Choose a new password'), findsOneWidget);
      expect(find.text('New password'), findsOneWidget);
      expect(find.text('Confirm new password'), findsOneWidget);
      // The whole point: the person here cannot supply a current
      // password, so being asked for one would strand them.
      expect(find.text('Current password'), findsNothing);
    });

    testWidgets('refuses a short password without calling the server',
        (tester) async {
      await tester.pumpWidget(harness());

      await tester.enterText(find.byType(TextFormField).first, 'abc');
      await tester.tap(find.text('Set password'));
      await tester.pump();

      expect(find.text('Use at least 8 characters'), findsOneWidget);
    });

    testWidgets('refuses two passwords that disagree', (tester) async {
      await tester.pumpWidget(harness());

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'a-long-enough-one');
      await tester.enterText(fields.at(1), 'a-different-one');
      await tester.tap(find.text('Set password'));
      await tester.pump();

      expect(find.text('The two passwords do not match'), findsOneWidget);
    });

    testWidgets('offers a way out for somebody who did not ask for the e-mail',
        (tester) async {
      await tester.pumpWidget(harness());
      expect(find.text('I did not ask for this — sign out'), findsOneWidget);
    });
  });
}
