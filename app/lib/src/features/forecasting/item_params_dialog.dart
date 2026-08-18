import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// What this item does differently from the rest of the catalogue.
///
/// Every field is optional and every empty field means "use the
/// company's answer" — which is why they are cleared to null rather
/// than saved as zero. A minimum order quantity of nought and no
/// minimum order quantity are different statements, and writing the
/// first when somebody meant the second is how a suggestion of seven
/// silently becomes seven when the carton is twelve.
///
/// Returns true when something was saved.
Future<bool> showItemForecastParams(
  BuildContext context,
  WidgetRef ref, {
  required String itemId,
  required String itemLabel,
}) async {
  final current = await ref.read(itemForecastParamsProvider(itemId).future);
  if (!context.mounted) return false;
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _ItemParamsDialog(
      itemId: itemId,
      itemLabel: itemLabel,
      current: current ?? const {},
    ),
  );
  if (saved ?? false) ref.invalidate(itemForecastParamsProvider(itemId));
  return saved ?? false;
}

class _ItemParamsDialog extends ConsumerStatefulWidget {
  const _ItemParamsDialog({
    required this.itemId,
    required this.itemLabel,
    required this.current,
  });

  final String itemId;
  final String itemLabel;
  final Map<String, dynamic> current;

  @override
  ConsumerState<_ItemParamsDialog> createState() => _ItemParamsDialogState();
}

class _ItemParamsDialogState extends ConsumerState<_ItemParamsDialog> {
  final _form = GlobalKey<FormState>();

  late final _min = _c('min_quantity');
  late final _max = _c('max_quantity');
  late final _moq = _c('min_order_quantity');
  late final _multiple = _c('order_multiple');
  late final _lead = _c('lead_time_days');
  late String? _supplier = widget.current['supplier_id'] as String?;
  late bool _excluded = widget.current['is_excluded'] as bool? ?? false;
  bool _saving = false;

  TextEditingController _c(String key) =>
      TextEditingController(text: widget.current[key]?.toString() ?? '');

  @override
  void dispose() {
    for (final c in [_min, _max, _moq, _multiple, _lead]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = ref.watch(
      contactsProvider((type: 'supplier', search: '')),
    );

    return AlertDialog(
      title: Text(widget.itemLabel),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Leave a field empty to use the company setting.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Space.md),
                _number(
                  _min,
                  'Minimum on the shelf',
                  'A floor you impose whatever the demand says — the stock '
                      'you hold so somebody can collect it today. An item '
                      'under it is asked for even when its cover is long.',
                ),
                _number(
                  _max,
                  'Most to hold',
                  'How you stop the system suggesting a year of something '
                      'with a shelf life.',
                ),
                _number(
                  _moq,
                  'Supplier minimum order',
                  'The smallest quantity this supplier will accept.',
                ),
                _number(
                  _multiple,
                  'Order multiple',
                  'The carton. Suggestions round up to it, never down: a '
                      'carton rounded down is an order that arrives short.',
                ),
                _number(
                  _lead,
                  'Lead time override, in days',
                  'Only set this when the measured figure is wrong. Left '
                      'empty the lead time is measured from this item\'s own '
                      'deliveries, which is better evidence than a number '
                      'anybody types.',
                  whole: true,
                  max: 365,
                ),
                const SizedBox(height: Space.sm),
                suppliers.maybeWhen(
                  data: (list) => DropdownButtonFormField<String?>(
                    value: _supplier,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Buy this from',
                      helperText:
                          'Overrides the preferred supplier on the item. '
                          'Orders are grouped by supplier, and an item with '
                          'none cannot be ordered at all.',
                      helperMaxLines: 3,
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Use the item\'s preferred supplier'),
                      ),
                      for (final Contact c in list)
                        DropdownMenuItem<String?>(
                          value: c.id,
                          child: Text(c.name),
                        ),
                    ],
                    onChanged: (v) => setState(() => _supplier = v),
                  ),
                  orElse: () => const LinearProgressIndicator(),
                ),
                const SizedBox(height: Space.sm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _excluded,
                  title: const Text('Leave this item out of the forecast'),
                  subtitle: const Text(
                    'It still appears in the run\'s counts, so "we forecast '
                    '12 of 400 items" stays answerable.',
                  ),
                  onChanged: (v) => setState(() => _excluded = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
      ],
    );
  }

  Widget _number(
    TextEditingController c,
    String label,
    String help, {
    bool whole = false,
    num? max,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: Space.md),
    child: TextFormField(
      controller: c,
      keyboardType: TextInputType.numberWithOptions(decimal: !whole),
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 4,
      ),
      validator: (v) {
        final t = (v ?? '').trim();
        if (t.isEmpty) return null;
        final n = whole ? int.tryParse(t) : double.tryParse(t);
        if (n == null) return whole ? 'A whole number' : 'A number';
        if (n < 0) return 'Not negative';
        if (max != null && n > max) return 'At most $max';
        return null;
      },
    ),
  );

  /// Empty means "no answer here", which has to reach the database as
  /// null rather than as zero.
  Object? _valueOf(TextEditingController c, {bool whole = false}) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return whole ? int.tryParse(t) : double.tryParse(t);
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved. Run the forecast again to see it applied.',
      action: () => repo.saveItemForecastParams(widget.itemId, {
        'min_quantity': _valueOf(_min),
        'max_quantity': _valueOf(_max),
        'min_order_quantity': _valueOf(_moq),
        'order_multiple': _valueOf(_multiple),
        'lead_time_days': _valueOf(_lead, whole: true),
        'supplier_id': _supplier,
        'is_excluded': _excluded,
      }),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context, true);
  }
}
