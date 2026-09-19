import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  // `my.iakauntan.iakauntan/push` in `push_io.dart` -- two directions on
  // one channel. Dart calls `authorizationStatus`, `requestAuthorization`
  // and `registerForRemoteNotifications`; this app calls back with
  // `remoteToken` or `remoteTokenError` once Apple answers, because
  // neither of UIKit's own callbacks for that hands back a value where
  // Dart is waiting for one -- they arrive later, as their own delegate
  // methods below.
  private var pushChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "my.iakauntan.iakauntan/push",
        binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handlePushCall(call, result: result)
      }
      pushChannel = channel
    }

    // Without a delegate, iOS swallows a notification that arrives while
    // this app is already open -- no banner, no sound -- which reads as
    // "push is broken" the first time anybody tests it with the app in
    // the foreground. See `userNotificationCenter(_:willPresent:...)`
    // below.
    UNUserNotificationCenter.current().delegate = self

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handlePushCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "authorizationStatus":
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        result(AppDelegate.name(for: settings.authorizationStatus))
      }

    case "requestAuthorization":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
        granted, _ in
        if granted {
          // Apple requires this call on the main thread, and the
          // permission callback above is not it.
          DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
          }
        }
        result(granted)
      }

    case "registerForRemoteNotifications":
      // Fire-and-forget: the token or the failure arrives later, as its
      // own call to Dart below, never as this method's result.
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func name(for status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .provisional: return "provisional"
    case .ephemeral: return "ephemeral"
    default: return "notDetermined"
    }
  }

  /// The token, hex-encoded -- `register_device`'s shape check (0657)
  /// and APNs itself both expect hex, not the base64 some samples online
  /// use.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushChannel?.invokeMethod("remoteToken", arguments: hex)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    pushChannel?.invokeMethod("remoteTokenError", arguments: error.localizedDescription)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  // `FlutterAppDelegate` already conforms to `UNUserNotificationCenterDelegate`
  // and already implements this method, which is why this is `override`
  // rather than a fresh conformance in an extension -- CI's iOS build
  // (macOS, the only place this Swift is actually compiled) refused the
  // first version of this file on exactly that: "Overriding declaration
  // requires an 'override' keyword" and "Redundant conformance ... to
  // protocol 'UNUserNotificationCenterDelegate'".
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound, .list])
  }
}
