import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// Whose dish this is.
///
/// `0268` puts it plainly: "`items.stall_id` says whose dish it is;
/// `pos_sale_lines.stall_id` is stamped from it when the line is rung
/// up and never read from the item again." Nothing in the app could
/// set it — `setItemStall` had no caller — so every line rang up with
/// no stall, `pos_stall_takings` counts only lines where `stall_id is
/// not null`, and the Settling tab was empty for every food court that
/// ever used this. The stalls, the commission and the settlement were
/// all there and could not produce a ringgit.

/// The dishes this stall sells.
List<Map<String, dynamic>> itemsOnStall(
  Iterable<Map<String, dynamic>> items,
  String stallId,
) =>
    items.where((i) => i['stall_id'] == stallId).toList();

/// Everything that could be moved onto it: the unassigned, and the
/// dishes another stall currently sells.
///
/// A dish moving between stalls is a real event — a stall changes
/// hands, or a recipe is taken over — and `0268` has already decided
/// what it means: the line was stamped when it was rung up, so moving
/// the item now "must not move money with it". Offering the move is
/// therefore safe, and refusing it would be inventing a rule the
/// database does not have.
List<Map<String, dynamic>> itemsOffStall(
  Iterable<Map<String, dynamic>> items,
  String stallId,
) =>
    items.where((i) => i['stall_id'] != stallId).toList();

bool itemIsUnassigned(Map<String, dynamic> item) => item['stall_id'] == null;

/// Where a dish sits now, said in the picker so nobody moves one out
/// of a stall without noticing.
String stallItemNote(
  Map<String, dynamic> item,
  Map<String, String> stallNames,
) {
  final id = item['stall_id'] as String?;
  if (id == null) return 'On no stall';
  return 'Now on ${stallNames[id] ?? 'another stall'}';
}

/// The stalls by id, for reading an item's current home.
Map<String, String> stallNamesOf(Iterable<Map<String, dynamic>> stalls) => {
      for (final s in stalls)
        if (s['id'] != null) '${s['id']}': '${s['name'] ?? s['code'] ?? ''}',
    };

/// Say which dishes this stall sells.
Future<bool> showStallItems(
  BuildContext context, {
  required Map<String, dynamic> stall,
  required List<Map<String, dynamic>> stalls,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _StallItemsDialog(stall: stall, stalls: stalls),
    ) ??
    false;

class _StallItemsDialog extends ConsumerStatefulWidget {
  const _StallItemsDialog({required this.stall, required this.stalls});

  final Map<String, dynamic> stall;
  final List<Map<String, dynamic>> stalls;

  @override
  ConsumerState<_StallItemsDialog> createState() => _StallItemsDialogState();
}

class _StallItemsDialogState extends ConsumerState<_StallItemsDialog> {
  final _search = TextEditingController();
  bool _busy = false;
  bool _changed = false;

  String get _stallId => '${widget.stall['id']}';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _set(Map<String, dynamic> item, String? stallId) async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.setItemStall('${item['id']}', stallId),
      successMessage: stallId == null ? 'Taken off the stall' : 'Added',
    );
    if (mounted) setState(() => _busy = false);
    if (ok) {
      _changed = true;
      ref.invalidate(itemStallsProvider);
    }
  }

  Future<void> _add() async {
    final all = ref.read(itemStallsProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
    final names = stallNamesOf(widget.stalls);
    final choices = itemsOffStall(all, _stallId);
    if (choices.isEmpty) return;

    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        final search = TextEditingController();
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final needle = search.text.trim().toLowerCase();
            final rows = [
              for (final i in choices)
                if (needle.isEmpty ||
                    '${i['code']}'.toLowerCase().contains(needle) ||
                    '${i['name']}'.toLowerCase().contains(needle))
                  i,
            ];
            return AlertDialog(
              title: const Text('Which dish'),
              content: SizedBox(
                width: 480,
                height: 400,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const ValueKey('stall-item-search'),
                      controller: search,
                      onChanged: (_) => setLocal(() {}),
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 18),
                        hintText: 'Code or name',
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Expanded(
                      child: rows.isEmpty
                          ? const Center(child: Text('Nothing matches that.'))
                          : ListView.separated(
                              itemCount: rows.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final it = rows[i];
                                return ListTile(
                                  dense: true,
                                  title: Text('${it['code']} ${it['name']}'),
                                  subtitle: Text(
                                    stallItemNote(it, names),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: itemIsUnassigned(it)
                                          ? null
                                          : context.colors.warning,
                                    ),
                                  ),
                                  onTap: () => Navigator.of(ctx).pop(it),
                                );
                              },
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
              ],
            );
          },
        );
      },
    );
    if (chosen == null || !mounted) return;
    await _set(chosen, _stallId);
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(itemStallsProvider);
    final canWrite = ref.watch(canWriteProvider);

    return AlertDialog(
      title: Text('What ${widget.stall['name']} sells'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: AsyncView<List<Map<String, dynamic>>>(
          value: items,
          onRetry: () => ref.invalidate(itemStallsProvider),
          builder: (all) {
            final mine = itemsOnStall(all, _stallId);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'A dish is stamped with its stall when it is rung up, so '
                  'what is settled for February does not change when a '
                  'stall changes hands in March.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Space.sm),
                Expanded(
                  child: mine.isEmpty
                      ? Center(
                          child: Text(
                            'Nothing is this stall’s yet, so nothing it '
                            'sells reaches its settlement.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        )
                      : ListView.separated(
                          itemCount: mine.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final it = mine[i];
                            return ListTile(
                              dense: true,
                              title: Text('${it['code']} ${it['name']}'),
                              trailing: !canWrite
                                  ? null
                                  : IconButton(
                                      key: ValueKey('off-stall-${it['id']}'),
                                      tooltip: 'Take it off this stall',
                                      icon: const Icon(
                                        Icons.remove_circle_outline,
                                        size: 18,
                                      ),
                                      onPressed: _busy
                                          ? null
                                          : () => _set(it, null),
                                    ),
                            );
                          },
                        ),
                ),
                if (canWrite)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('add-stall-item'),
                      onPressed: _busy ? null : _add,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add a dish'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_changed),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
