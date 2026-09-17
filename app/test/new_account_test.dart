import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/settings/new_account_dialog.dart';

/// Adding an account from the box that wanted one.
void main() {
  group('what kind of account a number says it is', () {
    test('follows the convention the chart is numbered by', () {
      // 1xxx asset, 2xxx liability, 3xxx equity, 4xxx revenue,
      // 5xxx and 6xxx expense — which the Settings card already states
      // as helper text.
      expect(accountTypeFromCode('1000'), 'asset');
      expect(accountTypeFromCode('2100'), 'liability');
      expect(accountTypeFromCode('3000'), 'equity');
      expect(accountTypeFromCode('4000'), 'revenue');
      expect(accountTypeFromCode('5100'), 'expense');
      expect(accountTypeFromCode('6210'), 'expense');
    });

    test('and guesses nothing where the convention says nothing', () {
      // A wrong guess silently filed on the wrong statement is worse
      // than no guess: the caller falls back to asking.
      expect(accountTypeFromCode('7000'), isNull);
      expect(accountTypeFromCode('9999'), isNull);
      expect(accountTypeFromCode('0100'), isNull);
      expect(accountTypeFromCode('Printing'), isNull);
      expect(accountTypeFromCode(''), isNull);
      expect(accountTypeFromCode('   '), isNull);
    });

    test('a number with spaces round it is still a number', () {
      expect(accountTypeFromCode('  6210 '), 'expense');
    });
  });

  group('whether what was typed was a number or a name', () {
    test('digits are a number', () {
      // Which box the seed lands in: somebody who typed "6210" was
      // reaching for a code, and somebody who typed "Printing" was
      // reaching for a name.
      expect(looksLikeAccountCode('6210'), isTrue);
      expect(looksLikeAccountCode(' 6210 '), isTrue);
      expect(looksLikeAccountCode('7'), isTrue);
    });

    test('anything else is a name', () {
      expect(looksLikeAccountCode('Printing'), isFalse);
      expect(looksLikeAccountCode('6210 Printing'), isFalse);
      expect(looksLikeAccountCode('6210-A'), isFalse);
      expect(looksLikeAccountCode(''), isFalse);
    });
  });

  group('the subtypes offered per kind', () {
    test('every kind has at least one, so the form always has an answer', () {
      // The dialog reads `accountSubtypes[_type]!.first` when the kind
      // changes; a kind with an empty list would throw.
      for (final entry in accountSubtypes.entries) {
        expect(entry.value, isNotEmpty, reason: entry.key);
      }
    });

    test('and none is offered under two kinds', () {
      // Offering all twenty-odd against every kind is how an expense
      // ends up filed as share capital and the balance sheet stops
      // making sense.
      final seen = <String>{};
      for (final subtypes in accountSubtypes.values) {
        for (final s in subtypes) {
          expect(seen.add(s), isTrue, reason: '$s is offered twice');
        }
      }
    });

    test('every kind a number can imply is a kind the form offers', () {
      // Otherwise a typed "1000" would set a kind the dropdown cannot
      // show, and the form would throw on the next rebuild.
      for (final code in ['1', '2', '3', '4', '5', '6']) {
        expect(accountSubtypes.containsKey(accountTypeFromCode(code)), isTrue,
            reason: code);
      }
    });
  });
}
