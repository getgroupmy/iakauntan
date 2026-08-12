import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

/// Deducting tax from what a supplier is about to be paid.
///
/// The rate offered is the one in the Act. It is editable because a
/// double tax agreement can reduce any of them, and which one applies
/// depends on where the payee is resident — something no table here
/// knows. The section is recorded either way, because that is what goes
/// on the form.
Future<bool?> showWithholdingDialog(
  BuildContext context,
  String billId,
  double billTotal,
) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _WithholdingDialog(billId: billId, billTotal: billTotal),
  );
}

class _WithholdingDialog extends ConsumerStatefulWidget {
  const _WithholdingDialog({required this.billId, required this.billTotal});

  final String billId;
  final double billTotal;

  @override
  ConsumerState<_WithholdingDialog> createState() => _WithholdingDialogState();
}

class _WithholdingDialogState extends ConsumerState<_WithholdingDialog> {
  late final TextEditingController _gross =
      TextEditingController(text: widget.billTotal.toStringAsFixed(2));
  final _rate = TextEditingController();

  String? _code;
  bool _postNow = true;
  bool _saving = false;

  @override
  void dispose() {
    _gross.dispose();
    _rate.dispose();
    super.dispose();
  }

  double get _tax {
    final gross = double.tryParse(_gross.text.trim()) ?? 0;
    final rate = double.tryParse(_rate.text.trim()) ?? 0;
    return (gross * rate / 100 * 100).round() / 100;
  }

  Future<void> _save() async {
    if (_code == null) return;
    setState(() => _saving = true);
    final repo = ref.read(repoProvider)!;
    final ok = await runWithFeedback(
      context,
      action: () async {
        final id = await repo.createWithholding(
          billId: widget.billId,
          whtCode: _code!,
          grossAmount: double.tryParse(_gross.text.trim()),
          rate: double.tryParse(_rate.text.trim()),
        );
        if (_postNow) await repo.postWithholding(id);
      },
      successMessage: _postNow
          ? 'Withheld ${Fmt.money(_tax)}'
          : 'Certificate raised as a draft',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.invalidate(withholdingReportProvider);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = ref.watch(withholdingTypesProvider);

    return AlertDialog(
      title: const Text('Withhold tax'),
      content: SizedBox(
        width: 520,
        child: AsyncView(
          value: types,
          onRetry: () => ref.invalidate(withholdingTypesProvider),
          builder: (list) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  value: _code,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Under which section'),
                  items: [
                    for (final t in list)
                      DropdownMenuItem(
                        value: t['code'] as String,
                        child: Text(
                          '${t['section']} — ${t['name']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    final t = list.firstWhere((e) => e['code'] == v);
                    setState(() {
                      _code = v;
                      _rate.text = Fmt.toDouble(t['rate']).toStringAsFixed(2);
                    });
                  },
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _gross,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Amount subject to withholding',
                        prefixText: 'RM ',
                        helperText: 'The whole bill unless part of it is '
                            'reimbursed expenses',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 130,
                    child: TextField(
                      controller: _rate,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Rate',
                        suffixText: '%',
                        helperText: 'A treaty may cut it',
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(children: [
                    const Expanded(
                      child: Text('Withheld, and owed to LHDN',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Money(_tax, bold: true),
                  ]),
                ),
                const SizedBox(height: 4),
                Text(
                  'The supplier is paid ${Fmt.money(widget.billTotal - _tax)} '
                  'and gets a certificate for the rest. Remittance is due '
                  'within one month.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _postNow,
                  onChanged: (v) => setState(() => _postNow = v),
                  title: const Text('Post it now'),
                  subtitle: const Text(
                      'Moves the deduction off the payable straight away'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _code == null || _tax <= 0 ? null : _save,
          child: const Text('Withhold'),
        ),
      ],
    );
  }
}
