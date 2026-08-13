import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/download.dart';
import '../../core/format.dart';
import '../../core/pdf_kit.dart' show LetterheadMode;
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
// The settlement and email methods live in an `extension on Repo`, and
// an extension is only in scope where its library is imported.
import '../../data/repository.dart';
import 'email_dialog.dart' show sendNowOutcome;
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
        OutlinedButton.icon(
          onPressed: data.valueOrNull == null
              ? null
              : () => _download(context, ref, data.value!),
          icon: const Icon(Icons.download_outlined, size: 18),
          label: const Text('PDF'),
        ),
        // Sales only. A supplier does not want a copy of the voucher we
        // wrote to record paying them — they issue their own receipt.
        if (isSales)
          FilledButton.icon(
            onPressed: data.valueOrNull == null
                ? null
                : () => _email(context, ref, data.value!),
            icon: const Icon(Icons.mail_outline, size: 18),
            label: const Text('Email it'),
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

  Future<void> _email(
      BuildContext context, WidgetRef ref, Map<String, dynamic> s) async {
    final to = '${(s['contacts'] as Map?)?['email'] ?? ''}'.trim();
    await showReceiptEmailDialog(
      context,
      receiptId: id,
      receiptNo: '${s['receipt_no'] ?? ''}',
      defaultTo: to.isEmpty ? null : to,
      buildPdf: () async {
        final org = ref.read(currentOrgProvider).valueOrNull;
        if (org == null) throw StateError('No organization loaded');
        return buildReceiptPdf(
          org: org,
          settlement: s,
          isSales: true,
          logo: await ref.read(orgLogoProvider.future),
          mode: org.usesPreprintedLetterhead
              ? LetterheadMode.stationery
              : LetterheadMode.printed,
        );
      },
    );
  }

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

/// Sending a customer their receipt.
///
/// Separate from the document send dialog rather than a mode of it: this
/// one attaches by default and offers no link, because a receipt is
/// evidence of a completed fact rather than a document that stays
/// current, and issuing a share token here would revoke the invoice's
/// live link as a side effect. The two are the same shape and not the
/// same thing.
///
/// The parts worth getting right are shared: [sendNowOutcome] decides
/// what actually happened from the outbox row, so "Sent" here means the
/// same as it does there.
Future<void> showReceiptEmailDialog(
  BuildContext context, {
  required String receiptId,
  required String receiptNo,
  String? defaultTo,
  required Future<Uint8List> Function() buildPdf,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ReceiptEmailDialog(
      receiptId: receiptId,
      receiptNo: receiptNo,
      defaultTo: defaultTo,
      buildPdf: buildPdf,
    ),
  );
}

class _ReceiptEmailDialog extends ConsumerStatefulWidget {
  const _ReceiptEmailDialog({
    required this.receiptId,
    required this.receiptNo,
    required this.buildPdf,
    this.defaultTo,
  });

  final String receiptId;
  final String receiptNo;
  final String? defaultTo;
  final Future<Uint8List> Function() buildPdf;

  @override
  ConsumerState<_ReceiptEmailDialog> createState() =>
      _ReceiptEmailDialogState();
}

class _ReceiptEmailDialogState extends ConsumerState<_ReceiptEmailDialog> {
  late final TextEditingController _to =
      TextEditingController(text: widget.defaultTo ?? '');

  /// On by default, unlike a document. The attachment is the point of a
  /// receipt — there is no link to send instead.
  bool _attach = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _to.dispose();
    super.dispose();
  }

  bool get _addressLooksSane {
    final v = _to.text.trim();
    if (v.isEmpty) return true;
    return RegExp(r'^[^@\s,]+@[^@\s,]+\.[^@\s,]{2,}$').hasMatch(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Email ${widget.receiptNo}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _to,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Send to',
                hintText: widget.defaultTo ?? 'the address on the customer',
                helperText: widget.defaultTo == null
                    ? 'This customer has no address saved — type one'
                    : 'Leave as-is to use the customer’s address',
                errorText: _addressLooksSane
                    ? null
                    : 'That does not look like an email address',
              ),
            ),
            CheckboxListTile(
              value: _attach,
              onChanged:
                  _busy ? null : (v) => setState(() => _attach = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Attach the receipt'),
              subtitle: Text(
                _attach
                    ? 'The customer gets a PDF they can file.'
                    : 'Just the message — nothing to keep.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: Space.sm),
              Text(_error!, style: TextStyle(color: context.colors.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        OutlinedButton.icon(
          onPressed: _busy || !_addressLooksSane ? null : () => _send(now: false),
          icon: const Icon(Icons.schedule_send_outlined, size: 18),
          label: const Text('Queue it'),
        ),
        FilledButton.icon(
          onPressed: _busy || !_addressLooksSane ? null : () => _send(now: true),
          icon: const Icon(Icons.send_outlined, size: 18),
          label: const Text('Send now'),
        ),
      ],
    );
  }

  Future<void> _send({required bool now}) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final to = _to.text.trim().isEmpty ? null : _to.text.trim();

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      String? path;
      String? name;
      if (_attach) {
        final stem = widget.receiptNo
            .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
            .toLowerCase();
        name = '$stem.pdf';
        path = await repo.uploadReceiptPdf(
            widget.receiptId, name, await widget.buildPdf());
      }

      String message;
      var finished = true;
      if (now) {
        final outcome = sendNowOutcome(await repo.emailReceiptNow(
            widget.receiptId,
            to: to,
            attachmentPath: path,
            attachmentName: name));
        message = outcome.message;
        finished = outcome.finished;
        _error = outcome.error;
      } else {
        await repo.emailReceipt(widget.receiptId,
            to: to, attachmentPath: path, attachmentName: name);
        message = 'Queued — it will go out on the next send';
      }

      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(message)));
      if (finished) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
