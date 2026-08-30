import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../data/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'recipe_requirement_dialog.dart';

/// How a recipe line reads on one line of the editor.
///
/// Pure and exported so the list, the editor and the tests agree. The
/// wastage is only mentioned when there is any: "200 GRM" is what a
/// cook wrote down, and "200 GRM, 10% waste" is a different statement
/// that should look different.
String recipeLine(Map<String, dynamic> row) {
  final qty = num.tryParse('${row['quantity'] ?? 0}') ?? 0;
  final uom = '${row['uom_code'] ?? ''}';
  final waste = num.tryParse('${row['wastage_percent'] ?? 0}') ?? 0;
  final parts = <String>['${trimNumber(qty)} $uom'.trim()];
  if (waste > 0) parts.add('${trimNumber(waste)}% waste');
  if (row['is_optional'] == true) parts.add('optional');
  return parts.join(' · ');
}

/// What the countdown says on a dish, in the words a kitchen uses.
///
/// Null portions means nothing counted limits it — every ingredient is
/// untracked, or there is no recipe — and saying "unlimited" would be a
/// promise nobody made. Saying nothing is the honest answer.
String? portionsLabel(Map<String, dynamic> row) {
  final off = '${row['off_reason'] ?? ''}';
  if (off.isNotEmpty) return off;
  final portions = row['portions'];
  if (portions == null) return null;
  final n = num.tryParse('$portions') ?? 0;
  if (n <= 0) {
    final limit = '${row['limiting_item_name'] ?? ''}';
    return limit.isEmpty ? 'Out' : 'Out of ${limit.toLowerCase()}';
  }
  return '${trimNumber(n)} left';
}

/// A number without the trailing zeros a numeric column carries. 0.1800
/// is what the database holds and 0.18 is what a cook wrote.
String trimNumber(num value) {
  final s = value.toStringAsFixed(4);
  if (!s.contains('.')) return s;
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// The recipes a kitchen keeps: what each dish is made of, what it
/// costs, and how many more of it the store can still make.
class RecipesScreen extends ConsumerStatefulWidget {
  const RecipesScreen({super.key});

  @override
  ConsumerState<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends ConsumerState<RecipesScreen> {
  String? _outlet;

  void _reload() {
    ref.invalidate(posRecipesProvider);
    if (_outlet != null) {
      ref.invalidate(posItemAvailabilityProvider(_outlet!));
    }
  }

  Future<void> _edit(Map<String, dynamic>? existing) async {
    final items = await ref.read(itemsProvider('').future);
    if (!mounted) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RecipeSheet(recipe: existing, items: items),
    );
    if (saved == true) _reload();
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Forget how to make ${row['item_name']}?'),
        content: const Text(
          'The dish stays on the menu and keeps selling. It just stops '
          'taking anything out of the store when it does.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Forget it'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.deletePosRecipe(row['id'] as String),
      successMessage: 'Recipe removed.',
    );
    if (done) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final recipes = ref.watch(posRecipesProvider);
    final outlets = ref.watch(posOutletsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Recipes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('Recipe'),
      ),
      body: AsyncView(
        value: recipes,
        onRetry: _reload,
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.restaurant_menu_outlined,
              title: 'No recipes yet',
              message:
                  'A dish with a recipe takes its ingredients out of the '
                  'store when the bill is settled, and the till can say '
                  'how many more the kitchen can make.',
            );
          }

          // The countdown needs an outlet, because it is a question
          // about one kitchen's shelves.
          final availability = outlets.maybeWhen(
            data: (list) {
              if (list.isEmpty) return null;
              final id = _outlet ?? list.first['id'] as String;
              return ref.watch(posItemAvailabilityProvider(id));
            },
            orElse: () => null,
          );
          final byItem = <String, Map<String, dynamic>>{
            for (final a in availability?.valueOrNull ?? const [])
              '${a['item_id']}': a,
          };

          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final row = rows[i];
              final left = byItem['${row['item_id']}'];
              final label = left == null ? null : portionsLabel(left);
              final ok = left == null || left['available'] == true;
              return ListTile(
                title: Text('${row['item_name']}'),
                subtitle: Text(
                  '${row['line_count']} ingredient'
                  '${row['line_count'] == 1 ? '' : 's'} · '
                  'costs ${Fmt.money(num.tryParse('${row['cost_per_unit'] ?? 0}'))}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The reasoning behind the number beside it. The
                    // requirement list is described in the repository
                    // as "the list that explains why the countdown
                    // says four", and nothing called it — so the
                    // number was shown and never its reason.
                    if (label != null)
                      IconButton(
                        key: ValueKey('why-${row['item_id']}'),
                        tooltip: 'Why',
                        icon: const Icon(Icons.help_outline, size: 18),
                        onPressed: () => showRecipeRequirement(
                          context,
                          itemId: '${row['item_id']}',
                          name: '${row['item_name']}',
                        ),
                      ),
                    if (label != null)
                      Chip(
                        label: Text(label),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: ok
                            ? null
                            : Theme.of(
                                context,
                              ).extension<AppColors>()?.danger.withValues(
                                alpha: 0.15,
                              ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Forget this recipe',
                      onPressed: () => _remove(row),
                    ),
                  ],
                ),
                onTap: () => _edit(row),
              );
            },
          );
        },
      ),
    );
  }
}

/// Writing one down: what it makes, and what goes into it.
class _RecipeSheet extends ConsumerStatefulWidget {
  const _RecipeSheet({required this.recipe, required this.items});

  final Map<String, dynamic>? recipe;
  final List<Item> items;

