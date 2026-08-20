import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'item_prices_dialog.dart';
import 'item_variants_dialog.dart';
import 'stock_card_dialog.dart';

class ItemsScreen extends ConsumerStatefulWidget {
  const ItemsScreen({super.key});

  @override
  ConsumerState<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends ConsumerState<ItemsScreen> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(itemsProvider(_search));
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Items'),
        actions: [
          if (canWrite)
            IconButton(
              tooltip: 'Price levels',
              icon: const Icon(Icons.sell_outlined, size: 20),
              onPressed: () => showPriceLevels(context),
            ),
          if (canWrite)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: () => _openEditor(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New item'),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: const InputDecoration(
                hintText: 'Search items by name, code or barcode',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
            ),
          ),
        ),
      ),
      body: AsyncView(
        value: items,
        onRetry: () => ref.invalidate(itemsProvider),
        builder: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'No items yet',
              message: 'Add the products and services you sell.',
              action: canWrite
                  ? FilledButton.icon(
                      onPressed: () => _openEditor(context),
                      icon: const Icon(Icons.add),
                      label: const Text('Add item'),
                    )
                  : null,
            );
          }

          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final item = list[i];
              return ListTile(
                onTap: canWrite ? () => _openEditor(context, item) : null,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                    if (item.isLowStock) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'At or below reorder level',
                        child: Icon(Icons.warning_amber_rounded,
                            size: 16, color: context.colors.warning),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                  '${item.code} · ${Fmt.label(item.itemType)}'
                  '${item.trackInventory ? ' · ${Fmt.qty(item.quantityOnHand)} ${item.uomCode} on hand' : ''}',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Money(item.unitPrice, bold: true),
                  // Not gated on canWrite: the card changes nothing, and
                  // the person who has to answer for what is on the shelf
                  // is often not the person who may edit prices.
                  if (item.trackInventory) ...[
                    const SizedBox(width: Space.sm),
                    TextButton(
                      key: ValueKey('stock-card-${item.id}'),
                      onPressed: () => showStockCard(context, item),
                      child: const Text('Stock card'),
                    ),
                  ],
                  if (canWrite) ...[
                    const SizedBox(width: Space.sm),
                    TextButton(
                      onPressed: () => showItemPrices(context, item),
                      child: const Text('Prices'),
                    ),
                  ],
                  // Offered on things that sit on a shelf. A variant is
                  // an item of its own — 0211's whole point — so this is
                  // where "the same shirt in six sizes" becomes six
                  // rows that stock and costing can actually see.
                  //
                  // Not hidden for an item that is already a variant of
                  // something: the model does not carry the parent, and
                  // the server refuses that case by name rather than
                  // leaving somebody to guess why a button did nothing.
                  if (canWrite && item.trackInventory) ...[
                    const SizedBox(width: Space.sm),
                    TextButton(
                      key: ValueKey('variants-${item.id}'),
                      onPressed: () => showItemVariants(context, item),
                      child: const Text('Variants'),
                    ),
                  ],
                ]),
              );
            },
          );
        },
      ),
    );
  }

  void _openEditor(BuildContext context, [Item? item]) {
    showDialog<void>(
      context: context,
      builder: (_) => _ItemDialog(item: item),
    );
  }
}

class _ItemDialog extends ConsumerStatefulWidget {
  const _ItemDialog({this.item});

  final Item? item;

  @override
  ConsumerState<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends ConsumerState<_ItemDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _code;
  late final TextEditingController _name;
  late final TextEditingController _price;
  late final TextEditingController _cost;
  late final TextEditingController _reorder;

