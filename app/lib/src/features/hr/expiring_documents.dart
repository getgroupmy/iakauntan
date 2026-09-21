import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// The list `0025` built an index for and nobody wrote.
///
/// `employee_documents` has had an index on `(org_id, expires_date)`
/// since the HR module shipped, with a comment above it saying it is
/// what an "expiring in the next 60 days" list reads. There was no such
/// list, so a work permit about to lapse could only be found by opening
/// every employee record in turn.
///
/// The stake is not tidiness. Employing somebody whose Pass has expired
/// is an offence by the **employer** under s.55B of the Immigration Act
/// 1959/63, charged per person — so an expired permit is a different
/// kind of row from a first-aid certificate that needs renewing, and
/// this screen says which is which rather than sorting both by date.

/// How urgent a row is, in the terms the person reading it acts on.
///
/// The three the report returns. Named rather than inferred from dates,
/// because the difference between them is a matter of law and not of
/// how many days are left.
enum DocumentConsequence {
  /// An expired work permit on an expatriate or foreign worker. The
  /// company is committing an offence for as long as this stands.
  offence,

  /// A work permit that has not lapsed yet.
  permit,

  /// Anything else with a date on it.
  renewal,
}

DocumentConsequence consequenceOf(String? value) => switch (value) {
      'offence' => DocumentConsequence.offence,
      'permit' => DocumentConsequence.permit,
      _ => DocumentConsequence.renewal,
    };

/// What the row says about itself.
String describeExpiry(Map<String, dynamic> row) {
  final days = (row['days_until'] as num?)?.toInt();
  if (days == null) return 'No expiry date';
  if (days < 0) {
    final n = -days;
    return n == 1 ? 'Expired yesterday' : 'Expired $n days ago';
  }
  if (days == 0) return 'Expires today';
  return days == 1 ? 'Expires tomorrow' : 'Expires in $days days';
}

/// The line under the expiry, when there is something to add to it.
///
/// Only on the offence, and worded as what it is. "Renew soon" on a
/// pass that lapsed a fortnight ago understates it to the point of
/// being wrong.
String? consequenceNote(Map<String, dynamic> row) {
  switch (consequenceOf(row['consequence'] as String?)) {
    case DocumentConsequence.offence:
      return 'Employing on an expired pass is an offence by the company '
          'under s.55B of the Immigration Act 1959/63.';
    case DocumentConsequence.permit:
    case DocumentConsequence.renewal:
      return null;
  }
}

/// Show every document expiring inside the window.
Future<void> showExpiringDocuments(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _ExpiringDialog(),
    );

class _ExpiringDialog extends ConsumerStatefulWidget {
  const _ExpiringDialog();

  @override
  ConsumerState<_ExpiringDialog> createState() => _ExpiringDialogState();
}

class _ExpiringDialogState extends ConsumerState<_ExpiringDialog> {
  /// Sixty days is the window `0025`'s comment named, and it is the
  /// right default: a work permit renewal takes weeks, so a fortnight's
  /// notice is notice of something already too late to do calmly.
  int _days = 60;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(expiringDocumentsProvider(_days));

