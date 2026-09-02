import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

/// Handing the company to somebody else, and the record of it having
/// happened before.
///
/// Shown to owners. An administrator runs the company; giving it away is
/// a different thing, and the database refuses it to anybody but the
/// owner — so offering the button to an admin would be offering a
/// refusal.
///
/// Nothing about the books moves. A company was never inside a firm or
/// inside anything else, so a handover moves one membership row and
/// writes a record; the ledger does not notice.
class HandoverCard extends ConsumerWidget {
  const HandoverCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(memberRoleProvider).valueOrNull;
    final history = ref.watch(companyTransferHistoryProvider);
    final isOwner = role == 'owner';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Ownership',
          subtitle: isOwner
              ? 'Hand this company to another accountant, or back to '
                    'its proprietor'
              : 'Only the owner may hand the company over',
          action: isOwner
              ? OutlinedButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const _HandOverDialog(),
                  ),
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('Hand over'),
                )
              : null,
        ),
        AsyncView(
          value: history,
          onRetry: () => ref.invalidate(companyTransferHistoryProvider),
          builder: (rows) => Card(
            child: Column(
              children: [
                if (rows.isEmpty)
                  const ListTile(
                    dense: true,
                    title: Text('This company has never changed hands.'),
                  ),
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _HandoverTile(row: rows[i]),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HandoverTile extends StatelessWidget {
  const _HandoverTile({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final forcedBy = row['forced_by'] as String?;
    final firm = row['from_firm'] as String?;
    final note = row['note'] as String?;
    final at = DateTime.tryParse('${row['at']}');

    return ListTile(
      dense: true,
      title: Text('${row['handed_by']} → ${row['handed_to']}'),
      subtitle: Text(
        [
          Fmt.dateTime(at),
          if (firm != null) 'left $firm',
          if (note != null && note.isNotEmpty) note,
          // A forced handover is the one thing on this list somebody may
          // not have consented to, so it says so and says why.
          if (forcedBy != null)
            'forced by $forcedBy — ${row['forced_reason']}',
        ].join(' · '),
      ),
      leading: Icon(
        forcedBy == null ? Icons.swap_horiz : Icons.gavel_outlined,
        size: 18,
      ),
    );
  }
}

class _HandOverDialog extends ConsumerStatefulWidget {
  const _HandOverDialog();

  @override
  ConsumerState<_HandOverDialog> createState() => _HandOverDialogState();
}

class _HandOverDialogState extends ConsumerState<_HandOverDialog> {
  final _email = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Hand this company over'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'They become the owner. You stay on as an administrator, '
              'so somebody can still answer questions about last year — '
              'they can remove you in one click if that is not wanted. '
              'Any practice keeping the books loses its access, and can '
              'be appointed again by the new owner.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Their e-mail',
                helperText:
                    'They must already have an account. A company whose '
                    'owner is an unaccepted invitation has no owner.',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                labelText: 'Note for the record',
                hintText: 'Optional',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final email = _email.text.trim();
            if (email.isEmpty) return;
            final orgId = ref.read(currentOrgIdProvider);
            if (orgId == null) return;
            final ok = await confirm(
              context,
              title: 'Hand the company to $email?',
              message:
                  'You stop being the owner the moment this is done, '
                  'and only the new owner can hand it back.',
              confirmLabel: 'Hand over',
              destructive: true,
            );
            if (!ok || !context.mounted) return;
            final repo = ref.read(firmsRepoProvider);
            final done = await runWithFeedback(
              context,
              doing: 'hand a company over',
              successMessage: 'Handed over',
              action: () => repo.transferCompany(
                orgId,
                email,
                note: _note.text.trim().isEmpty ? null : _note.text.trim(),
              ),
            );
            ref.invalidate(companyTransferHistoryProvider);
            ref.invalidate(teamProvider);
            ref.invalidate(memberRoleProvider);
            if (done && context.mounted) Navigator.pop(context);
          },
          child: const Text('Hand over'),
        ),
      ],
    );
  }
}
