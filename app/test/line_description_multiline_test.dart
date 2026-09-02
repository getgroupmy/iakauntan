import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/line_draft.dart';
import 'package:iakauntan/src/features/documents/line_editor.dart';

/// A charge on a supplier's bill often needs more than one line to
/// describe: a part number, a period covered, a site address. The
/// description field was single-line, which meant a description carrying
/// a newline could be neither read nor typed — a scanned bill whose item
/// ran to two printed lines showed one run-on line and there was no way
/// to put the break back.
///
/// Asserted on the widget rather than trusted to the source, because
/// `maxLines` defaults to 1 and the default is invisible in a diff.
void main() {
  Future<void> pump(WidgetTester tester, LineDraft line) async {
    // Wide enough for the desktop layout; both layouts share the field.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        // The card reads the item and tax-code lists to build its
        // pickers; without these it throws before it draws anything.
        overrides: [
          repoProvider.overrideWithValue(null),
          itemsProvider.overrideWith((ref, search) async => const <Item>[]),
          taxCodesProvider.overrideWith((ref) async => const <TaxCode>[]),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LineEditorCard(
                lines: [line],
                editable: true,
                currency: 'MYR',
                onChanged: () {},
                onAdd: () {},
                onRemove: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a description can be more than one line', (tester) async {
    await pump(tester, LineDraft(description: 'Konsultansi'));

    final field = tester.widget<TextFormField>(
      find.widgetWithText(TextFormField, 'Konsultansi'),
    );
    // Reached through the built TextField, which is what actually holds
    // the value: TextFormField passes it down.
    final text = tester.widget<TextField>(
      find.descendant(
        of: find.byWidget(field),
        matching: find.byType(TextField),
      ),
    );

    expect(
      text.maxLines,
      greaterThan(1),
      reason: 'a two-line description has nowhere to go otherwise',
    );
    expect(
      text.minLines,
      1,
      reason: 'and a one-line description still costs one line of height',
    );
  });

  testWidgets('and one that already has a break shows both halves',
      (tester) async {
    await pump(
      tester,
      LineDraft(description: 'Servis penyelenggaraan\nNo. siri: MX-4471-A'),
    );

    // One field, both lines in it — not a truncation and not two lines.
    expect(
      find.text('Servis penyelenggaraan\nNo. siri: MX-4471-A'),
      findsOneWidget,
    );
  });
}