    return AlertDialog(
      title: const Text('Documents expiring'),
      content: SizedBox(
        width: 640,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 30, label: Text('30 days')),
                ButtonSegment(value: 60, label: Text('60 days')),
                ButtonSegment(value: 180, label: Text('6 months')),
              ],
              selected: {_days},
              onSelectionChanged: (v) => setState(() => _days = v.first),
            ),
            const SizedBox(height: Space.md),
            Expanded(
              child: AsyncView(
                value: rows,
                onRetry: () =>
                    ref.invalidate(expiringDocumentsProvider(_days)),
                skeleton: const ListSkeleton(rows: 6),
                builder: (list) {
                  if (list.isEmpty) {
                    return const EmptyState(
                      icon: Icons.event_available_outlined,
                      title: 'Nothing expiring',
                      message: 'No permit, contract or certificate runs '
                          'out inside this window.',
                    );
                  }
                  return ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = list[i];
                      final kind =
                          consequenceOf(r['consequence'] as String?);
                      final note = consequenceNote(r);
                      final urgent = kind == DocumentConsequence.offence ||
                          (r['is_expired'] as bool? ?? false);
                      return ListTile(
                        key: ValueKey('expiring-${r['document_id']}'),
                        leading: Icon(
                          kind == DocumentConsequence.offence
                              ? Icons.gpp_maybe_outlined
                              : Icons.event_outlined,
                          color: urgent ? context.colors.danger : null,
                        ),
                        title: Text('${r['employee_name']} · ${r['title']}'),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${Fmt.label(r['doc_type']?.toString() ?? '')}'
                              ' · ${describeExpiry(r)}',
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    urgent ? context.colors.danger : null,
                              ),
                            ),
                            if (note != null)
                              Padding(
                                padding:
                                    const EdgeInsets.only(top: Space.xs),
                                child: Text(
                                  note,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: context.colors.danger,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        trailing: Text(
                          Fmt.date(Fmt.parseDate(r['expires_date'])),
                          style: const TextStyle(fontSize: 12),
                        ),
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
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Whether a renewal is a sensible offer on this row at all.
///
/// A document with no expiry has nothing to renew to, and one being
/// created has not been recorded yet. Neither is a refusal about who is
/// asking — `renew_employee_document` handles that, and its answer is
/// the one that counts.
bool canRenewDocument(Map<String, dynamic>? row) =>
    row != null && row['id'] != null && row['expires_date'] != null;

/// Why the new expiry will not do, or null when it will.
///
/// The database refuses this too. Saying it here saves a round trip and
/// puts the sentence next to the field it is about.
String? renewalBlockedBecause({
  required DateTime? currentExpiry,
  required DateTime? newExpiry,
}) {
  if (newExpiry == null) {
    return 'A renewal has a new expiry date. Without one there is '
        'nothing to renew it to.';
  }
  if (currentExpiry != null && !newExpiry.isAfter(currentExpiry)) {
    return 'A renewal runs past the document it replaces, which runs to '
        '${Fmt.date(currentExpiry)}.';
  }
  return null;
}

/// Ask for the new expiry, and record the renewal.
///
/// Only the date is asked. Everything else is carried across by
/// `renew_employee_document`, because a renewed permit is the same
/// permit with new dates and offering the rest again is how the
/// renewal comes out as a different kind from the one it replaces.
Future<bool> showRenewDocument(
  BuildContext context, {
  required String documentId,
  required DateTime? currentExpiry,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _RenewDialog(
        documentId: documentId,
        currentExpiry: currentExpiry,
      ),
    ) ??
    false;

class _RenewDialog extends ConsumerStatefulWidget {
  const _RenewDialog({required this.documentId, this.currentExpiry});

  final String documentId;
  final DateTime? currentExpiry;

  @override
  ConsumerState<_RenewDialog> createState() => _RenewDialogState();
}

class _RenewDialogState extends ConsumerState<_RenewDialog> {
  DateTime? _expires;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final blocked = renewalBlockedBecause(
      currentExpiry: widget.currentExpiry,
      newExpiry: _expires,
    );

    return AlertDialog(
      title: const Text('Renew it'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.currentExpiry == null
                  ? 'The renewal replaces this document.'
                  : 'This one runs to '
                      '${Fmt.date(widget.currentExpiry)}. The renewal '
                      'replaces it, and it drops off the expiring list.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            InputDecorator(
              decoration: InputDecoration(
                labelText: 'New expiry',
                errorText: _expires == null ? null : blocked,
              ),
              child: InkWell(
                key: const ValueKey('renew-expiry'),
                onTap: _saving
                    ? null
                    : () async {
                        final now = DateTime.now();
                        final picked = await showDatePicker(
                          context: context,
                          initialDate:
                              widget.currentExpiry?.add(
                                      const Duration(days: 365)) ??
                                  now,
                          firstDate: DateTime(now.year - 1),
                          lastDate: DateTime(now.year + 20),
                        );
                        if (picked != null) {
                          setState(() => _expires = picked);
                        }
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.sm),
                  child: Text(_expires == null
                      ? 'Choose a date'
                      : Fmt.date(_expires!)),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('renew-save'),
          onPressed: _saving || blocked != null ? null : _renew,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Renew'),
        ),
      ],
    );
  }

  Future<void> _renew() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.renewEmployeeDocument(
            documentId: widget.documentId,
            expiresDate: _expires!,
          ),
      successMessage: 'Renewed',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.of(context).pop(true);
  }
}
