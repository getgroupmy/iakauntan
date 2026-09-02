import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/imports/import_screen.dart';

/// A contact file with no code column.
///
/// What the database does with such a file is asserted in
/// `supabase/tests/contact_import_codes.sql`: a blank code validates,
/// the preview says what shape the drawn code will take and draws
/// nothing, and the import draws it from the row's own series --
/// customer, supplier or prospect. What is asserted here is that the
/// screen does not get in the way of that, and does not waste it.
///
/// It could get in the way by insisting on the code column, as it did
/// before 0479, when the database also did. It could waste it by
/// listing only the rows with something wrong: the preview of a file
/// with no codes would then read 'all of them fine' and the codes the
/// import drew would be on nobody's screen.
void main() {
  Widget harness() => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      canWriteProvider.overrideWithValue(true),
      canPostProvider.overrideWithValue(true),
      migrationProgressProvider.overrideWith((ref) async => const []),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const ImportScreen()),
  );

  FontWeight? weightOf(WidgetTester tester, String chip) =>
      tester.widget<Text>(find.text(chip)).style?.fontWeight;

  testWidgets('a contact needs a name and not a code', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(
      weightOf(tester, 'name'),
      FontWeight.w700,
      reason: 'name is required',
    );
    expect(
      weightOf(tester, 'code'),
      FontWeight.w400,
      reason: 'the code is drawn when it is left blank',
    );
  });

  testWidgets('an item still needs its code', (tester) async {
    // The control. An item code is what every later document line
    // names the item by, so the loosening is for contacts only.
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Items'));
    await tester.pumpAndSettle();

    expect(weightOf(tester, 'code'), FontWeight.w700);
    expect(weightOf(tester, 'name'), FontWeight.w700);
  });

  testWidgets('the sample file shows a row with the code left blank', (
    tester,
  ) async {
    // Somebody arranging a spreadsheet reads the sample, not the
    // migration. A sample where every row has a code says the code is
    // needed, whatever the chips say.
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.decoration?.hintText,
      contains('\n,Beta Supplies Sdn Bhd,supplier,'),
    );
  });

  group('what the verdict lists', () {
    Map<String, dynamic> row(
      int no,
      String status, {
      String code = '',
      String message = '',
    }) => {'row_no': no, 'code': code, 'status': status, 'message': message};

    test('errors, then warnings, then fine rows with something to say', () {
      final listed = importRowsToList([
        row(1, 'ok', code: 'C-001'),
        row(
          2,
          'ok',
          message:
              'No code in the file. The next P-YYYY-NNNNN '
              'is drawn when the file is imported.',
        ),
        row(3, 'warning', code: 'AR', message: 'differs by 12.00'),
        row(4, 'error', code: 'C-001', message: 'C-001 appears twice.'),
        row(5, 'ok', code: 'S-001'),
      ]);

      expect(listed.map((r) => r['row_no']), [4, 3, 2]);
    });

    test('a fine row with nothing to say is not listed', () {
      // A hundred rows of 'ok' would bury the two that matter.
      expect(importRowsToList([row(1, 'ok', code: 'C-001')]), isEmpty);
    });

    test('after the import, the drawn code is what gets listed', () {
      // The database answers the drawn row with the code it drew and a
      // message saying so; the keyed row arrives with neither. The one
      // line on the screen is the one somebody needs to write down.
      final listed = importRowsToList([
        row(1, 'imported', code: 'K-1'),
        row(
          2,
          'imported',
          code: 'P-2026-00001',
          message: 'No code in the file; this one was drawn.',
        ),
      ]);

      expect(listed.single['code'], 'P-2026-00001');
    });

    test('and none of them count as blocking', () {
      expect(
        importBlockingErrors([
          row(1, 'ok', message: 'No code in the file.'),
          row(
            2,
            'imported',
            message: 'No code in the file; this one was drawn.',
          ),
        ]),
        0,
      );
    });
  });
}
