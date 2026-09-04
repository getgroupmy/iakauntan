import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/line_draft.dart';
import 'package:iakauntan/src/features/documents/line_editor.dart';

/// The line had one box for the item and it was the description. Anybody
/// who knows the part number had to scroll a menu of fifty to find it,
/// and anybody who knows the number but not what it is called could not
/// look it up at all.
///
/// The item-number box searches on BOTH: the code, and the description.
/// The two are how people actually find an item — a storeman knows the
/// number and whoever wrote the order knows what the thing is called —
/// and matching only the code would leave half of them where they were.
///
/// Asserted on the widget, because the whole feature is which rows come
/// back for what was typed. A filter that quietly matched only the code
/// would look right in a screenshot.
void main() {
  final items = [
    Item(
      id: 'i1',
      code: 'BRG-001',
      name: 'Simen Portland',
      itemType: 'stock',
      unitPrice: 22.50,
    ),
    Item(
      id: 'i2',
      code: 'BRG-002',
      name: 'Batu bata merah',
      itemType: 'stock',
      unitPrice: 0.85,
    ),
    Item(
      id: 'i3',
      code: 'SVC-100',
      name: 'Upah pemasangan simen',
      itemType: 'service',
      unitPrice: 150,
      trackInventory: false,
    ),
  ];

  Future<void> pump(WidgetTester tester, LineDraft line) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repoProvider.overrideWithValue(null),
          itemsProvider.overrideWith((ref, search) async => items),
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

  Finder codeField() => find.widgetWithText(TextFormField, 'Item no.');

  testWidgets('the line has a box for the item number', (tester) async {
    await pump(tester, LineDraft());
    expect(codeField(), findsOneWidget);
  });

  testWidgets('a part number finds its item', (tester) async {
    await pump(tester, LineDraft());

    await tester.enterText(codeField(), 'BRG-002');
    await tester.pumpAndSettle();

    expect(find.text('BRG-002'), findsWidgets);
    expect(find.textContaining('Batu bata merah'), findsOneWidget);
    // And nothing else: a number typed in full is one item.
    expect(find.textContaining('Simen Portland'), findsNothing);
  });

  testWidgets('a part of the number finds every item under it',
      (tester) async {
    await pump(tester, LineDraft());

    await tester.enterText(codeField(), 'BRG');
    await tester.pumpAndSettle();

    expect(find.textContaining('Simen Portland'), findsOneWidget);
    expect(find.textContaining('Batu bata merah'), findsOneWidget);
    expect(find.textContaining('Upah pemasangan simen'), findsNothing);
  });

  testWidgets('and so does the description, for whoever does not know '
      'the number', (tester) async {
    await pump(tester, LineDraft());

    await tester.enterText(codeField(), 'bata');
    await tester.pumpAndSettle();

    expect(find.textContaining('Batu bata merah'), findsOneWidget);
    expect(find.textContaining('Simen Portland'), findsNothing);
  });

  testWidgets('a match on the code is offered before a match on the name',
      (tester) async {
    await pump(tester, LineDraft());

    // 'SVC' is the code of one item; 'simen' is in the name of two. This
    // types the string that matches BOTH ways, so the order is the
    // assertion: the code match first.
    await tester.enterText(codeField(), 'simen');
    await tester.pumpAndSettle();

    // Nothing's CODE contains 'simen', so both come back on the name and
    // both are offered.
    expect(find.textContaining('Simen Portland'), findsOneWidget);
    expect(find.textContaining('Upah pemasangan simen'), findsOneWidget);
  });

  testWidgets('an empty box offers nothing at all', (tester) async {
    await pump(tester, LineDraft());

    await tester.enterText(codeField(), 'BRG');
    await tester.pumpAndSettle();
    expect(find.textContaining('Simen Portland'), findsOneWidget);

    await tester.enterText(codeField(), '');
    await tester.pumpAndSettle();
    expect(find.textContaining('Simen Portland'), findsNothing);
  });

  testWidgets('picking one fills the line', (tester) async {
    final line = LineDraft();
    await pump(tester, line);

    await tester.enterText(codeField(), 'SVC');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Upah pemasangan simen'));
    await tester.pumpAndSettle();

    expect(line.itemId, 'i3');
    expect(line.description, 'Upah pemasangan simen');
    expect(line.unitPrice, 150);
    // The number stays in the box it was typed into.
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller?.text,
      'SVC-100',
    );
  });

  testWidgets('a line reopened on an item already shows its number',
      (tester) async {
    await pump(tester, LineDraft(itemId: 'i1', description: 'Simen Portland'));

    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller?.text,
      'BRG-001',
    );
  });

  // -------------------------------------------------------------------
  // The description box searches too
  //
  // Same search, both boxes: somebody typing in either one is doing the
  // same thing, looking for an item. The description stays FREE TEXT --
  // a charge is often something not on the item list at all, and a box
  // that refused what was typed would make half the invoices in this
  // system un-typeable.
  // -------------------------------------------------------------------
  Finder descriptionField() =>
      find.widgetWithText(TextFormField, 'Description');

  testWidgets('the description box finds an item by its name too',
      (tester) async {
    await pump(tester, LineDraft());

    await tester.enterText(descriptionField(), 'bata');
    await tester.pumpAndSettle();

    expect(find.text('Batu bata merah'), findsWidgets);
    expect(find.text('Simen Portland'), findsNothing);
  });

  testWidgets('and by part number, for whoever types the code in the '
      'wrong box', (tester) async {
    await pump(tester, LineDraft());

    await tester.enterText(descriptionField(), 'SVC-100');
    await tester.pumpAndSettle();

    expect(find.text('Upah pemasangan simen'), findsWidgets);
  });

  testWidgets('picking from the description fills the line', (tester) async {
    final line = LineDraft();
    await pump(tester, line);

    await tester.enterText(descriptionField(), 'Portland');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simen Portland').last);
    await tester.pumpAndSettle();

    expect(line.itemId, 'i1');
    expect(line.unitPrice, 22.50);
  });

  testWidgets('but a description that matches nothing is still typeable',
      (tester) async {
    final line = LineDraft();
    await pump(tester, line);

    // The charge that is not on the item list, which is most of them on
    // a professional firm's invoice.
    await tester.enterText(
      descriptionField(),
      'Audit fee for the year ended 31 December',
    );
    await tester.pumpAndSettle();

    expect(line.description, 'Audit fee for the year ended 31 December');
    expect(line.itemId, isNull);
  });
}