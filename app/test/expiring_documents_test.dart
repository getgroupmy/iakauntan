import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/hr/expiring_documents.dart';

Map<String, dynamic> row({
  String? consequence,
  int? days,
  bool expired = false,
}) => <String, dynamic>{
      'consequence': consequence,
      'days_until': days,
      'is_expired': expired,
    };

void main() {
  group('how urgent a row is', () {
    test('an expired pass on a foreign worker is the company\'s offence', () {
      expect(consequenceOf('offence'), DocumentConsequence.offence);
      expect(
        consequenceNote(row(consequence: 'offence')),
        contains('s.55B of the Immigration Act'),
      );
    });

    test('a pass that has not lapsed is a permit, and says nothing extra',
        () {
      expect(consequenceOf('permit'), DocumentConsequence.permit);
      expect(consequenceNote(row(consequence: 'permit')), isNull);
    });

    test('anything else is a renewal to chase', () {
      expect(consequenceOf('renewal'), DocumentConsequence.renewal);
      expect(consequenceOf(null), DocumentConsequence.renewal);
      expect(consequenceNote(row(consequence: 'renewal')), isNull);
    });
  });

  group('what the row says about itself', () {
    test('days ahead', () {
      expect(describeExpiry(row(days: 45)), 'Expires in 45 days');
      expect(describeExpiry(row(days: 1)), 'Expires tomorrow');
      expect(describeExpiry(row(days: 0)), 'Expires today');
    });

    test('days behind, which is the case that matters', () {
      expect(describeExpiry(row(days: -1)), 'Expired yesterday');
      expect(describeExpiry(row(days: -14)), 'Expired 14 days ago');
    });

    test('and a row with no date does not pretend to have one', () {
      expect(describeExpiry(row()), 'No expiry date');
    });
  });

  group('whether a renewal is offered at all', () {
    test('an existing document with an expiry can be renewed', () {
      expect(
        canRenewDocument({'id': 'd1', 'expires_date': '2026-12-31'}),
        isTrue,
      );
    });

    test('one with no expiry has nothing to renew to', () {
      expect(canRenewDocument({'id': 'd1', 'expires_date': null}), isFalse);
    });

    test('and one not yet recorded is not a document', () {
      expect(canRenewDocument(null), isFalse);
      expect(canRenewDocument({'expires_date': '2026-12-31'}), isFalse);
    });
  });

  group('the new expiry', () {
    test('is required, or there is nothing to renew to', () {
      expect(
        renewalBlockedBecause(
            currentExpiry: DateTime(2026, 12, 31), newExpiry: null),
        contains('nothing to renew it to'),
      );
    });

    test('runs past the one it replaces', () {
      expect(
        renewalBlockedBecause(
          currentExpiry: DateTime(2026, 12, 31),
          newExpiry: DateTime(2026, 6, 30),
        ),
        contains('runs past the document it replaces'),
      );
    });

    test('and the same date is not past it', () {
      expect(
        renewalBlockedBecause(
          currentExpiry: DateTime(2026, 12, 31),
          newExpiry: DateTime(2026, 12, 31),
        ),
        isNotNull,
      );
    });

    test('a later date will do', () {
      expect(
        renewalBlockedBecause(
          currentExpiry: DateTime(2026, 12, 31),
          newExpiry: DateTime(2027, 12, 31),
        ),
        isNull,
      );
    });

    test('and a document with no expiry takes any date', () {
      expect(
        renewalBlockedBecause(
            currentExpiry: null, newExpiry: DateTime(2027, 1, 1)),
        isNull,
      );
    });
  });
}
