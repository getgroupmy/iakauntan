import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'chat_attachments.dart';
import 'chat_live.dart';

/// Talking to people, in the app the work is already in.
///
/// Wide screens get the list and the open conversation side by side,
/// because that is what a chat on a desktop is; narrow ones get the list
/// and push the thread on top of it. One screen either way — the same
/// state, laid out twice — rather than two that can drift apart.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  String? _openId;

  static const _twoPane = 840.0;

  @override
  Widget build(BuildContext context) {
    // Holding the subscription open for as long as this screen is: the
    // socket and the heartbeat belong to chat, not to the whole app.
    ref.watch(chatLiveProvider);

    final wide = MediaQuery.sizeOf(context).width >= _twoPane;

    if (wide) {
      return Scaffold(
        appBar: AppBar(title: const Text('Chat')),
        body: Row(
          children: [
            SizedBox(
              width: 340,
              child: _ConversationList(
                selectedId: _openId,
                onOpen: (id) => setState(() => _openId = id),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: _openId == null
                  ? const EmptyState(
                      icon: Icons.forum_outlined,
                      title: 'Pick a conversation',
                      message: 'Or start one with the button on the left.',
                    )
                  : _Thread(key: ValueKey(_openId), conversationId: _openId!),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Chat')),
      body: _ConversationList(
        selectedId: null,
        onOpen: (id) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Conversation')),
              body: _Thread(conversationId: id),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------
class _ConversationList extends ConsumerWidget {
  const _ConversationList({required this.selectedId, required this.onOpen});

  final String? selectedId;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(chatConversationsProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  key: const ValueKey('chat-new'),
                  onPressed: () => _startOne(context, ref),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('New conversation'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: AsyncView(
            value: conversations,
            onRetry: () => ref.invalidate(chatConversationsProvider),
            builder: (list) => list.isEmpty
                ? const EmptyState(
                    icon: Icons.forum_outlined,
                    title: 'No conversations yet',
                    message:
                        'Colleagues appear once an administrator '
                        'switches chat on for them. People at another '
                        'company appear once the two companies are '
                        'linked.',
                  )
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final c = list[i];
                      final unread = (c['unread'] as num?)?.toInt() ?? 0;
                      final typing = c['they_are_typing'] == true;
                      return ListTile(
                        key: ValueKey('chat-${c['conversation_id']}'),
                        selected: c['conversation_id'] == selectedId,
                        onTap: () => onOpen(c['conversation_id'] as String),
                        leading: _Avatar(
                          name: c['other_name']?.toString(),
                          url: c['other_avatar_url']?.toString(),
                          state: c['other_state']?.toString(),
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                c['other_name']?.toString() ??
                                    c['title']?.toString() ??
                                    'Conversation',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: unread > 0
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                            if (c['last_message_at'] != null)
                              Text(
                                Fmt.date(
                                  DateTime.parse(
                                    c['last_message_at'].toString(),
                                  ).toLocal(),
                                ),
                                style: const TextStyle(fontSize: 11),
                              ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // The company is named on every cross-company
                            // row, always. In a thread that leaves the
                            // building, who you are talking to matters
                            // more than what they said.
                            if (c['is_cross_company'] == true)
                              Text(
                                c['other_org_name']?.toString() ?? '',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: context.colors.info,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            Text(
                              typing
                                  ? 'typing…'
                                  : (c['last_message']?.toString() ?? ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontStyle: typing
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                                color: typing ? context.colors.success : null,
                              ),
                            ),
                          ],
                        ),
                        trailing: unread > 0
                            ? Badge(label: Text('$unread'))
                            : null,
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _startOne(BuildContext context, WidgetRef ref) async {
    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _DirectoryDialog(),
    );
    if (chosen == null || !context.mounted) return;

    String? id;
    final ok = await runWithFeedback(
      context,
      action: () async {
        id = await ref
            .read(repoProvider)!
            .chatStartDirect(
              chosen['user_id'] as String,
              chosen['org_id'] as String,
            );
      },
      successMessage: null,
    );
    if (ok && id != null) {
      ref.invalidate(chatConversationsProvider);
      onOpen(id!);
    }
  }
}

/// A face, with a dot that says whether they are about.
class _Avatar extends StatelessWidget {
  const _Avatar({this.name, this.url, this.state});

  final String? name;
  final String? url;
  final String? state;

  @override
  Widget build(BuildContext context) {
    final initials = (name ?? '?')
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();

    final colour = switch (state) {
      'online' => context.colors.success,
      // Amber rather than green: the app is open and nobody is looking,
      // which is a different promise about how fast a reply comes.
      'idle' => context.colors.warning,
      _ => null,
    };

    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 18,
          backgroundImage: (url != null && url!.isNotEmpty)
              ? NetworkImage(url!)
              : null,
          child: (url == null || url!.isEmpty)
              ? Text(
                  initials.isEmpty ? '?' : initials,
                  style: const TextStyle(fontSize: 12),
                )
              : null,
        ),
        if (colour != null)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: colour,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// The thread
// ---------------------------------------------------------------------
class _Thread extends ConsumerStatefulWidget {
  const _Thread({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<_Thread> createState() => _ThreadState();
}

class _ThreadState extends ConsumerState<_Thread> {
  final _controller = TextEditingController();
  Timer? _typingThrottle;
  bool _sending = false;

  /// One typing notice every three seconds while keys are actually being
  /// pressed. Per keystroke would be a write per character.
  static const _throttle = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    // Opening it is reading it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
  }

  @override
  void dispose() {
    _typingThrottle?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _markRead() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    await repo.chatMarkRead(widget.conversationId).catchError((_) {});
    if (mounted) ref.invalidate(chatConversationsProvider);
  }

  void _onChanged(String value) {
    if (value.isEmpty) {
      _typingThrottle?.cancel();
      _typingThrottle = null;
      ref
          .read(repoProvider)
          ?.chatTypingStop(widget.conversationId)
          .catchError((_) {});
      return;
    }
    if (_typingThrottle?.isActive ?? false) return;
    ref
        .read(repoProvider)
        ?.chatTypingPing(widget.conversationId)
        .catchError((_) {});
    _typingThrottle = Timer(_throttle, () {});
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty || _sending) return;

    // The company we are in this conversation as, which the database
    // checks the message against rather than taking on trust.
    final row = (ref.read(chatConversationsProvider).value ?? const [])
        .cast<Map<String, dynamic>?>()
        .firstWhere(
          (c) => c?['conversation_id'] == widget.conversationId,
          orElse: () => null,
        );
    final myOrg = ref.read(currentOrgProvider).value?.id;
    if (myOrg == null) return;

    setState(() => _sending = true);
    _controller.clear();
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .chatSend(widget.conversationId, body, senderOrgId: myOrg),
      successMessage: null,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) {
      ref.invalidate(chatThreadProvider(widget.conversationId));
      ref.invalidate(chatConversationsProvider);
    } else {
      // Give it back rather than losing what they typed.
      _controller.text = body;
    }
    // Referenced so the unused-local analyzer stays quiet about the row
    // lookup above, which documents why sender_org_id is what it is.
    assert(row == null || row['conversation_id'] == widget.conversationId);
  }

  @override
  Widget build(BuildContext context) {
    final thread = ref.watch(chatThreadProvider(widget.conversationId));
    final typing = ref.watch(chatTypingProvider(widget.conversationId));
    // The company we are in this conversation as. Null only while the
    // organization is still loading, which is when there is nothing to
    // attach a file to anyway.
    final myOrg = ref.watch(currentOrgProvider).value?.id;

    return Column(
      children: [
        Expanded(
          child: AsyncView(
            value: thread,
            onRetry: () =>
                ref.invalidate(chatThreadProvider(widget.conversationId)),
            builder: (rows) => rows.isEmpty
                ? const EmptyState(
                    icon: Icons.waving_hand_outlined,
                    title: 'Nothing yet',
                    message: 'Say something.',
                  )
                : ListView.builder(
                    // The function returns newest first and the view is
                    // reversed, so the newest sits at the bottom without
                    // anything having to scroll after it loads.
                    reverse: true,
                    padding: const EdgeInsets.all(Space.lg),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => _Bubble(message: rows[i]),
                  ),
          ),
        ),
        // Whoever is typing, named, because in a room "someone" is not
        // useful and in a direct thread the name is already on screen.
        SizedBox(
          height: 18,
          child: typing.maybeWhen(
            data: (who) => who.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                    child: Text(
                      who.length == 1
                          ? '${who.first['full_name']} is typing…'
                          : '${who.length} people are typing…',
                      style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: context.colors.success,
                      ),
                    ),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(Space.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (myOrg != null)
                ChatComposerActions(
                  conversationId: widget.conversationId,
                  senderOrgId: myOrg,
                  onSent: () {
                    ref.invalidate(chatThreadProvider(widget.conversationId));
                    ref.invalidate(chatConversationsProvider);
                  },
                ),
              Expanded(
                child: TextField(
                  key: const ValueKey('chat-input'),
                  controller: _controller,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onChanged: _onChanged,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Write a message',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: Space.sm),
              IconButton.filled(
                key: const ValueKey('chat-send'),
                onPressed: _sending ? null : _send,
                icon: const Icon(Icons.send, size: 18),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final Map<String, dynamic> message;

  @override
  Widget build(BuildContext context) {
    final mine = message['is_mine'] == true;
    final scheme = Theme.of(context).colorScheme;
    final at = DateTime.parse(message['created_at'].toString()).toLocal();

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (!mine)
              Text(
                message['sender_name']?.toString() ?? '',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            for (final a in (message['attachments'] as List? ?? const []))
              ChatAttachmentView(
                attachment: Map<String, dynamic>.from(a as Map),
              ),
            // A file or a voice note may arrive with nothing said about
            // it, and an empty line under it reads as a rendering fault.
            if ((message['body']?.toString() ?? '').trim().isNotEmpty)
              Text(message['body'].toString()),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${at.hour.toString().padLeft(2, '0')}:'
                  '${at.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 10),
                ),
                if (message['edited_at'] != null)
                  const Text(' · edited', style: TextStyle(fontSize: 10)),
                if (mine) ...[
                  const SizedBox(width: 4),
                  _Receipt(state: message['state']?.toString()),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One tick sent, two delivered, two blue read — the convention people
/// already know, so it needs no key on screen.
class _Receipt extends StatelessWidget {
  const _Receipt({required this.state});

  final String? state;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      'read' => Icon(Icons.done_all, size: 13, color: context.colors.info),
      'delivered' => const Icon(Icons.done_all, size: 13),
      _ => const Icon(Icons.done, size: 13),
    };
  }
}

// ---------------------------------------------------------------------
// Who you may talk to
// ---------------------------------------------------------------------
class _DirectoryDialog extends ConsumerStatefulWidget {
  const _DirectoryDialog();

  @override
  ConsumerState<_DirectoryDialog> createState() => _DirectoryDialogState();
}

class _DirectoryDialogState extends ConsumerState<_DirectoryDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final directory = ref.watch(chatDirectoryProvider);
    final q = _query.trim().toLowerCase();

    return AlertDialog(
      title: const Text('Start a conversation'),
      content: SizedBox(
        width: 440,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Name or company',
              ),
            ),
            const SizedBox(height: Space.sm),
            Expanded(
              child: AsyncView(
                value: directory,
                onRetry: () => ref.invalidate(chatDirectoryProvider),
                builder: (all) {
                  final rows = q.isEmpty
                      ? all
                      : all
                            .where(
                              (p) => '${p['full_name']} ${p['org_name']}'
                                  .toLowerCase()
                                  .contains(q),
                            )
                            .toList();
                  if (rows.isEmpty) {
                    return const EmptyState(
                      icon: Icons.person_search_outlined,
                      title: 'Nobody to message',
                      message:
                          'Colleagues appear once an administrator '
                          'switches chat on for them. People at another '
                          'company appear once both companies have '
                          'agreed a link.',
                    );
                  }
                  return ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final p = rows[i];
                      return ListTile(
                        dense: true,
                        leading: _Avatar(
                          name: p['full_name']?.toString(),
                          url: p['avatar_url']?.toString(),
                          state: p['state']?.toString(),
                        ),
                        title: Text(p['full_name']?.toString() ?? ''),
                        subtitle: Text(
                          p['org_name']?.toString() ?? '',
                          style: TextStyle(
                            fontSize: 11,
                            color: p['is_cross_company'] == true
                                ? context.colors.info
                                : null,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(p),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
