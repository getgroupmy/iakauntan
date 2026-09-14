import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'tax_exemption.dart';

/// Adding a rate, or correcting one.
///
/// Retiring rather than deleting is the only part with an opinion in it.
/// A tax code is on every document that ever used it, and a rate that
/// stops applying today still applied last year — a deleted one would
/// leave the trial balance unable to explain itself.
///
/// It lives in its own file because it is reached from two directions
/// now: the Tax codes card in settings, and [pickedTaxCode] — the
/// "it is not on the list" offer at the bottom of every tax code
/// picker. A tax code asks more than a name and a code, so it cannot be
/// a `QuickAddDialog`: it asks for the rate, the LHDN tax type, and
/// what exempts it, and getting the rate wrong is a wrong number on
/// every document from here on.
///
/// It pops the id of the code it saved, or null if nothing was saved,
/// so the picker that opened it can select what was just added.
class TaxCodeDialog extends ConsumerStatefulWidget {
  const TaxCodeDialog({super.key, this.existing, this.seed});

  final TaxCode? existing;

  /// What was typed into the picker that opened this. It seeds the
  /// code, upper-cased, because that is what somebody types when they
  /// are looking for a rate: "SR8", not "Service tax at 8%".
  final String? seed;

  @override
  ConsumerState<TaxCodeDialog> createState() => _TaxCodeDialogState();
}

