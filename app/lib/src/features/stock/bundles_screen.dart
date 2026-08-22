import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// What a bundle's row says under its name.
String bundleSummary(Map<String, dynamic> row) {
  final parts = Fmt.toInt(row['parts']);
  return [
    '$parts part${parts == 1 ? '' : 's'}',
    '${Fmt.money(num.tryParse('${row['price']}'))} for '
        '${Fmt.money(num.tryParse('${row['cost']}'))} of stock',
  ].join(' · ');
}

/// The margin, said the way somebody setting a price would ask it.
///
/// A bundle sold below what its parts cost is the mistake this screen
/// exists to catch, so it is said in words rather than left as a
/// negative number somebody has to notice.
String marginLabel(Map<String, dynamic>? margin) {
  if (margin == null) return '';
  final m = num.tryParse('${margin['margin'] ?? 0}') ?? 0;
  final pct = num.tryParse('${margin['margin_pct'] ?? ''}');
  if (m < 0) {
    return 'Sold for ${Fmt.money(-m)} less than the parts cost';
  }
  if (m == 0) return 'Sold for exactly what the parts cost';
  return pct == null
      ? '${Fmt.money(m)} margin'
      : '${Fmt.money(m)} margin · ${pct.toStringAsFixed(1)}%';
}

/// Red when a bundle is priced under its own parts.
Color? marginColour(BuildContext context, Map<String, dynamic>? margin) {
  if (margin == null) return null;
  final m = num.tryParse('${margin['margin'] ?? 0}') ?? 0;
  if (m < 0) return context.colors.danger;
  return m == 0 ? context.colors.warning : null;
}

/// How many can be sold out of what is on the shelf.
String availabilityLabel(Map<String, dynamic>? a) {
  if (a == null) return '';
  final n = Fmt.toInt(a['can_make']);
  final limiting = '${a['limiting_item'] ?? ''}'.trim();
  if (n == 0) {
    return limiting.isEmpty
        ? 'None can be made'
        : 'None can be made — no $limiting';
  }
  return limiting.isEmpty
      ? '$n can be made'
      : '$n can be made · $limiting runs out first';
}

/// An item that is six other things.
class BundlesScreen extends ConsumerStatefulWidget {
  const BundlesScreen({super.key});

  @override
  ConsumerState<BundlesScreen> createState() => _BundlesScreenState();
}

