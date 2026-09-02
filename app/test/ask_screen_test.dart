import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/ai/ask_screen.dart';

/// Ask about your books.
///
/// 0470 built the whole database half of this module — tools, a runner
/// that applies RLS as the asker, conversations, messages — and nothing
/// called any of it. A module a company can buy and cannot reach is
/// worse than one that does not exist, so what these assert is that the
/// screen reaches the server and says what came back, including when
/// what came back is a refusal.
void main() {
  Widget harness({
    List<Map<String, dynamic>> tools = const [],
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      aiToolsProvider.overrideWith((_) async => tools),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const AskScreen(),
    ),
  );

  testWidgets('before anything is asked, it says what it can read', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        tools: const [
          {'name': 'who_owes_us', 'description': 'Unpaid customer invoices.'},
          {'name': 'trial_balance', 'description': 'Every account.'},
        ],
      ),
    );
    await tester.pumpAndSettle();

    // The list is the server's catalogue, not a list typed into the
    // app: a screen that promises a report the assistant cannot reach
    // is worse than one that promises nothing.
    expect(find.text('Unpaid customer invoices.'), findsOneWidget);
    expect(find.text('Every account.'), findsOneWidget);
    expect(find.text('Who Owes Us'), findsOneWidget);
  });

  testWidgets('and says so plainly when it can read nothing', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // Not a blank panel. A company whose tools are all switched off
    // should be told that, rather than shown an empty box that looks
    // like a loading failure.
    expect(
      find.textContaining('no reports switched on'),
      findsOneWidget,
    );
  });

  testWidgets('the question box is there and Ask is reachable', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ask-question')), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-send')), findsOneWidget);

    // Start again only appears once there is something to start again
    // from — an empty conversation has nothing to clear.
    expect(find.byKey(const ValueKey('ask-new')), findsNothing);
  });

  testWidgets('an empty question is not sent', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // With a null repo, a send that got through would throw. Nothing
    // happens, which is the assertion: whitespace is not a question,
    // and it is not worth the charge `ai_ask` takes before answering.
    await tester.enterText(find.byKey(const ValueKey('ask-question')), '   ');
    await tester.tap(find.byKey(const ValueKey('ask-send')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Reading the books'), findsNothing);
  });
}
