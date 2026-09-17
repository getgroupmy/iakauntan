import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/quick_add_dialog.dart';

/// Adding a row to a short list without leaving what you were doing.
void main() {
  group('the code suggested from a name', () {
    test('is the first word, upper case', () {
      expect(suggestCode('Kuala Lumpur office'), 'KUALA');
      expect(suggestCode('printing'), 'PRINTING');
    });

    test('drops what a code column would not want', () {
      expect(suggestCode('R&D (main)'), 'RD');
      expect(suggestCode('Line-2 assembly'), 'LINE2');
    });

    test('stops at eight characters', () {
      expect(suggestCode('Administration'), 'ADMINIST');
    });

    test('and a name with nothing usable suggests nothing', () {
      // Rather than something the person then has to clear.
      expect(suggestCode(''), '');
      expect(suggestCode('   '), '');
      expect(suggestCode('!!!'), '');
    });
  });

  group('the dialog', () {
    Future<void> pump(
      WidgetTester tester, {
      String? codeLabel,
      String? seed,
      required Future<String> Function({required String name, String? code})
          save,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuickAddDialog(
              title: 'New project',
              save: save,
              codeLabel: codeLabel,
              seed: seed,
            ),
          ),
        ),
      );
    }

    testWidgets('seeds the name with what was typed', (tester) async {
      await pump(tester, seed: 'Menara Hijau', save: ({required name, code}) async => 'p1');
      expect(find.text('Menara Hijau'), findsOneWidget);
    });

    testWidgets('and suggests a code beside it, where the list has one',
        (tester) async {
      await pump(
        tester,
        seed: 'Menara Hijau',
        codeLabel: 'Code',
        save: ({required name, code}) async => 'p1',
      );
      expect(find.text('MENARA'), findsOneWidget);
    });

    testWidgets('no code box where the list has no codes', (tester) async {
      // Asking for a code a table has no column for is how a dialog
      // teaches somebody a rule that is not there.
      await pump(tester, seed: 'Menara Hijau',
          save: ({required name, code}) async => 'p1');
      expect(find.widgetWithText(TextFormField, 'MENARA'), findsNothing);
    });

    testWidgets('saving passes the name and the upper-cased code',
        (tester) async {
      String? gotName;
      String? gotCode;
      await pump(
        tester,
        seed: 'Menara Hijau',
        codeLabel: 'Code',
        save: ({required name, code}) async {
          gotName = name;
          gotCode = code;
          return 'p1';
        },
      );
      await tester.enterText(find.byType(TextFormField).last, 'mh');
      await tester.tap(find.text('Create and use'));
      await tester.pumpAndSettle();

      expect(gotName, 'Menara Hijau');
      expect(gotCode, 'MH');
    });

    testWidgets('and passes a null code where there is no code box',
        (tester) async {
      String? gotCode = 'not called';
      await pump(
        tester,
        seed: 'Menara Hijau',
        save: ({required name, code}) async {
          gotCode = code;
          return 'p1';
        },
      );
      await tester.tap(find.text('Create and use'));
      await tester.pumpAndSettle();
      expect(gotCode, isNull);
    });

    testWidgets('an empty name is refused rather than written',
        (tester) async {
      var called = false;
      await pump(tester, save: ({required name, code}) async {
        called = true;
        return 'p1';
      });
      await tester.tap(find.text('Create and use'));
      await tester.pumpAndSettle();

      expect(called, isFalse);
      expect(find.text('It needs a name.'), findsOneWidget);
    });

    testWidgets('a failed write is shown rather than thrown away',
        (tester) async {
      // The likely failure is a code already in use, and losing what is
      // behind this dialog to find that out is the worst outcome.
      await pump(
        tester,
        seed: 'Menara Hijau',
        save: ({required name, code}) async => throw Exception('MH is taken'),
      );
      await tester.tap(find.text('Create and use'));
      await tester.pumpAndSettle();
      expect(find.textContaining('MH is taken'), findsOneWidget);
    });
  });
}