class _BundlesScreenState extends ConsumerState<BundlesScreen> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final bundles = ref.watch(itemBundlesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Bundles')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.widgets_outlined),
        label: const Text('New bundle'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: bundles,
        onRetry: () => ref.invalidate(itemBundlesProvider),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.widgets_outlined,
              title: 'No bundles',
              message: 'A gift set is six other things sold as one. Define '
                  'what is in it and selling one takes its parts off the '
                  'shelf and books what they cost.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final b = rows[i];
              final id = '${b['item_id']}';
              final open = _open == id;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: const Icon(Icons.widgets_outlined),
                    title: Text('${b['code']} ${b['name']}'),
                    subtitle: Text(bundleSummary(b)),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () => _edit(b),
                    ),
                    onTap: () => setState(() => _open = open ? null : id),
                  ),
                  if (open) _parts(id),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _parts(String id) {
    final parts = ref.watch(bundlePartsProvider(id));
    final margin = ref.watch(bundleMarginProvider(id)).valueOrNull;
    final avail = ref.watch(bundleAvailabilityProvider(id)).valueOrNull;

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  marginLabel(margin),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: marginColour(context, margin),
                  ),
                ),
                Text(
                  availabilityLabel(avail),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.sm),
          AsyncView<List<Map<String, dynamic>>>(
            value: parts,
            onRetry: () => ref.invalidate(bundlePartsProvider(id)),
            builder: (rows) => Column(
              children: [
                for (final p in rows)
                  ListTile(
                    dense: true,
                    title: Text('${p['code']} ${p['name']}'),
                    subtitle: Text(
                      '${Fmt.qty(num.tryParse('${p['quantity']}'))} '
                      '${p['uom_code']} at '
                      '${Fmt.money(num.tryParse('${p['unit_cost']}'))}',
                    ),
                    trailing: Money(num.tryParse('${p['line_cost']}')),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(Map<String, dynamic>? bundle) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _BundleDialog(itemId: bundle?['item_id']?.toString()),
    );
    if (saved == true) {
      ref.invalidate(itemBundlesProvider);
      if (bundle != null) {
        ref.invalidate(bundlePartsProvider('${bundle['item_id']}'));
        ref.invalidate(bundleMarginProvider('${bundle['item_id']}'));
      }
    }
  }
}

/// One part being written down, before it has been saved.
class PartDraft {
  PartDraft({this.itemId, this.quantity = 1});

  String? itemId;
  double quantity;

  Map<String, dynamic> toJson() => {'item': itemId, 'quantity': quantity};
}

/// Whether a bundle is worth sending to the server yet.
///
/// Checked here as well as on the server so somebody typing sees the
/// button come alive. The server's refusal is the one that counts.
bool canSaveBundle(String? itemId, List<PartDraft> parts) =>
    itemId != null &&
    parts.isNotEmpty &&
    parts.every((p) => p.itemId != null && p.quantity > 0) &&
    parts.map((p) => p.itemId).toSet().length == parts.length;

class _BundleDialog extends ConsumerStatefulWidget {
  const _BundleDialog({this.itemId});

  final String? itemId;

  @override
  ConsumerState<_BundleDialog> createState() => _BundleDialogState();
}

class _BundleDialogState extends ConsumerState<_BundleDialog> {
  String? _item;
  final _parts = <PartDraft>[PartDraft()];
  bool _busy = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _item = widget.itemId;
  }

  Future<void> _save() async {
    final repo = ref.read(repoProvider);
    if (repo == null || _item == null) return;
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => repo.saveItemBundle(
        itemId: _item!,
        parts: [for (final p in _parts) p.toJson()],
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(itemsProvider('')).valueOrNull ?? const <Item>[];

    // An existing bundle opens with what is already in it.
    if (widget.itemId != null && !_loaded) {
      final existing = ref.watch(bundlePartsProvider(widget.itemId!)).valueOrNull;
      if (existing != null) {
        _loaded = true;
        _parts
          ..clear()
          ..addAll([
            for (final p in existing)
              PartDraft(
                itemId: '${p['component_id']}',
                quantity: (num.tryParse('${p['quantity']}') ?? 1).toDouble(),
              ),
          ]);
        if (_parts.isEmpty) _parts.add(PartDraft());
      }
    }

    return AlertDialog(
      title: Text(widget.itemId == null ? 'A bundle' : 'What is in it'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A bundle holds no stock of its own — the server refuses
              // one on an item that does, so the list only offers the
              // items that can be one.
              DropdownButtonFormField<String>(
                value: _item,
                decoration: const InputDecoration(
                  labelText: 'Which item is the bundle',
                  helperText: 'A bundle keeps no stock of its own; its parts do',
                ),
                items: [
                  for (final i in items.where((i) => !i.trackInventory))
                    DropdownMenuItem(
                      value: i.id,
                      child: Text('${i.code} ${i.name}'),
                    ),
                ],
                onChanged: widget.itemId != null
                    ? null
                    : (v) => setState(() => _item = v),
              ),
              const SizedBox(height: Space.md),
              SectionHeader(
                'What is in it',
                action: TextButton.icon(
                  onPressed: () => setState(() => _parts.add(PartDraft())),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add a part'),
                ),
              ),
              for (var i = 0; i < _parts.length; i++)
                Row(
                  key: ObjectKey(_parts[i]),
                  children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        value: _parts[i].itemId,
                        isDense: true,
                        decoration: const InputDecoration(isDense: true),
                        items: [
                          for (final it in items.where((x) => x.id != _item))
                            DropdownMenuItem(
                              value: it.id,
                              child: Text(
                                '${it.code} ${it.name}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _parts[i].itemId = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 90,
                      child: TextFormField(
                        initialValue: '${_parts[i].quantity}',
                        textAlign: TextAlign.right,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(isDense: true),
                        onChanged: (v) => setState(
                          () => _parts[i].quantity = double.tryParse(v) ?? 0,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: _parts.length == 1
                          ? null
                          : () => setState(() => _parts.removeAt(i)),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy || !canSaveBundle(_item, _parts) ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
