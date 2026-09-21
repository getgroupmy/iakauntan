import AVFoundation
import CallKit
import Flutter
import PushKit
import UIKit
import UserNotifications

/// The iOS half of push notifications.
///
/// `app/lib/src/core/push_native.dart` is the Dart side and carries the
/// argument for why an iPhone is reached through APNs directly rather
/// than through Firebase. This file is the part only native code can
/// do: ask for permission, ask Apple for a device token, and hand it
/// back so `register_device` can put it on the register.
///
/// ## Why the token is awaited rather than returned
///
/// `registerForRemoteNotifications()` returns immediately and says
/// nothing. The token arrives later, on a delegate callback, and may
/// never arrive at all — a device in aeroplane mode, or a build with no
/// push entitlement, simply stays quiet. So `register` holds its
/// `FlutterResult` until one of three things happens: the token lands,
/// Apple reports a failure, or [tokenDeadline] passes. Whichever comes
/// first answers every caller waiting, exactly once.
///
/// Answering "no token" is not a failure to report to anybody. It is
/// one of the ordinary outcomes, and the Dart side turns it into a
/// settings screen that says notifications are not on rather than an
/// error nobody can act on.
///
/// ## PushKit, and why it could not come one commit earlier
///
/// A VoIP push is the only thing that makes a locked iPhone ring the
/// way people expect a phone to ring. It is also the most dangerous
/// thing an app can register for: iOS requires that EVERY VoIP push be
/// reported to CallKit, in the same turn of the run loop, with
/// `reportNewIncomingCall`. An app that takes one and does not is
/// killed, and killed often enough has its PushKit registration
/// revoked — so the failure is not a dropped call, it is a handset that
/// stops receiving calls permanently.
///
/// So `reportIncoming` reports FIRST and asks questions afterwards. A
/// push whose payload is unreadable still produces a reported call,
/// which is then ended immediately: the alternative is not "nothing
/// happens", it is the operating system killing the process.
///
/// ## What is written from documentation rather than from a device
///
/// The audio session. `didActivate` sets the category and nothing more,
/// because activation is the system's job under CallKit. If a real
/// device answers a call into silence, the next step is the documented
/// `RTCAudioSession.audioSessionDidActivate(_:)` handshake that
/// `flutter_webrtc` expects — deliberately NOT here, because importing
/// `WebRTC` would make this file depend on a CocoaPods module name, and
/// a rename there would break the iOS build for everybody rather than
/// producing a quiet audio bug for one person. It is one line in each
/// of the two `didActivate`/`didDeactivate` methods when somebody has a
/// handset to try it on.
///
/// Everything else here is reachable from `callkit.dart`'s tests: the
/// queue, the event shapes and the routing are asserted there, and this
/// file's job is to produce them.
@main
@objc class AppDelegate: FlutterAppDelegate {
  /// How long `register` waits for Apple before answering without a
  /// token.
  ///
  /// Ten seconds. The token normally arrives in well under one; this is
  /// sized for a bad network rather than for a typical one, and the
  /// thing it is protecting against is a settings screen that spins
  /// forever because a device will never get one.
  private static let tokenDeadline: TimeInterval = 10

  /// The channel name is the bundle identifier, as every channel in
  /// this app is. `doc_scanner_io.dart` uses the same prefix, and both
  /// break SILENTLY if the Dart and the native side drift apart — which
  /// is why `docs/handoff.md` lists them together among the places an
  /// Application ID change has to touch at once.
  private static let channelName = "my.iakauntan.iakauntan/push"

  /// The second channel, for calls. Separate because the two have
  /// different lifetimes: push registration is asked for by a screen,
  /// and a call arrives whether or not anything is listening.
  private static let callChannelName = "my.iakauntan.iakauntan/calls"

  private var pushChannel: FlutterMethodChannel?
  private var callChannel: FlutterMethodChannel?

  /// The APNs device token for alerts, as hexadecimal. Nil until Apple
  /// has issued one, and again once it is given back.
  private var alertToken: String?

  /// The PushKit token, which is a different token from a different
  /// Apple service and is registered under `apns_voip`. See `0658`.
  private var voipToken: String?

