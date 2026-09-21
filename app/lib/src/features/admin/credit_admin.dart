import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Selling scanning credit, and the invoices that go with it.
///
/// The price per scan is not here — it is an ordinary row on
/// `platform_settings`, edited under Service settings alongside
/// everything else the platform decides, so there is one place to look
/// for "what do we charge" rather than two.
///
/// What is here is the part that moves money: who is out of credit, a
/// top-up that raises a real invoice, and an adjustment that cannot be
/// made without saying why.
class CreditAdminTab extends ConsumerWidget {
  const CreditAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balances = ref.watch(platformCreditProvider);
    final invoices = ref.watch(platformInvoicesProvider);

    return AsyncView(
      value: balances,
      onRetry: () => ref.invalidate(platformCreditProvider),
      skeleton: const CardRowsSkeleton(rows: 4, trailing: 2),
      builder: (rows) => SingleChildScrollView(
        child: PageBody(
          maxWidth: 980,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        'Scanning credit',
                        subtitle:
                            'Emptiest first. A tenant on their own provider '
                            'key never appears to run out, because they '
                            'never spend this.',
                      ),
                      if (rows.isEmpty)
                        const Text('No organizations yet.')
                      else
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _BalanceRow(row: rows[i]),
                        ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        'Invoices issued',
                        subtitle:
                            'Raised by the platform, not by a tenant — these '
                            'are not in anybody\'s books here.',
                      ),
                      AsyncView(
                        value: invoices,
                        onRetry: () =>
                            ref.invalidate(platformInvoicesProvider),
                        skeleton: const CardRowsSkeleton(
                            rows: 3, leading: false, trailing: 2),
                        builder: (list) => list.isEmpty
                            ? const Text('Nothing sold yet.')
                            : Column(children: [
                                for (var i = 0; i < list.length; i++) ...[
                                  if (i > 0) const Divider(height: 1),
                                  _InvoiceRow(invoice: list[i]),
                                ],
                              ]),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _BalanceRow extends ConsumerWidget {
  const _BalanceRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = Fmt.toDouble(row['balance']);
    final scans = Fmt.toInt(row['scans_30d']);
    final spent = Fmt.toDouble(row['spent_30d']);
    final last = Fmt.parseDate(row['last_scan_at']);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(row['org_name']?.toString() ?? '—',
          style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        scans == 0
            ? 'No scans in the last 30 days'
            : '$scans scans · ${Fmt.money(spent)} in the last 30 days'
                '${last == null ? '' : ' · last ${Fmt.date(last)}'}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        // Zero is the ordinary state for a tenant that has never bought
        // any; a balance spent down to almost nothing is the one worth
        // noticing, because that tenant is about to be stopped.
        Money(
          balance,
          bold: true,
          style: balance > 0 && balance < 5
              ? TextStyle(color: context.colors.warning)
              : null,
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Sell credit',
          icon: const Icon(Icons.add_card_outlined, size: 20),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => _TopUpDialog(
              orgId: row['org_id'].toString(),
              orgName: row['org_name']?.toString() ?? '',
            ),
          ),
        ),
        IconButton(
          tooltip: 'Adjust by hand',
          icon: const Icon(Icons.tune, size: 20),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => _AdjustDialog(
              orgId: row['org_id'].toString(),
              orgName: row['org_name']?.toString() ?? '',
            ),
          ),
        ),
      ]),
    );
  }
}

class _InvoiceRow extends ConsumerWidget {
  const _InvoiceRow({required this.invoice});

  final Map<String, dynamic> invoice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = invoice['status']?.toString() ?? 'issued';
    final tax = Fmt.toDouble(invoice['tax_amount']);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      // `Wrap`, so the chip drops to a second line rather than off
      // the right edge. See the header of check_narrow_rows.py.
      title: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 2,
        children: [
          Text(invoice['invoice_no']?.toString() ?? '—',
              style: const TextStyle(fontWeight: FontWeight.w500)),
          StatusChip(status, compact: true),
        ],
      ),
      subtitle: Text(
        [
          invoice['bill_to_name'],
          Fmt.date(Fmt.parseDate(invoice['issue_date'])),
          if (tax > 0) 'incl. ${Fmt.money(tax)} tax',
        ].where((v) => v != null).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Money(Fmt.toDouble(invoice['total_amount']), bold: true),
        if (status == 'issued')
          IconButton(
            tooltip: 'Mark paid',
            icon: const Icon(Icons.check_circle_outline, size: 20),
            onPressed: () async {
              await runWithFeedback(
                context,
                action: () => ref
                    .read(platformRepoProvider)
                    .markInvoicePaid(invoice['id'].toString()),
                successMessage: 'Marked paid',
              );
              ref.invalidate(platformInvoicesProvider);
            },
          ),
      ]),
    );
  }
}

class _TopUpDialog extends ConsumerStatefulWidget {
  const _TopUpDialog({required this.orgId, required this.orgName});

  final String orgId;
  final String orgName;

  @override
  ConsumerState<_TopUpDialog> createState() => _TopUpDialogState();
}

class _TopUpDialogState extends ConsumerState<_TopUpDialog> {
  final _amount = TextEditingController(text: '100');
  final _note = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _sell() async {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    if (amount <= 0) return;

    setState(() => _saving = true);
    Map<String, dynamic>? result;
    final ok = await runWithFeedback(
      context,
      action: () async {
        result = await ref.read(platformRepoProvider).topUpCredit(
              widget.orgId,
              amount,
              note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            );
      },
      successMessage: 'Credit sold',
    );
    if (mounted) setState(() => _saving = false);
    if (!ok || !mounted) return;

    ref.invalidate(platformCreditProvider);
    ref.invalidate(platformInvoicesProvider);
    Navigator.pop(context);

    // The invoice number is the thing whoever did this now has to quote,
    // so it is said out loud rather than left to be found in a list.
    final no = result?['invoice_no'];
    if (no != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Invoice $no for '
            '${Fmt.money(Fmt.toDouble(result?['total']))}'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Sell credit to ${widget.orgName}'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Credit to grant',
              prefixText: 'RM ',
              helperText: 'What they can spend. Service tax goes on top.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'Note on the invoice',
              hintText: 'Bank transfer 11 Aug',
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _sell,
          child: const Text('Sell and invoice'),
        ),
      ],
    );
  }
}

class _AdjustDialog extends ConsumerStatefulWidget {
  const _AdjustDialog({required this.orgId, required this.orgName});

  final String orgId;
  final String orgName;

  @override
  ConsumerState<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends ConsumerState<_AdjustDialog> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _adjust() async {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    if (amount == 0 || _reason.text.trim().isEmpty) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(platformRepoProvider)
          .adjustCredit(widget.orgId, amount, _reason.text.trim()),
      successMessage: 'Adjusted',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    ref.invalidate(platformCreditProvider);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Adjust ${widget.orgName}'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'No invoice is raised. Use this for goodwill after an outage, '
            'or to take back a top-up keyed wrongly.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            decoration: const InputDecoration(
              labelText: 'Amount',
              prefixText: 'RM ',
              helperText: 'Negative takes it away',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(
              labelText: 'Reason *',
              helperText: 'Goes on the ledger line, where it stays',
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _adjust,
          child: const Text('Adjust'),
        ),
      ],
    );
  }
}
