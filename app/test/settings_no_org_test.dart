import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/settings_screen.dart';

/// Your password is yours whether or not you belong to a company.
///
/// The settings screen used to gate its whole body on an organization
/// and return "create a company to get started" when there was none —
/// with the account card, and therefore Change password and Sign out,
/// below that check. Platform staff routinely belong to no company, so
/// the person most likely to be holding a credential worth rotating was
/// the one person the screen would not let rotate it.
///
/// This asserts the affordance is on the screen with no organization at
/// all. It is a weaker claim than "the password can be changed" — the
/// dialog talks to GoTrue and this harness has none — but it is the
/// claim that failed, and it fails again the moment the card goes back
/// inside the branch.
void main() {
  Widget harness() => ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          authStateProvider
              .overrideWith((_) => const Stream<AuthState>.empty()),
          currentOrgProvider.overrideWith((_) async => null),
          organizationsProvider.overrideWith((_) async => <Organization>[]),
          isDemoAccountProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SettingsScreen(),
        ),
      );

  testWidgets('with no organization, the account card is still reachable',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // The point of the test.
    expect(find.text('Change password'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Your account'), findsOneWidget);

    // The company half is correctly absent, and says so rather than
    // rendering an empty shell of settings for a company that is not
    // there. Without this the test would still pass if somebody made
    // the screen show everything unconditionally, which is the other
    // way to get this wrong.
    expect(find.text('No organization'), findsOneWidget);

    // Close account needs a company — the blockers it lists are facts
    // about one — so it is deliberately not offered here.
    expect(find.text('Close this account'), findsNothing);
  });
}
