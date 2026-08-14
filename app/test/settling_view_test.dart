import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';

/// The first second after signing in.
///
/// Signing in resolves in stages — session, organizations, current
/// organization, a repository bound to it — and a screen built before
/// the last of those has nothing to read. That is the ordinary cold
/// load, and it used to reach the dashboard as `Bad state: No
/// organization selected` under a red icon: an accurate description of
/// the code and a useless one of the situation.
void main() {
  Widget harness(AsyncValue<String> value, {VoidCallback? onRetry}) =>
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: AsyncView<String>(
            value: value,
            onRetry: onRetry,
            builder: (data) => Text(data),
          ),
        ),
      );

  testWidgets('a company still loading reads as a load, not a failure',
      (tester) async {
    await tester.pumpWidget(
        harness(AsyncValue.error(const OrgNotReady(), StackTrace.empty)));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Something went wrong'), findsNothing);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('it keeps waiting for ten seconds', (tester) async {
    await tester.pumpWidget(
        harness(AsyncValue.error(const OrgNotReady(), StackTrace.empty)));

    await tester.pump(const Duration(seconds: 9));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Something went wrong'), findsNothing);

    // Settled and still nothing: now it is a failure worth reporting.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('and says something a person can act on', (tester) async {
    await tester.pumpWidget(
        harness(AsyncValue.error(const OrgNotReady(), StackTrace.empty)));
    await tester.pump(const Duration(seconds: 11));

    // Not `Bad state: No organization selected`, which is what a
    // StateError's toString gives you and what was on screen before.
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('has not finished loading'), findsOneWidget);
  });

  testWidgets('the company arriving ends the wait', (tester) async {
    await tester.pumpWidget(
        harness(AsyncValue.error(const OrgNotReady(), StackTrace.empty)));
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(harness(const AsyncValue.data('Dashboard')));
    await tester.pump();

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('it nudges while it waits, and stops when the time is up',
      (tester) async {
    var retries = 0;
    await tester.pumpWidget(harness(
      AsyncValue.error(const OrgNotReady(), StackTrace.empty),
      onRetry: () => retries++,
    ));

    await tester.pump(const Duration(seconds: 4));
    expect(retries, greaterThan(0));

    await tester.pump(const Duration(seconds: 8));
    final afterDeadline = retries;
    await tester.pump(const Duration(seconds: 5));

    // Nothing kept polling behind the failure screen.
    expect(retries, afterDeadline);
  });

  testWidgets('a real failure is not held back for ten seconds',
      (tester) async {
    // The whole point of giving "not ready" its own type. A refusal or a
    // dropped connection is something the person can act on, and hiding
    // it behind a spinner would be the opposite of helpful.
    await tester.pumpWidget(harness(
      AsyncValue.error(Exception('permission denied'), StackTrace.empty),
      onRetry: () {},
    ));
    await tester.pump();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.textContaining('permission denied'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('an ordinary load still shows the spinner', (tester) async {
    await tester.pumpWidget(harness(const AsyncValue.loading()));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Something went wrong'), findsNothing);
  });
}
