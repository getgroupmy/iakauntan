/// What the line under the register button says, and why it is not a
/// literal.
///
/// Asked for as: `By clicking "Register", you agree to iAkauntan's terms
/// of service and privacy policy.` Two words in that sentence are
/// settable from the console, and both would have been wrong on
/// somebody's deployment — so what is asserted here is mostly that they
/// follow what they name rather than what was typed once.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/auth/signup_consent.dart';

String said({
  String buttonLabel = 'Register',
  String brand = 'iAkauntan',
  Set<String> published = const {'terms-of-service', 'privacy'},
}) => signupConsentText(
  buttonLabel: buttonLabel,
  brand: brand,
  published: published,
);

void main() {
  group('the sentence', () {
    test('is the one that was asked for', () {
      expect(
        said(),
        'By clicking "Register", you agree to iAkauntan\'s terms of '
            'service and privacy policy.',
      );
    });

    test('quotes the button that is actually drawn', () {
      // `registerLabel` is settable from the console and the button
      // reads it, so the button says "Create account" out of the box.
      // A consent line quoting a button nobody can see reads as a
      // mistake, on the one sentence that has to describe the act it
      // is attached to.
      expect(said(buttonLabel: 'Create account'), contains('"Create account"'));
      expect(said(buttonLabel: 'Daftar'), contains('"Daftar"'));
      expect(said(buttonLabel: 'Create account'), isNot(contains('Register')));
    });

    test('names the platform, not this one', () {
      // White-labelled. A deployment that renamed itself must not tell
      // its customers they agreed to somebody else's terms.
      expect(said(brand: 'Sinar Books'), contains("Sinar Books'"));
      expect(said(brand: 'Sinar Books'), isNot(contains('iAkauntan')));
    });

    test('a plural name takes the apostrophe without a second s', () {
      // "Akauntans's" is what a naive join produces, on the one
      // sentence somebody may read closely.
      expect(possessive('Akauntans'), "Akauntans'");
      expect(possessive('iAkauntan'), "iAkauntan's");
      expect(possessive('BOOKS'), "BOOKS'");
    });

    test('an empty button label falls back rather than quoting nothing', () {
      // `By clicking "", you agree` is the shape of a console field
      // somebody cleared.
      expect(said(buttonLabel: '   '), contains('"Register"'));
    });

    test('an empty brand says "the terms" rather than a stray apostrophe', () {
      final line = said(brand: '  ');
      expect(line, isNot(contains("'s")));
      expect(line, contains('you agree to the terms of service'));
    });

    test('and it always ends in a full stop', () {
      for (final brand in ['iAkauntan', 'Books', '']) {
        expect(said(brand: brand), endsWith('.'), reason: brand);
      }
    });
  });

  group('what it links to', () {
    test('both pages, when both are published', () {
      final spans = signupConsent(
        buttonLabel: 'Register',
        brand: 'iAkauntan',
        published: const {'terms-of-service', 'privacy'},
      );
      final linked = {
        for (final s in spans)
          if (s.slug != null) s.slug!: s.text,
      };
      expect(linked, {
        'terms-of-service': 'terms of service',
        'privacy': 'privacy policy',
      });
    });

    test('an unpublished page is still NAMED, just not linked', () {
      // The deliberate half-measure. A link to an unpublished page
      // lands on "this page has not been written yet", which under a
      // sentence claiming the reader agreed to it is worse than no
      // link -- but dropping the words would quietly change what the
      // sentence says.
      final spans = signupConsent(
        buttonLabel: 'Register',
        brand: 'iAkauntan',
        published: const {'privacy'},
      );
      final terms = spans.firstWhere((s) => s.text == 'terms of service');
      expect(terms.slug, isNull);
      expect(
        said(published: const {'privacy'}),
        contains('terms of service'),
      );
    });

    test('neither published is still the whole sentence', () {
      expect(said(published: const {}), said());
      final spans = signupConsent(
        buttonLabel: 'Register',
        brand: 'iAkauntan',
        published: const {},
      );
      expect(spans.where((s) => s.slug != null), isEmpty);
    });

    test('the slugs are the ones the router serves', () {
      // The sentence points at `/terms-of-service` and `/privacy`.
      // These are the strings `router.dart` builds routes from and
      // `0651` put in the check constraint; a fourth name for the same
      // page is how a link starts 404ing.
      expect(consentSlugs, ['terms-of-service', 'privacy']);
    });

    test('and terms of USE is not one of them', () {
      // `/terms` is a different document. Linking a consent line to it
      // would have somebody agree to the rules for the website when
      // the sentence says the contract for the service.
      final spans = signupConsent(
        buttonLabel: 'Register',
        brand: 'iAkauntan',
        published: const {'terms', 'terms-of-service', 'privacy'},
      );
      expect(spans.map((s) => s.slug), isNot(contains('terms')));
    });
  });

  test('the spans join back into the sentence', () {
    // The screen draws the spans and the screen reader is handed the
    // string. If they could differ, one of the two would be wrong and
    // nothing would say which.
    final spans = signupConsent(
      buttonLabel: 'Daftar',
      brand: 'Sinar',
      published: const {'privacy'},
    );
    expect(
      spans.map((s) => s.text).join(),
      said(buttonLabel: 'Daftar', brand: 'Sinar', published: const {'privacy'}),
    );
  });
}
