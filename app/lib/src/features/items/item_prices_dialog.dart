import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/quick_add_dialog.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// What this item costs at each price level, and at what quantity.
///
/// `item_prices` has been in the schema since 0003 with nothing able to
/// write it, so a price level could only shift every item by the same
/// percentage — and the resolver added in 0088 reads named prices and
/// quantity breaks that nothing could put there.
Future<void> showItemPrices(BuildContext context, Item item) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ItemPricesDialog(item: item),
  );
}

class _ItemPricesDialog extends ConsumerWidget {
  const _ItemPricesDialog({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prices = ref.watch(itemPricesProvider(item.id));
    final levels = ref.watch(priceLevelsProvider).valueOrNull ?? const [];

    return AlertDialog(
      title: Text('${item.name} · prices'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'List price ${Fmt.money(item.unitPrice)}. A named price '
                'below overrides it for customers on that level; a level '
                'with no named price falls back to its percentage of list.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              if (levels.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'No price levels have been set up, so there is '
                        'nothing to price against yet.',
                        style: TextStyle(color: context.colors.warning),
                      ),
                      const SizedBox(height: Space.sm),
                      OutlinedButton(
                        onPressed: () => showPriceLevels(context),
                        child: const Text('Set up price levels'),
                      ),
                    ],
                  ),
                )
              else
                AsyncView(
                  value: prices,
                  onRetry: () => ref.invalidate(itemPricesProvider(item.id)),
                  builder: (list) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (list.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: Space.lg),
                          child: Text('No named prices — every level is a '
                              'percentage of the list price.'),
                        )
                      else
                        for (final p in list)
                          _PriceRow(
                            row: p,
                            listPrice: item.unitPrice,
                            onEdit: () => _edit(context, ref, p),
                            onDelete: () => _delete(context, ref, p),
                          ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (levels.isNotEmpty)
          TextButton(
            onPressed: () => _edit(context, ref, null),
            child: const Text('Add price'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref,
      Map<String, dynamic>? row) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _PriceDialog(itemId: item.id, row: row),
    );
    if (saved == true) ref.invalidate(itemPricesProvider(item.id));
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, Map<String, dynamic> row) async {
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .deleteSetupRow('item_prices', row['id'] as String),
      successMessage: 'Price removed',
    );
    ref.invalidate(itemPricesProvider(item.id));
  }
}

class _PriceRow extends StatelessWidget {
  const _PriceRow({
    required this.row,
    required this.listPrice,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, dynamic> row;
  final double listPrice;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final level = row['price_levels'];
    final price = Fmt.toDouble(row['unit_price']);
    final min = Fmt.toDouble(row['min_quantity']);
    // Against list, because that is the number somebody is checking
    // when they open this: how much am I discounting?
    final delta = listPrice == 0 ? 0.0 : (price - listPrice) / listPrice * 100;

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: onEdit,
      title: Text(level is Map
          ? '${level['code']} · ${level['name']}'
          : 'Price level'),
      subtitle: Text(
        [
          if (min > 0) 'from ${Fmt.qty(min)} units' else 'any quantity',
          if (listPrice > 0)
            '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}% on list',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Money(price, bold: true),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          onPressed: onDelete,
        ),
      ]),
    );
  }
}

class _PriceDialog extends ConsumerStatefulWidget {
  const _PriceDialog({required this.itemId, this.row});

  final String itemId;
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_PriceDialog> createState() => _PriceDialogState();
}

class _PriceDialogState extends ConsumerState<_PriceDialog> {
  late String? _levelId = widget.row?['price_level_id'] as String?;
  late final _price =
      TextEditingController(text: widget.row?['unit_price']?.toString() ?? '');
  late final _minQty = TextEditingController(
      text: widget.row?['min_quantity']?.toString() ?? '0');
  bool _saving = false;

