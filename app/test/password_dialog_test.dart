import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/auth/sign_in_screen.dart';

/// The password, asked in a box of its own.
///
/// Pumped here rather than through the sign-in screen, deliberately.
/// The screen does not reach quiescence with a route above it — three
/// tests that tried hung to their ten-minute timeout and took a CI job
/// with them — and the box is the thing worth pressing, so it is a
/// widget of its own that a test can put on screen by itself.
void main() {
  Widget wrap({
    required Future<String?> Function(String) onSubmit,
    String email = 'ali@sinar.test',
  }) => MaterialApp(
    home: Scaffold(
      body: PasswordDialog(
        email: email,
        label: 'Password',
        action: 'Sign in',
        onSubmit: onSubmit,
      ),
    ),
  );

  testWidgets('shows whose account it is about', (tester) async {
    await tester.pumpWidget(wrap(onSubmit: (_) async => null));

    // Typed a step ago and worth seeing again, because by now it is off
    // the screen.
    expect(find.text('ali@sinar.test'), findsOneWidget);
    expect(find.text('Sign in'), findsWidgets);
  });

  testWidgets('the password is hidden, and can be looked at', (tester) async {
    await tester.pumpWidget(wrap(onSubmit: (_) async => null));

    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);

    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isFalse,
    );
  });

  testWidgets('sends what was typed', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(wrap(onSubmit: (p) async {
      sent.add(p);
      return null;
    }));

    await tester.enterText(find.byType(TextField), 'correct horse');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(sent, ['correct horse']);
  });

  testWidgets('an empty box is not sent anywhere', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(wrap(onSubmit: (p) async {
      sent.add(p);
      return null;
    }));

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(sent, isEmpty);
    expect(find.text('Enter your password'), findsOneWidget);
  });

  testWidgets('a wrong password is corrected where it was typed',
      (tester) async {
    await tester.pumpWidget(wrap(
      onSubmit: (_) async => 'Invalid login credentials',
    ));

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    // Inside the box, with the box still open — the alternative is a
    // message behind a box that has just closed.
    expect(find.text('Invalid login credentials'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('and nothing is sent twice while one is in flight',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(wrap(onSubmit: (_) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return null;
    }));

    await tester.enterText(find.byType(TextField), 'slow');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    // A till gets pressed twice by people wearing gloves.
    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    expect(calls, 1);

    await tester.pump(const Duration(milliseconds: 300));
  });
}
