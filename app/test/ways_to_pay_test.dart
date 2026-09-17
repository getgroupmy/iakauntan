import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/settings/ways_to_pay.dart';

/// How a company is told what it may pay with.
///
/// The screen this backs had one button wired to Billplz and drew it
/// for every outstanding invoice. What is asserted here is mostly the
/// other branch — what the screen says when this app cannot start the
/// payment — because that is the sentence somebody acts on by picking
/// up the phone, and the old screen never said it.
Map<String, dynamic> gateway({
  String code = 'billplz',
  String name = 'Billplz',
  List<String>? methods,
  List<String>? countries,
  String? instructions,
  String? docs,
}) => {
      'code': code,
      'name': name,
      if (methods != null) 'methods': methods,
      if (countries != null) 'countries': countries,
      'instructions': instructions,
      'docs_url': docs,
    };

void main() {
  group('the rails a gateway carries', () {
    test('are read in the order somebody looks for them', () {
      // Stored sorted, because 0352 normalises. Sorted opens on
      // `bank_transfer`; in Malaysia the answer being looked for is FPX.
      final row = gateway(methods: ['bank_transfer', 'card', 'fpx']);

      expect(methodsOf(row), ['fpx', 'card', 'bank_transfer']);
      expect(methodsLine(row), 'FPX · Card · Bank transfer');
    });

    test('and one nobody has taught this screen about is still shown', () {
      // A method added by a later migration should look unpolished
      // here, not vanish. Vanishing is how a shop finds out from a
      // customer.
      final row = gateway(methods: ['card', 'crypto']);

      expect(methodsOf(row), ['card', 'crypto']);
      expect(methodsLine(row), contains('crypto'));
    });

    test('a gateway that says nothing about them takes up no line', () {
      expect(methodsLine(gateway()), '');
      expect(methodsLine(gateway(methods: [])), '');
    });

    test('each rail has a name a person would use', () {
      expect(methodLabel('fpx'), 'FPX');
      expect(methodLabel('ewallet'), 'E-wallet');
      expect(methodLabel('over_counter'), 'Over the counter');
      expect(methodLabel('bnpl'), 'Buy now, pay later');
    });
  });

  group('where a gateway sells', () {
    test('is listed when it is a list', () {
      expect(coverageLabel(gateway(countries: ['MY', 'SG'])), 'MY · SG');
    });

    test('and an empty list says everywhere rather than nothing', () {
      // 0352 makes `{}` mean "sells everywhere". Printing nothing would
      // send an operator looking for a list left empty on purpose.
      expect(coverageLabel(gateway(countries: [])), 'Everywhere');
      expect(coverageLabel(gateway()), 'Everywhere');
    });
  });

  group('whether this app can start the payment', () {
    test('it can, when the gateway is the one it has code for', () {
      final rows = [gateway(code: 'toyyibpay'), gateway(code: 'billplz')];

      expect(hostedCheckout(rows)?['code'], 'billplz');
      expect(payByHandBecause(rows), isNull);
    });

    test('and it cannot, when the platform switched on something else', () {
      // The defect this closes: the Pay button called `billplz-checkout`
      // whatever was switched on, so an operator who set up toyyibPay
      // gave every tenant a button that failed on missing credentials.
      final rows = [gateway(code: 'toyyibpay', name: 'toyyibPay')];

      expect(hostedCheckout(rows), isNull);
      expect(payByHandBecause(rows), contains('toyyibPay'));
    });

    test('and it names all of them, not the first', () {
      final rows = [
        gateway(code: 'toyyibpay', name: 'toyyibPay'),
        gateway(code: 'ipay88', name: 'iPay88'),
      ];

      final said = payByHandBecause(rows)!;
      expect(said, contains('toyyibPay'));
      expect(said, contains('iPay88'));
    });

    test('with nothing switched on it says so, and does not name nobody', () {
      final said = payByHandBecause(const [])!;

      expect(said, contains('No online payment is set up'));
      expect(said, contains('Get in touch'));
      expect(said, isNot(contains('through ')));
    });
  });

  group('what an operator left on a gateway', () {
    test('a note is kept when there is one', () {
      expect(instructionsOf(gateway(instructions: 'Ask Aida.')), 'Ask Aida.');
    });

    test('and a cleared field is nothing, not an empty line', () {
      // A cleared TextField sends '', and `''` drawn as a paragraph is
      // a blank row on the screen with no explanation.
      expect(instructionsOf(gateway(instructions: '')), isNull);
      expect(instructionsOf(gateway(instructions: '   ')), isNull);
      expect(instructionsOf(gateway()), isNull);
    });

    test('a documentation link is followed only when it is https', () {
      expect(
        docsUrlOf(gateway(docs: 'https://ipay88.com/docs')),
        'https://ipay88.com/docs',
      );
      expect(docsUrlOf(gateway(docs: 'http://ipay88.com/docs')), isNull);
      expect(docsUrlOf(gateway(docs: 'ipay88.com/docs')), isNull);
      expect(docsUrlOf(gateway()), isNull);
    });
  });

  group('a list typed into a console field', () {
    test('splits on commas and on spaces, because both get typed', () {
      expect(splitCodes('MY, SG'), ['MY', 'SG']);
      expect(splitCodes('MY SG'), ['MY', 'SG']);
      expect(splitCodes(' MY ,  SG , '), ['MY', 'SG']);
    });

    test('and is not normalised here, because the database does that', () {
      // Upper-casing and sorting live in 0352. A second implementation
      // in Dart is a second thing to keep in step, and the one that
      // decides is the one the row goes through.
      expect(splitCodes('my,sg'), ['my', 'sg']);
      expect(splitCodes('SG,MY'), ['SG', 'MY']);
    });

    test('an emptied field is an empty list, and an absent one is null', () {
      // The distinction the save depends on: `[]` says "sells
      // everywhere" and null says "leave this column alone". Collapsing
      // them would empty the coverage list of every gateway somebody
      // merely switched on.
      expect(splitCodes(''), isEmpty);
      expect(splitCodes('   '), isEmpty);
      expect(splitCodes(null), isNull);
    });
  });
}