  @override
  void dispose() {
    _price.dispose();
    _minQty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final levels = ref.watch(priceLevelsProvider).valueOrNull ?? const [];
    if (_levelId == null && levels.isNotEmpty) {
      _levelId = levels.first['id'] as String;
    }

    return AlertDialog(
      title: Text(widget.row == null ? 'Add price' : 'Edit price'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SearchablePicker<String>(
              options: [
                for (final l in levels)
                  PickerOption<String>(
                    value: l['id'] as String,
                    label: '${l['name']}',
                    sublabel: '${l['code']}',
                    keywords: ['${l['code']}'],
                  ),
              ],
              value: _levelId,
              label: 'Price level',
              createLabel: 'Add price level',
              onCreate: (typed) => quickAdd(
                context,
                title: 'New price level',
                blurb: 'Not on the list yet. A name and a code is all a '
                    'level is; which customers get it is set on the '
                    'Price levels screen.',
                nameHint: 'Wholesale',
                codeLabel: 'Code',
                seed: typed,
                save: ({required name, code}) async {
                  final id = await ref.read(repoProvider)!.createQuickRow(
                        QuickAddList.priceLevel,
                        name: name,
                        code: code,
                      );
                  ref.invalidate(priceLevelsProvider);
                  return id;
                },
              ),
              onChanged: (v) => setState(() => _levelId = v),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _price,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Unit price *', prefixText: 'RM '),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _minQty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'From quantity',
                helperText: 'A quantity break. Leave at zero for any quantity',
              ),
            ),
          ],
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
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final price = double.tryParse(_price.text.trim());
    final problem = _levelId == null
        ? 'Choose a price level.'
        : (price == null || price < 0)
            ? 'Enter a price.'
            : null;
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
      return;
    }

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveItemPrice(
            {
              'item_id': widget.itemId,
              'price_level_id': _levelId,
              'unit_price': price,
              'min_quantity': double.tryParse(_minQty.text.trim()) ?? 0,
            },
            id: widget.row?['id'] as String?,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}

/// The price levels themselves: Retail, Wholesale, Staff, whatever a
/// business calls them.
///
/// `price_levels` has been readable since 0003 and creatable by nothing,
/// so `contacts.price_level_id` could only ever be null and the named
/// prices above had no level to hang off. Half of a feature is not a
/// feature.
Future<void> showPriceLevels(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _PriceLevelsDialog(),
  );
}

class _PriceLevelsDialog extends ConsumerWidget {
  const _PriceLevelsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final levels = ref.watch(priceLevelsProvider);

    return AlertDialog(
      title: const Text('Price levels'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'A level moves every price by a percentage of list. Name a '
                'price for a particular item and that wins instead.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              AsyncView(
                value: levels,
                onRetry: () => ref.invalidate(priceLevelsProvider),
                builder: (list) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (list.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: Space.lg),
                        child: Text('None yet.'),
                      )
                    else
                      for (final l in list)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          onTap: () => _edit(context, ref, l),
                          title: Row(children: [
                            Flexible(
                              child: Text('${l['code']} · ${l['name']}',
                                  overflow: TextOverflow.ellipsis),
                            ),
                            if (l['is_default'] == true) ...[
                              const SizedBox(width: Space.sm),
                              const StatusChip('default', compact: true),
                            ],
                          ]),
                          subtitle: Text(
                            [
                              _percentLabel(Fmt.toDouble(l['adjustment_percent'])),
                              if (l['is_active'] != true) 'inactive',
                            ].join(' · '),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _edit(context, ref, null),
          child: const Text('Add level'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  static String _percentLabel(double percent) => percent == 0
      ? 'list price'
      : '${percent > 0 ? '+' : ''}${Fmt.qty(percent)}% on list';

  Future<void> _edit(BuildContext context, WidgetRef ref,
      Map<String, dynamic>? row) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _LevelDialog(row: row),
    );
    if (saved == true) ref.invalidate(priceLevelsProvider);
  }
}

class _LevelDialog extends ConsumerStatefulWidget {
  const _LevelDialog({this.row});

  final Map<String, dynamic>? row;

  @override
  ConsumerState<_LevelDialog> createState() => _LevelDialogState();
}

class _LevelDialogState extends ConsumerState<_LevelDialog> {
  late final _code =
      TextEditingController(text: widget.row?['code']?.toString() ?? '');
  late final _name =
      TextEditingController(text: widget.row?['name']?.toString() ?? '');
  late final _percent = TextEditingController(
      text: widget.row?['adjustment_percent']?.toString() ?? '0');
  late bool _active = widget.row?['is_active'] != false;
  bool _saving = false;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _percent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.row == null ? 'Add price level' : 'Edit price level'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _code,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Code *', hintText: 'WHOLESALE'),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                  labelText: 'Name *', hintText: 'Wholesale'),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _percent,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true),
              decoration: const InputDecoration(
                labelText: 'Adjustment',
                suffixText: '%',
                helperText: 'Negative for a discount off list',
              ),
            ),
            const SizedBox(height: Space.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('Active'),
            ),
          ],
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
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_code.text.trim().isEmpty || _name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A level needs a code and a name')));
      return;
    }
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveSetupRow(
            'price_levels',
            {
              'code': _code.text.trim().toUpperCase(),
              'name': _name.text.trim(),
              'adjustment_percent':
                  double.tryParse(_percent.text.trim()) ?? 0,
              'is_active': _active,
            },
            id: widget.row?['id'] as String?,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}
