import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';

void main() {
  testWidgets('a refusal with no provider scope above it is still shown', (
    tester,
  ) async {
    // `runWithFeedback` is where every screen in this app shows its
    // errors. Reading the repository out of the scope to report the
    // refusal must never turn "the server said no" into a crash.
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) {
            ctx = context;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    final ok = await runWithFeedback(
      ctx,
      doing: 'Post a journal',
      successMessage: null,
      action: () async =>
          throw Exception('not permitted to write for this organization'),
    );
    await tester.pump();

    expect(ok, isFalse);
    expect(find.textContaining('not permitted'), findsOneWidget);
  });
}
