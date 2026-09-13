import 'package:flutter_test/flutter_test.dart';
import 'package:passkeys/types.dart';

import 'package:iakauntan/src/features/auth/passkey_failure.dart';
import 'package:iakauntan/src/features/auth/passkey_mobile.dart';

/// The phone half, and the assumption it rests on.
///
/// The ceremony needs a handset, so it cannot be asserted here. What
/// CAN be asserted is the claim that makes `passkey_mobile.dart` five
/// lines instead of five hundred: that the plugin's request and
/// response types already speak the JSON GoTrue speaks, so nothing
/// converts base64url by hand on the sign-in path.
///
/// That is an assumption about somebody else's package, which is
/// exactly the kind that stops being true at a version bump and does so
/// silently — a signature that will not verify looks, from the sign-in
/// screen, like a passkey that stopped working. These tests fail
/// instead.
void main() {
  // What GoTrue's `startAuthentication` hands back: a W3C
  // `PublicKeyCredentialRequestOptionsJSON`, base64url without padding,
  // and — the part that matters — credential descriptors with no
  // `transports`, because WebAuthn marks that field optional.
  Map<String, dynamic> gotrueRequestOptions() => {
    'challenge': 'w6uP8Tcg6K2QR905Rms8iXTlksL6OD1KOWBxTK7wxPI',
    'rpId': 'iakauntan.com',
    'timeout': 60000,
    'userVerification': 'preferred',
    'allowCredentials': [
      {'type': 'public-key', 'id': 'AQIDBAUGBwgJCgsMDQ4PEA'},
    ],
  };

  group('the request GoTrue sends', () {
    test('survives the plugin unchanged', () {
      final request = AuthenticateRequestType.fromJson(
        pluginOptions(gotrueRequestOptions(), creating: false),
        preferImmediatelyAvailableCredentials: false,
      );

      // Every field that the signature is computed over. A challenge
      // that arrives altered is a ceremony that cannot verify.
      expect(request.challenge, 'w6uP8Tcg6K2QR905Rms8iXTlksL6OD1KOWBxTK7wxPI');
      expect(request.relyingPartyId, 'iakauntan.com');
      expect(request.userVerification, 'preferred');
      expect(request.timeout, 60000);
      expect(request.allowCredentials, hasLength(1));
      expect(request.allowCredentials!.single.id, 'AQIDBAUGBwgJCgsMDQ4PEA');
    });

    test('and the challenge is not re-encoded on the way through', () {
      // Unpadded in, unpadded out. The plugin documents the challenge
      // as base64url WITHOUT padding and the user id as WITH, which is
      // the sort of detail that invites somebody to "fix" one of them.
      final request = AuthenticateRequestType.fromJson(
        pluginOptions(gotrueRequestOptions(), creating: false),
        preferImmediatelyAvailableCredentials: false,
      );
      expect(request.toJson()['challenge'], isNot(contains('=')));
      expect(request.toJson()['challenge'], request.challenge);
    });

    test('but only after transports are filled in', () {
      // The bug this guards, asserted in both directions because the
      // guard is invisible otherwise. `CredentialType.fromJson` is
      // generated code that casts `transports` with `as List<dynamic>`,
      // and WebAuthn marks that field optional — so GoTrue's own
      // descriptors throw a TypeError, which is not an
      // AuthenticatorException and would escape the sign-in handler as
      // a crash rather than a message.
      expect(
        () => AuthenticateRequestType.fromJson(
          gotrueRequestOptions(),
          preferImmediatelyAvailableCredentials: false,
        ),
        throwsA(isA<TypeError>()),
        reason:
            'if this stops throwing the plugin has been fixed and '
            'pluginOptions can go',
      );

      expect(
        () => AuthenticateRequestType.fromJson(
          pluginOptions(gotrueRequestOptions(), creating: false),
          preferImmediatelyAvailableCredentials: false,
        ),
        returnsNormally,
      );
    });

    test('and an absent transports becomes empty, not a guess', () {
      // Empty means the same thing to both platforms as absent: no
      // hint about how to reach this credential. Inventing `internal`
      // or `hybrid` here would be telling the system something nobody
      // knows.
      final filled = pluginOptions(gotrueRequestOptions(), creating: false);
      final descriptor =
          (filled['allowCredentials'] as List).single as Map<String, dynamic>;
      expect(descriptor['transports'], isEmpty);
      expect(descriptor['id'], 'AQIDBAUGBwgJCgsMDQ4PEA');
    });

    test('and a transports the server did send is left alone', () {
      final options = gotrueRequestOptions();
      options['allowCredentials'] = [
        {
          'type': 'public-key',
          'id': 'AQIDBAUGBwgJCgsMDQ4PEA',
          'transports': ['internal', 'hybrid'],
        },
      ];
      final filled = pluginOptions(options, creating: false);
      final descriptor =
          (filled['allowCredentials'] as List).single as Map<String, dynamic>;
      expect(descriptor['transports'], ['internal', 'hybrid']);
    });
  });

  group('the response the device gives back', () {
    test('is already an AuthenticationResponseJSON', () {
      // The shape `verifyAuthentication` wants: identifiers at the top,
      // the three signed pieces nested under `response`, and a `type`
      // of `public-key`.
      final json = AuthenticateResponseType(
        id: 'AQIDBAUGBwgJCgsMDQ4PEA',
        rawId: 'AQIDBAUGBwgJCgsMDQ4PEA',
        clientDataJSON: 'eyJ0eXBlIjoid2ViYXV0aG4uZ2V0In0',
        authenticatorData: 'SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2M',
        signature: 'MEUCIQD',
        userHandle: 'dXNlci1pZA',
      ).toJson();

      expect(json['type'], 'public-key');
      expect(json['id'], 'AQIDBAUGBwgJCgsMDQ4PEA');
      expect(json['rawId'], 'AQIDBAUGBwgJCgsMDQ4PEA');
      expect(json['clientExtensionResults'], isA<Map<String, dynamic>>());

      final response = json['response'] as Map<String, dynamic>;
      expect(response['clientDataJSON'], 'eyJ0eXBlIjoid2ViYXV0aG4uZ2V0In0');
      expect(
        response['authenticatorData'],
        'SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2M',
      );
      expect(response['signature'], 'MEUCIQD');
      expect(response['userHandle'], 'dXNlci1pZA');
    });

    test('and omits userHandle rather than sending an empty one', () {
      // An empty string is not a user handle, and a verifier that
      // takes it at its word is looking up an account named "".
      final json = AuthenticateResponseType(
        id: 'AQIDBAUGBwgJCgsMDQ4PEA',
        rawId: 'AQIDBAUGBwgJCgsMDQ4PEA',
        clientDataJSON: 'eyJ0eXBlIjoid2ViYXV0aG4uZ2V0In0',
        authenticatorData: 'SZYN5YgO',
        signature: 'MEUCIQD',
        userHandle: '',
      ).toJson();

      expect(
        (json['response'] as Map<String, dynamic>).containsKey('userHandle'),
        isFalse,
      );
    });
  });

  group('enrolment options', () {
    test('carry an unpadded user id through, as GoTrue sends it', () {
      // The plugin documents `user.id` as padded and its validator
      // allows both. Asserted because the doc comment says otherwise
      // and somebody will one day add the padding to match it.
      final request = RegisterRequestType.fromJson(
        pluginOptions({
          'challenge': 'w6uP8Tcg6K2QR905Rms8iXTlksL6OD1KOWBxTK7wxPI',
          'rp': {'id': 'iakauntan.com', 'name': 'iAkauntan'},
          'user': {
            'id': 'dXNlci1pZA',
            'name': 'someone@example.test',
            'displayName': 'Someone',
          },
          'pubKeyCredParams': [
            {'type': 'public-key', 'alg': -7},
          ],
        }, creating: true),
      );

      expect(request.user.id, 'dXNlci1pZA');
      expect(request.user.id, isNot(contains('=')));
      expect(request.relyingParty.id, 'iakauntan.com');
      expect(request.excludeCredentials, isEmpty);
    });
  });

  group('this build', () {
    test('is not a phone, and says so', () {
      // The test runner is the Dart VM on Linux. This file is selected
      // by `dart.library.io`, which includes it, so the answer has to
      // be a runtime one — a compile-time true here would be a sign-in
      // button drawn on a desktop that cannot honour it.
      expect(passkeysAvailable, isFalse);
    });

    test(
      'and refuses the ceremony rather than reaching for a channel',
      () async {
        // No platform channel exists under the test runner. Returning
        // null is what keeps this a decision rather than a MissingPlugin
        // crash.
        expect(await getPasskeyAssertion(gotrueRequestOptions()), isNull);
        expect(await createPasskeyCredential(const {}), isNull);
      },
    );
  });

  group('a stated failure', () {
    test('carries the sentence rather than a code', () {
      // The whole reason `PasskeyFailure` exists: a domain that is not
      // associated is otherwise a button that silently does nothing,
      // which is the worst way to present a build-configuration
      // mistake.
      const failure = PasskeyFailure('This app is not set up for passkeys.');
      expect(failure.message, 'This app is not set up for passkeys.');
      expect(failure.toString(), contains('This app is not set up'));
    });
  });
}
