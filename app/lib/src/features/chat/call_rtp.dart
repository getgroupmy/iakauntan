// `RTCRtpMediaType` comes through here too -- the mediasoup package
// re-exports flutter_webrtc's enum rather than declaring its own kind.
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';

/// Serialising RTP capabilities without throwing half of them away.
///
/// ## The bug this exists for
///
/// `RtpCapabilities.toMap()` in `mediasfu_mediasoup_client 0.1.4` is,
/// in full:
///
///     Map<String, dynamic> toMap() {
///       return <String, dynamic>{
///         'codecs': codecs.map((c) => c.toMap()).toList()
///       };
///     }
///
/// It serialises the codecs and **silently drops `headerExtensions` and
/// `fecMechanisms`**. `RtpHeaderExtension` has no `toMap` at all, so the
/// package cannot serialise one even if asked.
///
/// A mediasoup client sends those capabilities once, at `join`, and they
/// are what the server uses to work out what each CONSUMER may carry.
/// Sending no header extensions means every consumer is built against an
/// empty extension list, so the server strips every extension from every
/// stream this device receives. Nothing errors: mediasoup treats a
/// missing `headerExtensions` as an empty one, the call connects, audio
/// and video flow.
///
/// What goes missing with them is `urn:3gpp:video-orientation` — CVO.
/// A phone captures LANDSCAPE sensor frames and does not rotate the
/// pixels; it sends the rotation beside them in that extension. Strip it
/// and the receiver draws raw sensor frames, which is why every remote
/// camera was 90 degrees out while the sender's own preview was upright
/// — the preview never goes through RTP.
///
/// So the sideways video was never a widget problem and never a
/// libwebrtc negotiation quirk. It was five missing lines in a
/// serialiser.
///
/// ## Why this is safe to send
///
/// `validateRtpHeaderExtension` on the server requires a non-empty
/// string `uri` and a numeric `preferredId`, and permits `kind` to be
/// absent. Anything without those two is dropped here rather than sent,
/// so the server cannot reject the set and refuse the `join` — which
/// would not be a sideways picture, it would be no call at all.
///
/// Everything that survives the filter came from the device's own
/// capabilities, which are the router's capabilities intersected with
/// what this platform told libwebrtc it can receive. So the extensions
/// added back are ones this device already said it understands.
Map<String, dynamic> rtpCapabilitiesToMap(RtpCapabilities caps) {
  return <String, dynamic>{
    'codecs': [for (final codec in caps.codecs) codec.toMap()],
    'headerExtensions': [
      for (final ext in caps.headerExtensions)
        if (_sendable(ext))
          <String, dynamic>{
            if (ext.kind != null)
              'kind': RTCRtpMediaTypeExtension.value(ext.kind!),
            'uri': ext.uri,
            'preferredId': ext.preferredId,
            'preferredEncrypt': ext.preferredEncrypt ?? false,
            'direction': (ext.direction ?? RtpHeaderDirection.SendRecv).value,
          },
    ],
    'fecMechanisms': caps.fecMechanisms,
  };
}

/// The two fields the server insists on, and a kind it can understand.
///
/// `data` is a real `RTCRtpMediaType` and not a real header-extension
/// kind: mediasoup takes `audio`, `video` or nothing. One that said
/// `data` would be refused, and a refused capability set means a refused
/// `join`.
bool _sendable(RtpHeaderExtension ext) =>
    (ext.uri ?? '').isNotEmpty &&
    ext.preferredId != null &&
    ext.kind != RTCRtpMediaType.RTCRtpMediaTypeData;

/// Coordination of Video Orientation, as RFC 5285 names it.
const String videoOrientationUri = 'urn:3gpp:video-orientation';

/// Whether this stream carries its own rotation.
///
/// Read off the consumer the server actually built, not off what was
/// asked for — the server decides, and the whole reason this code exists
/// is that it once decided "no extensions" and said nothing.
///
/// True means the rotation arrives with the frames and the pixels are
/// turned natively, so nothing in the widget tree should turn them
/// again. False means they arrive raw and the screen has to.
bool carriesVideoOrientation(List<RtpHeaderExtensionParameters> extensions) =>
    extensions.any((e) => e.uri == videoOrientationUri);