  @override
  ConsumerState<_RecipeSheet> createState() => _RecipeSheetState();
}

class _RecipeSheetState extends ConsumerState<_RecipeSheet> {
  late final TextEditingController _yield = TextEditingController(
    text: '${widget.recipe?['yield_quantity'] ?? 1}',
  );
  late final TextEditingController _notes = TextEditingController(
    text: '${widget.recipe?['notes'] ?? ''}',
  );
  String? _item;
  final List<Map<String, dynamic>> _lines = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _item = widget.recipe?['item_id'] as String?;
  }

  @override
  void dispose() {
    _yield.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.recipe?['id'] as String?;
    if (id == null) {
      setState(() => _loaded = true);
      return;
    }
    final rows = await ref.read(repoProvider)!.posRecipeLines(id);
    if (!mounted) return;
    setState(() {
      _lines
        ..clear()
        ..addAll(
          rows.map(
            (r) => {
              'item': r['component_item_id'],
              'name': r['component_name'],
              'quantity': r['quantity'],
              'uom': r['uom_code'],
              'wastage': r['wastage_percent'],
              'optional': r['is_optional'],
            },
          ),
        );
      _loaded = true;
    });
  }

  Future<void> _addLine() async {
    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _IngredientDialog(items: widget.items),
    );
    if (chosen == null) return;
    setState(() => _lines.add(chosen));
  }

  Future<void> _save() async {
    final item = _item;
    if (item == null) return;
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .savePosRecipe(
            itemId: item,
            yield_: num.tryParse(_yield.text.trim()) ?? 1,
            lines: _lines
                .map(
                  (l) => {
                    'item': l['item'],
                    'quantity': l['quantity'],
                    'uom': l['uom'],
                    'wastage': l['wastage'],
                    'optional': l['optional'],
                  },
                )
                .toList(),
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          ),
      successMessage: 'Recipe saved.',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      _load();
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final editing = widget.recipe != null;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(Space.lg),
          children: [
            Text(
              editing ? '${widget.recipe!['item_name']}' : 'A new recipe',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Space.md),
            if (!editing)
              DropdownButtonFormField<String>(
                value: _item,
                decoration: const InputDecoration(labelText: 'The dish'),
                items: [
                  for (final i in widget.items)
                    DropdownMenuItem(
                      value: i.id,
                      child: Text(i.name),
                    ),
                ],
                onChanged: (v) => setState(() => _item = v),
              ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _yield,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Makes',
                helperText:
                    'Write the pot you actually make. Dividing by twenty '
                    'once here beats rounding a twentieth of an onion '
                    'twenty times.',
              ),
            ),
            const SizedBox(height: Space.md),
            for (final line in _lines)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${line['name']}'),
                subtitle: Text(
                  recipeLine({
                    'quantity': line['quantity'],
                    'uom_code': line['uom'],
                    'wastage_percent': line['wastage'],
                    'is_optional': line['optional'],
                  }),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _lines.remove(line)),
                ),
              ),
            TextButton.icon(
              onPressed: _addLine,
              icon: const Icon(Icons.add),
              label: const Text('Ingredient'),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
            const SizedBox(height: Space.lg),
            FilledButton(
              onPressed: _item == null ? null : _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One ingredient: what, how much, in what unit, and how much of it
/// never reaches the plate.
class _IngredientDialog extends ConsumerStatefulWidget {
  const _IngredientDialog({required this.items});

  final List<Item> items;

  @override
  ConsumerState<_IngredientDialog> createState() => _IngredientDialogState();
}

class _IngredientDialogState extends ConsumerState<_IngredientDialog> {
  String? _item;
  String? _uom;
  final _qty = TextEditingController();
  final _waste = TextEditingController(text: '0');
  bool _optional = false;

  @override
  void dispose() {
    _qty.dispose();
    _waste.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = _item == null
        ? const AsyncValue<List<Map<String, dynamic>>>.data([])
        : ref.watch(itemUomOptionsProvider(_item!));

    return AlertDialog(
      title: const Text('An ingredient'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: _item,
              decoration: const InputDecoration(labelText: 'What'),
              items: [
                for (final i in widget.items)
                  DropdownMenuItem(
                    value: i.id,
                    child: Text(i.name),
                  ),
              ],
              onChanged: (v) => setState(() {
                _item = v;
                _uom = null;
              }),
            ),
            TextField(
              controller: _qty,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'How much'),
            ),
            DropdownButtonFormField<String>(
              value: _uom,
              decoration: const InputDecoration(labelText: 'In what unit'),
              items: [
                for (final o in options.valueOrNull ?? const [])
                  DropdownMenuItem(
                    value: '${o['uom_code']}',
                    child: Text('${o['uom_name']}'),
                  ),
              ],
              onChanged: (v) => setState(() => _uom = v),
            ),
            TextField(
              controller: _waste,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Waste %',
                helperText: 'Trim, peel and what never comes out of the pot.',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _optional,
              title: const Text('A garnish'),
              subtitle: const Text('Still used, but never stops a sale.'),
              onChanged: (v) => setState(() => _optional = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _item == null || _uom == null
              ? null
              : () {
                  final name = widget.items
                      .firstWhere((i) => i.id == _item)
                      .name;
                  Navigator.of(context).pop({
                    'item': _item,
                    'name': name,
                    'quantity': num.tryParse(_qty.text.trim()) ?? 0,
                    'uom': _uom,
                    'wastage': num.tryParse(_waste.text.trim()) ?? 0,
                    'optional': _optional,
                  });
                },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
