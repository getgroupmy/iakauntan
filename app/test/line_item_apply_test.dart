import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/item_apply_dialog.dart';
import 'package:iakauntan/src/features/documents/line_draft.dart';
import 'package:iakauntan/src/features/documents/line_editor.dart';

/// Putting an item on a line used to write over everything on it.
///
/// Reported twice from the same scanned bill. First the description --
/// four lines of the supplier's own wording replaced by the item
/// master's name. Then the rest of it: "why when the item number is
/// keyed in replace the unit price disc% tax and amount". The price read
/// off the paper was 23.3332258 and the item's was zero, so the line
/// went to RM 0.00 and the amount with it.
///
/// The claims worth more than the rest:
///
///   * KEEPING is what a dismissal does, on every field;
///   * the fields are SEPARATE choices. "Ask in the prompt to add or
///     update the tax without changing the value" cannot be expressed by
///     an all-or-nothing prompt;
///   * and the line is bound to the item either way. This asks which of
///     its values to copy, not whether to use it.
void main() {
  final st8 = TaxCode(
    id: 't8',
    code: 'ST8',
    name: 'Service tax 8%',
    rate: 8,
    taxTypeCode: '06',
  );
  final zero = TaxCode(
    id: 't0',
    code: 'ZR',
    name: 'Zero rated',
    rate: 0,
    taxTypeCode: '06',
  );
  final taxCodes = [st8, zero];

  final workspace = Item(
    id: 'i1',
    code: 'ITM-140',
    // Deliberately NOT a substring of the description typed below:
    // `find.textContaining` would otherwise match the line's own
    // description box as well as the suggestion, and tap the wrong one.
    // That is what the first run of this file did.
    name: 'Langganan bulanan',
    itemType: 'service',
    unitPrice: 0,
    uomCode: 'C62',
    salesTaxCodeId: 't0',
    trackInventory: false,
  );

  LineDraft scanned() => LineDraft(
        description: 'Google Workspace Business Starter Usage',
        quantity: 31,
        unitPrice: 23.3332258,
        taxCodeId: 't8',
        taxRate: 8,
        uomCode: 'MON',
      );

  group('what an item would overwrite', () {
    test('a blank line has nothing to lose', () {
      expect(
        itemWouldOverwrite(LineDraft(), workspace, taxCodes),
        isEmpty,
      );
    });

    test('and a scanned line has four things', () {
      final parts = itemWouldOverwrite(scanned(), workspace, taxCodes)
          .map((c) => c.part)
          .toSet();
      expect(parts, {
        LinePart.description,
        LinePart.unitPrice,
        LinePart.taxCode,
        LinePart.unit,
      });
    });

    // A PRICED item for the next three, because `workspace` costs
    // nothing: with both sides at zero, "is it empty" and "is it the
    // same" cannot be told apart, and two mutants survived the first
    // sweep in exactly that gap.
    final priced = Item(
      id: 'i9',
      code: 'ITM-900',
      name: 'Langganan bulanan',
      itemType: 'service',
      unitPrice: 30,
      uomCode: 'C62',
      salesTaxCodeId: 't0',
      trackInventory: false,
    );

    test('a price of zero is this field\'s empty', () {
      // A line nobody has priced reads zero, and asking about it would
      // put a dialog in front of the commonest path there is.
      final parts = itemWouldOverwrite(
        LineDraft(unitPrice: 0, description: 'Something'),
        priced,
        taxCodes,
      ).map((c) => c.part);
      expect(parts, isNot(contains(LinePart.unitPrice)));
    });

    test('and the same value is not a change', () {
      final line = LineDraft(
        description: priced.name,
        unitPrice: 30,
        taxCodeId: 't0',
        uomCode: 'C62',
      );
      expect(itemWouldOverwrite(line, priced, taxCodes), isEmpty);
    });

    // The line has none of its own, so there is nothing to lose and the
    // item's code is exactly what is wanted.
    test('a line with no tax is not asked about tax', () {
      final parts = itemWouldOverwrite(
        LineDraft(description: 'Typed by hand', unitPrice: 12, uomCode: 'C62'),
        priced,
        taxCodes,
      ).map((c) => c.part);
      expect(parts, isNot(contains(LinePart.taxCode)));
      // And the price it does have is still asked about, so this is not
      // passing because nothing was compared.
      expect(parts, contains(LinePart.unitPrice));
    });

    // The same, on a line that is SWAPPING items rather than being
    // filled for the first time. Without it the case above proves
    // nothing about the empty check: with `previous` null, the
    // "not what the last item put there" test already answers no.
    //
    // It costs one thing, said here rather than discovered later: a tax
    // somebody deliberately CLEARED reads the same as one never set, so
    // picking an item puts a code back without asking. The alternative
    // is a prompt on every blank line that gets an item, which is the
    // commonest path in the editor.
    test('nor is one that was cleared while another item was on it', () {
      final taxed = Item(
        id: 'i8',
        code: 'ITM-800',
        name: 'Zoom Pro',
        itemType: 'service',
        unitPrice: 60,
        uomCode: 'C62',
        salesTaxCodeId: 't8',
      );
      final parts = itemWouldOverwrite(
        LineDraft(description: 'Typed by hand', unitPrice: 12, uomCode: 'C62'),
        priced,
        taxCodes,
        previous: taxed,
      ).map((c) => c.part);
      expect(parts, isNot(contains(LinePart.taxCode)));
      expect(parts, contains(LinePart.unitPrice));
    });

    // Correcting a mis-picked item would otherwise ask about every
    // field the first one had filled in.
    test('nor is what the item it is already on put there', () {
      final other = Item(
        id: 'i2',
        code: 'ITM-200',
        name: 'Zoom Pro',
        itemType: 'service',
        unitPrice: 60,
        uomCode: 'MON',
        salesTaxCodeId: 't8',
      );
      final line = LineDraft(
        description: other.name,
        unitPrice: other.unitPrice,
        taxCodeId: 't8',
        uomCode: 'MON',
      );
      expect(
        itemWouldOverwrite(line, workspace, taxCodes, previous: other),
        isEmpty,
      );
    });

    // The dialog shows these, so a rounded one is a dialog asking about
    // a number that is not the one on the line.
    test('the price is shown as it was typed, not rounded', () {
      final change = itemWouldOverwrite(scanned(), workspace, taxCodes)
          .firstWhere((c) => c.part == LinePart.unitPrice);
      expect(change.current, '23.3332258');
    });

    test('and the tax by its code and rate', () {
      final change = itemWouldOverwrite(scanned(), workspace, taxCodes)
          .firstWhere((c) => c.part == LinePart.taxCode);
      expect(change.current, 'ST8 (8%)');
      expect(change.suggested, 'ZR (0%)');
    });

    // A company with no default and an item that names no code leaves
    // the line's tax alone, so there is nothing to ask about.
    test('a tax nothing would replace is not asked about', () {
      final nameless = Item(
        id: 'i3',
        code: 'X',
        name: 'X',
        itemType: 'service',
        uomCode: 'MON',
      );
      final parts =
          itemWouldOverwrite(scanned(), nameless, const <TaxCode>[])
              .map((c) => c.part);
      expect(parts, isNot(contains(LinePart.taxCode)));
    });
  });

  group('applying only what was chosen', () {
    test('taking nothing still binds the item', () {
      final line = scanned();
      applyItemKeeping(line, workspace, taxCodes, const {});

      expect(line.itemId, 'i1');
      expect(line.description, 'Google Workspace Business Starter Usage');
      expect(line.unitPrice, 23.3332258);
      expect(line.taxCodeId, 't8');
      expect(line.taxRate, 8);
      expect(line.uomCode, 'MON');
    });

    // The half that was asked for in the second report: the item's tax
    // code, and the figure off the paper left alone.
    test('the tax can be taken without the price', () {
      final line = scanned();
      applyItemKeeping(line, workspace, taxCodes, {LinePart.taxCode});

      expect(line.taxCodeId, 't0');
      expect(line.taxRate, 0);
      expect(line.unitPrice, 23.3332258);
      expect(line.description, 'Google Workspace Business Starter Usage');
    });

    test('and the price without the tax', () {
      final line = scanned();
      applyItemKeeping(line, workspace, taxCodes, {LinePart.unitPrice});

      expect(line.unitPrice, 0);
      expect(line.taxCodeId, 't8');
      expect(line.taxRate, 8);
    });

    // `0641`: a line that took the rate and not the inclusive flag put
    // an inclusive price on screen at its exclusive total.
    test('keeping the tax keeps all three of its parts', () {
      final line = scanned()..isTaxInclusive = true;
      applyItemKeeping(line, workspace, taxCodes, const {});

      expect(line.taxCodeId, 't8');
      expect(line.taxRate, 8);
      expect(line.isTaxInclusive, isTrue);
    });

    test('taking everything is what it always did', () {
      final line = scanned();
      applyItemKeeping(line, workspace, taxCodes, LinePart.values.toSet());

      expect(line.description, 'Langganan bulanan');
      expect(line.unitPrice, 0);
      expect(line.taxCodeId, 't0');
      expect(line.uomCode, 'C62');
    });
  });

  group('the question itself', () {
    Future<List<Set<LinePart>?>> openTheQuestion(
      WidgetTester tester, {
      LineDraft? line,
    }) async {
      // A tall surface. Four fields, each with two value boxes and a
      // switch, do not fit the 800x600 a widget test defaults to — the
      // dialog scrolls, and a tap on a row below the fold silently
      // hits nothing. Two of these tests failed that way first, both
      // reporting an empty answer rather than a missed tap.
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final answers = <Set<LinePart>?>[];
      final draft = line ?? scanned();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                // A box and not a returned future: the button's own
                // handler is what awaits the dialog, so a helper that
                // returned the answer would return it BEFORE anybody
                // had pressed anything. The first draft did exactly
                // that and read null three times.
                answers.add(await whatToTakeFrom(
                  context,
                  line: draft,
                  item: workspace,
                  taxCodes: taxCodes,
                ));
              },
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return answers;
    }

    testWidgets('shows every value, current beside suggested',
        (tester) async {
      await openTheQuestion(tester);

      expect(find.text('What should this line keep?'), findsOneWidget);
      expect(
        find.text('Google Workspace Business Starter Usage'),
        findsOneWidget,
      );
      expect(find.text('23.3332258'), findsOneWidget);
      expect(find.text('ST8 (8%)'), findsOneWidget);
      expect(find.text('MON'), findsOneWidget);
      expect(find.text('Langganan bulanan'), findsOneWidget);
      expect(find.text('ZR (0%)'), findsOneWidget);
    });

    testWidgets('and keeps everything by default', (tester) async {
      final answers = await openTheQuestion(tester);
      await tester.tap(find.byKey(const ValueKey('item-apply-confirm')));
      await tester.pumpAndSettle();

      // Nothing was toggled, so nothing of the four is taken.
      expect(answers.single, isEmpty);
    });

    // The whole point of a per-field prompt.
    testWidgets('one field can be taken and the rest kept', (tester) async {
      final answers = await openTheQuestion(tester);

      await tester
          .ensureVisible(find.byKey(const ValueKey('item-apply-switch-taxCode')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('item-apply-switch-taxCode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('item-apply-confirm')));
      await tester.pumpAndSettle();

      expect(answers.single, {LinePart.taxCode});
    });

    testWidgets('or all of them at once', (tester) async {
      final answers = await openTheQuestion(tester);

      await tester.ensureVisible(find.byKey(const ValueKey('item-apply-take-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('item-apply-take-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('item-apply-confirm')));
      await tester.pumpAndSettle();

      expect(answers.single, {
        LinePart.description,
        LinePart.unitPrice,
        LinePart.taxCode,
        LinePart.unit,
      });
    });

    testWidgets('keeping all of mine takes nothing', (tester) async {
      final answers = await openTheQuestion(tester);
      await tester.tap(find.byKey(const ValueKey('item-apply-keep')));
      await tester.pumpAndSettle();
      expect(answers.single, isEmpty);
    });

    // Null, which the caller reads as "keep". The destructive answer is
    // never what a dismissal does.
    testWidgets('and walking away keeps everything', (tester) async {
      final answers = await openTheQuestion(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(answers.single, isEmpty);
    });

    testWidgets('a line with nothing of its own is never asked',
        (tester) async {
      final answers = await openTheQuestion(tester, line: LineDraft());
      expect(find.text('What should this line keep?'), findsNothing);
      // Everything, without a word.
      expect(answers.single, LinePart.values.toSet());
    });

    // One field in question reads as a question about that field.
    testWidgets('a single difference asks about it by name', (tester) async {
      final answers = await openTheQuestion(
        tester,
        line: LineDraft(description: 'Google Workspace Business Starter'),
      );
      expect(find.text('Replace the description?'), findsOneWidget);
      expect(find.byKey(const ValueKey('item-apply-take-all')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('item-apply-keep')));
      await tester.pumpAndSettle();

      // Keeping the description does not mean keeping a price, a tax
      // and a unit the line never had: what was NOT in question comes
      // from the item, silently, which is what binding to an item is
      // for. A mutant that dropped those survived the first sweep,
      // because every other test here asks about all four fields or
      // about none.
      expect(answers.single, {
        LinePart.unitPrice,
        LinePart.taxCode,
        LinePart.unit,
      });
    });
  });

  // The wiring, on both layouts. It is written out twice in
  // `line_editor.dart` — once for the grid and once for the card — and
  // this file's own subject is a drift between those two copies: the
  // narrow one once set everything except the tax code, so a line added
  // on a phone silently carried no SST.
  for (final wide in [true, false]) {
    group(wide ? 'on a wide screen' : 'on a phone', () {
      Future<void> pump(WidgetTester tester, LineDraft line) async {
        tester.view.physicalSize =
            wide ? const Size(1400, 2000) : const Size(420, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(ProviderScope(
          overrides: [
            repoProvider.overrideWithValue(null),
            itemsProvider.overrideWith((ref, search) async => [workspace]),
            taxCodesProvider.overrideWith((ref) async => taxCodes),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: LineEditorCard(
                  sales: false,
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
        ));
        await tester.pump();
      }

      Future<void> pickTheItem(WidgetTester tester) async {
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Item no.'), 'ITM-140');
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Langganan bulanan').last);
        await tester.pumpAndSettle();
      }

      testWidgets('a scanned line is asked about before anything moves',
          (tester) async {
        final line = scanned();
        await pump(tester, line);
        await pickTheItem(tester);

        expect(find.text('What should this line keep?'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('item-apply-keep')));
        await tester.pumpAndSettle();

        // Everything off the paper is still there...
        expect(line.description, 'Google Workspace Business Starter Usage');
        expect(line.unitPrice, 23.3332258);
        expect(line.taxCodeId, 't8');
        expect(line.uomCode, 'MON');
        // ...and the line is bound to the item, which is what putting a
        // number in the item box is for.
        expect(line.itemId, 'i1');
      });

      testWidgets('and the tax alone can be taken', (tester) async {
        final line = scanned();
        await pump(tester, line);
        await pickTheItem(tester);

        await tester
            .tap(find.byKey(const ValueKey('item-apply-switch-taxCode')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('item-apply-confirm')));
        await tester.pumpAndSettle();

        expect(line.taxCodeId, 't0');
        expect(line.unitPrice, 23.3332258);
        expect(line.description, 'Google Workspace Business Starter Usage');
      });

      testWidgets('an empty line is filled without a word', (tester) async {
        final line = LineDraft();
        await pump(tester, line);
        await pickTheItem(tester);

        expect(find.text('What should this line keep?'), findsNothing);
        expect(line.description, 'Langganan bulanan');
        expect(line.itemId, 'i1');
      });
    });
  }
}
