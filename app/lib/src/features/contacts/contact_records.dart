import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// One company, one record per role.
///
/// A supplier who starts buying from you is not retyped; a second
/// record is made, coded in the customer series, and the supplier
/// record goes on carrying its bills under its own code:
///
///     Al Hardware Sdn Bhd   supplier   S-2026-00001
///     Al Hardware Sdn Bhd   customer   C-2026-00013
///     Al Hardware Sdn Bhd   prospect   P-2026-00343
///
/// This sheet shows the other records of the company this contact is,
/// and offers a record for each role it has none for. The options come
/// from `contact_records`, which reads the same helper
/// `create_contact_as` refuses on -- so the sheet cannot offer a record
/// the database will refuse to make, and cannot hide one it would.
Future<void> showContactRecords(BuildContext context, String contactId) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _RecordsSheet(contactId: contactId),
    );

/// What each role is called, and the sentence that says what a record
/// in it is for.
const _roles = <String, (String, String)>{
  'customer': ('Customer', 'You sell to them'),
  'supplier': ('Supplier', 'You buy from them'),
  'prospect': ('Prospect', 'Somebody you have not sold to yet'),
};

/// What a role is called on screen: `both` is spelt out, the rest
/// as [_roles] has them.
String contactRoleLabel(String type) => switch (type) {
  'both' => 'Customer & Supplier',
  _ => _roles[type]?.$1 ?? Fmt.label(type),
};

IconData contactRoleIcon(String type) => switch (type) {
  'customer' => Icons.person_outline,
  'supplier' => Icons.local_shipping_outlined,
  'both' => Icons.swap_horiz,
  'prospect' => Icons.emoji_objects_outlined,
  _ => Icons.badge_outlined,
};

class _RecordsSheet extends ConsumerWidget {
  const _RecordsSheet({required this.contactId});

  final String contactId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(contactRecordsProvider(contactId));

    return SizedBox(
      height: 520,
      child: AsyncView(
        value: records,
        onRetry: () => ref.invalidate(contactRecordsProvider(contactId)),
        builder: (data) {
          final others = (data['records'] as List? ?? [])
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList();
          final options = (data['options'] as List? ?? [])
              .map((o) => Map<String, dynamic>.from(o as Map))
              .toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
            children: [
              Text(
                '${data['name']}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '${data['code']} · ${contactRoleLabel('${data['contact_type']}')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Text(
                'Other records of this company',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              if (others.isEmpty)
                Text(
                  'None yet. This is their only record.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                for (final r in others)
                  Card(
                    child: ListTile(
                      key: ValueKey('record-${r['id']}'),
                      leading: Icon(
                        contactRoleIcon('${r['contact_type']}'),
                        size: 20,
                      ),
                      title: Text('${r['code']}'),
                      subtitle: Text(contactRoleLabel('${r['contact_type']}')),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () {
                        Navigator.pop(context);
                        context.go('/contacts/${r['id']}');
                      },
                    ),
                  ),
              const SizedBox(height: 16),
              Text(
                'Create a record',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              for (final o in options)
                _CreateOption(
                  contactId: contactId,
                  as: '${o['as']}',
                  prefix: '${o['prefix'] ?? ''}',
                  existing: o['existing'] == null
                      ? null
                      : Map<String, dynamic>.from(o['existing'] as Map),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CreateOption extends ConsumerWidget {
  const _CreateOption({
    required this.contactId,
    required this.as,
    required this.prefix,
    required this.existing,
  });

  final String contactId;
  final String as;
  final String prefix;

  /// The record that already fills this role, if any. Shown rather
  /// than the option being hidden: somebody who came here to make a
  /// supplier record needs to see that there is one, and which.
  final Map<String, dynamic>? existing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (label, blurb) = _roles[as] ?? (Fmt.label(as), '');
    final have = existing;
    final open = have == null;

    return Card(
      child: ListTile(
        key: ValueKey('create-as-$as'),
        enabled: open,
        leading: Icon(
          contactRoleIcon(as),
          size: 20,
          color: open ? null : Theme.of(context).disabledColor,
        ),
        title: Text('Create a $label record'),
        subtitle: Text(
          open
              ? '$blurb · coded ${prefix}YYYY-NNNNN'
              : 'Already ${have['code']}',
        ),
        onTap: !open
            ? null
            : () async {
                final repo = ref.read(repoProvider);
                if (repo == null) return;
                String? newId;
                final done = await runWithFeedback(
                  context,
                  doing: 'create the $label record',
                  successMessage: '$label record created',
                  action: () async {
                    newId = await repo.createContactAs(contactId, as);
                  },
                );
                ref.invalidate(contactRecordsProvider(contactId));
                ref.invalidate(contactsProvider);
                if (!done || !context.mounted) return;
                Navigator.pop(context);
                final id = newId;
                if (id != null) context.go('/contacts/$id');
              },
      ),
    );
  }
}
