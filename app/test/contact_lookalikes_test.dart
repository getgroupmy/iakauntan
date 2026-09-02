import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/contacts/contact_lookalikes.dart';

/// The same company, typed by hand.
///
/// Al Hardware is on file as supplier S-2026-00001. Somebody typing
/// them in again is told before Save, in words that say what Save
/// would do: a second supplier record is a duplicate; a customer
/// record is the same company and will be linked; the same name alone
/// is mentioned and links nothing. The rows are the server's
/// (`contact_lookalikes`); these assert that the editor says each one
/// faithfully, and does not ask until there is something to ask about.
void main() {
  Map<String, dynamic> row({
    String id = 's1',
    String code = 'S-2026-00001',
    String type = 'supplier',
    String matchedOn = 'registration_no',
    bool sameRole = false,
  }) => {
    'id': id,
    'code': code,
    'name': 'Al Hardware Sdn Bhd',
    'contact_type': type,
    'matched_on': matchedOn,
    'same_role': sameRole,
  };

  group('what a row means', () {
    test('the same role on an identifier is a duplicate', () {
      final l = Lookalike.fromJson(row(sameRole: true));
      expect(l.kind, LookalikeKind.duplicate);
      expect(l.title, 'Already on file as supplier S-2026-00001');
      expect(l.detail, contains('The same registration number'));
      expect(l.detail, contains('second record'));
    });

    test('another role on an identifier is the same company, linked', () {
      final l = Lookalike.fromJson(row(matchedOn: 'tin'));
      expect(l.kind, LookalikeKind.sameCompany);
      expect(l.title, 'The same company as supplier S-2026-00001');
      expect(l.detail, contains('The same TIN as Al Hardware Sdn Bhd'));
      expect(l.detail, contains('linked'));
    });

    test('a name alone is mentioned and links nothing', () {
      // Even in the same role: two Ali Enterprises are ordinary.
      final l = Lookalike.fromJson(row(matchedOn: 'name', sameRole: true));
      expect(l.kind, LookalikeKind.sameName);
      expect(l.title, 'Same name as supplier S-2026-00001');
      expect(l.detail, contains('will not be linked'));
    });

    test('the reason is spelt out for each identifier', () {
      expect(
        Lookalike.fromJson(row(matchedOn: 'id')).reason,
        'the same ID number',
      );
      expect(Lookalike.fromJson(row(matchedOn: 'tin')).reason, 'the same TIN');
      expect(
        Lookalike.fromJson(row(matchedOn: 'registration_no')).reason,
        'the same registration number',
      );
    });

    test('a customer & supplier record is named as such', () {
      final l = Lookalike.fromJson(
        row(type: 'both', code: 'C-2026-00004', sameRole: true),
      );
      expect(l.title, 'Already on file as customer & supplier C-2026-00004');
    });
  });

  group('when to ask', () {
    test('not on a name of two letters', () {
      expect(worthAskingAbout(name: 'Al'), isFalse);
      expect(worthAskingAbout(name: '  Al '), isFalse);
      expect(worthAskingAbout(name: 'Al '), isFalse);
    });

    test('from the third letter of a name', () {
      expect(worthAskingAbout(name: 'Al ', registrationNo: null), isFalse);
      expect(worthAskingAbout(name: 'Al H'), isTrue);
    });

    test('on any identifier, however short', () {
      expect(worthAskingAbout(name: '', registrationNo: '1'), isTrue);
      expect(worthAskingAbout(name: '', tin: 'C1'), isTrue);
      expect(worthAskingAbout(name: '', idValue: '9'), isTrue);
    });

    test('blanks are not identifiers', () {
      expect(
        worthAskingAbout(name: '', registrationNo: '  ', tin: '', idValue: ' '),
        isFalse,
      );
    });
  });

  group('the notice', () {
    Widget host(List<Lookalike> rows, {void Function(Lookalike)? onOpen}) =>
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ContactLookalikesNotice(rows: rows, onOpen: onOpen),
          ),
        );

    testWidgets('says nothing when there is nothing on file', (t) async {
      await t.pumpWidget(host(const []));
      expect(find.byType(Card), findsNothing);
      expect(find.text('Open'), findsNothing);
    });

    testWidgets('one row per record, the duplicate in warning colour', (
      t,
    ) async {
      await t.pumpWidget(
        host([
          Lookalike.fromJson(row(sameRole: true)),
          Lookalike.fromJson(
            row(id: 'c1', code: 'C-2026-00013', type: 'customer'),
          ),
        ]),
      );
      expect(find.text('Already on file as supplier S-2026-00001'), findsOne);
      expect(find.text('The same company as customer C-2026-00013'), findsOne);
      expect(find.text('Open'), findsNWidgets(2));

      final context = t.element(find.byType(ContactLookalikesNotice));
      final dup = t.widget<Text>(
        find.text('Already on file as supplier S-2026-00001'),
      );
      expect(dup.style?.color, context.colors.warning);
      final same = t.widget<Text>(
        find.text('The same company as customer C-2026-00013'),
      );
      expect(same.style?.color, context.colors.info);
    });

    testWidgets('Open hands over the record on file', (t) async {
      Lookalike? opened;
      await t.pumpWidget(
        host([Lookalike.fromJson(row(sameRole: true))], onOpen: (l) {
          opened = l;
        }),
      );
      await t.tap(find.text('Open'));
      expect(opened?.id, 's1');
    });
  });
}
