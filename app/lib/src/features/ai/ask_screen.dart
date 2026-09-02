import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Ask about your books.
///
/// A question in a sentence, answered from this company's own posted
/// figures. The assistant reads through `ai_run_tool` under the asker's
/// own token, so it can see exactly what they can see and nothing more
/// — which is why this screen shows what it was able to read beneath
/// each answer rather than asking anyone to take the number on trust.
class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key});

  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final _question = TextEditingController();
  final _scroll = ScrollController();

  /// The conversation being added to. Null is a new one, which the
  /// server opens on the first question.
  String? _conversationId;

  /// What has been said, oldest first. Held here rather than refetched
  /// after every turn: the answer arrives in the reply, and a refetch
  /// would put a spinner over a conversation somebody is reading.
  final List<_Turn> _turns = [];

  bool _asking = false;
  String? _error;

  @override
  void dispose() {
    _question.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _question.text.trim();
    if (text.isEmpty || _asking) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    setState(() {
      _turns.add(_Turn.question(text));
      _asking = true;
      _error = null;
      _question.clear();
    });
    _toBottom();

    try {
      final res = await repo.aiAsk(text, conversationId: _conversationId);
      if (!mounted) return;
      setState(() {
        _conversationId = res['conversation_id'] as String?;
        _turns.add(
          _Turn.answer(
            '${res['answer']}',
            (res['tool_calls'] as List? ?? [])
                .map((c) => '${(c as Map)['tool']}')
                .toList(),
          ),
        );
        _asking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Shown rather than swallowed. Every refusal that reaches here
        // — no credit, the module switched off, a report this person
        // may not read — is a sentence somebody wrote for somebody to
        // read, and it says what to do next.
        _error = e.toString().replaceFirst('Exception: ', '');
        _asking = false;
      });
    }
    _toBottom();
  }

  /// Reopen something asked before.
  ///
  /// The stored turns are replayed as they were said. Tool results are
  /// not among them — `ai_messages` keeps which reports an answer used,
  /// not what they said that day, deliberately: a balance shown again a
  /// week later, looking current, is worse than one not shown at all.
  Future<void> _open(String id) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() {
      _asking = true;
      _error = null;
    });
    try {
      final convo = await repo.aiConversation(id);
      if (!mounted) return;
      final said = (convo['messages'] as List? ?? [])
          .map((m) => Map<String, dynamic>.from(m as Map))
          .toList();
      setState(() {
        _conversationId = id;
        _turns
          ..clear()
          ..addAll([
            for (final m in said)
              if (m['role'] == 'user')
                _Turn.question('${m['content']}')
              else if (m['role'] == 'assistant')
                _Turn.answer(
                  '${m['content']}',
                  (m['tool_calls'] as List? ?? [])
                      .map((c) => '${(c as Map)['tool']}')
                      .toList(),
                ),
          ]);
        _asking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _asking = false;
      });
    }
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ask about your books'),
        actions: [
          IconButton(
            key: const ValueKey('ask-earlier'),
            tooltip: 'Asked before',
            onPressed: _asking
                ? null
                : () => showModalBottomSheet<void>(
                    context: context,
                    showDragHandle: true,
                    builder: (_) => _Earlier(onOpen: _open),
                  ),
            icon: const Icon(Icons.history),
          ),
          if (_turns.isNotEmpty)
            IconButton(
              key: const ValueKey('ask-new'),
              tooltip: 'Start again',
              onPressed: _asking
                  ? null
                  : () => setState(() {
                      _turns.clear();
                      _conversationId = null;
                      _error = null;
                    }),
              icon: const Icon(Icons.add_comment_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _turns.isEmpty
                ? const _Opening()
                : ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.all(Space.lg),
                    itemCount: _turns.length + (_asking ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => i < _turns.length
                        ? _TurnCard(turn: _turns[i])
                        : const _Thinking(),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 18,
                    color: context.colors.danger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(color: context.colors.danger),
                    ),
                  ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('ask-question'),
                      controller: _question,
                      minLines: 1,
                      maxLines: 4,
                      enabled: !_asking,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Who owes us the most, and since when?',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('ask-send'),
                    onPressed: _asking ? null : _send,
                    child: const Text('Ask'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What it can do, before anybody has asked it anything.
///
/// The list is the tool catalogue, read from the server rather than
/// typed here: a screen that promises a report the assistant cannot
/// reach is worse than one that promises nothing.
class _Opening extends ConsumerWidget {
  const _Opening();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tools = ref.watch(aiToolsProvider);
    return AsyncView(
      value: tools,
      onRetry: () => ref.invalidate(aiToolsProvider),
      builder: (rows) => ListView(
        padding: const EdgeInsets.all(Space.lg),
        children: [
          const EmptyState(
            icon: Icons.auto_awesome_outlined,
            title: 'Ask about your books',
            message:
                'Questions are answered from this company\'s own posted '
                'figures, not from memory. It sees exactly what you can '
                'see — no more.',
          ),
          const SizedBox(height: 8),
          Text(
            'What it can read',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          for (final t in rows)
            Card(
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.description_outlined, size: 20),
                title: Text(Fmt.label('${t['name']}')),
                subtitle: Text('${t['description']}'),
              ),
            ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.md),
              child: Text(
                'Nothing yet — the assistant has no reports switched on '
                'for this company.',
              ),
            ),
        ],
      ),
    );
  }
}

/// What this person has asked before, in this company.
///
/// Their own, and an administrator's view of everybody's — which is
/// `ai_conversations_for`'s rule, not this sheet's, so there is nothing
/// here that could disagree with it.
class _Earlier extends ConsumerWidget {
  const _Earlier({required this.onOpen});

  final void Function(String id) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final convos = ref.watch(aiConversationsProvider);
    return SizedBox(
      height: 420,
      child: AsyncView(
        value: convos,
        onRetry: () => ref.invalidate(aiConversationsProvider),
        builder: (rows) => rows.isEmpty
            ? const EmptyState(
                icon: Icons.history,
                title: 'Nothing asked yet',
                message: 'Questions you ask are kept here, so you can pick '
                    'one up where you left it.',
              )
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                itemCount: rows.length,
                itemBuilder: (_, i) {
                  final r = rows[i];
                  return ListTile(
                    key: ValueKey('ask-earlier-${r['id']}'),
                    leading: const Icon(Icons.chat_bubble_outline, size: 20),
                    title: Text('${r['title']}'),
                    subtitle: Text(
                      Fmt.dateTime(
                        DateTime.tryParse('${r['updated_at']}'),
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      onOpen('${r['id']}');
                    },
                  );
                },
              ),
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(Space.md),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Text('Reading the books…'),
        ],
      ),
    );
  }
}

class _Turn {
  const _Turn.question(this.text) : mine = true, tools = const [];
  const _Turn.answer(this.text, this.tools) : mine = false;

  final String text;
  final bool mine;

  /// Which reports the answer was built from. Shown because a figure
  /// nobody can trace is a figure nobody should act on.
  final List<String> tools;
}

class _TurnCard extends StatelessWidget {
  const _TurnCard({required this.turn});

  final _Turn turn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: turn.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Card(
          color: turn.mine ? scheme.secondaryContainer : null,
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(turn.text),
                if (turn.tools.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in turn.tools.toSet())
                        Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.description_outlined,
                              size: 14),
                          label: Text(Fmt.label(t)),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
