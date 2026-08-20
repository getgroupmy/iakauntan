import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/safe_link.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
// `RepoPosEinvoice` is an extension, and a Dart extension is only in
// scope where its declaring library is imported.
import '../../data/repository.dart';

/// Operational view over MyInvois: what is queued, what LHDN validated,
/// and what needs fixing.
class EinvoiceScreen extends ConsumerStatefulWidget {
  const EinvoiceScreen({super.key});

  @override
  ConsumerState<EinvoiceScreen> createState() => _EinvoiceScreenState();
}

class _EinvoiceScreenState extends ConsumerState<EinvoiceScreen> {
  String _filter = 'all';
  bool _refreshing = false;

  Future<void> _refreshStatus() async {
    setState(() => _refreshing = true);
    await runWithFeedback(
      context,
      action: () async {
        final result = await ref.read(repoProvider)!.refreshEinvoiceStatus();
        final valid = result['valid'] ?? 0;
        final invalid = result['invalid'] ?? 0;
        if (invalid is int && invalid > 0) {
          throw Exception('$invalid document(s) failed LHDN validation');
        }
        if (valid is int && valid == 0 && (result['checked'] ?? 0) == 0) {
          throw Exception('Nothing is awaiting validation');
        }
      },
      successMessage: 'Status updated from MyInvois',
      pendingMessage: 'Checking with LHDN…',
    );
    if (mounted) {
      setState(() => _refreshing = false);
      ref.invalidate(einvoicesProvider);
      ref.invalidate(dashboardProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(einvoicesProvider(_filter));
    final org = ref.watch(currentOrgProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('e-Invoice'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: OutlinedButton.icon(
              onPressed: _refreshing ? null : _refreshStatus,
              icon: _refreshing
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync, size: 18),
              label: const Text('Check status'),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: FilterBar(
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'all', label: Text('All')),
                ButtonSegment(value: 'queued', label: Text('Queued')),
                ButtonSegment(value: 'submitted', label: Text('Submitted')),
                ButtonSegment(value: 'valid', label: Text('Valid')),
                ButtonSegment(value: 'attention', label: Text('Needs fixing')),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (org != null && !org.einvoiceEnabled) const _SetupBanner(),
          const _ConsolidationDue(),
          Expanded(
            child: AsyncView(
              value: docs,
              onRetry: () => ref.invalidate(einvoicesProvider),
              builder: (list) {
                if (list.isEmpty) {
                  return const EmptyState(
                    icon: Icons.verified_outlined,
                    title: 'No e-Invoices yet',
                    message:
                        'Post an invoice, then submit it to MyInvois from the '
                        'invoice screen.',
                  );
                }
                return ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _EinvoiceTile(doc: list[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The consolidated e-Invoice, and how long is left to file it.
///
/// A sale gets its own e-Invoice when the buyer asks for one. The rest
/// roll up: under the LHDN guideline a seller aggregates the period's
/// unidentified sales into a single submission, due within seven days
/// of month end. 0210 built all of that and nothing called it, so a
/// shop selling through the till has been accruing a statutory
/// obligation with no way to see it, let alone discharge it.
///
/// ## Nothing here works out a deadline
///
/// `period_end + 7` is generated on the consolidation row and
/// `days_left` comes back from `pos_einvoice_outstanding`. A screen
/// that subtracted dates itself would be a second opinion on a
/// statutory date, and the month it disagreed would be the month
/// somebody files late.
///
/// A negative `days_left` is shown as overdue rather than clamped. The
/// deadline having passed is the single most important thing this
/// widget can say, and rounding it up to "0 days left" would hide it.
class _ConsolidationDue extends ConsumerStatefulWidget {
  const _ConsolidationDue();

  @override
  ConsumerState<_ConsolidationDue> createState() => _ConsolidationDueState();
}

class _ConsolidationDueState extends ConsumerState<_ConsolidationDue> {
  String? _busy;

  Future<void> _consolidate(Map<String, dynamic> period) async {
    final start = period['period_start']?.toString();
    if (start == null) return;
    setState(() => _busy = start);
    await runWithFeedback(
      context,
      pendingMessage: 'Rolling the period up…',
      successMessage: 'Consolidated, and queued for MyInvois',
      action: () => ref.read(repoProvider)!.consolidatePosEinvoices(start),
    );
    if (!mounted) return;
    setState(() => _busy = null);
    ref
      ..invalidate(posEinvoiceOutstandingProvider)
      ..invalidate(einvoicesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final outstanding = ref.watch(posEinvoiceOutstandingProvider);
    return outstanding.maybeWhen(
      // Silent when there is nothing owed and silent while it loads. A
      // shop with no till, or one that has filed everything, should not
      // be shown an empty box about consolidation.
      data: (periods) {
        if (periods.isEmpty) return const SizedBox.shrink();
        return Column(
          children: [
            for (final p in periods) _PeriodRow(
              period: p,
              busy: _busy == p['period_start']?.toString(),
              onConsolidate: () => _consolidate(p),
            ),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _PeriodRow extends StatelessWidget {
  const _PeriodRow({
    required this.period,
    required this.busy,
    required this.onConsolidate,
  });

  final Map<String, dynamic> period;
  final bool busy;
  final VoidCallback onConsolidate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final days = Fmt.toDouble(period['days_left']).round();
    final overdue = days < 0;
    final waiting = period['sales_waiting'] ?? 0;
    final status = (period['consolidation_status'] ?? 'not started') as String;

    final tone = overdue
        ? scheme.errorContainer
        : days <= 3
        ? context.colors.warning.withValues(alpha: 0.16)
        : scheme.surfaceContainerHighest;
    final ink = overdue ? scheme.onErrorContainer : scheme.onSurface;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, 0),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: tone,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$waiting till sales to consolidate for '
                  '${Fmt.date(Fmt.parseDate(period['period_start']))} – '
                  '${Fmt.date(Fmt.parseDate(period['period_end']))}',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(color: ink),
                ),
                const SizedBox(height: 2),
                Text(
                  overdue
                      ? 'Was due ${Fmt.date(Fmt.parseDate(period['due_date']))}'
                            ' — ${-days} day${days == -1 ? '' : 's'} late'
                      : 'Due ${Fmt.date(Fmt.parseDate(period['due_date']))}'
                            ' — $days day${days == 1 ? '' : 's'} left',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: ink,
                    fontWeight: overdue ? FontWeight.w600 : null,
                  ),
                ),
                Text(
                  'LHDN wants one submission for the sales nobody asked an '
                  'invoice for. Status: $status.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: ink),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.md),
          FilledButton(
            onPressed: busy ? null : onConsolidate,
            child: busy
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Consolidate'),
          ),
        ],
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: context.colors.warning.withValues(alpha: 0.12),
      padding: const EdgeInsets.all(Space.lg),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: context.colors.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'e-Invoice is switched off. Add your MyInvois client ID and '
              'secret under Settings to start submitting to LHDN.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _EinvoiceTile extends ConsumerWidget {
  const _EinvoiceTile({required this.doc});

  final EinvoiceDocument doc;

  static const _typeNames = {
    '01': 'Invoice',
    '02': 'Credit Note',
    '03': 'Debit Note',
    '04': 'Refund Note',
    '11': 'Self-billed Invoice',
    '12': 'Self-billed Credit Note',
    '13': 'Self-billed Debit Note',
    '14': 'Self-billed Refund Note',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: Space.lg),
      title: Row(
        children: [
          Text(
            doc.internalDocNo,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 10),
          StatusChip(doc.status, compact: true),
        ],
      ),
      subtitle: Text(
        '${_typeNames[doc.typeCode] ?? doc.typeCode} · ${doc.buyerName ?? '—'} '
        '· ${Fmt.date(doc.issueDate)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Money(doc.payableAmount, currency: doc.currency, bold: true),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (doc.status == 'valid') _ValidDetails(doc: doc),
              if (doc.status == 'invalid' || doc.status == 'failed')
                _ErrorDetails(doc: doc),
              if (doc.status == 'queued')
                const Text(
                  'Waiting to be submitted. Use Submit e-Invoice on the '
                  'invoice, or submit the queue in bulk.',
                  style: TextStyle(fontSize: 13),
                ),
              if (doc.status == 'submitted')
                const Text(
                  'Accepted by MyInvois and awaiting validation. Use '
                  '"Check status" to refresh.',
                  style: TextStyle(fontSize: 13),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (doc.validationLink != null)
                    OutlinedButton.icon(
                      onPressed: () =>
                          // Through the guard: this URL is whatever
                          // MyInvois returned, not one we built.
                          launchExternal(doc.validationLink),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('View on MyInvois'),
                    ),
                  if (doc.canCancel)
                    OutlinedButton.icon(
                      onPressed: () => _cancel(context, ref),
                      icon: const Icon(Icons.cancel_outlined, size: 16),
                      label: Text('Cancel (${_hoursLeft(doc)}h left)'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: context.colors.danger,
                      ),
                    ),
                  if (doc.status == 'invalid' || doc.status == 'failed')
                    FilledButton.icon(
                      onPressed: () => _resubmit(context, ref),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Resubmit'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  static int _hoursLeft(EinvoiceDocument doc) =>
      (doc.cancelWindowLeft?.inHours ?? 0).clamp(0, 72);

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel e-Invoice'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'LHDN requires a reason. This cannot be undone — after '
              'cancelling you must issue a fresh invoice.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.danger,
            ),
            onPressed: () => Navigator.pop(ctx, reasonController.text.trim()),
            child: const Text('Cancel e-Invoice'),
          ),
        ],
      ),
    );

    if (reason == null || reason.length < 3 || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.cancelEinvoice(doc.id, reason),
      successMessage: 'e-Invoice cancelled with LHDN',
      pendingMessage: 'Cancelling…',
    );
    ref.invalidate(einvoicesProvider);
    ref.invalidate(dashboardProvider);
  }

  Future<void> _resubmit(BuildContext context, WidgetRef ref) async {
    await runWithFeedback(
      context,
      action: () async {
        final repo = ref.read(repoProvider)!;
        final result = await repo.submitEinvoice(einvoiceIds: [doc.id]);
        if ((result['rejected'] as int? ?? 0) > 0) {
          throw Exception('Still rejected: ${result['errors']}');
        }
      },
      successMessage: 'Resubmitted to MyInvois',
      pendingMessage: 'Resubmitting…',
    );
    ref.invalidate(einvoicesProvider);
  }
}

class _ValidDetails extends StatelessWidget {
  const _ValidDetails({required this.doc});

  final EinvoiceDocument doc;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (doc.validationLink != null)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: QrImageView(
              data: doc.validationLink!,
              size: 108,
              padding: EdgeInsets.zero,
            ),
          ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Validated by LHDN',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: context.colors.success,
                ),
              ),
              const SizedBox(height: 6),
              _KeyValue(label: 'UUID', value: doc.myinvoisUuid ?? '—'),
              _KeyValue(
                label: 'Validated',
                value: Fmt.dateTime(doc.validatedAt),
              ),
              _KeyValue(
                label: 'Cancellation window',
                value: doc.canCancel
                    ? 'closes ${Fmt.dateTime(doc.cancelDeadline)}'
                    : 'closed — issue a credit note instead',
              ),
              const SizedBox(height: 6),
              Text(
                'Print this QR code on the invoice so the buyer can verify it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ErrorDetails extends StatelessWidget {
  const _ErrorDetails({required this.doc});

  final EinvoiceDocument doc;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: context.colors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.colors.danger.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            doc.errorMessage ?? 'Rejected by LHDN',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: context.colors.danger,
            ),
          ),
          if (doc.validationErrors.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final err in doc.validationErrors.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• ${_describe(err)}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// LHDN nests errors differently depending on which stage failed.
  static String _describe(dynamic err) {
    if (err is String) return err;
    if (err is Map) {
      final inner = err['error'];
      if (inner is Map) {
        return [
          inner['code'],
          inner['message'],
        ].where((e) => e != null).join(': ');
      }
      return [
        err['code'],
        err['message'],
        err['status'],
        err['name'],
      ].where((e) => e != null).join(' · ');
    }
    return err.toString();
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: SelectableText(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
