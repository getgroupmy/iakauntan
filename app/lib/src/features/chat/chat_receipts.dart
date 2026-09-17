/// Two grey ticks, which nothing could ever draw.
///
/// `chat_screen.dart` renders three states — one tick sent, two grey
/// delivered, two blue read — and `chat_mark_delivered` had no caller.
/// A message went from one tick straight to two blue, so "delivered"
/// was a state the screen drew and the app could not produce: the
/// sender could not tell a colleague whose phone is off from one who
/// has read it and not replied, which is the only thing the middle
/// state is for.
library;

/// Whether this device now holds messages it did not before.
///
/// Read from `unread` rather than from a timestamp: the conversation
/// list is what fetched them, and a conversation with something unread
/// in it is a conversation whose messages have arrived on this device.
/// That is exactly what `last_delivered_at` records — arrival, not
/// attention. Attention is `chat_mark_read`, and the chat screen sends
/// that when it opens.
bool hasArrivedHere(Map<String, dynamic> conversation) =>
    (num.tryParse('${conversation['unread'] ?? 0}') ?? 0) > 0;

/// The conversations to report delivery on, given what has already been
/// reported.
///
/// Marking does not change `unread` — the messages are delivered, not
/// read — so a list that fired on every rebuild would fire for ever.
/// What has been said once is not said again.
List<String> newlyDelivered(
  Iterable<Map<String, dynamic>> conversations,
  Set<String> alreadyTold,
) => [
  for (final c in conversations)
    if (hasArrivedHere(c) &&
        c['id'] != null &&
        !alreadyTold.contains('${c['id']}'))
      '${c['id']}',
];
