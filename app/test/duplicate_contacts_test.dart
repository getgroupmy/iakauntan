import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/contacts/duplicate_contacts_screen.dart';

/// The records that were already on file twice.
///
/// The server decides what is a duplicate; the screen's own job is to
/// say what was found, let somebody untick what does not belong, and
/// refuse to link fewer than two records. A card that changed identity
/// when the same pair was reported under a different number would lose
/// what had been unticked, so the key is the records themselves.
void main() {
  Map<String, dynamic> rec(String id, String code, String type) => {
    'id': id,
    'code': code,
    'name': 'Al Hardware Sdn Bhd',
    'contact_type': type,
    'party_id': null,
  };

  Map<String, dynamic> dupGroup({
    String matchedOn = 'registration_no',
    String value = '202001012345',
    List<Map<String, dynamic>>? records,
  }) => {
    'matched_on': matchedOn,
    'value': value,
    'records':
        records ??
        [rec('s1', 'S-2026-00001', 'supplier'),
         rec('c1', 'C-2026-00013', 'customer')],
  };

  group('what the group says', () {
    test('the reason is spelt out', () {
      expect(duplicateReason('registration_no'), 'Same registration number');
      expect(duplicateReason('id'), 'Same ID number');
      expect(duplicateReason('tin'), 'Same TIN');
      expect(duplicateReason('anything else'), 'Same details');
    });

    test('an ID shows its number without the type in front', () {
      expect(
        duplicateValue(dupGroup(matchedOn: 'id', value: 'BRN:202001012345')),
        '202001012345',
      );
    });

    test('other identifiers are shown as they are', () {
      expect(duplicateValue(dupGroup()), '202001012345');
      expect(
        duplicateValue(dupGroup(matchedOn: 'tin', value: 'C12345678900')),
        'C12345678900',
      );
    });

    test('the key is the records, not the identifier that found them', () {
      // The same pair found by the registration number and by the TIN
      // is one card, so unticking survives a rebuild.
      expect(
        groupKey(dupGroup()),
        groupKey(dupGroup(matchedOn: 'tin', value: 'C12345678900')),
      );
      // Order in the payload does not change it either.
      expect(
        groupKey(dupGroup()),
        groupKey(dupGroup(records: [
          rec('c1', 'C-2026-00013', 'customer'),
          rec('s1', 'S-2026-00001', 'supplier'),
        ])),
      );
    });

    test('a different set of records is a different card', () {
      expect(
        groupKey(dupGroup()),
        isNot(groupKey(dupGroup(records: [
          rec('s1', 'S-2026-00001', 'supplier'),
          rec('p1', 'P-2026-00001', 'prospect'),
        ]))),
      );
    });
  });

  group('the screen', () {
    Widget host(List<Map<String, dynamic>> groups, {bool canWrite = true}) =>
        ProviderScope(
          overrides: [
            repoProvider.overrideWithValue(null),
            canWriteProvider.overrideWithValue(canWrite),
            contactDuplicatesProvider.overrideWith((ref) async => groups),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DuplicateContactsScreen(),
          ),
        );

    // `find.byType` matches the exact runtime type, and
    // `FilledButton.icon` builds a private subclass of
    // `ButtonStyleButton`, so the button is found by what it is rather
    // than by what it was written as.
    Finder linkButton() => find.ancestor(
      of: find.text('Link as one company'),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    );

    testWidgets('nothing on file twice is said, not left blank', (t) async {
      await t.pumpWidget(host(const []));
      await t.pumpAndSettle();
      expect(find.text('Nothing on file twice'), findsOne);
    });

    testWidgets('a group lists its records, all ticked', (t) async {
      await t.pumpWidget(host([dupGroup()]));
      await t.pumpAndSettle();
      expect(find.text('Same registration number'), findsOne);
      expect(find.text('202001012345'), findsOne);
      expect(find.text('S-2026-00001 · Supplier'), findsOne);
      expect(find.text('C-2026-00013 · Customer'), findsOne);
      for (final id in const ['s1', 'c1']) {
        expect(
          t.widget<CheckboxListTile>(find.byKey(ValueKey('dup-$id'))).value,
          isTrue,
        );
      }
      expect(
        t.widget<ButtonStyleButton>(linkButton()).onPressed,
        isNotNull,
      );
    });

    testWidgets('one record left ticked is not a link', (t) async {
      await t.pumpWidget(host([dupGroup()]));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('dup-c1')));
      await t.pump();
      expect(
        t.widget<ButtonStyleButton>(linkButton()).onPressed,
        isNull,
      );
    });

    testWidgets('somebody who may only read cannot link or untick', (
      t,
    ) async {
      await t.pumpWidget(host([dupGroup()], canWrite: false));
      await t.pumpAndSettle();
      expect(
        t
            .widget<CheckboxListTile>(find.byKey(const ValueKey('dup-s1')))
            .onChanged,
        isNull,
      );
      expect(
        t.widget<ButtonStyleButton>(linkButton()).onPressed,
        isNull,
      );
    });
  });
}
