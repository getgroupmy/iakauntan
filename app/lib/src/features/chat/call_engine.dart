import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';
// `RTCIceServer` is mediasoup's own type — flutter_webrtc takes ICE
// servers as loose maps, so the package had to declare one — and the
// package does not export it from its root. Reaching into `src` for it
// is ugly and the alternative is worse: `createSendTransportFromMap`,
// the only public path that avoids this import, hard-codes
// `iceServers: []`. That works on a home network and fails on roughly
// one office network in five, which is the exact case TURN exists for.
// ignore: implementation_imports
import 'package:mediasfu_mediasoup_client/src/handlers/handler_interface.dart'
    show RTCIceCredentialType, RTCIceServer;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/error_text.dart';

/// Where the media server is, and what this person may do there.
///
/// Minted by the `call-token` edge function, which holds the SFU's
/// signing secret. Nothing here is derived on the device: a client that
/// could name its own room or its own display name could walk into
/// somebody else's call wearing their name.
class CallCredentials {
  const CallCredentials({
    required this.url,
    required this.room,
    required this.peerId,
    required this.displayName,
    required this.token,
    required this.iceServers,
  });

  factory CallCredentials.fromMap(Map<String, dynamic> map) => CallCredentials(
    url: map['url'] as String,
    room: map['room'] as String,
    peerId: map['peer_id'] as String,
    displayName: map['display_name'] as String? ?? 'Somebody',
    token: map['token'] as String,
    iceServers: (map['ice_servers'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(),
  );

  final String url;
  final String room;
  final String peerId;
  final String displayName;
  final String token;
  final List<Map<String, dynamic>> iceServers;
}

/// Somebody else in the room, and the two renderers their tracks land
/// in.
///
/// Two, not one, because mediasoup delivers each consumer in its own
/// `MediaStream` — a peer's microphone and camera never arrive in the
/// same one, so they cannot share a renderer. [mic] is never shown. It
/// exists because on the web a track only plays once it is attached to
/// an element that is in the document; a renderer nobody mounts is
/// silence. The call screen mounts it at one logical pixel.
class CallPeer {
  CallPeer({required this.id, required this.displayName});

  final String id;
  String displayName;
  RTCVideoRenderer? camera;
  RTCVideoRenderer? mic;
  RTCVideoRenderer? screen;

  /// Which consumer each renderer is showing, so `consumerClosed` can
  /// find it. The renderer holds a `MediaStream`, whose id is the
  /// stream's and not the consumer's — matching on that would silently
  /// never match and leave a frozen last frame on screen forever.
  String? cameraConsumerId;
  String? micConsumerId;
  String? screenConsumerId;

  /// Whether they have muted themselves, and whether their camera is
  /// off. Tracked from `consumerPaused` / `consumerResumed`, which the
  /// server sends and this used to ignore — so somebody muting looked
  /// exactly like somebody who had stopped talking.
  bool micMuted = false;
  bool cameraOff = false;

  bool get hasVideo => camera != null && !cameraOff;
  bool get isSharing => screen != null;
}

enum CallPhase { connecting, connected, failed, closed }

/// What the call screen talks to.
///
/// An interface rather than the class directly so the screen can be
/// built and tested without a media stack — every implementation detail
/// below this line needs a real device, a real network and a real SFU,
/// none of which exist in a widget test.
abstract class CallEngine implements Listenable {
  CallPhase get phase;

  /// Why it failed, in words meant for the person on the call.
  String? get failure;

  List<CallPeer> get peers;
  RTCVideoRenderer? get localVideo;
  bool get micOn;
  bool get cameraOn;

  /// Whether this person is sharing, and whether this device could.
  bool get sharingScreen;
  bool get canShareScreen;

  /// What everybody is looking at, if anybody is sharing. Null when
  /// nobody is — including when the sharer is this person, because
  /// showing somebody their own screen inside their own screen is a
  /// hall of mirrors and a wasted decode.
  CallPeer? get screenSharer;

  Future<void> connect(CallCredentials credentials, {required bool video});
  Future<void> setMic(bool on);
  Future<void> setCamera(bool on);
  Future<void> switchCamera();
  Future<void> setScreenShare(bool on);
  Future<void> close();
}

/// The mediasoup half of a call.
///
/// The protocol it speaks is written down in `docs/call-signalling.md`,
/// and that document is a contract rather than a description: mediasoup
/// is a library, not a server, and defines no client protocol at all.
/// Whatever the server implements, this is what the app sends.
///
/// The server end is `server/sfu`, in this repository, and its tests
/// drive every method and notification below against real mediasoup
/// routers and transports. What no test anywhere covers is media
/// actually arriving: nothing in a test process performs a DTLS
/// handshake or opens a microphone, so a green suite says the two ends
/// agree on the protocol and says nothing about whether anybody can hear
/// anything. That takes two devices.
class MediasoupCallEngine extends ChangeNotifier implements CallEngine {
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _frames;
  Device? _device;
  Transport? _send;
  Transport? _recv;
  MediaStream? _local;
  Producer? _micProducer;
  Producer? _camProducer;
  Producer? _screenProducer;
  MediaStream? _screen;
  RTCVideoRenderer? _localVideo;

  final _peers = <String, CallPeer>{};
  final _consumers = <String, Consumer>{};
  final _arrivedPaused = <String, bool>{};
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  var _nextId = 1;

  CallPhase _phase = CallPhase.connecting;
  String? _failure;
  bool _micOn = true;
  bool _cameraOn = false;
  bool _sharingScreen = false;
  List<RTCIceServer> _ice = const [];

  /// Long enough for a phone waking a radio, short enough that a dead
  /// server does not look like a call that is about to connect.
  static const _timeout = Duration(seconds: 15);

  @override
  CallPhase get phase => _phase;
  @override
  String? get failure => _failure;
  @override
  List<CallPeer> get peers => _peers.values.toList(growable: false);
  @override
  RTCVideoRenderer? get localVideo => _localVideo;
  @override
  bool get micOn => _micOn;
  @override
  bool get cameraOn => _cameraOn;
  @override
  bool get sharingScreen => _sharingScreen;

  /// Where the app can capture a screen at all.
  ///
  /// The browser and the desktop builds can, through `getDisplayMedia`,
  /// with no extra permission and no platform code. Android and iOS
  /// cannot, and the reason is not laziness in this file:
  ///
  ///   * Android needs a foreground service of type `mediaProjection`
  ///     running for the whole capture, or the system kills it after a
  ///     few seconds. That is a service class, a notification, and a
  ///     dependency, none of which can be tested from here.
  ///   * iOS needs a Broadcast Upload Extension — a second target in
  ///     the Xcode project, sharing an App Group with the app. It
  ///     cannot be added from the Dart side at all.
  ///
  /// Both are real work rather than impossible, and until they are done
  /// this returns false so the button is simply absent. A button that
  /// starts a capture the operating system stops three seconds later is
  /// worse than no button.
  @override
  bool get canShareScreen =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  CallPeer? get screenSharer {
    for (final peer in _peers.values) {
      if (peer.isSharing) return peer;
    }
    return null;
  }

  // -------------------------------------------------------------------
  // Getting in
  // -------------------------------------------------------------------
  @override
  Future<void> connect(
    CallCredentials credentials, {
    required bool video,
  }) async {
    try {
      _ice = credentials.iceServers
          .map(
            (s) => RTCIceServer(
              urls: (s['urls'] as List? ?? const []).cast<String>(),
              username: s['username'] as String? ?? '',
              credential: s['credential'],
              credentialType: RTCIceCredentialType.password,
            ),
          )
          .toList();

      // The room is not in the query string. It is inside the token,
      // where the client cannot change it — see the edge function.
      final uri = Uri.parse(
        credentials.url,
      ).replace(queryParameters: {'token': credentials.token});
      final socket = WebSocketChannel.connect(uri);
      _socket = socket;
      await socket.ready.timeout(_timeout);
      _frames = socket.stream.listen(
        _onFrame,
        onError: (Object e) => _fail('Lost the call server: ${errorText(e)}'),
        onDone: () => _hangUpFromTheOtherEnd(),
      );

      final caps = await _request('getRouterRtpCapabilities');
      final device = Device();
      await device.load(routerRtpCapabilities: RtpCapabilities.fromMap(caps));
      _device = device;

      // Both transports before `join`, because joining is what makes the
      // server start describing everybody already in the room — and
      // there has to be somewhere to put them by then.
      _send = await _makeTransport(producing: true);
      _recv = await _makeTransport(producing: false);

      final joined = await _request('join', {
        'rtpCapabilities': device.rtpCapabilities.toMap(),
        'displayName': credentials.displayName,
      });
      for (final peer in (joined['peers'] as List? ?? const [])) {
        final map = Map<String, dynamic>.from(peer as Map);
        final id = map['id'] as String;
        _peers[id] = CallPeer(
          id: id,
          displayName: map['displayName'] as String? ?? 'Somebody',
        );
      }

      await _openLocalMedia(video: video);

      if (_phase == CallPhase.connecting) _phase = CallPhase.connected;
      notifyListeners();
    } catch (error) {
      _fail(_readable(error));
    }
  }

  Future<Transport> _makeTransport({required bool producing}) async {
    final data = await _request('createWebRtcTransport', {
      'producing': producing,
      'consuming': !producing,
    });

    final id = data['id'] as String;
    final iceParameters = IceParameters.fromMap(data['iceParameters']);
    final iceCandidates = (data['iceCandidates'] as List)
        .map((c) => IceCandidate.fromMap(c))
        .toList();
    final dtlsParameters = DtlsParameters.fromMap(data['dtlsParameters']);

    final transport = producing
        ? _device!.createSendTransport(
            id: id,
            iceParameters: iceParameters,
            iceCandidates: iceCandidates,
            dtlsParameters: dtlsParameters,
            iceServers: _ice,
            producerCallback: _onProducer,
          )
        : _device!.createRecvTransport(
            id: id,
            iceParameters: iceParameters,
            iceCandidates: iceCandidates,
            dtlsParameters: dtlsParameters,
            iceServers: _ice,
            consumerCallback: _onConsumer,
          );

    // DTLS parameters do not exist until the handler has built an offer,
    // which is why this is an event and not something sent above.
    transport.on('connect', (Map data) async {
      try {
        await _request('connectWebRtcTransport', {
          'transportId': transport.id,
          'dtlsParameters': (data['dtlsParameters'] as DtlsParameters).toMap(),
        });
        (data['callback'] as Function)();
      } catch (error) {
        (data['errback'] as Function)(error);
      }
    });

    if (producing) {
      transport.on('produce', (Map data) async {
        try {
          final res = await _request('produce', {
            'transportId': transport.id,
            'kind': data['kind'],
            'rtpParameters': (data['rtpParameters'] as RtpParameters).toMap(),
            'appData': data['appData'],
          });
          (data['callback'] as Function)(res['id']);
        } catch (error) {
          (data['errback'] as Function)(error);
          // The server refuses a second screen share, naming whoever
          // has it. Without this the button stays lit and the capture
          // keeps running against a room that is not receiving it.
          final appData = data['appData'];
          if (appData is Map && appData['source'] == 'screen') {
            _failure = _readable(error);
            unawaited(_stopScreenShare());
          }
        }
      });
    }

    transport.on('connectionstatechange', (Map data) {
      if (data['connectionState'] == 'failed') {
        _fail('The connection to the call server failed.');
      }
    });

    return transport;
  }

  Future<void> _openLocalMedia({required bool video}) async {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video ? _cameraConstraints : false,
    });
    _local = stream;

    final audio = stream.getAudioTracks();
    if (audio.isNotEmpty) {
      _send!.produce(
        track: audio.first,
        stream: stream,
        source: 'mic',
        appData: const {'source': 'mic'},
      );
    }

    if (video) {
      final cameras = stream.getVideoTracks();
      if (cameras.isNotEmpty) {
        final renderer = RTCVideoRenderer();
        await renderer.initialize();
        renderer.srcObject = stream;
        _localVideo = renderer;
        _cameraOn = true;
        // One encoding rather than simulcast. Simulcast is the right
        // answer for a room of a dozen and it is also the part most
        // likely to be wrong against a server nobody here can run, so
        // it is deliberately left until there is something to test it
        // against.
        _send!.produce(
          track: cameras.first,
          stream: stream,
          source: 'cam',
          appData: const {'source': 'cam'},
        );
      }
    }
  }

