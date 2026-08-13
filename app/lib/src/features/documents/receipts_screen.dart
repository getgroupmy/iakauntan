import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/download.dart';
import '../../core/format.dart';
import '../../core/pdf_kit.dart' show LetterheadMode;
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'receipt_pdf.dart';
import 'settlement_dialog.dart';

/// Money in and money out.
///
/// Both were recordable from the day the settlement dialog was built and
/// neither was ever *visible*: no route, no screen, no printable
/// document. A receipt sat posted in the database with nothing able to
/// show it, which is the same shape as the bank reconciliation and the
/// stock adjustments before it — fully built, unreachable.
class ReceiptsScreen extends ConsumerStatefulWidget {
  const ReceiptsScreen({super.key});

  @override
  ConsumerState<ReceiptsScreen> createState() => _ReceiptsScreenState();
}

class _ReceiptsScreenState extends ConsumerState<ReceiptsScreen> {
  bool _isSales = true;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(settlementsProvider(_isSales));
    final canPost = ref.watch(canPostProvider);

    return PageBody(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: true,
                    label: Text('Received'),
                    icon: Icon(Icons.south_west, size: 16)),
                ButtonSegment(
                    value: false,
                    label: Text('Paid out'),
                    icon: Icon(Icons.north_east, size: 16)),
              ],
              selected: {_isSales},
              onSelectionChanged: (s) => setState(() => _isSales = s.first),
            ),
            const Spacer(),
            if (canPost)
              FilledButton.icon(
                onPressed: () => showSettlementDialog(context, ref,
                    kind: _isSales ? DocKind.sales : DocKind.purchase),
                icon: const Icon(Icons.add, size: 18),
                label: Text(_isSales ? 'Receive payment' : 'Pay supplier'),
              ),
          ]),
          const SizedBox(height: Space.md),
          Expanded(
            child: AsyncView(
              value: rows,
              onRetry: () => ref.invalidate(settlementsProvider(_isSales)),
              builder: (list) => list.isEmpty
                  ? EmptyState(
                      icon: Icons.payments_outlined,
                      title: _isSales
                          ? 'No payments received yet'
                          : 'Nothing paid out yet',
                      message: _isSales
                          ? 'Recording a payment sets it against the '
                              'customer’s open invoices and posts it to the '
                              'bank account it landed in.'
                          : 'Recording a payment sets it against the '
                              'supplier’s open bills.',
                    )
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _SettlementTile(
                        row: list[i],
                        isSales: _isSales,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettlementTile extends ConsumerWidget {
  const _SettlementTile({required this.row, required this.isSales});

  final Map<String, dynamic> row;
  final bool isSales;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final no = '${row[isSales ? 'receipt_no' : 'payment_no'] ?? ''}';
    final date = DateTime.tryParse(
        '${row[isSales ? 'receipt_date' : 'payment_date'] ?? ''}');
    final contact = (row['contacts'] as Map?)?['name'] ?? '';
    final currency = '${row['currency'] ?? 'MYR'}';
    final unapplied = _num(row['unapplied_amount']);
    final status = '${row['status'] ?? ''}';

    return ListTile(
      dense: true,
      onTap: () => showSettlementDetail(
          context, id: '${row['id']}', isSales: isSales),
      title: Row(children: [
        Text(no, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: Space.sm),
        StatusChip(status, compact: true),
        // The number people chase. A receipt with money left on it is
        // not finished business, and it is invisible on the invoice.
        if (unapplied > 0) ...[
          const SizedBox(width: Space.sm),
          Text('${Fmt.money(unapplied, currency: currency)} on account',
              style: TextStyle(fontSize: 11, color: context.colors.warning)),
        ],
      ]),
      subtitle: Text([
        '$contact',
        Fmt.date(date),
        if (row['payment_mode_code'] != null) '${row['payment_mode_code']}',
        if (row['reference'] != null &&
            '${row['reference']}'.trim().isNotEmpty)
          '${row['reference']}',
      ].where((s) => s.trim().isNotEmpty).join('  ·  ')),
      trailing: Money(_num(row['amount']), currency: currency),
    );
  }
}

/// One settlement, what it was set against, and a copy for the customer.
Future<void> showSettlementDetail(BuildContext context,
    {required String id, required bool isSales}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SettlementDetail(id: id, isSales: isSales),
  );
}

class _SettlementDetail extends ConsumerWidget {
  const _SettlementDetail({required this.id, required this.isSales});

  final String id;
  final bool isSales;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (id: id, isSales: isSales);
    final data = ref.watch(settlementProvider(key));

    return AlertDialog(
      title: Text(isSales ? 'Receipt' : 'Payment'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: AsyncView(
            value: data,
            onRetry: () => ref.invalidate(settlementProvider(key)),
            builder: (s) => _body(context, s),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: data.valueOrNull == null
              ? null
              : () => _download(context, ref, data.value!),
          icon: const Icon(Icons.download_outlined, size: 18),
          label: Text(isSales ? 'Receipt PDF' : 'Voucher PDF'),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, Map<String, dynamic> s) {
    final currency = '${s['currency'] ?? 'MYR'}';
    final allocations =
        (s['allocations'] as List? ?? const []).cast<Map<String, dynamic>>();
    final unapplied = _num(s['unapplied_amount']);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${s[isSales ? 'receipt_no' : 'payment_no'] ?? ''}',
                    style: Theme.of(context).textTheme.titleMedium),
                Text('${(s['contacts'] as Map?)?['name'] ?? ''}'),
                Text(
                  Fmt.longDate(DateTime.tryParse(
                      '${s[isSales ? 'receipt_date' : 'payment_date'] ?? ''}')),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Money(_num(s['amount']), currency: currency),
        ]),
        const Divider(height: Space.xl),
        Text(isSales ? 'Set against' : 'Settling',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: Space.xs),
        if (allocations.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Space.sm),
            child: Text('Nothing yet — the whole amount is on account.'),
          )
        else
          for (final a in allocations)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(
                  child: Text('${_doc(a)?['doc_no'] ?? 'On account'}'),
                ),
                Text(Fmt.money(_num(a['amount']), currency: currency)),
              ]),
            ),
        if (unapplied > 0) ...[
          const SizedBox(height: Space.sm),
          Text(
            '${Fmt.money(unapplied, currency: currency)} is still on account '
            'and can be set against a future ${isSales ? 'invoice' : 'bill'}.',
            style: TextStyle(color: context.colors.warning, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Map<String, dynamic>? _doc(Map<String, dynamic> a) =>
      (a[isSales ? 'sales_documents' : 'purchase_documents'] as Map?)
          ?.cast<String, dynamic>();

  Future<void> _download(
      BuildContext context, WidgetRef ref, Map<String, dynamic> s) async {
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgProvider).valueOrNull;
    if (org == null) return;
    try {
      final bytes = await buildReceiptPdf(
        org: org,
        settlement: s,
        isSales: isSales,
        logo: await ref.read(orgLogoProvider.future),
        mode: org.usesPreprintedLetterhead
            ? LetterheadMode.stationery
            : LetterheadMode.printed,
      );
      final no = '${s[isSales ? 'receipt_no' : 'payment_no'] ?? 'receipt'}';
      final stem = no.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').toLowerCase();
      final saved =
          await saveBytesFile('$stem.pdf', 'application/pdf', bytes);
      messenger.showSnackBar(SnackBar(
        content: Text(saved
            ? 'Downloaded'
            : 'PDF download is only available in the browser'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

double _num(dynamic v) =>
    v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);
