import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/quick_add_dialog.dart';
import '../../core/searchable_picker.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'item_categories.dart';
import 'item_categories_dialog.dart';
import 'item_prices_dialog.dart';
import 'item_packs_dialog.dart';
import 'item_variants_dialog.dart';
import 'modifier_groups_dialog.dart';
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
    final modules = ref.watch(enabledModulesProvider).value ?? const <String>{};

    return Scaffold(
      appBar: AppBar(
        title: const Text('Items'),
        actions: [
          // Beside prices, because both are things about the menu
          // rather than about a shop, and this is where somebody
          // editing the menu already is.
          if (canWrite && modules.contains('pos'))
            IconButton(
              tooltip: 'Questions a dish comes with',
              icon: const Icon(Icons.help_outline, size: 20),
              onPressed: () => showModifierGroups(context),
            ),
          if (canWrite)
            IconButton(
              tooltip: 'Categories',
              icon: const Icon(Icons.folder_outlined, size: 20),
              onPressed: () => showItemCategories(context),
            ),
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
                  // Belt and braces beside the narrow layout below. A
                  // subtitle with no line limit, given a column two
                  // pixels wide, wraps ONE CHARACTER AT A TIME — which
                  // is exactly what was reported. Capped, the worst a
                  // future trailing can do is an ellipsis.
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: _ItemActions(item: item, canWrite: canWrite),
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


/// What a row offers to do with the item beside it.
///
/// Pure and separate from the widget so the SET can be asserted, and
/// so the wide layout and the narrow one cannot drift apart — they are
/// two renderings of one list, not two lists.
///
///   * The STOCK CARD is not gated on `canWrite`: it changes nothing,
///     and the person who has to answer for what is on the shelf is
///     often not the person who may edit prices.
///   * VARIANTS and PACKS are offered on things that sit on a shelf. A
///     variant is an item of its own — 0211's whole point — so that is
///     where "the same shirt in six sizes" becomes six rows stock and
///     costing can see. Neither is hidden for an item that is already
///     a variant: the model does not carry the parent, and the server
///     refuses that case by name rather than leaving somebody to guess
///     why a button did nothing.
///   * PACKS is how big a carton is. The reference table leaves
///     packaging units out on purpose, so until a shop says, a quantity
///     written in cartons has nothing to convert by.
List<({String key, String label, void Function(BuildContext) open})>
    itemRowActions(Item item, {required bool canWrite}) => [
  if (item.trackInventory)
    (
      key: 'stock-card-${item.id}',
      label: 'Stock card',
      open: (c) => showStockCard(c, item),
    ),
  if (canWrite)
    (
      key: 'prices-${item.id}',
      label: 'Prices',
      open: (c) => showItemPrices(c, item),
    ),
  if (canWrite && item.trackInventory) ...[
    (
      key: 'variants-${item.id}',
      label: 'Variants',
      open: (c) => showItemVariants(c, item),
    ),
    (
      key: 'packs-${item.id}',
      label: 'Packs',
      open: (c) => showItemPacks(c, item),
    ),
  ],
];

/// The price and the row's actions, for a caller that has its own
/// `ListTile` — the items list, and the test that pins the layout.
Widget itemRowTrailing(Item item, {required bool canWrite}) =>
    _ItemActions(item: item, canWrite: canWrite);

/// The price, and the ways into the item beside it.
///
/// ON A PHONE THEY COLLAPSE INTO ONE MENU, and that is the whole point
/// of this widget. `ListTile` gives its `trailing` the width it asks
/// for and leaves the title and subtitle whatever is left: four text
/// buttons and a price want about 450 logical pixels, which on a 400
/// pixel phone left the subtitle a column ONE CHARACTER WIDE. The item
/// list was unreadable on the device most likely to be standing in
/// front of the shelf.
class _ItemActions extends StatelessWidget {
  const _ItemActions({required this.item, required this.canWrite});

  final Item item;
  final bool canWrite;

  /// Below this, the buttons become a menu. The same threshold the
  /// stock take and the payroll screens use.
  static const _narrow = 700.0;

  @override
  Widget build(BuildContext context) {
    final actions = itemRowActions(item, canWrite: canWrite);
    final narrow = MediaQuery.sizeOf(context).width < _narrow;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Money(item.unitPrice, bold: true),
        if (actions.isEmpty)
          const SizedBox.shrink()
        else if (narrow)
          PopupMenuButton<int>(
            key: ValueKey('item-actions-${item.id}'),
            tooltip: 'More',
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (i) => actions[i].open(context),
            itemBuilder: (_) => [
              for (var i = 0; i < actions.length; i++)
                PopupMenuItem<int>(
                  value: i,
                  key: ValueKey(actions[i].key),
                  child: Text(actions[i].label),
                ),
            ],
          )
        else
          for (final action in actions) ...[
            const SizedBox(width: Space.sm),
            TextButton(
              key: ValueKey(action.key),
              onPressed: () => action.open(context),
              child: Text(action.label),
            ),
          ],
      ],
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
  String? _categoryId;
  bool _trackInventory = true;
  String _tracking = 'none';
  bool _saving = false;

  /// The questions this dish is sold with, in the order they will be
  /// asked. Saved with the item rather than on their own, because
  /// attaching a question is editing the dish — and for a new item
  /// there is no id to attach to until the item exists.
  List<String> _modifierGroups = const [];

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
    _categoryId = i?.categoryId;
    _trackInventory = i?.trackInventory ?? true;
    _tracking = i?.tracking ?? 'none';
    if (i == null) _suggestCode();
    if (i != null) _loadModifierGroups(i.id);
  }

  Future<void> _loadModifierGroups(String itemId) async {
    try {
      final rows = await ref.read(repoProvider)!.itemModifierGroupIds(itemId);
      if (mounted) {
        setState(
          () => _modifierGroups = [for (final r in rows) '${r['group_id']}'],
        );
      }
    } catch (_) {
      // A company without the till has nothing to load, and does not
      // see the field either.
    }
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

    final posOn =
        (ref.read(enabledModulesProvider).value ?? const <String>{})
            .contains('pos');

    final ok = await runWithFeedback(
      context,
      action: () async {
        final repo = ref.read(repoProvider)!;
        final saved = await repo.saveItem(
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
            categoryId: _categoryId,
          ),
          id: widget.item?.id,
        );
        // After the item, because a new one has no id to attach to
        // until it exists. Skipped entirely for a company with no till,
        // and for a new item nobody attached anything to.
        if (posOn && (widget.item != null || _modifierGroups.isNotEmpty)) {
          await repo.setItemModifierGroups(saved.id, _modifierGroups);
        }
      },
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
    final modules = ref.watch(enabledModulesProvider).value ?? const <String>{};
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
                // Filed under. `items.category_id` has been on the
                // table since 0003 and this is the first field that
                // ever set it — until now every item anybody typed was
                // filed under nothing.
                Consumer(
                  builder: (context, ref, _) {
                    final all =
                        ref.watch(itemCategoriesProvider).valueOrNull ??
                        const <Map<String, dynamic>>[];
                    return SearchablePicker<String>(
                      options: [
                        for (final c in all)
                          PickerOption<String>(
                            value: c['id'] as String,
                            label: categoryPath(all, c['id'] as String?),
                          ),
                      ],
                      value: all.any((c) => c['id'] == _categoryId)
                          ? _categoryId
                          : null,
                      label: 'Filed under',
                      helperText: 'How a kitchen sends every drink to one '
                          'counter without naming them one at a time.',
                      allowEmpty: true,
                      emptyLabel: 'Nothing in particular',
                      createLabel: 'Add category',
                      onCreate: (typed) => quickAdd(
                        context,
                        title: 'New category',
                        blurb: 'Not on the list yet. It will be a '
                            'top-level category; move it under another '
                            'on the Categories screen.',
                        nameHint: 'Drinks',
                        codeLabel: 'Code',
                        seed: typed,
                        save: ({required name, code}) async {
                          final id = await ref
                              .read(repoProvider)!
                              .saveItemCategory(code: code!, name: name);
                          ref.invalidate(itemCategoriesProvider);
                          return id;
                        },
                      ),
                      onChanged: (v) => setState(() => _categoryId = v),
                    );
                  },
                ),
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
                // A hundred-odd UN/CEFACT codes. Somebody looking for
                // "kilogram" should type it rather than hunt for KGM.
                // Reference data, so no offer to add one.
                SearchablePicker<String>(
                  options: [
                    for (final u in uoms)
                      PickerOption(
                        value: u['code'] as String,
                        label: '${u['code']} — ${u['name']}',
                        keywords: ['${u['code']}', '${u['name']}'],
                      ),
                  ],
                  value: _uom,
                  label: 'Unit of measure',
                  onChanged: (v) => setState(() => _uom = v ?? 'C62'),
                ),
                const SizedBox(height: 12),
                // LHDN's classification list, which is long and which
                // nobody remembers by number. Searchable on the
                // DESCRIPTION as well, because "software" is what
                // somebody knows and 022 is what the invoice needs.
                SearchablePicker<String>(
                  options: [
                    for (final c in classifications)
                      PickerOption(
                        value: c['code'] as String,
                        label: '${c['code']} — ${c['description']}',
                        keywords: ['${c['code']}', '${c['description']}'],
                      ),
                  ],
                  value: _classification,
                  label: 'e-Invoice classification',
                  helperText: 'LHDN requires this on every invoice line',
                  onChanged: (v) => setState(() => _classification = v ?? '022'),
                ),
                // Only for a company that runs a till. A question a
                // plate comes with is a POS idea, and an accounting-only
                // company has nothing to attach.
                if (modules.contains('pos')) ...[
                  const SizedBox(height: 12),
                  ItemModifierField(
                    selected: _modifierGroups,
                    onChanged: (v) => setState(() => _modifierGroups = v),
                  ),
                ],
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
