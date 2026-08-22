import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// How a line reads while somebody decides how much of it is coming
/// back.
///
/// Pure and exported so the dialog and the tests agree. What is left is
/// the number that matters — a line already fully credited should say
/// so rather than offering a box that will be refused.
String creditLineLabel(Map<String, dynamic> row) {
  final invoiced = num.tryParse('${row['invoiced'] ?? 0}') ?? 0;
  final credited = num.tryParse('${row['credited'] ?? 0}') ?? 0;
  final remaining = num.tryParse('${row['remaining'] ?? 0}') ?? 0;
  if (credited <= 0) return '${Fmt.qty(invoiced)} invoiced';
  if (remaining <= 0) return 'All ${Fmt.qty(invoiced)} already credited';
  return '${Fmt.qty(invoiced)} invoiced · ${Fmt.qty(credited)} credited · '
      '${Fmt.qty(remaining)} left';
}

/// What the credit note will come to, at the invoice's own prices.
///
/// Shown before anything is posted, because the number somebody is
/// about to hand back is the thing being decided.
num creditTotal(
  List<Map<String, dynamic>> rows,
  Map<String, num> quantities,
) {
  num total = 0;
  for (final r in rows) {
    final q = quantities['${r['line_id']}'] ?? 0;
    total += q * (num.tryParse('${r['unit_price'] ?? 0}') ?? 0);
  }
  return total;
}

/// Whether there is anything to credit at all.
bool hasCreditable(List<Map<String, dynamic>> rows) =>
    rows.any((r) => (num.tryParse('${r['remaining'] ?? 0}') ?? 0) > 0);

/// Crediting an invoice: which lines, how many of each, and why.
///
/// Returns the new credit note's id, or null if nothing was created.
Future<String?> showCreditDialog(
  BuildContext context,
  WidgetRef ref, {
  required String invoiceId,
  required String invoiceNo,
}) => showDialog<String>(
  context: context,
  builder: (_) => _CreditDialog(invoiceId: invoiceId, invoiceNo: invoiceNo),
);

class _CreditDialog extends ConsumerStatefulWidget {
  const _CreditDialog({required this.invoiceId, required this.invoiceNo});

  final String invoiceId;
  final String invoiceNo;

  @override
  ConsumerState<_CreditDialog> createState() => _CreditDialogState();
}

class _CreditDialogState extends ConsumerState<_CreditDialog> {
  final Map<String, TextEditingController> _fields = {};
  final _reason = TextEditingController();
  bool _seeded = false;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _reason.dispose();
    super.dispose();
  }

  Map<String, num> get _quantities => {
    for (final e in _fields.entries)
      e.key: num.tryParse(e.value.text.trim()) ?? 0,
  };

  Future<void> _credit(List<Map<String, dynamic>> rows) async {
    final asked = <String, num>{
      for (final e in _quantities.entries)
        if (e.value > 0) e.key: e.value,
    };
    if (asked.isEmpty) return;

    String? made;
    final ok = await runWithFeedback(
      context,
      action: () async {
        made = await ref
            .read(repoProvider)!
            .creditSalesInvoice(
              widget.invoiceId,
              lines: asked,
              reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
            );
      },
      successMessage: null,
    );
    if (ok && made != null && mounted) Navigator.of(context).pop(made);
  }

  @override
  Widget build(BuildContext context) {
    final remaining = ref.watch(
      invoiceCreditRemainingProvider(widget.invoiceId),
    );

    return AlertDialog(
      title: Text('Credit ${widget.invoiceNo}'),
      content: SizedBox(
        width: 460,
        child: AsyncView(
          value: remaining,
          builder: (rows) {
            // Seeded once with everything still creditable: the common
            // case is the customer brought the lot back, and a dialog
            // full of zeros makes that the slowest thing to do.
            if (!_seeded) {
              for (final r in rows) {
                _fields['${r['line_id']}'] = TextEditingController(
                  text: '${r['remaining']}',
                );
              }
              _seeded = true;
            }
            if (!hasCreditable(rows)) {
              return const Padding(
                padding: EdgeInsets.all(Space.md),
                child: Text(
                  'Every line on this invoice has already been credited.',
                ),
              );
            }
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.sm),
                      child: TextField(
                        controller: _fields['${r['line_id']}'],
                        keyboardType: TextInputType.number,
                        enabled:
                            (num.tryParse('${r['remaining'] ?? 0}') ?? 0) > 0,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: '${r['description']}',
                          helperText: creditLineLabel(r),
                          suffixText: '${r['uom_code'] ?? ''}',
                        ),
                      ),
                    ),
                  const SizedBox(height: Space.sm),
                  TextField(
                    controller: _reason,
                    decoration: const InputDecoration(
                      labelText: 'Why',
                      helperText: 'Goes on the credit note.',
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    'Crediting ${Fmt.money(creditTotal(rows, _quantities))}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    'Posted straight away, against this invoice. Anything '
                    'sold from the till puts its ingredients back as well.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.colors.info,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: remaining.valueOrNull == null
              ? null
              : () => _credit(remaining.value!),
          child: const Text('Credit it'),
        ),
      ],
    );
  }
}
