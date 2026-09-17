import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// What the kitchen has run out of today.
///
/// `stop_pos_item` and `resume_pos_item` are reached from a long press
/// on the menu, and `pos_stopped_items` — "what this outlet has run out
/// of today, and who said so" — was not. So the list existed only as
/// greyed tiles scattered through a menu: nobody could see it whole,
/// nobody could see who took a dish off, and nobody could put one back
/// without first finding it.

/// Who took it off, and why.
///
/// The function already answers both plainly — an untyped reason comes
/// back as "Sold out" and a leaver as "Somebody who has left" — so the
/// screen has nothing to guess at and neither should it invent a
/// blank.
String stoppedBecause(Map<String, dynamic> row) {
  final at = DateTime.tryParse('${row['stopped_at'] ?? ''}');
  return [
    '${row['reason'] ?? ''}',
    '${row['stopped_by'] ?? ''}',
    // Left out rather than shown as a dash: an em dash between two
    // real facts reads as a missing third one, which is worse than
    // three words where there were four.
    if (at != null) Fmt.time(at.toLocal()),
  ].where((s) => s.trim().isNotEmpty).join(' · ');
}

/// What a stopped item reads as.
String stoppedItemLabel(Map<String, dynamic> row) =>
    '${row['code']} ${row['name']}'.trim();

/// The list is a day's list.
///
/// `pos_stopped_items` filters on today in Kuala Lumpur and nothing
/// else, so an empty list means the kitchen has everything — not that
/// nobody has looked.
const String soldOutScope =
    'Everything taken off today. The list clears itself overnight: a '
    'dish stopped this afternoon is back on the menu tomorrow.';

/// What the kitchen has run out of.
Future<void> showSoldOut(BuildContext context, String outletId) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SoldOutDialog(outletId: outletId),
    );

class _SoldOutDialog extends ConsumerWidget {
  const _SoldOutDialog({required this.outletId});

  final String outletId;

  Future<void> _resume(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> row,
  ) async {
    final ok = await runWithFeedback(
      context,
      successMessage: 'Back on',
      action: () => ref
          .read(repoProvider)!
          .resumePosItem(outletId, '${row['item_id']}'),
    );
    if (ok) {
      ref
        ..invalidate(posStoppedItemsProvider(outletId))
        ..invalidate(posMenuProvider(outletId));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stopped = ref.watch(posStoppedItemsProvider(outletId));
    final canWrite = ref.watch(canWriteProvider);

    return AlertDialog(
      title: const Text('Sold out today'),
      content: SizedBox(
        width: 520,
        height: 400,
        child: AsyncView<List<Map<String, dynamic>>>(
          value: stopped,
          onRetry: () => ref.invalidate(posStoppedItemsProvider(outletId)),
          builder: (rows) {
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.restaurant_menu,
                title: 'Everything is on',
                message: 'Nothing has been taken off the menu today.',
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  soldOutScope,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Space.sm),
                Expanded(
                  child: ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      return ListTile(
                        dense: true,
                        title: Text(stoppedItemLabel(r)),
                        subtitle: Text(
                          stoppedBecause(r),
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: !canWrite
                            ? null
                            : TextButton(
                                key: ValueKey('resume-${r['item_id']}'),
                                onPressed: () => _resume(context, ref, r),
                                child: const Text('Back on'),
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
