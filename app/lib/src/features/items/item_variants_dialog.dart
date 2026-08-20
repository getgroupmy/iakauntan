import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
// `RepoItemVariants` is an extension, and a Dart extension is only in
// scope where its declaring library is imported.
import '../../data/repository.dart';

/// The same shirt in six sizes.
///
/// 0211 built this and nothing has ever called it — nothing in the app
/// mentioned `parent_item_id` or `variant_attributes` at all, so a shop
/// selling clothing could hold one row called "shirt" and no way to say
/// which size left the shelf.
///
/// ## What this screen refuses to do itself
///
/// It does not build codes or names. `create_item_variants` derives
/// `SHIRT-M-NAVY` from the parent's code and the combination, and a
/// client that did the same arithmetic would disagree the first time
/// somebody used a slash in a colour — and a disagreement here is a
/// duplicate item nobody can merge afterwards.
///
/// It does not decide what already exists either. The function is
/// re-runnable: pass the full axis list again after adding a colour and
/// it returns every combination with `created` saying which ones it
/// actually made. So the dialog reports what came back rather than
/// claiming it made them all.
///
/// It does not offer to split an item that holds stock. The server
/// refuses that, because stock counted against the style has nowhere to
/// go once the style stops holding any, and the refusal names the item
/// and says to move or adjust it first. Shown as it arrives.
Future<void> showItemVariants(BuildContext context, Item item) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ItemVariantsDialog(item: item),
  );
}

class _ItemVariantsDialog extends ConsumerStatefulWidget {
  const _ItemVariantsDialog({required this.item});

  final Item item;

  @override
  ConsumerState<_ItemVariantsDialog> createState() =>
      _ItemVariantsDialogState();
}

class _ItemVariantsDialogState extends ConsumerState<_ItemVariantsDialog> {
  /// Axis name to the values typed for it. Two rows because a shirt is a
  /// size and a colour; a third is rarely wanted and can be added.
  final _axes = <_AxisField>[_AxisField(), _AxisField()];
  bool _busy = false;

  @override
  void dispose() {
    for (final a in _axes) {
      a.dispose();
    }
    super.dispose();
  }

  Map<String, List<String>> _payload() {
    final out = <String, List<String>>{};
    for (final a in _axes) {
      final name = a.name.text.trim();
      final values = a.values.text
          .split(',')
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)
          .toList();
      if (name.isNotEmpty && values.isNotEmpty) out[name] = values;
    }
    return out;
  }

  Future<void> _generate() async {
    final axes = _payload();
    if (axes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Give at least one axis, e.g. Size: S, M, L'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    List<Map<String, dynamic>> result = const [];
    final ok = await runWithFeedback(
      context,
      pendingMessage: 'Making the combinations…',
      // Said afterwards from what came back, because "created 12
      // variants" when six already existed is a lie the shop only finds
      // out about by counting.
      successMessage: null,
      action: () async {
        result = await ref
            .read(repoProvider)!
            .createItemVariants(widget.item.id, axes);
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;

    final made = result.where((r) => r['created'] == true).length;
    final skipped = result.length - made;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          skipped == 0
              ? 'Made $made variant${made == 1 ? '' : 's'}.'
              : 'Made $made, left $skipped that already existed.',
        ),
      ),
    );
    ref
      ..invalidate(itemVariantsProvider(widget.item.id))
      ..invalidate(itemVariantMatrixProvider(widget.item.id))
      ..invalidate(itemsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final variants = ref.watch(itemVariantsProvider(widget.item.id));
    final matrix =
        ref.watch(itemVariantMatrixProvider(widget.item.id)).valueOrNull ??
        const [];

    return AlertDialog(
      title: Text('${widget.item.name} · variants'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'A variant is an item of its own, so stock, cost and '
                'reordering all work against the size that actually left '
                'the shelf. The style keeps the shared name and accounts '
                'and holds no stock itself.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              if (matrix.isNotEmpty) ...[
                Text('Already split by', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: Space.xs),
                for (final axis in matrix)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '${axis['axis']}: '
                      '${(axis['axis_values'] as List?)?.join(', ') ?? ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: Space.md),
              ],
              Text('Add axes', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: Space.xs),
              Text(
                'Values separated by commas. Running this again with an '
                'axis added makes only the new combinations.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.sm),
              for (final a in _axes) ...[
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: a.name,
                        decoration: const InputDecoration(
                          labelText: 'Axis',
                          hintText: 'Size',
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: a.values,
                        decoration: const InputDecoration(
                          labelText: 'Values',
                          hintText: 'S, M, L',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.sm),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _axes.add(_AxisField())),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Another axis'),
                ),
              ),
              const SizedBox(height: Space.md),
              Text(
                'Variants',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: Space.xs),
              AsyncView<List<Map<String, dynamic>>>(
                value: variants,
                onRetry: () =>
                    ref.invalidate(itemVariantsProvider(widget.item.id)),
                builder: (rows) {
                  if (rows.isEmpty) {
                    return Text(
                      'None yet. This item is still a single item.',
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final v in rows)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('${v['name']}'),
                          subtitle: Text(
                            '${v['code']} · '
                            '${Fmt.qty(Fmt.toDouble(v['quantity_on_hand']))} '
                            'on hand',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Money(Fmt.toDouble(v['unit_price'])),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: _busy ? null : _generate,
          child: _busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Make variants'),
        ),
      ],
    );
  }
}

class _AxisField {
  final name = TextEditingController();
  final values = TextEditingController();

  void dispose() {
    name.dispose();
    values.dispose();
  }
}
