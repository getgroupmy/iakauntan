import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// How big a carton of this particular thing is.
///
/// `ref_uom_factors` leaves the packaging codes out on purpose — "a box
/// is only as big as whatever is in it, and that belongs on the item" —
/// and `item_uom_packs` is where a shop says so. Nothing in the app
/// could write one: `saveItemUomPack` and `deleteItemUomPack` had no
/// caller. So a company that buys in cartons and stocks in tins could
/// not tell the system how many tins are in a carton, and `app.uom_qty`
/// fell through to a reference factor that does not exist for a
/// packaging code — a recipe or a delivery written in cartons had
/// nowhere to convert to.

/// The pack sizes this shop has actually declared.
///
/// `item_uom_options` returns two kinds of row: reference units of the
/// item's own dimension, where the standards body has already said how
/// big a kilogram is, and the packs the shop set. Only the second kind
/// is anybody's to change.
List<Map<String, dynamic>> declaredPacks(
  Iterable<Map<String, dynamic>> options,
) =>
    options.where((o) => o['is_pack'] == true).toList();

/// The units a pack size could still be declared for.
///
/// Everything except the item's own unit, which `upsert_item_uom_pack`
/// refuses by name — "One % is one %, and saying so twice is how the
/// two copies come to disagree" — and except those already declared,
/// which are edited in place rather than added twice.
///
/// A reference unit is deliberately still offered. A pack the shop sets
/// beats the reference factor, so a bakery whose dozen is thirteen can
/// say so.
List<Map<String, dynamic>> packableUoms(
  Iterable<Map<String, dynamic>> allUoms,
  Iterable<Map<String, dynamic>> declared,
  String baseUom,
) {
  final taken = {for (final d in declared) d['uom_code']};
  return [
    for (final u in allUoms)
      if (u['code'] != baseUom && !taken.contains(u['code'])) u,
  ];
}

/// How many of the item's own units one of these is.
///
/// Fractions survive: half a metre of cloth is a real pack, and the
/// column carries six decimal places for exactly that. Zero and below
/// are refused, as the function refuses them — "A pack has to hold
/// something."
double? packSizeOf(String text) {
  final v = double.tryParse(text.trim().replaceAll(',', ''));
  if (v == null || v <= 0) return null;
  return v;
}

/// What a declared pack reads as.
String packLabel(Map<String, dynamic> pack, String baseUom) {
  final qty = num.tryParse('${pack['qty_in_stock_uom'] ?? 0}') ?? 0;
  return '1 ${pack['uom_code']} = ${Fmt.qty(qty)} $baseUom';
}

/// Say how this item is packed.
Future<void> showItemPacks(BuildContext context, Item item) =>
    showDialog<void>(
      context: context,
      builder: (_) => _PacksDialog(item: item),
    );

class _PacksDialog extends ConsumerStatefulWidget {
  const _PacksDialog({required this.item});

  final Item item;

  @override
  ConsumerState<_PacksDialog> createState() => _PacksDialogState();
}

class _PacksDialogState extends ConsumerState<_PacksDialog> {
  bool _busy = false;

  void _refresh() => ref.invalidate(itemUomOptionsProvider(widget.item.id));

  Future<void> _edit({Map<String, dynamic>? existing}) async {
    final all = ref.read(uomCodesProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
    final options = ref.read(itemUomOptionsProvider(widget.item.id)).valueOrNull ??
        const <Map<String, dynamic>>[];
    final choices = packableUoms(
      all,
      declaredPacks(options),
      widget.item.uomCode,
    );
    if (existing == null && choices.isEmpty) return;

    final controller = TextEditingController(
      text: existing == null ? '' : '${existing['qty_in_stock_uom']}',
    );
    final answer = await showDialog<({String uom, double qty})>(
      context: context,
      builder: (ctx) {
        String? uom = existing?['uom_code'] as String? ??
            choices.first['code'] as String?;
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Text(existing == null ? 'A pack size' : 'Change it'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (existing == null)
                    SearchablePicker<String>(
                      key: const ValueKey('pack-uom'),
                      options: [
                        for (final u in choices)
                          PickerOption<String>(
                            value: u['code'] as String,
                            label: '${u['name']}',
                            sublabel: '${u['code']}',
                            keywords: ['${u['code']}'],
                          ),
                      ],
                      value: uom,
                      label: 'Bought as',
                      onChanged: (v) => setLocal(() => uom = v),
                    )
                  else
                    Text(
                      'One ${existing['uom_code']} of '
                      '${widget.item.name}',
                      style: Theme.of(ctx).textTheme.bodyMedium,
                    ),
                  const SizedBox(height: Space.md),
                  TextField(
                    key: const ValueKey('pack-qty'),
                    controller: controller,
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Holds how many ${widget.item.uomCode}',
                      hintText: '24',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('pack-save'),
                onPressed: () {
                  final qty = packSizeOf(controller.text);
                  if (qty == null || uom == null) return;
                  Navigator.of(ctx).pop((uom: uom!, qty: qty));
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
    if (answer == null || !mounted) return;

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveItemUomPack(widget.item.id, answer.uom, answer.qty),
      successMessage: 'Saved',
    );
    if (mounted) setState(() => _busy = false);
    if (ok) _refresh();
  }

  Future<void> _remove(Map<String, dynamic> pack) async {
    final ok = await confirm(
      context,
      title: 'Forget this pack size?',
      message:
          'A quantity written in ${pack['uom_code']} will fall back on '
          'the reference factor, and a packaging unit has none — so it '
          'will stop converting rather than convert wrongly.',
      confirmLabel: 'Forget it',
      destructive: true,
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    final done = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.deleteItemUomPack(
            widget.item.id,
            '${pack['uom_code']}',
          ),
      successMessage: 'Forgotten',
    );
    if (mounted) setState(() => _busy = false);
    if (done) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(itemUomOptionsProvider(widget.item.id));
    final all =
        ref.watch(uomCodesProvider).valueOrNull ?? const <Map<String, dynamic>>[];
    final canWrite = ref.watch(canWriteProvider);

    return AlertDialog(
      title: Text('How ${widget.item.name} is packed'),
      content: SizedBox(
        width: 480,
        height: 380,
        child: AsyncView<List<Map<String, dynamic>>>(
          value: options,
          onRetry: _refresh,
          builder: (list) {
            final packs = declaredPacks(list);
            final choices =
                packableUoms(all, packs, widget.item.uomCode);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Stocked in ${widget.item.uomCode}. A carton is only as '
                  'big as what is in it, so the standards do not say — '
                  'this is where you do.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Space.md),
                Expanded(
                  child: packs.isEmpty
                      ? Center(
                          child: Text(
                            'Nothing declared. A quantity written in any '
                            'other unit converts by the reference factor, '
                            'and a packaging unit has none.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        )
                      : ListView.separated(
                          itemCount: packs.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final p = packs[i];
                            return ListTile(
                              dense: true,
                              enabled: !_busy,
                              onTap: canWrite
                                  ? () => _edit(existing: p)
                                  : null,
                              title: Text(
                                packLabel(p, widget.item.uomCode),
                              ),
                              trailing: !canWrite
                                  ? null
                                  : IconButton(
                                      key: ValueKey(
                                        'forget-pack-${p['uom_code']}',
                                      ),
                                      tooltip: 'Forget it',
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 18,
                                      ),
                                      onPressed:
                                          _busy ? null : () => _remove(p),
                                    ),
                            );
                          },
                        ),
                ),
                if (canWrite)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('add-pack'),
                      onPressed: _busy || choices.isEmpty
                          ? null
                          : () => _edit(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add a pack size'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
