import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'item_categories.dart';

/// What a shop files its items under.
Future<void> showItemCategories(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _CategoriesDialog(),
    );

class _CategoriesDialog extends ConsumerWidget {
  const _CategoriesDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(itemCategoriesProvider);
    void reload() => ref.invalidate(itemCategoriesProvider);

    return AlertDialog(
      title: const Text('Categories'),
      content: SizedBox(
        width: 520,
        height: 440,
        child: AsyncView<List<Map<String, dynamic>>>(
          value: categories,
          onRetry: reload,
          builder: (all) {
            if (all.isEmpty) {
              return const EmptyState(
                icon: Icons.folder_outlined,
                title: 'Nothing is filed yet',
                message: 'A category is how a shop groups what it sells — '
                    'and how a kitchen sends every drink to the same '
                    'counter without naming them one at a time.',
              );
            }
            final tree = categoryTree(all);
            return ListView.builder(
              itemCount: tree.length,
              itemBuilder: (context, i) {
                final node = tree[i];
                final id = node.row['id'] as String;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.only(
                    left: 8.0 + node.depth * 20,
                    right: 8,
                  ),
                  title: Text('${node.row['name']}'),
                  subtitle: Text('${node.row['code']}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        onPressed: () async {
                          final saved = await showDialog<bool>(
                            context: context,
                            builder: (_) => _CategorySheet(
                              all: all,
                              category: node.row,
                            ),
                          );
                          if (saved == true) reload();
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () async {
                          final go = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text('Remove ${node.row['name']}?'),
                              content: Text(deletionWarning(all, id)),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(ctx).pop(false),
                                  child: const Text('Keep it'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                  child: const Text('Remove'),
                                ),
                              ],
                            ),
                          );
                          if (go != true || !context.mounted) return;
                          final done = await runWithFeedback(
                            context,
                            successMessage: 'Removed',
                            doing: 'Remove an item category',
                            action: () =>
                                ref.read(repoProvider)!.deleteItemCategory(id),
                          );
                          if (done) reload();
                        },
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          key: const ValueKey('category-add'),
          onPressed: () async {
            final saved = await showDialog<bool>(
              context: context,
              builder: (_) => _CategorySheet(
                all: categories.valueOrNull ?? const [],
              ),
            );
            if (saved == true) reload();
          },
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Category'),
        ),
      ],
    );
  }
}

class _CategorySheet extends ConsumerStatefulWidget {
  const _CategorySheet({required this.all, this.category});

  final List<Map<String, dynamic>> all;
  final Map<String, dynamic>? category;

  @override
  ConsumerState<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends ConsumerState<_CategorySheet> {
  late final _code = TextEditingController(
    text: '${widget.category?['code'] ?? ''}',
  );
  late final _name = TextEditingController(
    text: '${widget.category?['name'] ?? ''}',
  );
  late String? _parentId = widget.category?['parent_id'] as String?;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {}));
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => ref.read(repoProvider)!.saveItemCategory(
        id: widget.category?['id'] as String?,
        code: _code.text.trim(),
        name: _name.text.trim(),
        parentId: _parentId,
      ),
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.category?['id'] as String?;
    final blocked = categoryBlockedBecause(
      code: _code.text,
      name: _name.text,
    );
    final taken = codeIsTaken(widget.all, _code.text, exceptId: id);
    final parents = assignableParents(widget.all, id);
    final small = Theme.of(context).textTheme.bodySmall;

    return AlertDialog(
      title: Text(widget.category == null ? 'A category' : 'Rename it'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('category-name'),
              controller: _name,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: 'Called'),
            ),
            TextField(
              controller: _code,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: 'Code',
                helperText: 'Short, and unique in this company.',
              ),
            ),
            const SizedBox(height: Space.md),
            DropdownButtonFormField<String?>(
              value: parents.any((c) => c['id'] == _parentId)
                  ? _parentId
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Filed under'),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Nothing — it is a top-level category'),
                ),
                for (final c in parents)
                  DropdownMenuItem<String?>(
                    value: c['id'] as String?,
                    child: Text(
                      categoryPath(widget.all, c['id'] as String?),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged:
                  _saving ? null : (v) => setState(() => _parentId = v),
            ),
            if (blocked != null || taken) ...[
              const SizedBox(height: Space.sm),
              Text(
                blocked ?? 'Something else already has that code.',
                style: small?.copyWith(color: context.colors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('category-save'),
          onPressed: _saving || blocked != null || taken ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
