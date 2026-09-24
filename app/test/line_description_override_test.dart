import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/description_override_dialog.dart';
import 'package:iakauntan/src/features/documents/line_draft.dart';
import 'package:iakauntan/src/features/documents/line_editor.dart';

/// Assigning an item used to silently replace the description.
///
/// Reported from a bill scanned off a supplier's PDF: the reading had
/// put "Google Workspace Business Starter Usage" on four lines, an item
/// was assigned afterwards, and `applyItemToLine` replaced all four with
/// the item master's name without a word.
///
/// The supplier's own wording is often the more useful of the two — it
/// is what the paper says, and it is what somebody reconciling the bill
/// will look for. So it is a question now, with both texts on screen.
///
/// The two claims worth more than the rest:
///
///   * KEEPING is what a dismissal does. The destructive answer is
///     never the default one;
///   * and the rest of the item is applied either way. This is a
///     question about the description and nothing else — a person who
///     keeps their wording must still get the item's price.
void main() {
  final items = [
    Item(
      id: 'i1',
      code: 'ITM-140',
      // Deliberately NOT a substring of the description typed below:
      // `find.textContaining` would otherwise match the line's own
      // description box as well as the suggestion, and tap the wrong
      // one. That is what the first run of this file did.
      name: 'Langganan bulanan',
      itemType: 'service',
      unitPrice: 30,
      trackInventory: false,
    ),
    Item(
      id: 'i2',
      code: 'ITM-200',
      name: 'Zoom Pro',
      itemType: 'service',
      unitPrice: 60,
      trackInventory: false,
    ),
  ];

  group('whether it is worth asking at all', () {
    test('an empty box is not', () {
      // Nothing to lose, and the item's name is exactly what is wanted.
      expect(
        descriptionIsWorthKeeping(current: '', suggested: 'Google Workspace'),
        isFalse,
      );
      expect(
        descriptionIsWorthKeeping(
            current: '   ', suggested: 'Google Workspace'),
        isFalse,
      );
    });

    test('nor is the same text in different clothes', () {
      // A dialog asking whether to replace a thing with itself is one
      // people learn to dismiss without reading.
      expect(
        descriptionIsWorthKeeping(
          current: '  google workspace ',
          suggested: 'Google Workspace',
        ),
        isFalse,
      );
    });

    test('nor is the name of the item it is already on', () {
      // That text got there because this editor put it there. Changing
      // item A for item B is not overriding anybody's work, and asking
      // would ask twice for one correction.
      expect(
        descriptionIsWorthKeeping(
          current: 'Zoom Pro',
          suggested: 'Google Workspace',
          boundItemName: 'Zoom Pro',
        ),
        isFalse,
      );
    });

    test('but what somebody typed is', () {
      expect(
        descriptionIsWorthKeeping(
          current: 'Google Workspace Business Starter Usage',
          suggested: 'Google Workspace',
          boundItemName: 'Zoom Pro',
        ),
        isTrue,
      );
    });

    test('and so is an item that would blank it', () {
      // An item with no name of its own would replace a line of typing
      // with nothing at all, which is the worst version of this.
      expect(
        descriptionIsWorthKeeping(
          current: 'Google Workspace Business Starter Usage',
          suggested: '',
        ),
        isTrue,
      );
    });
  });

  group('the question itself', () {
    /// Opens the dialog and hands back the box the answer will land in.
    ///
    /// A box and not a returned future: the button's own handler is
    /// what awaits the dialog, so a helper that returned the answer
    /// would return it BEFORE anybody had pressed anything. The first
    /// draft did exactly that and read null three times.
    Future<List<bool?>> openTheQuestion(WidgetTester tester) async {
      final answers = <bool?>[];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                answers.add(await askDescriptionOverride(
                  context,
                  current: 'Google Workspace Business Starter Usage',
                  suggested: 'Langganan bulanan',
                ));
              },
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Replace the description?'), findsOneWidget);
      return answers;
    }

    testWidgets('shows both texts, because neither can be judged alone',
        (tester) async {
      await openTheQuestion(tester);

      expect(
        find.text('Google Workspace Business Starter Usage'),
        findsOneWidget,
      );
      expect(find.text('Langganan bulanan'), findsOneWidget);
      expect(find.text('On the line now'), findsOneWidget);
      expect(find.text('From the item'), findsOneWidget);
    });

    testWidgets("taking the item's answers true", (tester) async {
      final answers = await openTheQuestion(tester);
      await tester.tap(find.byKey(const ValueKey('description-override-take')));
      await tester.pumpAndSettle();
      expect(answers.single, isTrue);
    });

    testWidgets('keeping what is there answers false', (tester) async {
      final answers = await openTheQuestion(tester);
      await tester.tap(find.byKey(const ValueKey('description-override-keep')));
      await tester.pumpAndSettle();
      expect(answers.single, isFalse);
    });

    testWidgets('and walking away answers neither', (tester) async {
      // Null, which the caller reads as "keep". The destructive answer
      // is never what a dismissal does.
      final answers = await openTheQuestion(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(answers.single, isNull);
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
        tester.view.physicalSize = wide
            ? const Size(1400, 1400)
            : const Size(420, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(ProviderScope(
          overrides: [
            repoProvider.overrideWithValue(null),
            itemsProvider.overrideWith((ref, search) async => items),
            taxCodesProvider.overrideWith((ref) async => const <TaxCode>[]),
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

      testWidgets('a description already there is asked about',
          (tester) async {
        final line = LineDraft(
          description: 'Google Workspace Business Starter Usage',
        );
        await pump(tester, line);
        await pickTheItem(tester);

        expect(find.text('Replace the description?'), findsOneWidget);

        await tester
            .tap(find.byKey(const ValueKey('description-override-keep')));
        await tester.pumpAndSettle();

        // Kept — on the draft, which is what gets saved.
        expect(line.description, 'Google Workspace Business Starter Usage');
        // And the rest of the item came across anyway. This is the half
        // that would be easy to break: a person who keeps their own
        // wording must still get the item's price.
        expect(line.itemId, 'i1');
        expect(line.unitPrice, 30);
      });

      testWidgets("and the item's is taken when that is the answer",
          (tester) async {
        final line = LineDraft(
          description: 'Google Workspace Business Starter Usage',
        );
        await pump(tester, line);
        await pickTheItem(tester);

        await tester
            .tap(find.byKey(const ValueKey('description-override-take')));
        await tester.pumpAndSettle();

        expect(line.description, 'Langganan bulanan');
        expect(line.itemId, 'i1');
      });

      // The mutant this exists for: `answer != false` instead of
      // `answer == true` makes a dismissal take the item's name, and
      // every other test in this file passes with it. Walking away must
      // never be the destructive answer.
      testWidgets('walking away keeps what was there', (tester) async {
        final line = LineDraft(
          description: 'Google Workspace Business Starter Usage',
        );
        await pump(tester, line);
        await pickTheItem(tester);
        expect(find.text('Replace the description?'), findsOneWidget);

        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        expect(line.description, 'Google Workspace Business Starter Usage');
        // And the item still came across, the same as pressing "keep".
        expect(line.itemId, 'i1');
        expect(line.unitPrice, 30);
      });

      testWidgets('an empty line is filled without a word', (tester) async {
        final line = LineDraft();
        await pump(tester, line);
        await pickTheItem(tester);

        expect(find.text('Replace the description?'), findsNothing);
        expect(line.description, 'Langganan bulanan');
        expect(line.unitPrice, 30);
      });
    });
  }
}
