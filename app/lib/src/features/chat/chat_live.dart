import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';

/// Chat arriving without being asked for, and this app saying it is here.
///
/// The organization-wide subscription in `core/live_updates.dart` cannot
/// carry chat, and not for want of adding a table name: it filters every
/// subscription on `org_id`, and a conversation that spans two companies
/// has no single one. `chat_messages` carries the sender's company, which
/// is the wrong column to filter on — filtering by it would deliver your
/// own messages and silently drop every reply.
///
/// So chat listens unfiltered and lets row level security do the
/// deciding, which is what it is for. Realtime applies the policies when
/// it decides who is sent a row, and those policies are narrower than
/// company membership: a message goes to the participants of that
/// conversation and to nobody else.
///
/// Like the other subscription, nothing here merges a payload into a
/// cached list. A change arrives, the provider is invalidated, it
/// re-reads. One code path for what a row means.
///
/// ## Not every row is worth the same hurry
///
/// It used to be one 250 ms window over all six tables, and every one of
/// them invalidated the conversation list. Two of those tables are
/// written by machines rather than by people: `chat_presence` takes a
/// heartbeat from every signed-in colleague every thirty seconds, and
/// `chat_typing` takes a row every few seconds for as long as somebody
/// is pressing keys — at BOTH ends, because a client is sent its own
/// writes back.
///
/// So the list, the open thread's header and the unread counts were
/// being refetched over and over while a conversation was simply being
/// had, and a message — the one row anybody is waiting on — went into
/// the same queue behind them and waited out the same window. It read
/// as a screen that would not sit still and would not keep up, which is
/// a strange pair of complaints until you notice they have one cause.
///
/// Two speeds now. What a person did goes fast and moves everything it
/// touches. What a machine did goes slow and moves only the dot and the
/// word it is actually about — with the conversation list allowed one
/// refetch every [_listFloor] out of the pair of them, because
/// presence is also what draws "online" beside a name and it does have
/// to arrive eventually.
class ChatLive {
  ChatLive(this._ref);

  final Ref _ref;
  RealtimeChannel? _channel;
  Timer? _fast;
  Timer? _slow;
  Timer? _heartbeat;
  final _pending = <String>{};
  DateTime? _listRefetchedAt;

  /// Tables a person wrote, and the only ones anybody is waiting for.
  static const _quick = {
    'chat_messages',
    'chat_participants',
    // A phone rings because a row appeared. Nothing polls for a call:
    // `chat_start_call` writes a participant row per member and this is
    // what turns that into a ringing handset — so it is never made to
    // wait behind a heartbeat.
    'chat_calls',
    'chat_call_participants',
  };

  /// Tables a timer wrote.
  static const _background = {'chat_typing', 'chat_presence'};

  /// Long enough to collect a burst — a message insert also moves the
  /// conversation's `last_message_at` — short enough that nobody would
  /// call it a delay.
  static const _window = Duration(milliseconds: 150);

  /// A typing dot and a presence light are worth having and not worth
  /// hurrying. Nothing downstream of this window is something somebody
  /// is waiting to read.
  static const _slowWindow = Duration(seconds: 2);

  /// The most often presence or typing alone may cost a refetch of the
  /// conversation list. They do change what it shows — "online", and
  /// the dot beside a name — but not enough to redraw it every two
  /// seconds for as long as somebody is typing.
  static const _listFloor = Duration(seconds: 20);

  /// Comfortably inside the 75-second window the database treats as
  /// still-present, so one dropped beat does not blink somebody offline.
  static const _beat = Duration(seconds: 30);

  /// What the socket last said about itself.
  ///
  /// `subscribe()` was called with no callback, so a subscription that
  /// was refused, timed out, or quietly died was indistinguishable from
  /// one that had nothing to deliver: chat simply stopped updating and
  /// nothing anywhere knew. This is not shown on screen — there is
  /// nothing useful to say to a person about a websocket — it is what
  /// [_onStatus] acts on, and what a test can read.
  RealtimeSubscribeStatus? status;

