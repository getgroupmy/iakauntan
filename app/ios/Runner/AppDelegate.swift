import Flutter
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
/// ## PushKit is deliberately NOT here yet
///
/// `0658` has a transport for the PushKit token, `send-push` routes to
/// it, and `push_native.dart` will pass one through the moment this
/// file produces one. It does not produce one, on purpose.
///
/// iOS requires that every VoIP push an app receives be reported to
/// CallKit, synchronously, with `reportNewIncomingCall`. An app that
/// takes a PushKit push and does not is KILLED, and killed often enough
/// has its PushKit registration revoked — so registering for VoIP
/// pushes before there is a `CXProvider` to report them to would not
/// degrade gracefully, it would break the app's ability to receive
/// calls at all, permanently, on handsets that had worked.
///
/// So PushKit lands with CallKit and not before. Nothing else waits on
/// it: alerts work on their own, a call already reaches anybody with
/// the app open through `IncomingCallWatcher`, and with this file in
/// place a call reaches a closed app as a banner.
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

  private var pushChannel: FlutterMethodChannel?

  /// The APNs device token for alerts, as hexadecimal. Nil until Apple
  /// has issued one, and again once it is given back.
  private var alertToken: String?

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
    }

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
    // "voip" is deliberately never set. See the note on PushKit above:
    // the Dart side already reads it, and this file will set it in the
    // same commit that gives CallKit something to report to.
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
        self?.flush()
      }
    }
    UIApplication.shared.registerForRemoteNotifications()
  }

  /// Answer everybody waiting, once, and stop the clock.
  private func flush() {
    deadline?.invalidate()
    deadline = nil
    let pending = waiting
    waiting = []
    for callback in pending { callback(nil) }
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
    flush()
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
    flush()
    super.application(
      application,
      didFailToRegisterForRemoteNotificationsWithError: error
    )
  }
}
