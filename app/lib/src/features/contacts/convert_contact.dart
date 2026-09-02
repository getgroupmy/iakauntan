import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Say what a contact is now.
///
/// A supplier who starts selling to you, a prospect who places an
/// order. The contact is the same contact; what it is *to you* has
/// changed.
///
/// The options come from `contact_conversions`, which reads the same
/// helper the database trigger enforces on — so this sheet cannot offer
/// something the save will refuse, and cannot hide something it would
/// have allowed.
Future<void> showConvertContact(
  BuildContext context,
  String contactId,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (_) => _ConvertSheet(contactId: contactId),
);

/// What each type is called, and the sentence that says why you would
/// pick it. `both` is the one people do not think of, and it is usually
/// the right answer, so it says so.
const _kinds = <String, (String, String)>{
  'customer': ('Customer', 'You sell to them'),
  'supplier': ('Supplier', 'You buy from them'),
  'both': ('Both', 'You sell to them and buy from them'),
  'prospect': ('Prospect', 'Somebody you have not sold to yet'),
};

class _ConvertSheet extends ConsumerWidget {
  const _ConvertSheet({required this.contactId});

  final String contactId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(contactConversionsProvider(contactId));

    return SizedBox(
      height: 460,
      child: AsyncView(
        value: options,
        onRetry: () => ref.invalidate(contactConversionsProvider(contactId)),
        builder: (data) {
          final now = '${data['contact_type']}';
          final list = (data['options'] as List? ?? [])
              .map((o) => Map<String, dynamic>.from(o as Map))
              .toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              0,
              Space.lg,
              Space.lg,
            ),
            children: [
              Text(
                '${data['name']}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Currently ${_kinds[now]?.$1 ?? Fmt.label(now)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final o in list)
                _Option(
                  contactId: contactId,
                  to: '${o['to']}',
                  allowed: o['allowed'] == true,
                  blockedBy: (o['blocked_by'] as List? ?? [])
                      .map((b) => '$b')
                      .toList(),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Option extends ConsumerWidget {
  const _Option({
    required this.contactId,
    required this.to,
    required this.allowed,
    required this.blockedBy,
  });

  final String contactId;
  final String to;
  final bool allowed;
  final List<String> blockedBy;

  /// Why it cannot be done, in the words of the thing that stops it.
  ///
  /// Shown rather than the option being hidden: somebody who came here
  /// to make this change needs to know it was considered and why the
  /// answer is no, or they will try it again in the editor.
  String get _why {
    final roles = blockedBy
        .map((r) => r == 'customer' ? 'sold to them' : 'bought from them')
        .join(' and ');
    return 'You have $roles. Use Both to add a role instead.';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (label, blurb) = _kinds[to] ?? (Fmt.label(to), '');

    return Card(
      child: ListTile(
        key: ValueKey('convert-to-$to'),
        enabled: allowed,
        leading: Icon(
          switch (to) {
            'customer' => Icons.person_outline,
            'supplier' => Icons.local_shipping_outlined,
            'both' => Icons.swap_horiz,
            _ => Icons.emoji_objects_outlined,
          },
          size: 20,
          color: allowed ? null : Theme.of(context).disabledColor,
        ),
        title: Text('Make them a $label'),
        subtitle: Text(allowed ? blurb : _why),
        onTap: !allowed
            ? null
            : () async {
                final repo = ref.read(repoProvider);
                if (repo == null) return;
                final done = await runWithFeedback(
                  context,
                  doing: 'change what this contact is',
                  successMessage: 'Now a $label',
                  action: () => repo.convertContact(contactId, to),
                );
                ref.invalidate(contactConversionsProvider(contactId));
                ref.invalidate(contactsProvider);
                if (done && context.mounted) Navigator.pop(context);
              },
      ),
    );
  }
}
