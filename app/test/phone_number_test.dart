import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/auth/phone_number.dart';

/// The mobile number somebody registers with, and the zero in front of
/// it.
///
/// A Malaysian writes their number 012-345 6789. The zero is a trunk
/// prefix — "a call inside this country" — and is not part of the
/// number: with the country code in front it is +60 12 345 6789. Keep
/// the zero and the stored number is +600123456789, which nothing can
/// dial, and nothing says so. The field accepted it, the profile stored
/// it, and a message one day is not delivered.
///
/// The same rules are in `app.phone_e164` and asserted in
/// `supabase/tests/signup_details.sql`. These are the screen's half:
/// what it refuses before anything is sent, and what it tells somebody
/// it is about to do to what they typed.
void main() {
  group('the zero that is not part of the number', () {
    test('comes off', () {
      expect(e164(dialCode: '60', number: '0123456789'), '+60123456789');
      // The assertion this file exists for: the answer must not be
      // +600123456789, which is what leaving the zero produces and
      // which every other assertion here would still pass.
      expect(
        e164(dialCode: '60', number: '0123456789'),
        isNot(startsWith('+600')),
      );
    });

    test('and a number written without one is unchanged', () {
      expect(e164(dialCode: '60', number: '123456789'), '+60123456789');
    });

    test('two zeros are two zeros', () {
      // Somebody who typed it twice. One zero left in front is the same
      // wrong number as two.
      expect(nationalNumber('00123456789'), '123456789');
    });

    test('and the punctuation people write is decoration', () {
      expect(
        e164(dialCode: '+60', number: '(012) 345-6789'),
        '+60123456789',
      );
      expect(phoneDigits('012-345 6789'), '0123456789');
    });

    test('the same rule anywhere else', () {
      expect(e164(dialCode: '44', number: '07911 123456'), '+447911123456');
    });
  });

  group('what is not a number', () {
    test('an empty box is nothing rather than a plus', () {
      expect(e164(dialCode: '60', number: ''), isNull);
      expect(e164(dialCode: '60', number: '000'), isNull);
      expect(e164(dialCode: '', number: '123456789'), isNull);
    });

    test('and the form says so before anything is sent', () {
      expect(phoneError(dialCode: '60', number: ''), isNotNull);
      expect(phoneError(dialCode: '60', number: '00'), isNotNull);
      expect(phoneError(dialCode: '60', number: '12345'), contains('short'));
      expect(
        phoneError(dialCode: '60', number: '1234567890123456'),
        contains('long'),
      );
    });

    test('a real number passes', () {
      expect(phoneError(dialCode: '60', number: '012-345 6789'), isNull);
      expect(phoneError(dialCode: '65', number: '9123 4567'), isNull);
    });

    test('and it is required, along with everything else on that form', () {
      // "Make all compulsory". A registration that takes a number when
      // it feels like it is a profile that is half empty.
      expect(phoneError(dialCode: '60', number: ''), isNotNull);
      expect(salutationError(null), isNotNull);
      expect(salutationError('  '), isNotNull);
      expect(salutationError("Dato' Sri"), isNull);
    });
  });

  group('what the form says it is about to do', () {
    test('shows the number that will be stored when a zero was typed', () {
      final note = phoneNote(dialCode: '60', number: '0123456789');
      expect(note, isNotNull);
      expect(note, contains('+60123456789'));
    });

    test('and says nothing when there is nothing to say', () {
      // Removing the zero silently is how a form gets accused of losing
      // a digit; saying it about a number that never had one is noise.
      expect(phoneNote(dialCode: '60', number: '123456789'), isNull);
      expect(phoneNote(dialCode: '60', number: ''), isNull);
    });

    test('the boxes are labelled', () {
      expect(phoneFieldLabel.toLowerCase(), contains('mobile'));
      expect(salutationFieldLabel, 'Title');
      expect(homeDialCode, '60');
    });
  });

  group('the two lists', () {
    final countries = [
      {'code': 'MYS', 'name': 'Malaysia', 'alpha2': 'MY', 'dial_code': '+60'},
      {'code': 'SGP', 'name': 'Singapore', 'alpha2': 'SG', 'dial_code': '+65'},
      {'code': 'XXX', 'name': 'Nowhere', 'alpha2': 'XX', 'dial_code': null},
    ];

    test('a country with no dialling code cannot be picked', () {
      // Picking it would build a number with no country in it.
      final shown = withDialCodes(countries);
      expect(shown.length, 2);
      expect(shown.map((c) => c['code']), isNot(contains('XXX')));
    });

    test('and reads as the code first, which is what people look for', () {
      expect(dialCodeLabel(countries.first), '+60 Malaysia');
    });

    test('and the second line says which kind of title it is', () {
      expect(
        salutationSublabel(
            {'name': 'Ir', 'grouping': 'Professional', 'note': 'Engineer'}),
        'Professional · Engineer',
      );
      expect(
        salutationSublabel({'name': 'Mr', 'grouping': 'Common', 'note': null}),
        'Common',
      );
    });

  });
}
