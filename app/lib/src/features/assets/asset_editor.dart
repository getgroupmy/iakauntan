import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// Adds or amends one asset.
///
/// Returns true if something was saved.
Future<bool?> showAssetEditor(
  BuildContext context,
  WidgetRef ref, {
  FixedAsset? asset,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _AssetEditor(asset: asset),
  );
}

class _AssetEditor extends ConsumerStatefulWidget {
  const _AssetEditor({this.asset});

  final FixedAsset? asset;

  @override
  ConsumerState<_AssetEditor> createState() => _AssetEditorState();
}

class _AssetEditorState extends ConsumerState<_AssetEditor> {
  final _assetNo = TextEditingController();
  final _name = TextEditingController();
  final _category = TextEditingController();
  final _cost = TextEditingController();
  final _residual = TextEditingController(text: '0');
  final _life = TextEditingController(text: '60');
  final _rate = TextEditingController(text: '20');
  final _serial = TextEditingController();
  final _location = TextEditingController();

  DateTime _acquired = DateTime.now();
  String _method = 'straight_line';

  /// The Schedule 3 class, and null is a real answer: land and goodwill
  /// attract no capital allowance at all. `0664` says so on the column
  /// so nobody reads the blanks as a to-do list.
  String? _caClass;
  bool _saving = false;

  bool get _isNew => widget.asset == null;

