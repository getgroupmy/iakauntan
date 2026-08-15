import 'push_types.dart';

/// Push notifications on everything that is not a browser.
///
/// Android and iOS reach a phone through Firebase and APNs, and neither
/// is built — see docs/push-notifications.md. This is not a silent
/// no-op pretending to work: `pushStatus` answers `unsupported`, the
/// settings screen says so plainly, and nothing registers a device that
/// could never be sent to.
Future<PushStatus> pushStatus(String vapidPublicKey) async =>
    PushStatus.unsupported;

Future<PushSubscriptionInfo?> subscribeToPush(
  String vapidPublicKey, {
  bool ask = false,
}) async => null;

Future<String?> currentPushEndpoint() async => null;

Future<void> unsubscribeFromPush() async {}