  void connect(SupabaseClient client) {
    final channel = client.channel('chat');
    for (final table in const [
      'chat_messages',
      'chat_participants',
      'chat_typing',
      'chat_presence',
      'chat_calls',
      'chat_call_participants',
    ]) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => _touched(table),
      );
    }
    channel.subscribe(_onStatus);
    _channel = channel;

    // Say we are here, now, rather than waiting out the first interval —
    // otherwise somebody who has just opened the app looks offline to
    // everybody for half a minute.
    _sendBeat();
    _heartbeat = Timer.periodic(_beat, (_) => _sendBeat());
  }

  /// A subscription that has gone away is one nothing is arriving over.
  ///
  /// The client reconnects its own socket, but a channel that errored or
  /// timed out stays down, and the app on the other side of it looks
  /// exactly like a quiet afternoon. So the next refetch is forced — the
  /// screen catches up to whatever was missed — and the channel is asked
  /// to subscribe again.
  void _onStatus(RealtimeSubscribeStatus next, Object? error) {
    status = next;
    switch (next) {
      case RealtimeSubscribeStatus.subscribed:
        // Whatever happened while it was down, happened. Ask for all of
        // it rather than working out what was missed, which is the same
        // decision the rest of this file makes.
        _pending.addAll(_quick);
        _pending.addAll(_background);
        _flush();
      case RealtimeSubscribeStatus.channelError:
      case RealtimeSubscribeStatus.timedOut:
        _resubscribe();
      case RealtimeSubscribeStatus.closed:
        break;
    }
  }

  /// Backed off a little, because the commonest reason a channel errors
  /// is that the network is not there, and a tight retry against no
  /// network is a flat battery.
  void _resubscribe() {
    Timer(const Duration(seconds: 3), () {
      final channel = _channel;
      if (channel == null) return;
      channel.subscribe(_onStatus);
    });
  }

  void _sendBeat() {
    final repo = _ref.read(repoProvider);
    if (repo == null) return;
    // A heartbeat that fails is not worth a message on screen; the next
    // one is thirty seconds away and presence is a guess regardless.
    repo
        .chatHeartbeat(
          idle:
              WidgetsBinding.instance.lifecycleState !=
              AppLifecycleState.resumed,
        )
        .catchError((_) {});
  }

  void _touched(String table) {
    _pending.add(table);
    if (_background.contains(table)) {
      // Restarted, deliberately: there is no hurry, and a colleague
      // holding a key down should cost one refetch at the end rather
      // than one every two seconds.
      _slow?.cancel();
      _slow = Timer(_slowWindow, _flush);
      return;
    }
    // NOT restarted. A trailing debounce that resets on every event has
    // no upper bound: a steady trickle can hold the flush off for as
    // long as the trickle lasts, which is precisely a busy conversation
    // — the case where waiting is least acceptable.
    _fast ??= Timer(_window, _flush);
  }

  void _flush() {
    _fast?.cancel();
    _fast = null;
    _slow?.cancel();
    _slow = null;
    final tables = Set<String>.from(_pending);
    _pending.clear();
    if (tables.isEmpty) return;

    // The list carries unread counts, presence and receipts, so every
    // one of these tables can change what it shows — but only the first
    // group changes it in a way anybody is waiting on.
    if (tables.any(_quick.contains)) {
      _refetchTheList();
    } else if (_listDue) {
      _refetchTheList();
    }

    if (tables.contains('chat_messages') ||
        tables.contains('chat_participants')) {
      _ref.invalidate(chatThreadProvider);
    }
    if (tables.contains('chat_typing')) {
      _ref.invalidate(chatTypingProvider);
    }
    if (tables.contains('chat_presence')) {
      _ref.invalidate(chatDirectoryProvider);
    }
    if (tables.contains('chat_calls') ||
        tables.contains('chat_call_participants')) {
      _ref.invalidate(chatIncomingCallsProvider);
      _ref.invalidate(chatActiveCallProvider);
    }
  }

  bool get _listDue {
    final last = _listRefetchedAt;
    return last == null || DateTime.now().difference(last) >= _listFloor;
  }

  void _refetchTheList() {
    _listRefetchedAt = DateTime.now();
    _ref.invalidate(chatConversationsProvider);
  }

  void dispose() {
    _fast?.cancel();
    _slow?.cancel();
    _heartbeat?.cancel();
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      channel.unsubscribe();
    }
  }
}

/// Alive for as long as somebody is signed in with chat available.
///
/// Watched by the chat screen rather than the shell, so an app whose
/// company has never bought chat opens no socket and sends no heartbeat.
final chatLiveProvider = Provider.autoDispose<ChatLive>((ref) {
  final user = ref.watch(currentUserProvider);
  final live = ChatLive(ref);
  ref.onDispose(live.dispose);
  if (user == null) return live;
  live.connect(ref.watch(supabaseProvider));
  return live;
});
