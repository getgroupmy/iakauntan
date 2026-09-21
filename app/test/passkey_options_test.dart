/// The options a second enrolment sends, and the parser that refused them.
///
/// Reported from a phone: a passkey saved and working, "Save another
/// passkey" pressed, and a red banner saying the system sent something
/// the app could not read. `passkey_options.dart` explains the
/// mechanism; this asserts it, against the plugin's OWN parser rather
/// than against a description of it.
///
/// That distinction is the whole value of this file. An assertion that
/// checked only "the map now has a `transports` key" would pass with
/// the repair subtly wrong and keep passing after the plugin changed
/// its mind about what it needs. So every shape here is handed to
/// `RegisterRequestType.fromJson` and `AuthenticateRequestType.fromJson`,
/// which are the two functions that were throwing, and the assertion is
/// that they throw before the repair and do not throw after it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/auth/passkey_options.dart';
import 'package:passkeys_platform_interface/types/types.dart';

/// Registration options in the shape GoTrue sends them, with whatever
/// `excludeCredentials` is given.
Map<String, dynamic> registrationOptions({List<dynamic>? exclude}) => {
  'challenge': 'Q2hhbGxlbmdl',
  'rp': {'id': 'iakauntan.com', 'name': 'iAkauntan'},
  'user': {
    'id': 'dXNlci1pZA',
    'name': 'ahmad@iakauntan.test',
    'displayName': 'Ahmad',
  },
  'pubKeyCredParams': [
    {'type': 'public-key', 'alg': -7},
  ],
  if (exclude != null) 'excludeCredentials': exclude,
};

