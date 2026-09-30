/// Two grey ticks, which nothing could ever draw.
///
/// `chat_screen.dart` renders three states — one tick sent, two grey
/// delivered, two blue read — and `chat_mark_delivered` had no caller.
/// A message went from one tick straight to two blue, so "delivered"
/// was a state the screen drew and the app could not produce: the
/// sender could not tell a colleague whose phone is off from one who
/// has read it and not replied, which is the only thing the middle
/// state is for.
///
/// ## And then it had one that could not work
///
/// The caller written to fix that read the conversation's id out of
/// `c['id']`. `chat_my_conversations` does not return a column called
/// `id`; it returns `conversation_id`, which is what every other reader
/// of these rows uses — `chat_screen.dart` looks up the open thread by
/// `c['conversation_id']` twice on its way down the same list.
///
/// So the key was null on every row, the `c['id'] != null` guard threw
/// all of them away, and [newlyDelivered] returned an empty list for
/// ever. Not "usually empty": empty, on every device, for every
/// conversation, since the day it was written. The grey tick still
/// could not be drawn, and nothing said so, because "nothing to report"
/// and "reported nothing" look identical from the outside.
///
/// That is the whole argument for these two functions being pure and
/// out here: the wrong column name is visible in a test and invisible
/// in a widget.
library;

/// The conversation this row is about.
///
/// `conversation_id` is what `chat_my_conversations` returns. `id` is
/// accepted as a fallback rather than assumed absent, because these
/// rows also reach here from tests and from anything later that
/// projects them differently — but it is the fallback, not the first
/// guess, which is the way round the defect above wanted.
String? conversationIdOf(Map<String, dynamic> conversation) {
  final value = conversation['conversation_id'] ?? conversation['id'];
  final text = value?.toString() ?? '';
  return text.isEmpty ? null : text;
}

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

/// What "this has been reported" is remembered as.
///
/// The conversation alone is not enough. Marking does not change
/// `unread` — the messages are delivered, not read — so a set keyed on
/// the conversation would report the first batch and then stay silent
/// for the rest of the day: the second message to arrive in a thread
/// already reported would sit on one tick until the app was restarted.
///
/// Keyed on the newest message instead, so each new arrival is a new
/// thing to say and a repeat of the same arrival is not.
String deliveryMark(Map<String, dynamic> conversation) =>
    '${conversationIdOf(conversation)}@${conversation['last_message_at']}';

/// The conversations to report delivery on, given what has already been
/// reported, each with the mark to remember it by.
List<({String id, String mark})> newlyDelivered(
  Iterable<Map<String, dynamic>> conversations,
  Set<String> alreadyTold,
) {
  final out = <({String id, String mark})>[];
  for (final c in conversations) {
    final id = conversationIdOf(c);
    if (id == null || !hasArrivedHere(c)) continue;
    final mark = deliveryMark(c);
    if (alreadyTold.contains(mark)) continue;
    out.add((id: id, mark: mark));
  }
  return out;
}
