import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Who in this company may use chat, and which other companies it may
/// talk to.
///
/// Both halves are administrator work and both are deliberately dull to
/// operate: a switch per person, and a list of companies with the
/// pending ones at the top. Buying chat for a company does not put every
/// clerk in it into a conversation with a supplier — somebody decides,
/// one person at a time, and can undo it.
class ChatCard extends ConsumerWidget {
  const ChatCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canAdmin = ref.watch(canAdminProvider);
    if (!canAdmin) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Chat',
              subtitle: 'Who may use it, and who they may reach',
            ),
            const _AccessList(),
            const Divider(height: Space.xl),
            const _Links(),
          ],
        ),
      ),
    );
  }
}

class _AccessList extends ConsumerWidget {
  const _AccessList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(chatAccessListProvider);

    return AsyncView(
      value: people,
      onRetry: () => ref.invalidate(chatAccessListProvider),
      loading: const LinearProgressIndicator(),
      builder: (list) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Chat is off for everybody until you switch it on. Switching '
            'somebody off again takes their conversations away, not just '
            'the button.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: Space.sm),
          for (final p in list)
            SwitchListTile(
              key: ValueKey('chat-access-${p['user_id']}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: p['is_enabled'] == true,
              title: Text(p['full_name']?.toString() ?? ''),
              subtitle: Text(
                '${p['email'] ?? ''}  ·  ${Fmt.label(p['role']?.toString() ?? '')}',
                style: const TextStyle(fontSize: 11),
              ),
              onChanged: (v) async {
                final ok = await runWithFeedback(
                  context,
                  action: () => ref
                      .read(repoProvider)!
                      .chatSetAccess(p['user_id'] as String, v),
                  successMessage: v ? 'Chat switched on' : 'Chat switched off',
                );
                if (ok) ref.invalidate(chatAccessListProvider);
              },
            ),
        ],
      ),
    );
  }
}

class _Links extends ConsumerWidget {
  const _Links();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = ref.watch(chatLinksProvider);

    return AsyncView(
      value: links,
      onRetry: () => ref.invalidate(chatLinksProvider),
      loading: const LinearProgressIndicator(),
      builder: (list) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Linked companies',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const Text(
            'People here can only message another company once both '
            'sides have agreed. A sister company in your group is no '
            'exception — it still asks, and you still accept.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: Space.sm),
          if (list.isEmpty)
            const Text('No links yet.', style: TextStyle(fontSize: 13))
          else
            for (final l in list)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l['other_org_name']?.toString() ?? '',
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                          Text(
                            [
                              l['kind'] == 'group'
                                  ? 'same group'
                                  : 'another company',
                              if (l['we_asked'] == true) 'we asked',
                              if (l['awaiting_us'] == true) 'waiting on you',
                            ].join('  ·  '),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    if (l['awaiting_us'] == true) ...[
                      TextButton(
                        onPressed: () => _decide(context, ref, l, false),
                        child: Text(
                          'Refuse',
                          style: TextStyle(color: context.colors.danger),
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: () => _decide(context, ref, l, true),
                        child: const Text('Accept'),
                      ),
                    ] else ...[
                      StatusChip(l['status']?.toString() ?? '', compact: true),
                      if (l['status'] != 'revoked')
                        IconButton(
                          tooltip: 'End this link',
                          icon: const Icon(Icons.link_off, size: 18),
                          onPressed: () => _revoke(context, ref, l),
                        ),
                    ],
                  ],
                ),
              ),
          const SizedBox(height: Space.sm),
          TextButton.icon(
            key: const ValueKey('chat-link-add'),
            onPressed: () => _ask(context, ref),
            icon: const Icon(Icons.add_link, size: 18),
            label: const Text('Ask another company'),
          ),
        ],
      ),
    );
  }

  Future<void> _decide(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> link,
    bool approve,
  ) async {
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.chatDecideLink(link['id'] as String, approve),
      successMessage: approve ? 'Linked' : 'Refused',
    );
    if (ok) {
      ref.invalidate(chatLinksProvider);
      ref.invalidate(chatDirectoryProvider);
    }
  }

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> link,
  ) async {
    final sure = await confirm(
      context,
      title: 'End the link with ${link['other_org_name']}?',
      message:
          'Nobody new can be messaged across it. Conversations that '
          'already exist keep their history — what stops is starting '
          'anything more.',
      confirmLabel: 'End it',
      destructive: true,
    );
    if (!sure || !context.mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.chatRevokeLink(link['id'] as String),
      successMessage: 'Link ended',
    );
    if (ok) {
      ref.invalidate(chatLinksProvider);
      ref.invalidate(chatDirectoryProvider);
    }
  }

  Future<void> _ask(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final note = TextEditingController();
    final id = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ask another company'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'They have to accept before anybody can message them. '
                'Their administrator will see the request in their own '
                'settings.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                key: const ValueKey('chat-link-org'),
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Their company ID',
                  helperText:
                      'Ask them for it — it is on their settings '
                      'screen',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: note,
                decoration: const InputDecoration(
                  labelText: 'Why (optional)',
                  hintText: 'We are your supplier',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isNotEmpty) Navigator.of(ctx).pop(v);
            },
            child: const Text('Send request'),
          ),
        ],
      ),
    );
    if (id == null || !context.mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.chatRequestLink(id, note: note.text),
      successMessage: 'Request sent',
    );
    if (ok) ref.invalidate(chatLinksProvider);
  }
}
