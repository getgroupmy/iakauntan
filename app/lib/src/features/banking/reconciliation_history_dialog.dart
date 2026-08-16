import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// The reconciliation register: what was agreed, when, and over how many
/// statement lines.
///
/// `docs/unreachable.md` carried this — `bank_reconciliations` rows were
/// written and never listed — and listing them is what showed that two
/// of every three could be phantoms. 0157 stops them being created; this
/// is what reads the register, and it still names one if it finds it,
/// because a database written before 0157 may hold some.
Future<bool?> showReconciliationHistory(
  BuildContext context, {
  required String bankAccountId,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _HistoryDialog(bankAccountId: bankAccountId),
  );
}

/// A reconciliation that closed over no statement lines agreed nothing.
///
/// This is the exact shape the pre-0157 duplicate produced: completing
/// twice found no lines left to stamp, because the first one had taken
/// them all, and wrote a record of an agreement anyway. Returns null for
/// an ordinary row.
String? phantomReconciliation(Map<String, dynamic> row) {
  final lines = Fmt.toDouble(row['lines']).round();
  if (lines > 0) return null;
  return 'This one closed over no statement lines, so it agreed nothing. '
      'It was recorded before the rule that a reconciliation has to carry '
      'on from the last one, and it is not evidence of anything.';
}

/// How a register row reads on one line.
String reconciliationSummary(Map<String, dynamic> row) {
  final lines = Fmt.toDouble(row['lines']).round();
  final who = row['completed_by'] as String?;
  return [
    '$lines statement ${lines == 1 ? 'line' : 'lines'}',
    if (who != null && who.isNotEmpty) 'closed by $who',
    if (row['completed_at'] != null)
      'on ${Fmt.date(Fmt.parseDate(row['completed_at']))}',
  ].join(' · ');
}

class _HistoryDialog extends ConsumerStatefulWidget {
  const _HistoryDialog({required this.bankAccountId});

  final String bankAccountId;

  @override
  ConsumerState<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends ConsumerState<_HistoryDialog> {
  bool _changed = false;

  Future<void> _reopen(Map<String, dynamic> row) async {
    final ok = await confirm(
      context,
      title: 'Reopen this reconciliation?',
      message:
          'Its statement lines go back to being matched but unclosed, and '
          'the record of the reconciliation is removed — a reconciliation '
          'that was reopened did not happen. Only the most recent one on '
          'an account can be reopened.',
      confirmLabel: 'Reopen',
    );
    if (!ok || !mounted) return;

    final done = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.reopenBankReconciliation(row['id'] as String),
      successMessage: 'Reopened',
    );
    if (done) {
      _changed = true;
      ref.invalidate(bankReconciliationsProvider(widget.bankAccountId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final register = ref.watch(
      bankReconciliationsProvider(widget.bankAccountId),
    );
    final canPost = ref.watch(canPostProvider);

    return AlertDialog(
      title: const Text('Reconciliation history'),
      content: SizedBox(
        width: 620,
        child: AsyncView(
          value: register,
          onRetry: () =>
              ref.invalidate(bankReconciliationsProvider(widget.bankAccountId)),
          builder: (rows) {
            if (rows.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: Space.lg),
                child: Text(
                  'This account has never been reconciled. Match the '
                  'statement lines and complete one, and it will be '
                  'recorded here.',
                ),
              );
            }
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final r in rows)
                    _RegisterRow(
                      row: r,
                      onReopen: canPost && r['can_reopen'] == true
                          ? () => _reopen(r)
                          : null,
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context, _changed),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _RegisterRow extends StatelessWidget {
  const _RegisterRow({required this.row, this.onReopen});

  final Map<String, dynamic> row;
  final VoidCallback? onReopen;

  @override
  Widget build(BuildContext context) {
    final phantom = phantomReconciliation(row);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Reconciled to ${Fmt.date(Fmt.parseDate(row['statement_date']))}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              reconciliationSummary(row),
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Money(Fmt.toDouble(row['statement_balance']), bold: true),
                if (onReopen != null)
                  IconButton(
                    key: ValueKey('reopen-${row['id']}'),
                    tooltip: 'Reopen',
                    icon: const Icon(Icons.lock_open_outlined, size: 20),
                    onPressed: onReopen,
                  ),
              ],
            ),
          ),
          if (phantom != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: Text(
                phantom,
                key: ValueKey('phantom-${row['id']}'),
                style: TextStyle(fontSize: 12, color: context.colors.warning),
              ),
            ),
        ],
      ),
    );
  }
}
