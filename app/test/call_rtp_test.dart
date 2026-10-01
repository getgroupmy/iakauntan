import 'package:flutter_test/flutter_test.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';

import 'package:iakauntan/src/features/chat/call_rtp.dart';

/// The five lines that made every incoming camera sideways.
///
/// `RtpCapabilities.toMap()` in `mediasfu_mediasoup_client 0.1.4`
/// serialises the codecs and silently drops `headerExtensions` and
/// `fecMechanisms`. A mediasoup client sends that set once, at `join`,
/// and it is what the server uses to decide what each CONSUMER may
/// carry — so sending no extensions had the server strip every
/// extension from every stream this device received, including
/// `urn:3gpp:video-orientation`, which is the only thing that tells a
/// receiver which way up a phone was held.
///
/// THE FIRST TEST IS THE WHOLE POINT. It asserts the package's own
/// `toMap` loses the extensions — not to criticise the package, but
/// because that is the premise everything else here rests on. If a later
/// version of the package fixes it, that test fails, and the failure is
/// the notice that `rtpCapabilitiesToMap` can go.
void main() {
  RtpHeaderExtension ext(
    String uri, {
    int? id = 1,
    RTCRtpMediaType? kind = RTCRtpMediaType.RTCRtpMediaTypeVideo,
    RtpHeaderDirection? direction,
    bool? encrypt,
  }) => RtpHeaderExtension(
    kind: kind,
    uri: uri,
    preferredId: id,
    preferredEncrypt: encrypt,
    direction: direction,
  );

  RtpCodecCapability codec() => RtpCodecCapability(
    kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
    mimeType: 'video/VP8',
    clockRate: 90000,
    preferredPayloadType: 96,
    parameters: const {},
    rtcpFeedback: const [],
  );

  List<Map<String, dynamic>> extensionsOf(Map<String, dynamic> map) =>
      (map['headerExtensions'] as List).cast<Map<String, dynamic>>();

  group('the premise', () {
    test('the package\'s own toMap drops every header extension', () {
      final caps = RtpCapabilities(
        codecs: [codec()],
        headerExtensions: [ext(videoOrientationUri, id: 4)],
        fecMechanisms: const ['flexfec'],
      );

      // If this ever fails, the package has been fixed and
      // `rtpCapabilitiesToMap` is no longer needed. That is the only
      // reason this assertion is phrased about somebody else's code.
      expect(caps.toMap().containsKey('headerExtensions'), isFalse);
      expect(caps.toMap().containsKey('fecMechanisms'), isFalse);
      expect(caps.toMap().keys, ['codecs']);
    });
  });

  group('rtpCapabilitiesToMap', () {
    test('carries the video orientation extension, which is the whole bug', () {
      final map = rtpCapabilitiesToMap(
        RtpCapabilities(codecs: [codec()], headerExtensions: [
          ext(videoOrientationUri, id: 4),
        ]),
      );

      expect(extensionsOf(map).single['uri'], videoOrientationUri);
      expect(extensionsOf(map).single['preferredId'], 4);
    });

    test('and the codecs, unchanged', () {
      // The half the package got right must keep working: a capability
      // set with extensions and no codecs is refused by the server.
      final map = rtpCapabilitiesToMap(
        RtpCapabilities(codecs: [codec()], headerExtensions: [ext('urn:x')]),
      );

      final codecs = (map['codecs'] as List).cast<Map<String, dynamic>>();
      expect(codecs.single['mimeType'], 'video/VP8');
      expect(codecs.single['preferredPayloadType'], 96);
    });

    test('and the fec mechanisms, which were dropped with them', () {
      final map = rtpCapabilitiesToMap(
        RtpCapabilities(codecs: [codec()], fecMechanisms: const ['flexfec']),
      );

      expect(map['fecMechanisms'], ['flexfec']);
    });

    test('every extension, not merely the one being hunted', () {
      // Transport-wide congestion control and abs-send-time were being
      // stripped by the same omission. Nothing visible went wrong, which
      // is exactly why nobody looked.
      final map = rtpCapabilitiesToMap(
        RtpCapabilities(codecs: [codec()], headerExtensions: [
          ext('urn:ietf:params:rtp-hdrext:sdes:mid', id: 1),
          ext('http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time',
              id: 2),
          ext('http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01',
              id: 3),
          ext(videoOrientationUri, id: 4),
        ]),
      );

      expect(
        extensionsOf(map).map((e) => e['uri']),
        containsAll(<String>[videoOrientationUri, 'urn:ietf:params:rtp-hdrext:sdes:mid']),
      );
      expect(extensionsOf(map), hasLength(4));
    });

    group('and refuses to send what the server would reject', () {
      // A rejected capability set is not a sideways picture. It is a
      // refused `join`, which is no call at all — so the filter matters
      // more than the extension it is protecting.
      test('an extension with no uri', () {
        final map = rtpCapabilitiesToMap(
          RtpCapabilities(codecs: [codec()], headerExtensions: [
            ext('', id: 9),
            ext(videoOrientationUri, id: 4),
          ]),
        );

        expect(extensionsOf(map), hasLength(1));
        expect(extensionsOf(map).single['uri'], videoOrientationUri);
      });

      test('an extension with no preferred id', () {
        final map = rtpCapabilitiesToMap(
          RtpCapabilities(codecs: [codec()], headerExtensions: [
            ext('urn:x', id: null),
            ext(videoOrientationUri, id: 4),
          ]),
        );

        expect(extensionsOf(map), hasLength(1));
      });

      test('and a kind of `data`, which is not a kind an extension has', () {
        // `RTCRtpMediaType` has three values because it describes a
        // track; mediasoup takes `audio`, `video` or nothing on an
        // extension and refuses the rest.
        final map = rtpCapabilitiesToMap(
          RtpCapabilities(codecs: [codec()], headerExtensions: [
            ext('urn:x', kind: RTCRtpMediaType.RTCRtpMediaTypeData),
            ext(videoOrientationUri, id: 4),
          ]),
        );

        expect(extensionsOf(map), hasLength(1));
        expect(extensionsOf(map).single['uri'], videoOrientationUri);
      });
    });

    group('the fields the server reads', () {
      test('a null kind is left out rather than sent as null', () {
        // An extension with no kind is valid and means "any". Sending
        // `kind: null` is not the same thing and is refused.
        final map = rtpCapabilitiesToMap(
          RtpCapabilities(codecs: [codec()],
              headerExtensions: [ext(videoOrientationUri, kind: null)]),
        );

        expect(extensionsOf(map).single.containsKey('kind'), isFalse);
        expect(extensionsOf(map).single['uri'], videoOrientationUri);
      });

      test('a kind is spelled the way the wire spells it', () {
        final map = rtpCapabilitiesToMap(
          RtpCapabilities(codecs: [codec()], headerExtensions: [
            ext('urn:a', kind: RTCRtpMediaType.RTCRtpMediaTypeAudio),
            ext('urn:v', id: 2),
          ]),
        );

        expect(extensionsOf(map).map((e) => e['kind']), ['audio', 'video']);
      });

      test('direction defaults to sendrecv, not to null', () {
        final map = rtpCapabilitiesToMap(
          RtpCapabilities(codecs: [codec()], headerExtensions: [
            ext(videoOrientationUri),
            ext('urn:x', id: 2, direction: RtpHeaderDirection.RecvOnly),
          ]),
        );

        expect(extensionsOf(map).map((e) => e['direction']),
            ['sendrecv', 'recvonly']);
      });

      test('and encrypt defaults to false, not to null', () {
        final map = rtpCapabilitiesToMap(
          RtpCapabilities(codecs: [codec()],
              headerExtensions: [ext(videoOrientationUri)]),
        );

        expect(extensionsOf(map).single['preferredEncrypt'], false);
      });
    });

    test('an empty set is an empty list, not a missing key', () {
      // The server defaults a missing `headerExtensions` to empty, which
      // is how this bug stayed silent. Sending the key explicitly means
      // "none" is a statement rather than an omission.
      final map = rtpCapabilitiesToMap(RtpCapabilities(codecs: [codec()]));

      expect(map.containsKey('headerExtensions'), isTrue);
      expect(extensionsOf(map), isEmpty);
    });
  });

  group('carriesVideoOrientation', () {
    RtpHeaderExtensionParameters param(String uri) =>
        RtpHeaderExtensionParameters(uri: uri, id: 1);

    test('true when the consumer was given the rotation', () {
      expect(
        carriesVideoOrientation([param('urn:x'), param(videoOrientationUri)]),
        isTrue,
      );
    });

    test('false when it was not', () {
      expect(carriesVideoOrientation([param('urn:x')]), isFalse);
    });

    test('and false on a consumer with no extensions at all', () {
      // The exact state the bug produced, and the one the screen has to
      // keep correcting for until a call proves otherwise.
      expect(carriesVideoOrientation(const []), isFalse);
    });

    test('the uri is the one in the RFC, spelled exactly', () {
      // A typo here would read as "no rotation" forever, which looks
      // identical to the bug being fixed.
      expect(videoOrientationUri, 'urn:3gpp:video-orientation');
      expect(carriesVideoOrientation([param('urn:3gpp:video_orientation')]),
          isFalse);
    });
  });
}
