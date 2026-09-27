import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// The support-access banner, on every screen rather than one. `0719`.
///
/// Support access hands a platform administrator `auditor` over somebody
/// else's company, and `auditor` reads everything the owner can read. So
/// the sales list, the ledger and the payslips all look exactly as they
/// would to somebody who belongs there — nothing else on the screen says
/// whose books these are. This banner is the only thing that does, which
/// is why it is wired into the shell and not into a page.
void main() {
  Widget harness({required List<Map<String, dynamic>> open}) => ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          authStateProvider
              .overrideWith((_) => const Stream<AuthState>.empty()),
          isPlatformAdminProvider.overrideWith((_) async => true),
          organizationsProvider.overrideWith((_) async => const []),
          currentOrgProvider.overrideWith((_) async => null),
          mySupportAccessProvider.overrideWith((_) async => open),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const AppShell(
            location: '/dashboard',
            child: Scaffold(body: Text('somebody else’s books')),
          ),
        ),
      );

  void sizeTo(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('says so, and names the company, while a session is open',
      (tester) async {
    sizeTo(tester);
    await tester.pumpWidget(harness(open: [
      {
        'id': 's1',
        'org_name': 'Sinar Teknologi',
        'reason': 'Ticket 412',
        'expires_at':
            DateTime.now().add(const Duration(minutes: 20)).toIso8601String(),
      },
    ]));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Sinar Teknologi'), findsWidgets);
    expect(find.textContaining('support access'), findsOneWidget);
    // The screen underneath is still there: this is a banner above the
    // shell, not a door in front of it.
    expect(find.text('somebody else’s books'), findsOneWidget);
  });

  testWidgets('and says nothing at all when there is no session',
      (tester) async {
    sizeTo(tester);
    await tester.pumpWidget(harness(open: const []));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('support access'), findsNothing);
    expect(find.text('somebody else’s books'), findsOneWidget);
  });

  testWidgets('a lookup that failed draws no banner and breaks no shell',
      (tester) async {
    // `valueOrNull` rather than `.value`, which throws on an error state —
    // and a throw here is a thrown build of the WHOLE app, which a release
    // build paints as a blank page. The banner is not worth that.
    sizeTo(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          authStateProvider
              .overrideWith((_) => const Stream<AuthState>.empty()),
          isPlatformAdminProvider.overrideWith((_) async => true),
          organizationsProvider.overrideWith((_) async => const []),
          currentOrgProvider.overrideWith((_) async => null),
          mySupportAccessProvider.overrideWith(
            (_) async => throw Exception('the network went away'),
          ),
        ],
        child: const MaterialApp(
          home: AppShell(
            location: '/dashboard',
            child: Scaffold(body: Text('still here')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('still here'), findsOneWidget);
  });
}