void main() {
  group('the credential entry that would not parse', () {
    test('a first enrolment has nothing to trip over', () {
      // The control, and it is the case that WORKED: with no
      // excludeCredentials there is no CredentialType to parse, which
      // is exactly why the fault only appeared on the second press.
      final raw = registrationOptions();
      expect(() => RegisterRequestType.fromJson(raw), returnsNormally);

      final fixed = passkeyOptionsForPlugin(raw);
      expect(fixed.notes, isEmpty);
      expect(() => RegisterRequestType.fromJson(fixed.options), returnsNormally);
    });

    test('an entry with no transports throws before the repair', () {
      // `transports` is a HINT in the WebAuthn specification and a
      // server that does not know it is supposed to leave it out. The
      // plugin's generated parser casts it unconditionally.
      final raw = registrationOptions(
        exclude: [
          {'type': 'public-key', 'id': 'Y3JlZC1vbmU'},
        ],
      );
      expect(() => RegisterRequestType.fromJson(raw), throwsA(isA<TypeError>()));

      final fixed = passkeyOptionsForPlugin(raw);
      expect(() => RegisterRequestType.fromJson(fixed.options), returnsNormally);
      expect(
        fixed.notes,
        contains('an entry in excludeCredentials had no transports; '
            'sent an empty list'),
      );
    });

    test('and the repaired entry still names the same credential', () {
      // The repair must not quietly lose the thing the list is FOR. An
      // excludeCredentials that arrives empty stops the authenticator
      // refusing a duplicate, which is the failure this whole exercise
      // is not allowed to introduce.
      final fixed = passkeyOptionsForPlugin(
        registrationOptions(
          exclude: [
            {'type': 'public-key', 'id': 'Y3JlZC1vbmU'},
          ],
        ),
      );
      final request = RegisterRequestType.fromJson(fixed.options);
      expect(request.excludeCredentials, hasLength(1));
      expect(request.excludeCredentials.single.id, 'Y3JlZC1vbmU');
      expect(request.excludeCredentials.single.type, 'public-key');
      expect(request.excludeCredentials.single.transports, isEmpty);
    });

    test('an entry with no type throws too, and is given the only one', () {
      final raw = registrationOptions(
        exclude: [
          {'id': 'Y3JlZC1vbmU', 'transports': <String>['internal']},
        ],
      );
      expect(() => RegisterRequestType.fromJson(raw), throwsA(isA<TypeError>()));

      final fixed = passkeyOptionsForPlugin(raw);
      final request = RegisterRequestType.fromJson(fixed.options);
      expect(request.excludeCredentials.single.type, 'public-key');
      // And the transports it DID send survive.
      expect(request.excludeCredentials.single.transports, ['internal']);
    });

    test('several entries are each repaired', () {
      final fixed = passkeyOptionsForPlugin(
        registrationOptions(
          exclude: [
            {'id': 'b25l'},
            {'id': 'dHdv', 'type': 'public-key'},
            {'id': 'dGhyZWU', 'transports': <String>['hybrid']},
          ],
        ),
      );
      final request = RegisterRequestType.fromJson(fixed.options);
      expect(
        request.excludeCredentials.map((c) => c.id),
        ['b25l', 'dHdv', 'dGhyZWU'],
      );
    });
  });

  group('the alphabet the plugin insists on', () {
    test('standard base64 becomes base64url, same bytes', () {
      // `+` and `/` are the same bytes in a different alphabet, so this
      // is a re-encoding and not a change of meaning. A credential id
      // is opaque; what matters is that the server gets back what it
      // sent, which it does because the platform echoes these bytes.
      expect(asPasskeyBase64Url('ab+cd/ef=='), 'ab-cd_ef');
      expect(asPasskeyBase64Url('ab-cd_ef'), 'ab-cd_ef');
    });

    test('an id already in the right alphabet is untouched', () {
      // The identity property, which is what makes it safe to run this
      // over every field of every request unconditionally.
      const ids = ['Y3JlZA', 'a-b_c', 'AAAA', '0123456789'];
      for (final id in ids) {
        expect(asPasskeyBase64Url(id), id, reason: id);
      }
    });

    test('the validator agrees with the plugin, including on empty', () {
      // Worth an assertion because it is the surprising one: the
      // plugin's regex requires at least one character, so an EMPTY id
      // is malformed rather than absent -- and an empty string is what
      // a missing field becomes in the same parser.
      expect(isPasskeyBase64Url(''), isFalse);
      expect(isPasskeyBase64Url('abc'), isTrue);
      expect(isPasskeyBase64Url('a+b'), isFalse);
      expect(isPasskeyBase64Url('a='), isFalse);
      expect(isPasskeyBase64Url('a=', allowPadding: true), isTrue);
      expect(isPasskeyBase64Url('a===', allowPadding: true), isFalse);
    });

    test('a challenge in the wrong alphabet is converted, not dropped', () {
      final fixed = passkeyOptionsForPlugin({
        ...registrationOptions(),
        'challenge': 'Q2hh+Gxl/2dl==',
      });
      expect(fixed.options['challenge'], 'Q2hh-Gxl_2dl');
      expect(fixed.notes, contains('the challenge was not base64url and '
          'was converted'));
    });

    test('so is the user id', () {
      final fixed = passkeyOptionsForPlugin({
        ...registrationOptions(),
        'user': {'id': 'dXNl+i1p/A==', 'name': 'a', 'displayName': 'b'},
      });
      expect((fixed.options['user'] as Map)['id'], 'dXNl-i1p_A');
    });

    test('an id that is still unreadable is dropped, not thrown', () {
      // The trade, stated in passkey_options.dart: excludeCredentials
      // is an optimisation and the ceremony is the feature. Losing an
      // entry risks a duplicate credential somebody can delete; keeping
      // it loses enrolment entirely.
      final fixed = passkeyOptionsForPlugin(
        registrationOptions(
          exclude: [
            {'id': 'has spaces and !', 'type': 'public-key'},
            {'id': 'Z29vZA', 'type': 'public-key'},
          ],
        ),
      );
      final request = RegisterRequestType.fromJson(fixed.options);
      expect(request.excludeCredentials.map((c) => c.id), ['Z29vZA']);
      expect(
        fixed.notes,
        contains('excludeCredentials held an id that is not base64url; '
            'dropped'),
      );
    });

    test('a list that loses everything is removed rather than emptied', () {
      final fixed = passkeyOptionsForPlugin(
        registrationOptions(exclude: [
          {'id': 'not valid!'},
        ]),
      );
      expect(fixed.options.containsKey('excludeCredentials'), isFalse);
      expect(() => RegisterRequestType.fromJson(fixed.options), returnsNormally);
    });
  });

  group('the sign-in half, which has the same parser', () {
    Map<String, dynamic> authOptions({List<dynamic>? allow}) => {
      'challenge': 'Q2hhbGxlbmdl',
      'rpId': 'iakauntan.com',
      if (allow != null) 'allowCredentials': allow,
    };

    test('allowCredentials without transports throws the same way', () {
      // It has not fired in production because GoTrue's sign-in options
      // use discoverable credentials and send no list. It is the same
      // defect waiting for the day somebody turns that on.
      final raw = authOptions(
        allow: [
          {'type': 'public-key', 'id': 'Y3JlZC1vbmU'},
        ],
      );
      expect(
        () => AuthenticateRequestType.fromJson(raw),
        throwsA(isA<TypeError>()),
      );

      final fixed = passkeyOptionsForPlugin(raw);
      final request = AuthenticateRequestType.fromJson(fixed.options);
      expect(request.allowCredentials, hasLength(1));
      expect(request.allowCredentials!.single.id, 'Y3JlZC1vbmU');
    });

    test('an empty sign-in list means offer anything, which is the default',
        () {
      final fixed = passkeyOptionsForPlugin(authOptions(allow: []));
      expect(fixed.options.containsKey('allowCredentials'), isFalse);
      final request = AuthenticateRequestType.fromJson(fixed.options);
      expect(request.allowCredentials, isNull);
    });
  });

  group('what it refuses to invent', () {
    test('the caller\'s map is not modified', () {
      // The caller holds a response object. A function that rewrote it
      // would make a retry behave differently from the first attempt,
      // for no reason visible at the call site.
      //
      // Asserted at BOTH levels. The first version of this checked only
      // the nested entry, and a mutant that replaced the top-level copy
      // with the caller's own map survived it: the entries were still
      // copied, so the assertion could not see the difference. The
      // top-level fields are the ones this rewrites in place.
      final raw = {
        ...registrationOptions(
          exclude: [
            {'id': 'Y3JlZA'},
          ],
        ),
        'challenge': 'Q2hh+Gxl/2dl==',
        'user': {'id': 'dXNl+i1p/A==', 'name': 'a', 'displayName': 'b'},
      };
      final before = (raw['excludeCredentials']! as List).first as Map;
      final keys = raw.keys.toList();

      final fixed = passkeyOptionsForPlugin(raw);

      expect(before.containsKey('transports'), isFalse);
      expect(before.containsKey('type'), isFalse);
      expect(raw['challenge'], 'Q2hh+Gxl/2dl==');
      expect((raw['user']! as Map)['id'], 'dXNl+i1p/A==');
      expect(raw.keys, keys);
      expect((raw['excludeCredentials']! as List), hasLength(1));

      // And the copy really did change, so the assertions above are
      // about a repair that happened rather than one that did not.
      expect(fixed.options['challenge'], 'Q2hh-Gxl_2dl');
    });

    test('a missing challenge stays missing', () {
      // Not invented. A server that sends no challenge is broken in a
      // way this must not paper over -- the plugin's own exception is
      // the right answer, and it now says which field.
      final fixed = passkeyOptionsForPlugin({'rp': {}, 'user': {}});
      expect(fixed.options.containsKey('challenge'), isFalse);
    });

    test('an entry with no id at all is dropped rather than given one', () {
      final fixed = passkeyOptionsForPlugin(
        registrationOptions(
          exclude: [
            {'type': 'public-key', 'transports': <String>[]},
          ],
        ),
      );
      expect(fixed.options.containsKey('excludeCredentials'), isFalse);
      expect(
        fixed.notes,
        contains('excludeCredentials held an entry with no id; dropped'),
      );
    });

    test('a list holding something that is not an object', () {
      final fixed = passkeyOptionsForPlugin(
        registrationOptions(exclude: ['nonsense', 42]),
      );
      expect(fixed.options.containsKey('excludeCredentials'), isFalse);
      expect(fixed.notes, hasLength(2));
    });

    test('transports holding something that is not a string', () {
      final fixed = passkeyOptionsForPlugin(
        registrationOptions(
          exclude: [
            {
              'id': 'Y3JlZA',
              'type': 'public-key',
              'transports': ['internal', 7, null],
            },
          ],
        ),
      );
      final request = RegisterRequestType.fromJson(fixed.options);
      expect(request.excludeCredentials.single.transports, ['internal']);
    });
  });
}
