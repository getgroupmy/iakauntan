import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'contact_records.dart' show contactRoleLabel, contactRoleIcon;

/// The records that were already on file twice.
///
/// The editor warns as a contact is typed, and the database links the
/// records of one company as they arrive. Neither reaches what was
/// typed before: Al Hardware filed as a supplier in March and typed
/// in again as a customer in June is two records that no correct
/// behaviour from now on will find. This is where they are found.
///
/// Nothing here links on sight. A registration number typed into the
/// wrong row would put two companies' invoices on one statement, and
/// the first anyone would know is the statement. So the server
/// reports the groups, somebody looks, and untickes what does not
/// belong before pressing the button.
class DuplicateContactsScreen extends ConsumerWidget {
  const DuplicateContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(contactDuplicatesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Records on file twice')),
      body: AsyncView(
        value: groups,
        onRetry: () => ref.invalidate(contactDuplicatesProvider),
        skeleton: const ListSkeleton(rows: 6, leading: false, subtitle: false),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.done_all,
              title: 'Nothing on file twice',
              message: 'No two records carry the same registration '
                  'number, ID or TIN.',
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final g in list)
                _Group(key: ValueKey(groupKey(g)), group: g),
            ],
          );
        },
      ),
    );
  }
}

/// A group is the set of records it holds, whatever identifier found
/// them: the same pair linked and reported again under another number
/// would otherwise be a different card on every rebuild.
String groupKey(Map<String, dynamic> group) =>
    (recordsOf(group).map((r) => '${r['id']}').toList()..sort()).join(',');

List<Map<String, dynamic>> recordsOf(Map<String, dynamic> group) => [
  for (final r in (group['records'] as List? ?? const []))
    Map<String, dynamic>.from(r as Map),
];

/// What the records were found by, in words.
String duplicateReason(String? matchedOn) => switch (matchedOn) {
  'registration_no' => 'Same registration number',
  'id' => 'Same ID number',
  'tin' => 'Same TIN',
  _ => 'Same details',
};

/// The number they share, with the ID's type taken off the front:
/// the server stores an ID match as `BRN:202001012345` so that an
/// NRIC and a BRN of the same digits are not one number.
String duplicateValue(Map<String, dynamic> group) {
  final v = '${group['value'] ?? ''}';
  return group['matched_on'] == 'id' && v.contains(':')
      ? v.substring(v.indexOf(':') + 1)
      : v;
}

class _Group extends ConsumerStatefulWidget {
  const _Group({super.key, required this.group});

  final Map<String, dynamic> group;

  @override
  ConsumerState<_Group> createState() => _GroupState();
}

class _GroupState extends ConsumerState<_Group> {
  late final Set<String> _chosen = {
    for (final r in recordsOf(widget.group)) '${r['id']}',
  };
  bool _busy = false;

  Future<void> _link() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      action: () => repo.linkContactRecords(_chosen.toList()),
      doing: 'link the records',
      successMessage: 'Linked as one company',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(contactDuplicatesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final records = recordsOf(widget.group);
    final canWrite = ref.watch(canWriteProvider);
    final value = duplicateValue(widget.group);
    return Card(
      margin: const EdgeInsets.fromLTRB(Space.lg, 6, Space.lg, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(
              duplicateReason('${widget.group['matched_on']}'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(value),
          ),
          const Divider(height: 1),
          for (final r in records)
            CheckboxListTile(
              key: ValueKey('dup-${r['id']}'),
              dense: true,
              value: _chosen.contains('${r['id']}'),
              onChanged: canWrite && !_busy
                  ? (v) => setState(() {
                      final id = '${r['id']}';
                      if (v == true) {
                        _chosen.add(id);
                      } else {
                        _chosen.remove(id);
                      }
                    })
                  : null,
              title: Text('${r['name']}'),
              subtitle: Text(
                '${r['code']} · '
                '${contactRoleLabel('${r['contact_type']}')}',
              ),
              secondary: IconButton(
                tooltip: 'Open',
                icon: Icon(contactRoleIcon('${r['contact_type']}'), size: 20),
                onPressed: () => context.go('/contacts/${r['id']}'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 4, Space.lg, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    // Which record the company is named after is not a
                    // choice: 0477 makes it the one filed first, and
                    // saying so here stops it looking arbitrary.
                    'The record filed first keeps its code and becomes '
                    'the company; the others are linked to it.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: canWrite && !_busy && _chosen.length > 1
                      ? _link
                      : null,
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('Link as one company'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
