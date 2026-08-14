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
class ChatLive {
  ChatLive(this._ref);

  final Ref _ref;
  RealtimeChannel? _channel;
  Timer? _settle;
  Timer? _heartbeat;
  final _pending = <String>{};

  /// Long enough to collect a burst — a message insert also moves the
  /// conversation's `last_message_at` and clears a typing row — short
  /// enough that it still reads as immediate.
  static const _window = Duration(milliseconds: 250);

  /// Comfortably inside the 75-second window the database treats as
  /// still-present, so one dropped beat does not blink somebody offline.
  static const _beat = Duration(seconds: 30);

  void connect(SupabaseClient client) {
    final channel = client.channel('chat');
    for (final table in const [
      'chat_messages',
      'chat_participants',
      'chat_typing',
      'chat_presence',
    ]) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => _touched(table),
      );
    }
    channel.subscribe();
    _channel = channel;

    // Say we are here, now, rather than waiting out the first interval —
    // otherwise somebody who has just opened the app looks offline to
    // everybody for half a minute.
    _sendBeat();
    _heartbeat = Timer.periodic(_beat, (_) => _sendBeat());
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
    _settle?.cancel();
    _settle = Timer(_window, _flush);
  }

  void _flush() {
    final tables = Set<String>.from(_pending);
    _pending.clear();
    if (tables.isEmpty) return;

    // The list carries unread counts, presence and receipts, so every
    // one of these tables can change what it shows.
    _ref.invalidate(chatConversationsProvider);
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
  }

  void dispose() {
    _settle?.cancel();
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
