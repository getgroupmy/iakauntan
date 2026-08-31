import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/settings/msic_picker.dart';

/// A handful from the seed in 0011.
List<Map<String, dynamic>> codes() => [
  {'code': '01261', 'description': 'Growing of oil palm (estate)',
    'category': 'Agriculture'},
  {'code': '10710', 'description': 'Manufacture of bakery products',
    'category': 'Manufacturing'},
  {'code': '10712', 'description': 'Manufacture of biscuits',
    'category': 'Manufacturing'},
  {'code': '62010', 'description': 'Computer programming activities',
    'category': 'Information'},
];

void main() {
  group('whether a code is the shape MSIC uses', () {
    test('five digits is', () {
      expect(msicLooksValid('62010'), isTrue);
      expect(msicLooksValid(' 10710 '), isTrue);
    });

    test('and anything else is not', () {
      expect(msicLooksValid('6201'), isFalse);
      expect(msicLooksValid('620100'), isFalse);
      expect(msicLooksValid('6201A'), isFalse);
      expect(msicLooksValid(''), isFalse);
    });
  });

  test('one reads as its code and what it is', () {
    expect(
      msicLabel(codes()[1]),
      '10710 · Manufacture of bakery products',
    );
  });

  group('what somebody typed finds', () {
    test('a code typed in full comes first', () {
      // It is what they meant. Anything else above it is the screen
      // second-guessing somebody who already knows the answer.
      final found = msicMatches(codes(), '10710');
      expect(found.first['code'], '10710');
    });

    test('half a code finds the codes that start with it', () {
      expect(
        [for (final r in msicMatches(codes(), '107')) r['code']],
        ['10710', '10712'],
      );
    });

    test('and only the ones that start with it', () {
      // A code with those digits in the middle is not the code
      // somebody is half-remembering.
      final all = [
        ...codes(),
        {'code': '31070', 'description': 'Manufacture of mattresses',
          'category': 'Manufacturing'},
      ];
      expect(
        [for (final r in msicMatches(all, '107')) r['code']],
        ['10710', '10712'],
      );
    });

    test('a code typed in full beats a description that mentions it', () {
      // The description match is listed first on purpose: what puts
      // the exact code at the top has to be the ranking, not the order
      // the rows happened to arrive in.
      final all = [
        {'code': '82990', 'description': 'Agency work, MSIC 10710 excluded',
          'category': 'Support'},
        ...codes(),
      ];
      expect(msicMatches(all, '10710').first['code'], '10710');
      expect(msicMatches(all, '10710').length, 2);
    });

    test('and a word finds what the business actually does', () {
      // "bakery" is how a baker looks for 10710. Same box.
      expect(
        [for (final r in msicMatches(codes(), 'bakery')) r['code']],
        ['10710'],
      );
    });

    test('the category is searchable too', () {
      expect(msicMatches(codes(), 'Manufacturing').length, 2);
    });

    test('however it is cased', () {
      expect(msicMatches(codes(), 'BISCUITS').length, 1);
    });

    test('an empty box shows everything rather than nothing', () {
      expect(msicMatches(codes(), '   ').length, 4);
    });

    test('and something nobody does finds nothing', () {
      expect(msicMatches(codes(), 'whaling'), isEmpty);
    });

    test('a code match outranks a word match', () {
      // '10' is the start of two codes and appears in no description
      // here; adding one proves the order rather than the filter.
      final all = [
        ...codes(),
        {'code': '99999', 'description': 'Renting of 10 vans',
          'category': 'Transport'},
      ];
      expect(msicMatches(all, '10').first['code'], '10710');
      expect(msicMatches(all, '10').last['code'], '99999');
    });
  });

  group('what the field shows for a code already chosen', () {
    test('the code and what it means', () {
      expect(
        msicSummary(codes(), '62010'),
        '62010 · Computer programming activities',
      );
    });

    test('however it was typed', () {
      // The picker hands back a clean code, but the field it fills is
      // a text box somebody may have pasted into.
      expect(
        msicSummary(codes(), ' 62010 '),
        '62010 · Computer programming activities',
      );
    });

    test('a code the list does not know is still shown', () {
      // A company registered under a code since retired still has that
      // code, and blanking it would look like it had none.
      expect(msicSummary(codes(), '46592'), '46592');
    });

    test('and nothing chosen says so', () {
      expect(msicSummary(codes(), null), 'Not set');
      expect(msicSummary(codes(), '   '), 'Not set');
    });
  });
}
