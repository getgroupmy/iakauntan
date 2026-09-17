import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/items/tariff_code.dart';

/// `0636`. The shape check exists to catch ONE thing: a description
/// typed into the box under the one labelled "e-Invoice
/// classification". The two fields sit together and are constantly
/// confused — this project's own gap analysis confused them, which is
/// why G3(c) was mis-stated.
///
/// It deliberately does not check membership of the PDK. Refusing a
/// code that is correct stops an invoice that should go; accepting one
/// that is wrong is caught by the customs officer who reads it.
void main() {
  group('what a tariff code may be', () {
    test('blank is a real answer', () {
      // Most items will never carry one, and a service cannot.
      expect(tariffCodeProblem(null), isNull);
      expect(tariffCodeProblem(''), isNull);
      expect(tariffCodeProblem('   '), isNull);
    });

    test('a four-digit heading', () {
      expect(tariffCodeProblem('4001'), isNull);
    });

    test('a six-digit subheading with a dot', () {
      expect(tariffCodeProblem('4001.10'), isNull);
    });

    test('a full Malaysian code', () {
      expect(tariffCodeProblem('4001.10.10.00'), isNull);
    });
  });

  group('what it refuses', () {
    test('a description, which is the error it exists for', () {
      expect(tariffCodeProblem('Natural rubber'), isNotNull);
    });

    test('and the message says a number is wanted', () {
      // "Invalid" would leave somebody who typed a product name with no
      // idea what the box is for.
      expect(tariffCodeProblem('Natural rubber'), contains('digits'));
      expect(tariffCodeProblem('Natural rubber'), contains('4001'));
    });

    test('too few digits', () {
      expect(tariffCodeProblem('400'), isNotNull);
      expect(tariffCodeProblem('4'), isNotNull);
    });

    test('a code that starts with a dot', () {
      expect(tariffCodeProblem('.4001'), isNotNull);
    });

    test('letters mixed in', () {
      expect(tariffCodeProblem('4001A'), isNotNull);
      expect(tariffCodeProblem('40O1'), isNotNull);
    });

    test('longer than the longest real code', () {
      expect(tariffCodeProblem('4001.10.10.00.99.88'), isNotNull);
    });
  });

  group('it agrees with the database', () {
    test('the same expression as items_tariff_code_shape', () {
      // The constraint is `^[0-9]{4}[0-9.]{0,10}$`. If these two drift,
      // the screen accepts what the database then refuses — a round
      // trip that fails with a constraint name instead of a sentence.
      final db = RegExp(r'^[0-9]{4}[0-9.]{0,10}$');
      for (final v in [
        '4001',
        '4001.10',
        '4001.10.10.00',
        '400',
        'Natural rubber',
        '4001A',
        '.4001',
        '4001.10.10.00.99.88',
      ]) {
        expect(
          tariffCodeProblem(v) == null,
          db.hasMatch(v),
          reason: 'the screen and the constraint disagree about "$v"',
        );
      }
    });
  });

  group('the item model', () {
    test('reads both columns', () {
      final i = Item.fromJson({
        'id': 'i-1',
        'code': 'RUB',
        'name': 'Getah',
        'item_type': 'stock',
        'classification_code': '022',
        'tariff_code': '4001.10.10',
        'country_of_origin': 'THA',
      });
      expect(i.tariffCode, '4001.10.10');
      expect(i.countryOfOrigin, 'THA');
      // The field it is constantly confused with is a different value.
      expect(i.classificationCode, '022');
    });

    test('an item with neither reads as null, not as a default', () {
      // A default here would send a tariff code to LHDN for goods
      // nobody classified.
      final i = Item.fromJson({
        'id': 'i-2',
        'code': 'SVC',
        'name': 'Nasihat',
        'item_type': 'service',
      });
      expect(i.tariffCode, isNull);
      expect(i.countryOfOrigin, isNull);
    });

    test('both survive a round trip through toJson', () {
      final i = Item(
        id: 'i-3',
        code: 'CHP',
        name: 'Cip',
        itemType: 'stock',
        tariffCode: '8542.31.00',
        countryOfOrigin: 'TWN',
      );
      final j = i.toJson();
      expect(j['tariff_code'], '8542.31.00');
      expect(j['country_of_origin'], 'TWN');
      // Absent keys would leave the columns unchanged on an update,
      // which is how a cleared field silently keeps its old value.
      expect(j.containsKey('tariff_code'), isTrue);
      expect(j.containsKey('country_of_origin'), isTrue);
    });

    test('clearing them sends null rather than omitting the key', () {
      final j = Item(
        id: 'i-4',
        code: 'X',
        name: 'X',
        itemType: 'service',
      ).toJson();
      expect(j.containsKey('tariff_code'), isTrue);
      expect(j['tariff_code'], isNull);
    });
  });
}
