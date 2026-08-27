import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/admin/branding_admin.dart';

/// Tapping a swatch under Branding.
///
/// The reason this file exists: `0343` shipped with the picker wired to
/// `findAncestorWidgetOfExactType<SchemePreview>()`, called from inside
/// `SchemePreview.build` — where that widget owns the context rather
/// than being an ancestor of it. The lookup returned null, the guard
/// returned, and tapping did nothing. Every test passed, because they
/// all tested `applyOverrides` and the payload and none of them ever
/// touched a swatch.
///
/// So these press the thing a person presses.
void main() {
  Widget wrap({
    Map<String, String> overrides = const {},
    void Function(String role, String? hex)? onOverride,
  }) => MaterialApp(
    home: Scaffold(
      body: SchemePreview(
        seed: AppTheme.seed,
        brightness: Brightness.light,
        overrides: overrides,
        onOverride: onOverride,
      ),
    ),
  );

  testWidgets('opens the picker for the role that was tapped',
      (tester) async {
    await tester.pumpWidget(wrap(onOverride: (_, __) {}));

    await tester.tap(find.text('Primary'));
    await tester.pumpAndSettle();

    // The dialog is titled with the role, so tapping Error and getting
    // Primary's box would be caught here too.
    expect(find.text('Colour'), findsOneWidget);
    expect(find.text('Use this'), findsOneWidget);
    expect(find.text('Let Material choose'), findsOneWidget);
  });

  testWidgets('and hands back the colour that was typed', (tester) async {
    final calls = <(String, String?)>[];
    await tester.pumpWidget(
      wrap(onOverride: (role, hex) => calls.add((role, hex))),
    );

    await tester.tap(find.text('Error'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '#B91C1C');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use this'));
    await tester.pumpAndSettle();

    expect(calls, [('error', '#B91C1C')]);
  });

  testWidgets('gives a role back to Material', (tester) async {
    final calls = <(String, String?)>[];
    await tester.pumpWidget(wrap(
      overrides: const {'primary': '#123456'},
      onOverride: (role, hex) => calls.add((role, hex)),
    ));

    await tester.tap(find.text('Primary'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Let Material choose'));
    await tester.pumpAndSettle();

    // Null rather than an empty string: the caller turns it into the
    // empty string the saver reads as "clear it", and the two meanings
    // should not be confused here.
    expect(calls, [('primary', null)]);
  });

  testWidgets('cancelling changes nothing', (tester) async {
    final calls = <(String, String?)>[];
    await tester.pumpWidget(
      wrap(onOverride: (role, hex) => calls.add((role, hex))),
    );

    await tester.tap(find.text('Secondary'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();

    expect(calls, isEmpty);
  });

  testWidgets('a colour that is not a colour cannot be used', (tester) async {
    await tester.pumpWidget(wrap(onOverride: (_, __) {}));

    await tester.tap(find.text('Surface'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'crimson');
    await tester.pumpAndSettle();

    final use = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Use this'),
    );
    expect(use.onPressed, isNull);
    expect(find.text('Six hex digits after a hash'), findsOneWidget);
  });

  testWidgets('and the preview is inert where nothing can be changed',
      (tester) async {
    // The landing CMS draws the same widget as a picture. Tapping it
    // there must not open a dialog somebody cannot act on.
    await tester.pumpWidget(wrap());

    await tester.tap(find.text('Primary'));
    await tester.pumpAndSettle();

    expect(find.text('Use this'), findsNothing);
  });

  testWidgets('every one of the six can be reached', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(wrap(onOverride: (role, _) => opened.add(role)));

    for (final label in const [
      'Primary', 'Container', 'Secondary', 'Surface', 'Surface tint', 'Error',
    ]) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '#123456');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this'));
      await tester.pumpAndSettle();
    }

    expect(opened, [
      'primary', 'container', 'secondary', 'surface', 'surfaceTint', 'error',
    ]);
  });
}
