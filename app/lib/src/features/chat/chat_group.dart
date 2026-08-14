import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Starting a room, and seeing who is in one.
///
/// The rule worth knowing while using this: to be added, somebody's
/// company must be linked to *every* company already in the room, not
/// merely to yours. Two suppliers who have each agreed to talk to you
/// have not thereby agreed to talk to each other, and the database
/// refuses the shortcut. The picker below says so before the refusal
/// arrives, because "42501" in a snackbar explains nothing.
class NewGroupDialog extends ConsumerStatefulWidget {
  const NewGroupDialog({super.key});

  @override
  ConsumerState<NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends ConsumerState<NewGroupDialog> {
  final _title = TextEditingController();
  final _chosen = <String, Map<String, dynamic>>{};
  String _query = '';
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  bool get _valid => _title.text.trim().isNotEmpty && _chosen.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final directory = ref.watch(chatDirectoryProvider);
    final q = _query.trim().toLowerCase();

    return AlertDialog(
      title: const Text('New group'),
      content: SizedBox(
        width: 460,
        height: 480,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('group-title'),
              controller: _title,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'What is it about',
                hintText: 'Projek Menara',
              ),
            ),
            const SizedBox(height: Space.sm),
            TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Add people',
                isDense: true,
              ),
            ),
            if (_chosen.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final p in _chosen.values)
                      Chip(
                        label: Text(p['full_name']?.toString() ?? ''),
                        onDeleted: () =>
                            setState(() => _chosen.remove(p['user_id'])),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
            ],
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
                      title: 'Nobody to add',
                      message:
                          'Colleagues appear once an administrator '
                          'switches chat on for them.',
                    );
                  }
                  return ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final p = rows[i];
                      final id = p['user_id'] as String;
                      return CheckboxListTile(
                        key: ValueKey('group-member-$id'),
                        dense: true,
                        value: _chosen.containsKey(id),
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
                        onChanged: (on) => setState(() {
                          if (on == true) {
                            _chosen[id] = p;
                          } else {
                            _chosen.remove(id);
                          }
                        }),
                      );
                    },
                  );
                },
              ),
            ),
            if (_crossesCompanies)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  'People from more than one company. Every company in '
                  'the group has to be linked to every other, not just '
                  'to yours — otherwise this will be refused.',
                  style: TextStyle(fontSize: 11, color: context.colors.warning),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('group-create'),
          onPressed: _valid && !_saving ? _create : null,
          child: const Text('Create'),
        ),
      ],
    );
  }

  /// More than one company among the people chosen, counting mine.
  bool get _crossesCompanies =>
      _chosen.values.map((p) => p['org_id']).toSet().length > 1 ||
      _chosen.values.any((p) => p['is_cross_company'] == true);

  Future<void> _create() async {
    setState(() => _saving = true);
    String? id;
    final ok = await runWithFeedback(
      context,
      action: () async {
        id = await ref
            .read(repoProvider)!
            .chatCreateGroup(
              title: _title.text.trim(),
              members: _chosen.values.toList(),
            );
      },
      successMessage: null,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok && id != null) Navigator.of(context).pop(id);
  }
}

/// Who is in this conversation, and the way out of it.
class MembersSheet extends ConsumerWidget {
  const MembersSheet({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(chatMembersProvider(conversationId));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: AsyncView(
          value: members,
          onRetry: () => ref.invalidate(chatMembersProvider(conversationId)),
          builder: (list) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                'In this conversation',
                subtitle: '${list.length} people',
              ),
              for (final m in list)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.circle,
                    size: 10,
                    color: switch (m['state']) {
                      'online' => context.colors.success,
                      'idle' => context.colors.warning,
                      _ => Theme.of(context).disabledColor,
                    },
                  ),
                  title: Text(
                    m['is_me'] == true
                        ? '${m['full_name']} (you)'
                        : m['full_name']?.toString() ?? '',
                  ),
                  // The company on every row, not just the away ones. In
                  // a room that leaves the building, "who else is here"
                  // is a question about companies as much as people.
                  subtitle: Text(
                    m['org_name']?.toString() ?? '',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  TextButton.icon(
                    key: const ValueKey('chat-add-member'),
                    onPressed: () => _add(context, ref),
                    icon: const Icon(Icons.person_add_alt, size: 18),
                    label: const Text('Add somebody'),
                  ),
                  const Spacer(),
                  TextButton(
                    key: const ValueKey('chat-leave'),
                    onPressed: () => _leave(context, ref),
                    child: Text(
                      'Leave',
                      style: TextStyle(color: context.colors.danger),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final directory = ref.read(chatDirectoryProvider).value ?? const [];
    final already =
        (ref.read(chatMembersProvider(conversationId)).value ??
                const <Map<String, dynamic>>[])
            .map((m) => m['user_id'])
            .toSet();
    final candidates = directory
        .where((p) => !already.contains(p['user_id']))
        .toList();

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Everybody you can reach is already in.')),
      );
      return;
    }

    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Add somebody'),
        children: [
          for (final p in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(p),
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(p['full_name']?.toString() ?? ''),
                subtitle: Text(
                  p['org_name']?.toString() ?? '',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !context.mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .chatAddParticipant(
            conversationId,
            chosen['user_id'] as String,
            chosen['org_id'] as String,
          ),
      successMessage: 'Added',
    );
    if (ok) {
      ref.invalidate(chatMembersProvider(conversationId));
      ref.invalidate(chatConversationsProvider);
    }
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final sure = await confirm(
      context,
      title: 'Leave this conversation?',
      message:
          'It goes off your list and you stop being able to read it — '
          'including what was said before today. The others keep the '
          'thread.',
      confirmLabel: 'Leave',
      destructive: true,
    );
    if (!sure || !context.mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.chatLeave(conversationId),
      successMessage: 'Left',
    );
    if (ok && context.mounted) {
      ref.invalidate(chatConversationsProvider);
      Navigator.of(context).pop(true);
    }
  }
}