  @override
  void initState() {
    super.initState();
    final a = widget.asset;
    if (a != null) {
      _assetNo.text = a.assetNo;
      _name.text = a.name;
      _category.text = a.category ?? '';
      _cost.text = a.cost.toStringAsFixed(2);
      _residual.text = a.residualValue.toStringAsFixed(2);
      _acquired = a.acquisitionDate;
      _method = a.method;
      if (a.usefulLifeMonths != null) _life.text = '${a.usefulLifeMonths}';
      if (a.ratePercent != null) _rate.text = Fmt.rate(a.ratePercent);
      _serial.text = a.serialNo ?? '';
      _location.text = a.location ?? '';
      _caClass = a.caClassCode;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _assetNo, _name, _category, _cost, _residual, _life, _rate,
      _serial, _location,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double get _costValue => double.tryParse(_cost.text.trim()) ?? 0;
  double get _residualValue => double.tryParse(_residual.text.trim()) ?? 0;

  /// What the annual charge works out at, so the figures can be sanity
  /// checked before they are committed to for the next five years.
  String get _annualCharge {
    if (_method == 'reducing_balance') {
      final rate = double.tryParse(_rate.text.trim()) ?? 0;
      return 'About ${Fmt.money(_costValue * rate / 100)} in the first year, '
          'less every year after';
    }
    final months = int.tryParse(_life.text.trim()) ?? 0;
    if (months <= 0) return '';
    final annual = (_costValue - _residualValue) * 12 / months;
    return '${Fmt.money(annual)} a year, '
        '${Fmt.money(annual / 12)} a month';
  }

  Future<void> _save() async {
    final problem = switch (null) {
      _ when _assetNo.text.trim().isEmpty => 'Give the asset a number.',
      _ when _name.text.trim().isEmpty => 'Give the asset a name.',
      _ when _costValue <= 0 => 'Enter what it cost.',
      _ when _residualValue > _costValue =>
        'The residual value cannot be more than the cost.',
      _ when _method == 'straight_line' &&
              (int.tryParse(_life.text.trim()) ?? 0) <= 0 =>
        'Enter the useful life in months.',
      _ when _method == 'reducing_balance' &&
              (double.tryParse(_rate.text.trim()) ?? 0) <= 0 =>
        'Enter the annual rate.',
      _ => null,
    };
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
      return;
    }

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveFixedAsset(
            FixedAsset(
              id: widget.asset?.id ?? '',
              assetNo: _assetNo.text.trim(),
              name: _name.text.trim(),
              category: _nullIfBlank(_category.text),
              acquisitionDate: _acquired,
              cost: _costValue,
              residualValue: _residualValue,
              method: _method,
              usefulLifeMonths: int.tryParse(_life.text.trim()),
              ratePercent: double.tryParse(_rate.text.trim()),
              serialNo: _nullIfBlank(_serial.text),
              location: _nullIfBlank(_location.text),
              caClassCode: _caClass,
            ),
            id: widget.asset?.id,
          ),
      successMessage: _isNew ? 'Asset added' : 'Asset saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  static String? _nullIfBlank(String v) =>
      v.trim().isEmpty ? null : v.trim();

  @override
  Widget build(BuildContext context) {
    final depreciated = (widget.asset?.accumulatedDepreciation ?? 0) > 0;

    return AlertDialog(
      title: Text(_isNew ? 'New asset' : widget.asset!.assetNo),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _assetNo,
                    decoration: const InputDecoration(labelText: 'Asset no. *'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Name *'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _category,
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      hintText: 'Motor vehicles, equipment…',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _acquired,
                        firstDate: DateTime(1990),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setState(() => _acquired = picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Acquired',
                        suffixIcon: Icon(Icons.calendar_today, size: 18),
                      ),
                      child: Text(Fmt.date(_acquired)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _cost,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Cost *',
                      prefixText: 'RM ',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _residual,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Residual value',
                      prefixText: 'RM ',
                      helperText: 'Never depreciated below this',
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                      value: 'straight_line', label: Text('Straight line')),
                  ButtonSegment(
                      value: 'reducing_balance', label: Text('Reducing balance')),
                ],
                selected: {_method},
                onSelectionChanged: (s) => setState(() => _method = s.first),
              ),
              const SizedBox(height: 12),
              if (_method == 'straight_line')
                TextField(
                  controller: _life,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Useful life',
                    suffixText: 'months',
                  ),
                )
              else
                TextField(
                  controller: _rate,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Annual rate',
                    suffixText: '%',
                    helperText: 'Applied monthly to the reducing balance',
                  ),
                ),
              if (_annualCharge.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(_annualCharge,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
              // Changing the basis of an asset already depreciated does
              // not rewrite what has been posted — the next run simply
              // measures against the new figures. Said out loud because
              // the alternative assumption is that it restates history.
              if (depreciated) ...[
                const SizedBox(height: 12),
                Text(
                  '${Fmt.money(widget.asset!.accumulatedDepreciation)} has '
                  'already been charged. Changing the cost or the basis '
                  'affects the next run onwards; nothing already posted is '
                  'rewritten.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _serial,
                    decoration:
                        const InputDecoration(labelText: 'Serial no.'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _location,
                    decoration: const InputDecoration(labelText: 'Location'),
                  ),
                ),
              ]),
              const SizedBox(height: Space.lg),
              const _CaClassHeading(),
              const SizedBox(height: Space.sm),
              _CaClassPicker(
                value: _caClass,
                onChanged: (c) => setState(() => _caClass = c),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// The heading over the tax side of the register.
///
/// Worth its own line rather than a label on the dropdown, because the
/// distinction it makes is the one everything else here depends on: the
/// figures above are the accounts, and this is the tax. They are not
/// meant to agree.
class _CaClassHeading extends StatelessWidget {
  const _CaClassHeading();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Capital allowances',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Text(
          'Schedule 3, ITA 1967. Separate from the depreciation above: '
          'depreciation is added back in a tax computation and replaced '
          'by these.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Which Schedule 3 class an asset falls in, read from the rate table.
///
/// Read rather than listed: Budget speeches move the rates, and a list
/// in Dart would be a second copy of them to forget.
class _CaClassPicker extends ConsumerWidget {
  const _CaClassPicker({required this.value, required this.onChanged});

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final classes = ref.watch(capitalAllowanceClassesProvider);
    final scheme = Theme.of(context).colorScheme;

    return AsyncView(
      value: classes,
      onRetry: () => ref.invalidate(capitalAllowanceClassesProvider),
      skeleton: const FormSkeleton(fields: 1),
      builder: (list) {
        // A class that is no longer in force but is still on this asset
        // must stay selectable, or opening an old asset silently blanks
        // its class and saving the form loses it.
        final known = list.any((c) => c.code == value);
        final chosen = list.where((c) => c.code == value).firstOrNull;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String?>(
              key: const ValueKey('asset-ca-class'),
              initialValue: known ? value : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Class'),
              items: [
                const DropdownMenuItem(
                  value: null,
                  // Not "none yet". Land attracts no capital allowance
                  // and never will, and a blank that reads as unfinished
                  // is a blank somebody fills in wrongly.
                  child: Text('No capital allowance (land, goodwill)'),
                ),
                for (final c in list)
                  DropdownMenuItem(
                    value: c.code,
                    child: Text('${c.label} — ${c.rates}'),
                  ),
              ],
              onChanged: onChanged,
            ),
            if (chosen?.costCap != null) ...[
              const SizedBox(height: Space.xs),
              Text(
                'Restricted: the allowance is computed on at most '
                '${Fmt.money(chosen!.costCap!)}, however much it cost.',
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ],
            if (chosen?.smallValueThreshold != null) ...[
              const SizedBox(height: Space.xs),
              Text(
                'Only for an asset costing less than '
                '${Fmt.money(chosen!.smallValueThreshold!)}. Above that '
                'it attracts nothing in this class — use its ordinary '
                'one.',
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ],
            if (chosen != null && !chosen.isVerified) ...[
              const SizedBox(height: Space.xs),
              Text(
                'These rates were taken from published percentages, not '
                'transcribed from the Act. Check them before filing.',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