  late String _itemType;
  late String _uom;
  late String _classification;
  String? _salesTaxCodeId;
  bool _trackInventory = true;
  String _tracking = 'none';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final i = widget.item;
    _code = TextEditingController(text: i?.code ?? '');
    _name = TextEditingController(text: i?.name ?? '');
    _price = TextEditingController(text: i?.unitPrice.toString() ?? '');
    _cost = TextEditingController(text: i?.costPrice.toString() ?? '');
    _reorder = TextEditingController(text: i?.reorderLevel.toString() ?? '0');
    _itemType = i?.itemType ?? 'stock';
    _uom = i?.uomCode ?? 'C62';
    _classification = i?.classificationCode ?? '022';
    _salesTaxCodeId = i?.salesTaxCodeId;
    _trackInventory = i?.trackInventory ?? true;
    _tracking = i?.tracking ?? 'none';
    if (i == null) _suggestCode();
  }

  Future<void> _suggestCode() async {
    try {
      final code = await ref.read(repoProvider)!.nextDocumentNumber('item');
      if (mounted) _code.text = code;
    } catch (_) {
      // The user can supply their own code.
    }
  }

  @override
  void dispose() {
    for (final c in [_code, _name, _price, _cost, _reorder]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveItem(
            Item(
              id: widget.item?.id ?? '',
              code: _code.text.trim(),
              name: _name.text.trim(),
              itemType: _itemType,
              uomCode: _uom,
              classificationCode: _classification,
              unitPrice: double.tryParse(_price.text) ?? 0,
              costPrice: double.tryParse(_cost.text) ?? 0,
              reorderLevel: double.tryParse(_reorder.text) ?? 0,
              trackInventory: _itemType == 'stock' && _trackInventory,
              tracking: _trackInventory ? _tracking : 'none',
              salesTaxCodeId: _salesTaxCodeId,
            ),
            id: widget.item?.id,
          ),
      successMessage: 'Item saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(itemsProvider);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final taxCodes = ref.watch(taxCodesProvider).value ?? const <TaxCode>[];
    final uoms = ref.watch(_uomProvider).value ?? const [];
    final classifications =
        ref.watch(classificationCodesProvider).value ?? const [];

    return AlertDialog(
      title: Text(widget.item == null ? 'New item' : 'Edit item'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _code,
                      decoration: const InputDecoration(labelText: 'Code *'),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _itemType,
                      decoration: const InputDecoration(labelText: 'Type'),
                      items: const [
                        DropdownMenuItem(value: 'stock', child: Text('Stock')),
                        DropdownMenuItem(
                            value: 'service', child: Text('Service')),
                        DropdownMenuItem(
                            value: 'non_stock', child: Text('Non-stock')),
                      ],
                      onChanged: (v) => setState(() => _itemType = v ?? 'stock'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name *'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _price,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'Selling price', prefixText: 'RM '),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _cost,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'Cost price', prefixText: 'RM '),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _salesTaxCodeId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Sales tax code'),
                  items: [
                    for (final t in taxCodes)
                      DropdownMenuItem(
                        value: t.id,
                        child: Text('${t.code} — ${t.name}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _salesTaxCodeId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _uom,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Unit of measure'),
                  items: [
                    for (final u in uoms)
                      DropdownMenuItem(
                        value: u['code'] as String,
                        child: Text('${u['code']} — ${u['name']}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _uom = v ?? 'C62'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _classification,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'e-Invoice classification',
                    helperText: 'LHDN requires this on every invoice line',
                  ),
                  items: [
                    for (final c in classifications)
                      DropdownMenuItem(
                        value: c['code'] as String,
                        child: Text(
                          '${c['code']} — ${c['description']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _classification = v ?? '022'),
                ),
                if (_itemType == 'stock') ...[
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _trackInventory,
                    onChanged: (v) => setState(() => _trackInventory = v),
                    title: const Text('Track inventory'),
                    subtitle: const Text('Move stock and post cost of sales'),
                  ),
                  if (_trackInventory) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _tracking,
                      decoration: const InputDecoration(
                        labelText: 'Identify each unit',
                        // Said here because it is the decision people get
                        // wrong: turning this on makes the batch number
                        // compulsory on every receipt and every despatch,
                        // and there is no half-way setting on purpose.
                        helperText: 'Batch and serial numbers become required',
                      ),
                      items: const [
                        DropdownMenuItem(value: 'none', child: Text('Not tracked')),
                        DropdownMenuItem(
                            value: 'batch', child: Text('By batch or lot number')),
                        DropdownMenuItem(
                            value: 'serial', child: Text('By serial number')),
                      ],
                      onChanged: (v) => setState(() => _tracking = v ?? 'none'),
                    ),
                  ],
                  TextFormField(
                    controller: _reorder,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration:
                        const InputDecoration(labelText: 'Reorder level'),
                  ),
                ],
              ],
            ),
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

final _uomProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final repo = ref.watch(repoProvider);
  if (repo == null) return const [];
  return repo.uomCodes();
});
