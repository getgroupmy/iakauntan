import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// Changing what a schedule bills.
///
/// A recurring document is a snapshot, not a pointer: "editing it
/// afterwards does not change what gets billed next month", which is
/// the right rule and leaves a schedule with no way to follow a price
/// rise. `update_recurring_template` is the way — re-point the schedule
/// at a newer document and it snapshots that instead — and it had no
/// caller, so the only remedy for a rate change was to delete the
/// schedule and build it again, losing when it next runs and how many
/// times it has already billed.

/// What kind of document this schedule copies.
///
/// `update_recurring_template` looks for an invoice on a sales schedule
/// and a bill on a purchase one, and raises if it does not find it. The
/// picker offers only the kind that will be accepted.
DocKind templateKindOf(String? kind) =>
    kind == 'purchase' ? DocKind.purchase : DocKind.sales;

/// Which documents may be copied from.
///
/// A draft is excluded: the function takes it, but a schedule built on
/// a draft bills what somebody was still typing. A voided one is
/// excluded for the same reason in the other direction.
List<BusinessDocument> templateCandidates(
  Iterable<BusinessDocument> docs,
) =>
    docs.where((d) => d.status != 'draft' && d.status != 'void').toList();

/// What a candidate reads as in the picker.
String templateLabel(BusinessDocument d) => [
      d.docNo,
      if (d.contactName != null) d.contactName!,
      Fmt.date(d.docDate),
      Fmt.money(d.totalAmount, currency: d.currency),
    ].join(' · ');

/// Point a schedule at a different document.
Future<bool> showRecurringTemplateDialog(
  BuildContext context, {
  required Map<String, dynamic> schedule,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _TemplateDialog(schedule: schedule),
    ) ??
    false;

class _TemplateDialog extends ConsumerStatefulWidget {
  const _TemplateDialog({required this.schedule});

  final Map<String, dynamic> schedule;

  @override
  ConsumerState<_TemplateDialog> createState() => _TemplateDialogState();
}

class _TemplateDialogState extends ConsumerState<_TemplateDialog> {
  String? _documentId;
  bool _saving = false;

  Future<void> _save() async {
    final id = _documentId;
    if (id == null) return;
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.updateRecurringTemplate(
            id: '${widget.schedule['id']}',
            documentId: id,
          ),
      successMessage: 'This is what it bills from now on',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(recurringDocumentsProvider);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = templateKindOf(widget.schedule['kind'] as String?);
    final docs = ref.watch(
      documentsProvider((
        kind: kind,
        docType: kind.isSales ? 'invoice' : 'bill',
        status: 'all',
        search: '',
      )),
    );

    return AlertDialog(
      title: Text('What ${widget.schedule['name']} bills'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: AsyncView<List<BusinessDocument>>(
          value: docs,
          onRetry: () => ref.invalidate(documentsProvider),
          builder: (list) {
            final candidates = templateCandidates(list);
            if (candidates.isEmpty) {
              return EmptyState(
                icon: Icons.repeat,
                title: 'Nothing to copy from',
                message: kind.isSales
                    ? 'Raise the invoice you want billed each month, then '
                        'point the schedule at it.'
                    : 'Enter the bill you want repeated, then point the '
                        'schedule at it.',
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'A schedule holds a copy, not a link — so changing the '
                  'original does nothing. Pointing it at a newer document '
                  'takes a fresh copy, and keeps when it next runs and how '
                  'many times it has already billed.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Space.sm),
                Expanded(
                  child: ListView.separated(
                    itemCount: candidates.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final d = candidates[i];
                      return RadioListTile<String>(
                        key: ValueKey('template-${d.id}'),
                        dense: true,
                        value: d.id,
                        groupValue: _documentId,
                        onChanged: _saving
                            ? null
                            : (v) => setState(() => _documentId = v),
                        title: Text(
                          templateLabel(d),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('template-save'),
          onPressed: _saving || _documentId == null ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Bill this instead'),
        ),
      ],
    );
  }
}