  static const Map<String, dynamic> _cameraConstraints = {
    'facingMode': 'user',
    'width': {'ideal': 640},
    'height': {'ideal': 480},
  };

  // -------------------------------------------------------------------
  // Controls
  // -------------------------------------------------------------------
  @override
  Future<void> setMic(bool on) async {
    final producer = _micProducer;
    _micOn = on;
    notifyListeners();
    if (producer == null) return;
    // Locally first, so the button is honest even if the socket is
    // slow: a muted microphone that is still sending is the one bug
    // nobody forgives.
    on ? producer.resume() : producer.pause();
    await _request(on ? 'resumeProducer' : 'pauseProducer', {
      'producerId': producer.id,
    }).catchError((_) => <String, dynamic>{});
  }

  @override
  Future<void> setCamera(bool on) async {
    if (on && _camProducer == null) {
      // A voice call that grows a camera. The track does not exist yet,
      // so this is not a pause — it is a new producer.
      try {
        final stream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': _cameraConstraints,
        });
        final tracks = stream.getVideoTracks();
        if (tracks.isEmpty) return;
        final renderer = RTCVideoRenderer();
        await renderer.initialize();
        renderer.srcObject = stream;
        _localVideo = renderer;
        _cameraOn = true;
        _send!.produce(
          track: tracks.first,
          stream: stream,
          source: 'cam',
          appData: const {'source': 'cam'},
        );
        notifyListeners();
      } catch (error) {
        _failure = _readable(error);
        notifyListeners();
      }
      return;
    }

    final producer = _camProducer;
    _cameraOn = on;
    notifyListeners();
    if (producer == null) return;
    on ? producer.resume() : producer.pause();
    await _request(on ? 'resumeProducer' : 'pauseProducer', {
      'producerId': producer.id,
    }).catchError((_) => <String, dynamic>{});
  }

  @override
  Future<void> setScreenShare(bool on) async {
    if (on == _sharingScreen) return;
    if (!on) {
      await _stopScreenShare();
      return;
    }
    if (!canShareScreen) {
      _failure = 'This device cannot share a screen.';
      notifyListeners();
      return;
    }

    try {
      // The picker is the browser's, not ours: which window or tab gets
      // shared is a decision the operating system owns, and an app that
      // could choose for you would be a keylogger with extra steps.
      final stream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          // A spreadsheet is text. Frame rate matters less than not
          // making 8-point figures unreadable, so resolution is left
          // alone and the frame rate is capped instead.
          'frameRate': {'ideal': 8, 'max': 15},
        },
        // Not asking for the system's audio. On the platforms that offer
        // it at all it is a separate track with its own consent, and
        // sharing a spreadsheet should not quietly also share whatever
        // else is playing.
        'audio': false,
      });

      final tracks = stream.getVideoTracks();
      if (tracks.isEmpty) {
        await stream.dispose();
        return;
      }
      final track = tracks.first;

      // The browser puts its own "Stop sharing" bar on screen, and it is
      // the one people actually press. Without this the app goes on
      // believing it is sharing and the far side sees a frozen frame.
      track.onEnded = () => unawaited(_stopScreenShare());

      _screen = stream;
      _sharingScreen = true;
      notifyListeners();

      _send!.produce(
        track: track,
        stream: stream,
        source: 'screen',
        appData: const {'source': 'screen'},
      );
    } catch (error) {
      // Cancelling the picker is the ordinary case, not a failure, and
      // it arrives as an exception like everything else. Saying "Screen
      // sharing failed" to somebody who pressed Cancel is worse than
      // saying nothing.
      await _stopScreenShare();
      final text = error.toString();
      if (!text.contains('NotAllowed') &&
          !text.contains('Permission') &&
          !text.contains('AbortError')) {
        _failure = _readable(error);
      }
      notifyListeners();
    }
  }

  Future<void> _stopScreenShare() async {
    if (!_sharingScreen && _screenProducer == null && _screen == null) return;
    _sharingScreen = false;

    final producer = _screenProducer;
    _screenProducer = null;
    if (producer != null) {
      producer.close();
      // Telling the server as well, because closing the producer locally
      // stops the packets and leaves the room believing somebody is
      // still sharing — which is the state that refuses the next person
      // who tries.
      await _request('closeProducer', {
        'producerId': producer.id,
      }).catchError((_) => <String, dynamic>{});
    }

    for (final track in _screen?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _screen?.dispose();
    _screen = null;
    notifyListeners();
  }

  @override
  Future<void> switchCamera() async {
    final producer = _camProducer;
    if (producer == null) return;
    await Helper.switchCamera(producer.track);
  }

  // -------------------------------------------------------------------
  // What the server says
  // -------------------------------------------------------------------
  void _onFrame(dynamic raw) {
    Map<String, dynamic> frame;
    try {
      frame = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
    } catch (_) {
      return; // Not ours to interpret.
    }

    if (frame['notification'] != null) {
      _onNotification(
        frame['notification'] as String,
        Map<String, dynamic>.from(frame['data'] as Map? ?? const {}),
      );
      return;
    }

    final id = frame['id'];
    if (id is! int) return;
    final waiting = _pending.remove(id);
    if (waiting == null || waiting.isCompleted) return;

    if (frame['ok'] == true) {
      waiting.complete(
        Map<String, dynamic>.from(frame['data'] as Map? ?? const {}),
      );
    } else {
      waiting.completeError(
        Exception(frame['error']?.toString() ?? 'The call server refused'),
      );
    }
  }

  void _onNotification(String name, Map<String, dynamic> data) {
    switch (name) {
      case 'newConsumer':
        _consume(data);
      case 'consumerClosed':
        _dropConsumer(data['consumerId'] as String?);
      case 'consumerPaused':
        _setPaused(data['consumerId'] as String?, true);
      case 'consumerResumed':
        _setPaused(data['consumerId'] as String?, false);
      case 'peerJoined':
        final id = data['peerId'] as String?;
        if (id == null) return;
        _peers[id] = CallPeer(
          id: id,
          displayName: data['displayName'] as String? ?? 'Somebody',
        );
        notifyListeners();
      case 'peerClosed':
        final peer = _peers.remove(data['peerId']);
        if (peer != null) {
          _consumers.remove(peer.cameraConsumerId)?.close();
          _consumers.remove(peer.micConsumerId)?.close();
          _consumers.remove(peer.screenConsumerId)?.close();
          peer.camera?.dispose();
          peer.mic?.dispose();
          peer.screen?.dispose();
        }
        notifyListeners();
    }
  }

  void _consume(Map<String, dynamic> data) {
    final recv = _recv;
    if (recv == null) return;
    // Somebody who muted before you joined arrives already paused.
    // Starting from `false` would show them as talking until they next
    // touched the button.
    _arrivedPaused[data['id'] as String] = data['producerPaused'] == true;
    try {
      recv.consume(
        id: data['id'] as String,
        producerId: data['producerId'] as String,
        peerId: data['peerId'] as String,
        kind: RTCRtpMediaTypeExtension.fromString(data['kind'] as String),
        rtpParameters: RtpParameters.fromMap(data['rtpParameters']),
        appData: Map<String, dynamic>.from(data['appData'] as Map? ?? const {}),
      );
    } catch (error) {
      debugPrint('call: could not consume ${data['id']}: $error');
    }
  }

  void _onProducer(Producer producer) {
    if (producer.source == 'screen') {
      _screenProducer = producer;
      // The server has the last word on who may share, and it refuses a
      // second one. If the produce was refused this never fires and
      // `_sharingScreen` has to come back down — handled where the
      // request fails, in the transport's `produce` listener.
    } else if (producer.source == 'cam') {
      _camProducer = producer;
    } else {
      _micProducer = producer;
      // The mute button may have been pressed before the producer
      // existed — which is easy on a slow join and looks like the
      // button doing nothing.
      if (!_micOn) producer.pause();
    }
    notifyListeners();
  }

  void _onConsumer(Consumer consumer, [Function? accept]) {
    unawaited(_attach(consumer));
    accept?.call();
  }

  Future<void> _attach(Consumer consumer) async {
    final peerId = consumer.peerId;
    if (peerId == null) return;
    final peer = _peers.putIfAbsent(
      peerId,
      () => CallPeer(id: peerId, displayName: 'Somebody'),
    );

    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = consumer.stream;

    _consumers[consumer.id] = consumer;
    final paused = _arrivedPaused.remove(consumer.id) ?? false;
    // A screen and a camera are both `kind: 'video'`. Only the label
    // separates them, which is why the server puts one on every
    // producer and why guessing from `kind` would put somebody's
    // spreadsheet in the little round avatar.
    final isScreen = consumer.appData['source'] == 'screen';
    if (isScreen) {
      await peer.screen?.dispose();
      peer.screen = renderer;
      peer.screenConsumerId = consumer.id;
    } else if (consumer.kind == 'video') {
      await peer.camera?.dispose();
      peer.camera = renderer;
      peer.cameraConsumerId = consumer.id;
      peer.cameraOff = paused;
    } else {
      await peer.mic?.dispose();
      peer.mic = renderer;
      peer.micConsumerId = consumer.id;
      peer.micMuted = paused;
    }
    notifyListeners();

    // Consumers are created paused on the server, so the first key frame
    // is not thrown at a client with nowhere to put it. Now there is
    // somewhere.
    await _request('resumeConsumer', {
      'consumerId': consumer.id,
    }).catchError((_) => <String, dynamic>{});
  }

  /// Somebody on the other side muted, or turned their camera off.
  void _setPaused(String? consumerId, bool paused) {
    if (consumerId == null) return;
    for (final peer in _peers.values) {
      if (peer.micConsumerId == consumerId) {
        peer.micMuted = paused;
        notifyListeners();
        return;
      }
      if (peer.cameraConsumerId == consumerId) {
        peer.cameraOff = paused;
        notifyListeners();
        return;
      }
    }
  }

  void _dropConsumer(String? consumerId) {
    if (consumerId == null) return;
    _consumers.remove(consumerId)?.close();
    for (final peer in _peers.values) {
      if (peer.cameraConsumerId == consumerId) {
        peer.camera?.dispose();
        peer.camera = null;
        peer.cameraConsumerId = null;
      }
      if (peer.micConsumerId == consumerId) {
        peer.mic?.dispose();
        peer.mic = null;
        peer.micConsumerId = null;
      }
      if (peer.screenConsumerId == consumerId) {
        peer.screen?.dispose();
        peer.screen = null;
        peer.screenConsumerId = null;
      }
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------
  // Plumbing
  // -------------------------------------------------------------------
  Future<Map<String, dynamic>> _request(
    String method, [
    Map<String, dynamic> data = const {},
  ]) {
    final socket = _socket;
    if (socket == null) {
      return Future.error(Exception('The call is not connected'));
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    socket.sink.add(jsonEncode({'id': id, 'method': method, 'data': data}));
    return completer.future.timeout(
      _timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('The call server did not answer "$method"');
      },
    );
  }

  void _fail(String message) {
    if (_phase == CallPhase.closed) return;
    _phase = CallPhase.failed;
    _failure = message;
    notifyListeners();
  }

  void _hangUpFromTheOtherEnd() {
    if (_phase == CallPhase.closed || _phase == CallPhase.failed) return;
    _phase = CallPhase.closed;
    notifyListeners();
  }

  String _readable(Object error) {
    if (error is TimeoutException) {
      return 'The call server did not answer.';
    }
    final text = error.toString();
    // getUserMedia's refusals are the ones people actually hit, and
    // "NotAllowedError" on its own tells them nothing to do about it.
    if (text.contains('NotAllowed') || text.contains('Permission')) {
      return 'This device would not give the app a microphone. Check the '
          'permission and try again.';
    }
    if (text.contains('NotFound')) {
      return 'No microphone was found on this device.';
    }
    return text.replaceFirst('Exception: ', '');
  }

  @override
  Future<void> close() async {
    if (_phase == CallPhase.closed) return;
    _phase = CallPhase.closed;

    for (final waiting in _pending.values) {
      if (!waiting.isCompleted) {
        waiting.completeError(Exception('The call ended'));
      }
    }
    _pending.clear();

    _micProducer?.close();
    _camProducer?.close();
    _screenProducer?.close();
    _screenProducer = null;
    _sharingScreen = false;
    for (final track in _screen?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _screen?.dispose();
    _screen = null;
    for (final consumer in _consumers.values) {
      consumer.close();
    }
    _consumers.clear();
    await _send?.close();
    await _recv?.close();

    for (final track in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _local?.dispose();
    _local = null;

    await _localVideo?.dispose();
    _localVideo = null;
    for (final peer in _peers.values) {
      await peer.camera?.dispose();
      await peer.mic?.dispose();
      await peer.screen?.dispose();
    }
    _peers.clear();

    await _frames?.cancel();
    await _socket?.sink.close();
    _socket = null;

    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
