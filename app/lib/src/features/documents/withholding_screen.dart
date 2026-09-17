import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Tax deducted from non-residents, and when it has to reach LHDN.
///
/// Grouped by form rather than by supplier because the form is the unit
/// of work: CP37 and CP37A are filed separately, and somebody sitting
/// down to file one does not want the other interleaved with it.
class WithholdingScreen extends ConsumerWidget {
  const WithholdingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(withholdingReportProvider);
    final canPost = ref.watch(canPostProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Withholding tax')),
      body: AsyncView(
        value: rows,
        onRetry: () => ref.invalidate(withholdingReportProvider),
        skeleton: const ListSkeleton(rows: 6, leading: false),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.account_balance_outlined,
              title: 'Nothing withheld',
              message: 'Open a posted bill from a non-resident and choose '
                  'Withhold tax.',
            );
          }

          // Anything late is the reason somebody opened this screen, so
          // it goes at the top rather than in form order.
          final overdue = list
              .where((r) => Fmt.toDouble(r['penalty_if_unpaid']) > 0)
              .toList();
          final forms = <String, List<Map<String, dynamic>>>{};
          for (final r in list) {
            forms.putIfAbsent(r['form_code']?.toString() ?? '—', () => [])
                .add(r);
          }

          return ListView(
            padding: const EdgeInsets.only(bottom: 48),
            children: [
              if (overdue.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: _LatePanel(rows: overdue),
                ),
              for (final entry in forms.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      Space.lg, Space.lg, Space.lg, Space.sm),
                  child: SectionHeader(
                    entry.key,
                    subtitle: '${entry.value.length} '
                        '${entry.value.length == 1 ? 'certificate' : 'certificates'}'
                        ' · ${Fmt.money(entry.value.fold<double>(
                              0,
                              (s, r) => s + Fmt.toDouble(r['base_tax_amount']),
                            ))} deducted',
                  ),
                ),
                for (final r in entry.value)
                  _CertificateTile(row: r, canPost: canPost),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// s.109(2) adds ten per cent to tax that misses its month. Shown as an
/// amount at risk, not as a liability: nobody has been charged it until
/// LHDN says so.
class _LatePanel extends StatelessWidget {
  const _LatePanel({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final penalty =
        rows.fold<double>(0, (s, r) => s + Fmt.toDouble(r['penalty_if_unpaid']));

    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: context.colors.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, color: context.colors.danger),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${rows.length} past their month',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                'Section 109(2) adds ten per cent once the deadline passes — '
                '${Fmt.money(penalty)} on these, and the expense stays '
                'disallowed until the tax is paid.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _CertificateTile extends ConsumerWidget {
  const _CertificateTile({required this.row, required this.canPost});

  final Map<String, dynamic> row;
  final bool canPost;

  Future<void> _remit(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Mark as remitted?',
      message: 'This records the payment to LHDN and clears the liability. '
          'Do it when the money has actually gone.',
      confirmLabel: 'Remitted',
    );
    if (!ok || !context.mounted) return;
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.remitWithholding(
            id: row['certificate_id'] as String,
            paidOn: DateTime.now(),
          ),
      successMessage: 'Remitted',
    );
    ref.invalidate(withholdingReportProvider);
    refreshLedgerData(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remitted = row['remitted_on'] != null;
    final late = Fmt.toDouble(row['penalty_if_unpaid']) > 0;

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
      title: Row(children: [
        Flexible(
          child: Text(row['contact_name']?.toString() ?? '—',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: Space.sm),
        StatusChip(remitted ? 'completed' : 'pending', compact: true),
      ]),
      subtitle: Text(
        [
          row['certificate_no']?.toString() ?? '',
          row['section']?.toString() ?? '',
          '${Fmt.money(Fmt.toDouble(row['gross_amount']))} at '
              '${Fmt.toDouble(row['rate']).toStringAsFixed(2)}%',
          remitted
              ? 'remitted ${Fmt.date(Fmt.parseDate(row['remitted_on']))}'
              : 'due ${Fmt.date(Fmt.parseDate(row['due_date']))}',
        ].where((s) => s.isNotEmpty).join(' · '),
        style: TextStyle(
          fontSize: 12,
          color: late ? context.colors.danger : null,
        ),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Money(Fmt.toDouble(row['base_tax_amount']), bold: true),
        if (!remitted && canPost) ...[
          const SizedBox(width: Space.sm),
          TextButton(
            onPressed: () => _remit(context, ref),
            child: const Text('Remit'),
          ),
        ],
      ]),
    );
  }
}