  private var voipRegistry: PKPushRegistry?
  private var callProvider: CXProvider?

  /// The CallKit identity of each ringing call, by the id the database
  /// knows it as. CallKit speaks UUIDs and `chat_calls` speaks its own
  /// ids, and a call has to be findable from either side: from a push
  /// (by call id) and from an answer action (by UUID).
  private var callUuids: [String: UUID] = [:]
  private var callIds: [UUID: String] = [:]

  /// Answers and hang-ups that happened before Dart was listening.
  ///
  /// A VoIP push can launch this process from cold, and CallKit can
  /// report an answer before the Flutter engine has run a line of the
  /// application. Sending on a channel nobody is listening to drops the
  /// message silently, so every event is QUEUED and Dart drains the
  /// queue; the channel is only ever a nudge to drain it sooner.
  private var pendingCallEvents: [[String: Any]] = []

  /// Everybody who called `register` and is still waiting for Apple.
  private var waiting: [FlutterResult] = []
  private var deadline: Timer?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: AppDelegate.channelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result: result)
      }
      pushChannel = channel

      let calls = FlutterMethodChannel(
        name: AppDelegate.callChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      calls.setMethodCallHandler { [weak self] call, result in
        self?.handleCall(call, result: result)
      }
      callChannel = calls
    }

    // Both started here rather than when somebody asks for them, and
    // that is the point: a VoIP push may be the reason this process is
    // running at all, and there would be nothing to receive it if
    // PushKit were registered from a settings screen.
    startCallKit()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - The channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      authorization { [weak self] state in
        result(self?.answer(authorization: state) ?? [String: Any]())
      }

    case "register":
      let ask = (call.arguments as? [String: Any])?["ask"] as? Bool ?? false
      register(ask: ask, result: result)

    case "tokens":
      // Deliberately does not consult the authorisation state. This is
      // "what is this handset registered with", and its one caller is
      // the code that takes those registrations off the register — at
      // which point what matters is the token, not the permission.
      result(answer(authorization: nil))

    case "unregister":
      UIApplication.shared.unregisterForRemoteNotifications()
      alertToken = nil
      // The PushKit registry is NOT torn down. Its token has already
      // been taken off the register by the caller, so nothing will be
      // sent to it — but an app that stops being able to report an
      // incoming call while a push is in flight is an app iOS kills.
      // Dropping the registration is not this switch's business.
      voipToken = nil
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// One shape for every answer this channel gives.
  private func answer(authorization: String?) -> [String: Any] {
    // Built by insertion rather than as a literal of optionals, so a
    // value that is not known is an ABSENT key. A dictionary of
    // `Any?` bridges a nil to NSNull, which crosses the channel as a
    // present key holding null — the same thing to a careful reader
    // and a different thing to a careless one.
    var answer: [String: Any] = [
      // Not `UIDevice.current.name`: since iOS 16 that is the model
      // name for anybody without a special entitlement, so asking for
      // the model outright is the same answer without pretending.
      "label": UIDevice.current.model
    ]
    if let authorization = authorization { answer["authorization"] = authorization }
    if let alertToken = alertToken { answer["alert"] = alertToken }
    if let voipToken = voipToken { answer["voip"] = voipToken }
    if let vendor = UIDevice.current.identifierForVendor?.uuidString {
      answer["deviceId"] = vendor
    }
    return answer
  }

  private func authorization(_ then: @escaping (String) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let state: String
      switch settings.authorizationStatus {
      case .authorized:
        state = "authorized"
      // Both deliver without ever having shown a prompt. Reported as
      // `provisional` because the Dart side treats it as a qualified
      // yes, and asking such a person again would be asking twice.
      case .provisional, .ephemeral:
        state = "provisional"
      case .denied:
        state = "denied"
      default:
        state = "notDetermined"
      }
      DispatchQueue.main.async { then(state) }
    }
  }

  // MARK: - Registering

  private func register(ask: Bool, result: @escaping FlutterResult) {
    authorization { [weak self] state in
      guard let self = self else { return }

      if state == "denied" {
        // Nothing to do and nothing that can be done: an app cannot
        // raise the prompt a second time.
        result(self.answer(authorization: state))
        return
      }

      if state == "notDetermined" {
        guard ask else {
          result(self.answer(authorization: state))
          return
        }
        UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .sound, .badge]
        ) { granted, _ in
          DispatchQueue.main.async {
            guard granted else {
              result(self.answer(authorization: "denied"))
              return
            }
            self.askApple(authorization: "authorized", result: result)
          }
        }
        return
      }

      self.askApple(authorization: state, result: result)
    }
  }

  /// Ask Apple for a token, and wait for it.
  private func askApple(authorization state: String, result: @escaping FlutterResult) {
    // Already held. Registering again is still worth doing — Apple may
    // reissue at any time and the register has to follow — but there is
    // nothing to wait for.
    if alertToken != nil {
      UIApplication.shared.registerForRemoteNotifications()
      result(answer(authorization: state))
      return
    }

    waiting.append { [weak self] _ in
      result(self?.answer(authorization: state) ?? [String: Any]())
    }
    if deadline == nil {
      deadline = Timer.scheduledTimer(
        withTimeInterval: AppDelegate.tokenDeadline,
        repeats: false
      ) { [weak self] _ in
        self?.flushWaiting()
      }
    }
    UIApplication.shared.registerForRemoteNotifications()
  }

  /// Answer everybody waiting, once, and stop the clock.
  fileprivate func flushWaiting() {
    deadline?.invalidate()
    deadline = nil
    let pending = waiting
    waiting = []
    for callback in pending { callback(nil) }
  }

  // MARK: - Calls

  /// PushKit and CallKit, started together because neither is safe
  /// without the other.
  private func startCallKit() {
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = true
    configuration.maximumCallsPerCallGroup = 1
    configuration.maximumCallGroups = 1
    // Generic, not `.phoneNumber` or `.emailAddress`. The handle is a
    // person's name as the conversation knows it, and telling iOS it is
    // a phone number would put a "call back" button in Recents that
    // dials nothing.
    configuration.supportedHandleTypes = [.generic]

    let provider = CXProvider(configuration: configuration)
    provider.setDelegate(self, queue: nil)
    callProvider = provider

    // `.main`, so `didReceiveIncomingPushWith` runs on the thread that
    // may report a call. PushKit is strict about the reporting
    // happening before the completion handler returns.
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
  }

  private func handleCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "drain":
      // Read and cleared together. An event delivered twice would
      // answer a call somebody had already declined.
      let events = pendingCallEvents
      pendingCallEvents = []
      result(events)

    case "end":
      // The app finished the call — somebody hung up inside it, or it
      // was never joined. CallKit does not find out by itself, and a
      // call it still believes is running is a green bar across the top
      // of the phone that nothing will clear.
      guard let id = (call.arguments as? [String: Any])?["call_id"] as? String
      else {
        result(nil)
        return
      }
      endCall(id, reason: .remoteEnded)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Queue an event and nudge Dart to come and get it.
  ///
  /// The queue is the delivery mechanism and the channel is only the
  /// doorbell. A `invokeMethod` on a channel nobody is listening to is
  /// dropped without a word, and "nobody is listening" is the ordinary
  /// case here: a VoIP push can start this process from cold and
  /// CallKit can report an answer before Dart has run.
  private func emit(_ event: [String: Any]) {
    pendingCallEvents.append(event)
    callChannel?.invokeMethod("wake", arguments: nil)
  }

  /// Tell CallKit a call is over, from whichever side ended it.
  private func endCall(_ id: String, reason: CXCallEndedReason) {
    guard let uuid = callUuids[id] else { return }
    callUuids[id] = nil
    callIds[uuid] = nil
    callProvider?.reportCall(with: uuid, endedAt: nil, reason: reason)
  }

  /// Report an incoming call, whatever the payload turns out to be.
  ///
  /// Reporting comes first and validation second, and the order is the
  /// whole safety property: a push that is not reported costs the app
  /// its life. A payload this cannot read still produces a call, ended
  /// on the next line, which is a moment of ringing rather than a
  /// terminated process.
  private func reportIncoming(_ payload: [AnyHashable: Any], then done: @escaping () -> Void) {
    let id = payload["call_id"] as? String
    let caller = payload["sender_name"] as? String
    let room = payload["title"] as? String
    let video = payload["video"] as? Bool ?? false

    let uuid = UUID()
    let update = CXCallUpdate()
    update.localizedCallerName = caller ?? room ?? "iAkauntan"
    update.hasVideo = video
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsHolding = false
    update.remoteHandle = CXHandle(type: .generic, value: id ?? "iAkauntan")

    // Set BEFORE the ring rather than on answer. Apple's own guidance,
    // and the reason is that the category decides whether the ringtone
    // ducks other audio; changing it afterwards is already too late.
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord, mode: .voiceChat, options: [.allowBluetooth])

    guard let provider = callProvider else {
      done()
      return
    }

    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      guard let self = self else {
        done()
        return
      }
      if error != nil || id == nil {
        // Reported, and immediately over. Either the system refused it
        // (Do Not Disturb, or a blocked caller) or the payload did not
        // say which call this is, and there is nothing to answer.
        provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
        done()
        return
      }
      let id = id!
      self.callUuids[id] = uuid
      self.callIds[uuid] = id
      // So the app can show the right screen the moment it is looked
      // at, whether or not anybody presses answer.
      self.emit([
        "event": "ringing",
        "call_id": id,
        "video": video,
        "caller": caller as Any,
        "title": room as Any,
      ])
      done()
    }
  }

  // MARK: - Apple's answers

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    // Hexadecimal, lower case, no separators. This is the form APNs
    // itself takes in the request path, and the form `0658`'s shape
    // check is written against.
    alertToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    flushWaiting()
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    // Not an error anybody is shown. The commonest cause by a distance
    // is a simulator or a build without the push entitlement, and the
    // useful consequence is the same as a token that never arrived:
    // this device is not registered, and the settings screen says so.
    alertToken = nil
    flushWaiting()
    super.application(
      application,
      didFailToRegisterForRemoteNotificationsWithError: error
    )
  }
}

