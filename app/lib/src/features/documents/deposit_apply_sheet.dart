import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Setting a deposit against the document it was taken for.
///
/// `apply_deposit` has been in `0273` since deposits went in, and the
/// only two things the app could do with a deposit were give it back
/// and keep it. The ordinary outcome — the job gets done, the invoice
/// goes out, and the money already held pays part of it — had no
/// button, so a deposit sat as a liability against an invoice that read
/// as unpaid, and somebody settled both by hand in a journal.

/// Which of a party's outstanding documents this deposit can go against.
///
/// `apply_deposit` refuses three shapes, and each refusal is a sentence
/// somebody would otherwise read after choosing: a document that is not
/// posted or partial, and one written in another currency — which it
/// sends to a receipt instead, so the exchange difference is struck
/// where the rest of them are. Narrowed here so the choice offered is
/// the choice the server will take.
List<BusinessDocument> applicableDocuments(
  Iterable<BusinessDocument> docs,
  String currency,
) =>
    docs
        .where(
          (d) =>
              (d.status == 'posted' || d.status == 'partial') &&
              d.currency == currency &&
              d.balanceAmount > 0,
        )
        .toList();

/// The most that can sensibly be applied.
///
/// Both ends bind: the deposit cannot give more than is left of it, and
/// the document cannot take more than it still owes. The smaller of the
/// two is what the field opens at, because it is right far more often
/// than either figure alone.
double applicableAmount(num depositBalance, num documentBalance) {
  final smaller =
      depositBalance < documentBalance ? depositBalance : documentBalance;
  return double.parse((smaller < 0 ? 0 : smaller).toStringAsFixed(2));
}

/// What was typed, or null where the server would refuse it.
///
/// Rounded to the sen first, because `apply_deposit` rounds before it
/// compares and a third decimal that rounds up past the balance is
/// refused for a reason nobody can see on screen.
double? applyAmountOf(
  String text, {
  required num depositBalance,
  required num documentBalance,
}) {
  final raw = double.tryParse(text.trim().replaceAll(',', ''));
  if (raw == null) return null;
  final v = double.parse(raw.toStringAsFixed(2));
  if (v <= 0) return null;
  if (v > depositBalance) return null;
  if (v > documentBalance) return null;
  return v;
}

/// What a document reads as in the picker.
String applicableLabel(BusinessDocument d) =>
    '${d.docNo} · ${Fmt.money(d.balanceAmount)} outstanding';

/// Set a deposit against an invoice or a bill.
Future<bool> showApplyDepositSheet(
  BuildContext context, {
  required String depositId,
  required String kind,
  required String contactId,
  required String currency,
  required num balance,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _ApplySheet(
        depositId: depositId,
        kind: kind,
        contactId: contactId,
        currency: currency,
        balance: balance,
      ),
    ) ??
    false;

class _ApplySheet extends ConsumerStatefulWidget {
  const _ApplySheet({
    required this.depositId,
    required this.kind,
    required this.contactId,
    required this.currency,
    required this.balance,
  });

  final String depositId;
  final String kind;
  final String contactId;
  final String currency;
  final num balance;

  @override
  ConsumerState<_ApplySheet> createState() => _ApplySheetState();
}

class _ApplySheetState extends ConsumerState<_ApplySheet> {
  final _amount = TextEditingController();

  String? _documentId;
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  List<BusinessDocument> _documents() {
    final docs = ref
            .watch(
              outstandingProvider((
                kind: widget.kind == 'customer' ? DocKind.sales : DocKind.purchase,
                contactId: widget.contactId,
              )),
            )
            .valueOrNull ??
        const <BusinessDocument>[];
    return applicableDocuments(docs, widget.currency);
  }

  BusinessDocument? _chosen(List<BusinessDocument> docs) {
    for (final d in docs) {
      if (d.id == _documentId) return d;
    }
    return null;
  }

  Future<void> _save(BusinessDocument doc) async {
    final amount = applyAmountOf(
      _amount.text,
      depositBalance: widget.balance,
      documentBalance: doc.balanceAmount,
    );
    if (amount == null) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.applyDeposit(
            depositId: widget.depositId,
            documentId: doc.id,
            amount: amount,
          ),
      successMessage: 'Applied to ${doc.docNo}',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(depositHistoryProvider(widget.depositId));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = _documents();
    final chosen = _chosen(docs);
    final ready = chosen != null &&
        applyAmountOf(
              _amount.text,
              depositBalance: widget.balance,
              documentBalance: chosen.balanceAmount,
            ) !=
            null;

    return AlertDialog(
      title: Text(
        widget.kind == 'customer' ? 'Apply to an invoice' : 'Apply to a bill',
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${Fmt.money(widget.balance)} is still held. Applying it '
                'discharges the deposit against the document and leaves '
                'both showing what is actually owed.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
              const SizedBox(height: Space.md),
              if (docs.isEmpty)
                Text(
                  widget.kind == 'customer'
                      ? 'This customer has nothing outstanding in '
                          '${widget.currency}. A deposit goes against a '
                          'posted invoice; raise it first.'
                      : 'Nothing is outstanding to this supplier in '
                          '${widget.currency}. A deposit goes against a '
                          'posted bill; enter it first.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.colors.warning),
                )
              else
                DropdownButtonFormField<String?>(
                  key: const ValueKey('apply-document'),
                  value: _documentId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Against'),
                  items: [
                    for (final d in docs)
                      DropdownMenuItem<String?>(
                        value: d.id,
                        child: Text(
                          applicableLabel(d),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (v) => setState(() {
                            _documentId = v;
                            // Whichever binds first: the deposit's
                            // balance or what the document still owes.
                            final d = _chosen(docs);
                            if (d != null) {
                              _amount.text = applicableAmount(
                                widget.balance,
                                d.balanceAmount,
                              ).toStringAsFixed(2);
                            }
                          }),
                ),
              if (chosen != null) ...[
                const SizedBox(height: Space.md),
                TextField(
                  key: const ValueKey('apply-amount'),
                  controller: _amount,
                  enabled: !_saving,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'How much',
                    prefixText: '${widget.currency} ',
                    helperText: 'At most ${Fmt.money(
                      applicableAmount(widget.balance, chosen.balanceAmount),
                    )} — the smaller of what is held and what is owed.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('apply-save'),
          onPressed: _saving || !ready ? null : () => _save(chosen),
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Apply'),
        ),
      ],
    );
  }
}
