import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/admin/closed_accounts_admin.dart';
import 'package:iakauntan/src/features/admin/platform_console_screen.dart';
import 'package:iakauntan/src/features/settings/settings_screen.dart';

/// Closing an account without destroying it. `0619`.
///
/// The rules live in `supabase/tests/account_closure.sql` — what is
/// hidden, what is kept, who may reopen it. What the screens have to
/// get right on their own is narrower and is what this file asserts:
///
///   * the sole owner's confirm button is DEAD until they have said
///     what should happen to the companies nobody else owns. The
///     database refuses that closure, so a live button there is a
///     button that always fails; and a button that quietly proceeds
///     without the checkbox would orphan a company's books.
///   * what the dialog hands back is what was typed and ticked, not a
///     default. `closeCompanies: false` sent after the box was ticked
///     is the same refusal with extra steps.
///   * the console row shows the identity the product no longer shows —
///     that is the whole point of the page — and offers "Reopen" only
///     on something still closed.
void main() {
  Future<CloseAccountAnswer?> pumpDialog(
    WidgetTester tester,
    List<Map<String, dynamic>> blockers,
  ) async {
    CloseAccountAnswer? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                answer = await showDialog<CloseAccountAnswer>(
                  context: context,
                  builder: (_) => CloseAccountDialog(blockers: blockers),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return answer;
  }

  group('the sole owner is asked a question, not refused', () {
    testWidgets('with nothing in the way the button is live', (tester) async {
      await pumpDialog(tester, const []);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('close-account-confirm')),
      );
      expect(button.onPressed, isNotNull);
      expect(find.byKey(const ValueKey('close-sole-owned')), findsNothing);
    });

    testWidgets('a sole owner gets the question and a dead button', (
      tester,
    ) async {
      await pumpDialog(tester, const [
        {'organization': 'Solo Sdn Bhd', 'reason': 'only owner'},
      ]);

      // Named, not summarised: somebody who owns three companies is
      // told which three.
      expect(find.textContaining('Solo Sdn Bhd'), findsOneWidget);
      expect(find.byKey(const ValueKey('close-sole-owned')), findsOneWidget);

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('close-account-confirm')),
      );
      expect(
        button.onPressed,
        isNull,
        reason: 'the database refuses this closure, so the button must not '
            'offer it',
      );
    });

    testWidgets('and ticking the box brings it to life', (tester) async {
      await pumpDialog(tester, const [
        {'organization': 'Solo Sdn Bhd', 'reason': 'only owner'},
      ]);
      await tester.tap(find.byKey(const ValueKey('close-sole-owned')));
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('close-account-confirm')),
      );
      expect(button.onPressed, isNotNull);
    });
  });

  group('what it hands back', () {
    testWidgets('is what was ticked and typed', (tester) async {
      CloseAccountAnswer? answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  answer = await showDialog<CloseAccountAnswer>(
                    context: context,
                    builder: (_) => const CloseAccountDialog(
                      blockers: [
                        {'organization': 'Solo Sdn Bhd', 'reason': 'x'},
                      ],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('close-sole-owned')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('close-account-reason')),
        '  Moving to another firm  ',
      );
      await tester.tap(find.byKey(const ValueKey('close-account-confirm')));
      await tester.pumpAndSettle();

      expect(answer, isNotNull);
      expect(answer!.closeCompanies, isTrue);
      // Trimmed, because a reason that is three spaces is not a reason
      // and the column would keep it.
      expect(answer!.reason, 'Moving to another firm');
    });

    testWidgets('an untouched reason is null, not an empty string', (
      tester,
    ) async {
      CloseAccountAnswer? answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  answer = await showDialog<CloseAccountAnswer>(
                    context: context,
                    builder: (_) => const CloseAccountDialog(blockers: []),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('close-account-confirm')));
      await tester.pumpAndSettle();

      expect(answer!.reason, isNull);
      expect(answer!.closeCompanies, isFalse);
    });

    testWidgets('and cancelling hands back nothing at all', (tester) async {
      CloseAccountAnswer? answer;
      var returned = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  answer = await showDialog<CloseAccountAnswer>(
                    context: context,
                    builder: (_) => const CloseAccountDialog(blockers: []),
                  );
                  returned = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(returned, isTrue);
      expect(answer, isNull);
    });
  });

  group('the console row', () {
    Future<void> pumpRow(
      WidgetTester tester,
      Map<String, dynamic> closure,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: ClosureRow(closure: closure)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the address the product no longer shows', (
      tester,
    ) async {
      await pumpRow(tester, {
        'id': 'c1',
        'subject_kind': 'user',
        'subject_id': 'u1',
        'label': 'Leaving Person',
        'detail': {'email': 'leaving@example.test', 'phone': '+60123456789'},
        'reason': 'Moving to another firm',
        'closed_via': 'self_service',
        'closed_at': '2026-09-01T10:00:00Z',
        'restored_at': null,
      });

      expect(find.text('Leaving Person'), findsOneWidget);
      expect(
        find.textContaining('leaving@example.test'),
        findsOneWidget,
        reason: 'a console that cannot say who a closed account was '
            'answers none of the questions it exists to answer',
      );
      expect(find.textContaining('Moving to another firm'), findsOneWidget);
      expect(
        find.textContaining('closed by the account holder'),
        findsOneWidget,
      );
    });

    testWidgets('offers to reopen one that is still closed', (tester) async {
      await pumpRow(tester, {
        'id': 'c2',
        'subject_kind': 'organization',
        'subject_id': 'o1',
        'label': 'Shut Trading',
        'detail': const <String, dynamic>{},
        'closed_via': 'console',
        'closed_at': '2026-09-01T10:00:00Z',
        'restored_at': null,
      });

      expect(find.byKey(const ValueKey('closure-restore-c2')), findsOneWidget);
      expect(find.textContaining('closed from the console'), findsOneWidget);
    });

    testWidgets('and not one already reopened', (tester) async {
      await pumpRow(tester, {
        'id': 'c3',
        'subject_kind': 'ledger_account',
        'subject_id': 'a1',
        'label': '6911 Never Used',
        'detail': const <String, dynamic>{},
        'closed_via': 'self_service',
        'closed_at': '2026-09-01T10:00:00Z',
        'restored_at': '2026-09-05T10:00:00Z',
        'restore_note': 'Asked for it back',
      });

      expect(
        find.byKey(const ValueKey('closure-restore-c3')),
        findsNothing,
        reason: 'the database refuses a second restore, so the button '
            'would always fail',
      );
      expect(find.textContaining('Asked for it back'), findsOneWidget);
    });
  });

  test('the console has a way in to it', () {
    // A page nothing routes to is a page nobody finds, and that failure
    // is silent: the widget compiles, the provider works, and the only
    // symptom is an operator who cannot answer "can you undelete my
    // account".
    expect(
      platformConsoleSections.any((s) => s.path == '/admin/closed'),
      isTrue,
    );
  });
}