// MARK: - PushKit

extension AppDelegate: PKPushRegistryDelegate {
  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate pushCredentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard type == .voIP else { return }
    voipToken = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    // The same queue the alert token drains: a `register` call waiting
    // for Apple takes whichever token arrives, and both are handed back
    // together whenever it finishes.
    flushWaiting()
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didInvalidatePushTokenFor type: PKPushType
  ) {
    guard type == .voIP else { return }
    // Apple has withdrawn it. Forgotten here so that the next
    // registration does not put a dead token back on the register; the
    // row itself is dropped by `send-push` when Apple answers 410.
    voipToken = nil
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    reportIncoming(payload.dictionaryPayload, then: completion)
  }
}

// MARK: - CallKit

extension AppDelegate: CXProviderDelegate {
  /// The system has thrown away every call it knew about.
  ///
  /// Not an error: it happens when the provider is reconfigured or the
  /// system decides to reset. What matters is that this side agrees,
  /// because a call id left in the map would never be findable again
  /// and `end` would silently do nothing for the rest of the session.
  func providerDidReset(_ provider: CXProvider) {
    callUuids.removeAll()
    callIds.removeAll()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard let id = callIds[action.callUUID] else {
      action.fail()
      return
    }
    emit(["event": "answered", "call_id": id])
    // Fulfilled immediately rather than when the app has joined. CallKit
    // gives an action a few seconds and then fails it on the app's
    // behalf, and joining a call means a round trip for credentials —
    // so the alternative is a call that CallKit gives up on while the
    // app is still connecting to it.
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if let id = callIds[action.callUUID] {
      callUuids[id] = nil
      callIds[action.callUUID] = nil
      // Declined, or hung up from the system's own call screen. Dart
      // decides which of `chat_decline_call` and `chat_leave_call` that
      // means, because only it knows whether the call was ever joined.
      emit(["event": "ended", "call_id": id])
    }
    action.fulfill()
  }

  /// The session is ours to use.
  ///
  /// Category only. Activation is CallKit's, and the WebRTC handshake
  /// that `flutter_webrtc` documents is deliberately not here — see the
  /// note at the top of this file for why, and for what to add if a
  /// real handset answers into silence.
  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    try? audioSession.setCategory(
      .playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    // Nothing to undo while the category is all this file sets.
  }
}