class _TaxCodeDialogState extends ConsumerState<TaxCodeDialog> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _rate = TextEditingController();
  late String _taxType;
  late bool _exempt;
  String? _exemptionReason;
  bool _saving = false;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final t = widget.existing;
    _code.text = t?.code ?? (widget.seed ?? '').trim().toUpperCase();
    _name.text = t?.name ?? '';
    _rate.text = t == null ? '' : t.rate.toStringAsFixed(2);
    _taxType = t?.taxTypeCode ?? '06';
    _exempt = t?.isExempt ?? false;
    _exemptionReason = t?.exemptionReason;
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _rate.dispose();
    super.dispose();
  }

  double? get _parsedRate => double.tryParse(_rate.text.trim());

  String? get _blocked =>
      exemptionBlockedBecause(isExempt: _exempt, reason: _exemptionReason);

  bool get _valid =>
      _code.text.trim().isNotEmpty &&
      _name.text.trim().isNotEmpty &&
      _parsedRate != null &&
      _parsedRate! >= 0 &&
      _parsedRate! <= 100 &&
      _blocked == null;

  Future<void> _save() async {
    setState(() => _saving = true);
    final repo = ref.read(repoProvider)!;
    // The row this dialog is about, so a picker that opened it can
    // select what was just added rather than leaving the box empty
    // next to a list that now contains the answer.
    var saved = widget.existing?.id;
    final ok = await runWithFeedback(
      context,
      action: () async {
        final reason = exemptionOf(isExempt: _exempt, reason: _exemptionReason);
        if (_isNew) {
          saved = await repo.createTaxCode(
            code: _code.text.trim().toUpperCase(),
            name: _name.text.trim(),
            rate: _parsedRate!,
            taxTypeCode: _taxType,
            isExempt: _exempt,
            exemptionReason: reason,
          );
        } else {
          await repo.updateTaxCode(
            widget.existing!.id,
            code: _code.text.trim().toUpperCase(),
            name: _name.text.trim(),
            rate: _parsedRate!,
            taxTypeCode: _taxType,
            isExempt: _exempt,
            exemptionReason: reason,
          );
        }
      },
      successMessage: _isNew ? 'Tax code added' : 'Tax code saved',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isNew ? 'New tax code' : 'Edit ${widget.existing!.code}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: TextField(
                    key: const ValueKey('tax-code-code'),
                    controller: _code,
                    enabled: !_saving,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Code'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('tax-code-name'),
                    controller: _name,
                    enabled: !_saving,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: TextField(
                    key: const ValueKey('tax-code-rate'),
                    controller: _rate,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Rate',
                      suffixText: '%',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _taxType,
                    decoration: const InputDecoration(
                      labelText: 'LHDN tax type',
                    ),
                    items: const [
                      DropdownMenuItem(value: '01', child: Text('01 — Sales')),
                      DropdownMenuItem(
                        value: '02',
                        child: Text('02 — Service'),
                      ),
                      DropdownMenuItem(
                        value: '06',
                        child: Text('06 — Not applicable'),
                      ),
                      DropdownMenuItem(value: 'E', child: Text('E — Exempt')),
                    ],
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => _taxType = v!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _exempt,
              onChanged: _saving ? null : (v) => setState(() => _exempt = v!),
              title: const Text('Exempt'),
              subtitle: const Text('Shown on the document as exempt, not zero'),
            ),
            // Only where it applies, and required there. An exempt line
            // that does not say what exempts it is an e-Invoice LHDN
            // has nothing to check the claim against.
            if (_exempt)
              Consumer(
                builder: (context, ref, _) {
                  final all =
                      ref.watch(exemptionReasonsProvider).valueOrNull ??
                      const <Map<String, dynamic>>[];
                  return DropdownButtonFormField<String?>(
                    key: const ValueKey('tax-exemption-reason'),
                    value: all.any((r) => r['code'] == _exemptionReason)
                        ? _exemptionReason
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'What exempts it',
                      helperText: 'LHDN puts this on the line.',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Not said'),
                      ),
                      for (final r in all)
                        DropdownMenuItem<String?>(
                          value: r['code'] as String?,
                          child: Text(
                            exemptionLabel(r),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => _exemptionReason = v),
                  );
                },
              ),
            if (!_isNew) ...[
              const Divider(height: Space.xl),
              Row(
                children: [
                  if (!widget.existing!.isDefault)
                    TextButton(
                      onPressed: _saving ? null : _makeDefault,
                      child: const Text('Make default'),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: _saving ? null : _retire,
                    child: Text(
                      'Retire',
                      style: TextStyle(color: context.colors.danger),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid && !_saving ? _save : null,
          child: Text(_isNew ? 'Add' : 'Save'),
        ),
      ],
    );
  }

  Future<void> _makeDefault() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.setDefaultTaxCode(widget.existing!.id),
      successMessage: 'Default tax code changed',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(widget.existing!.id);
  }

  Future<void> _retire() async {
    final sure = await confirm(
      context,
      title: 'Retire ${widget.existing!.code}?',
      message:
          'It stops being offered on new documents. Documents that '
          'already use it keep it, and the figures they carry do not move.',
      confirmLabel: 'Retire',
      destructive: true,
    );
    if (!sure || !mounted) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.retireTaxCode(widget.existing!.id),
      successMessage: 'Tax code retired',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(widget.existing!.id);
  }
}

/// The "it is not on the list" half of every tax code picker.
///
/// Opens [TaxCodeDialog] seeded with whatever was typed, refreshes the
/// list, and returns the new code's id so the picker selects it. Null
/// when the person backed out.
Future<String?> pickedTaxCode(
  BuildContext context,
  WidgetRef ref,
  String typed,
) async {
  final id = await showDialog<String>(
    context: context,
    builder: (_) => TaxCodeDialog(seed: typed),
  );
  if (id != null) ref.invalidate(taxCodesProvider);
  return id;
}

/// One tax code, found by typing.
///
/// Every screen that asks for a tax code asks the same question and
/// gets the same answer wrong in the same way, so it is asked once
/// here: the code and its rate are what somebody reads, the name is
/// what they search by, and the offer to add one is at the bottom
/// where a rate that was announced this month is not yet on file.
///
/// [allowEmpty] is the difference between the places. A line on an
/// invoice may have no tax; the default a company sets for new
/// documents may not be nothing, because "nothing" there means every
/// document from here on carries no tax at all.
class TaxCodePicker extends ConsumerWidget {
  const TaxCodePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Tax code',
    this.helperText,
    this.enabled = true,
    this.allowEmpty = false,
    this.emptyLabel = 'None',
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;
  final String? helperText;
  final bool enabled;
  final bool allowEmpty;
  final String emptyLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final codes = ref.watch(taxCodesProvider).valueOrNull ?? const <TaxCode>[];
    return SearchablePicker<String>(
      options: [
        for (final t in codes)
          PickerOption<String>(
            value: t.id,
            label: t.rate == 0 ? t.code : '${t.code} (${Fmt.percent(t.rate)})',
            sublabel: t.name,
          ),
      ],
      value: codes.any((t) => t.id == value) ? value : null,
      label: label,
      helperText: helperText,
      enabled: enabled,
      allowEmpty: allowEmpty,
      emptyLabel: emptyLabel,
      createLabel: 'Add tax code',
      onCreate: (typed) => pickedTaxCode(context, ref, typed),
      onChanged: onChanged,
    );
  }
}
