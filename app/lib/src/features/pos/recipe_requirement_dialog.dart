import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'recipes_screen.dart' show trimNumber;

/// Why the countdown says four.
///
/// `pos_recipe_requirement` is described in the repository as "the list
/// that explains why the countdown says four" — what making a dish
/// draws out of the store, sub-recipes already exploded — and nothing
/// called it. The screen showed the number and could not show the
/// reasoning, so a kitchen told it could make four more of something
/// had no way to find which shelf was the reason.

/// How many of this ingredient one dish takes.
String requirementLine(Map<String, dynamic> row) {
  final qty = num.tryParse('${row['quantity'] ?? 0}') ?? 0;
  final uom = '${row['uom_code'] ?? ''}';
  return [
    '${trimNumber(qty)} $uom'.trim(),
    if (row['is_optional'] == true) 'optional',
  ].join(' · ');
}

/// How many dishes this ingredient alone allows.
///
/// Null where the answer is "as many as you like": an ingredient the
/// shop does not count cannot limit anything, and neither can one the
/// recipe needs none of. Saying zero for either would name the wrong
/// shelf as the constraint.
double? portionsFrom(Map<String, dynamic> row) {
  final need = double.tryParse('${row['quantity'] ?? 0}') ?? 0;
  if (need <= 0) return null;
  final onHand = row['on_hand'];
  if (onHand == null) return null;
  final have = double.tryParse('$onHand') ?? 0;
  return have / need;
}

/// Which ingredient runs out first.
///
/// An optional one is skipped: the dish goes out without it, so it is
/// not what stops the kitchen making another. Null when nothing counted
/// limits it, which is the same answer the countdown gives.
Map<String, dynamic>? limitingIngredient(
  Iterable<Map<String, dynamic>> rows,
) {
  Map<String, dynamic>? worst;
  double? fewest;
  for (final r in rows) {
    if (r['is_optional'] == true) continue;
    final portions = portionsFrom(r);
    if (portions == null) continue;
    if (fewest == null || portions < fewest) {
      fewest = portions;
      worst = r;
    }
  }
  return worst;
}

/// What the store allows, over the whole recipe.
double? portionsPossible(Iterable<Map<String, dynamic>> rows) {
  final worst = limitingIngredient(rows);
  return worst == null ? null : portionsFrom(worst);
}

/// Why the countdown says what it says.
Future<void> showRecipeRequirement(
  BuildContext context, {
  required String itemId,
  required String name,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _RequirementDialog(itemId: itemId, name: name),
    );

class _RequirementDialog extends ConsumerWidget {
  const _RequirementDialog({required this.itemId, required this.name});

  final String itemId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(posRecipeRequirementProvider(itemId));

    return AlertDialog(
      title: Text('What one $name takes'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: AsyncView<List<Map<String, dynamic>>>(
          value: rows,
          onRetry: () => ref.invalidate(posRecipeRequirementProvider(itemId)),
          builder: (list) {
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.restaurant_menu_outlined,
                title: 'Nothing counted',
                message: 'This dish draws nothing tracked out of the store, '
                    'so nothing on a shelf limits it.',
              );
            }
            final worst = limitingIngredient(list);
            final possible = portionsPossible(list);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  possible == null
                      ? 'Nothing counted limits this dish.'
                      : 'The store allows about '
                          '${trimNumber(possible.floor())} more, and '
                          '${worst?['component_name']} is why.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Space.sm),
                Expanded(
                  child: ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = list[i];
                      final limiting = worst != null &&
                          r['component_item_id'] == worst['component_item_id'];
                      final onHand = r['on_hand'];
                      return ListTile(
                        dense: true,
                        title: Text(
                          '${r['component_name']}',
                          style: TextStyle(
                            fontWeight:
                                limiting ? FontWeight.w700 : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          requirementLine(r),
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Text(
                          onHand == null
                              ? 'not counted'
                              : '${trimNumber(num.tryParse('$onHand') ?? 0)} '
                                  'on hand',
                          style: TextStyle(
                            fontSize: 12,
                            color: limiting ? context.colors.warning : null,
                            fontWeight:
                                limiting ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      );
                    },
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
