import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
// `RepoPos` is an extension, and a Dart extension is only in scope
// where its declaring library is imported.
import '../../data/repository.dart';
import 'till_screen.dart' show PosRegisterPicker, posNum;

/// The room.
///
/// A waiter crossing a dining room needs one question answered — which
/// tables are taken — and needs it answered from three metres away.
/// So the tables are drawn as tiles rather than listed as rows, grouped
/// by the area they stand in, and the state that matters is carried by
/// colour and by the two figures a busy person actually reads: how long
/// they have been sitting, and what they are up to.
///
/// ## Tapping is the same gesture twice
///
/// A free table opens a bill; a taken one opens the bill it already
/// has. Both are one tap on the tile, because `seat_table()` returns
/// the existing sale when there is one rather than raising — the
/// server settled the ambiguity, so the screen does not have to ask.
///
/// ## Occupancy is not stored anywhere
///
/// Every tile's state comes from whether a parked sale points at that
/// table. Nothing here writes an "occupied" flag, which is why a
/// tablet that dies mid-service leaves no table stuck: there was
/// nothing set to go stale.
class FloorPlanScreen extends ConsumerStatefulWidget {
  const FloorPlanScreen({super.key});

  @override
  ConsumerState<FloorPlanScreen> createState() => _FloorPlanScreenState();
}

class _FloorPlanScreenState extends ConsumerState<FloorPlanScreen> {
  String? _registerId;
  String? _outletId;

  void _pickRegister(Map<String, dynamic> reg) {
    setState(() {
      _registerId = reg['id'] as String?;
      _outletId = (reg['pos_outlets'] as Map?)?['id'] as String?;
    });
  }

  Future<void> _seat(Map<String, dynamic> t) async {
    final reg = _registerId;
    final tableId = t['table_id'] as String?;
    if (reg == null || tableId == null) return;

    // Only asked for on the way in. A table that is already open has
    // been counted once, and asking again every time somebody opens
    // the bill would be asking the same question all night.
    int? covers;
    if (t['sale_id'] == null) {
      covers = await _askCovers(context, seats: (t['seats'] as num?)?.toInt());
      if (covers == null || !mounted) return;
    }
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () => repo.seatTable(reg, tableId, covers: covers),
    );
    if (!ok || !mounted) return;
    final outlet = _outletId;
    if (outlet != null) ref.invalidate(posFloorPlanProvider(outlet));
  }

  /// Moving a party. The destination list deliberately offers only free
  /// tables: `move_pos_sale` refuses a table that already has a bill,
  /// and offering a choice the server will reject is a screen setting
  /// somebody up to fail.
  Future<void> _move(
    Map<String, dynamic> from,
    List<Map<String, dynamic>> plan,
  ) async {
    final saleId = from['sale_id'] as String?;
    if (saleId == null) return;
    final free = [
      for (final t in plan)
        if (t['sale_id'] == null) t,
    ];
    if (free.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Every other table is taken.')),
      );
      return;
    }
    final to = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Move ${from['table_name']} to'),
        children: [
          for (final t in free)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(t),
              child: Text(
                '${t['table_name']}'
                '${t['area'] == null ? '' : ' · ${t['area']}'}',
              ),
            ),
        ],
      ),
    );
    if (to == null || !mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Moved to ${to['table_name']}',
      action: () => repo.movePosSale(saleId, to['table_id'] as String),
    );
    if (!ok || !mounted) return;
    final outlet = _outletId;
    if (outlet != null) ref.invalidate(posFloorPlanProvider(outlet));
  }

  @override
  Widget build(BuildContext context) {
    final registers = ref.watch(posRegistersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Floor'),
        actions: [
          registers.maybeWhen(
            data: (rows) => PosRegisterPicker(
              registers: rows,
              selectedId: _registerId,
              onPicked: _pickRegister,
            ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: registers,
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.table_restaurant_outlined,
              title: 'No tills yet',
              message:
                  'A floor plan hangs off an outlet, and an outlet needs '
                  'a register before anybody can seat anyone at it.',
            );
          }
          // Landing on the first register saves a tap on a device that
          // only ever has one, which is most of them.
          if (_registerId == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _pickRegister(rows.first);
            });
          }
          final outlet = _outletId;
          if (outlet == null) return const SizedBox.shrink();
          return _Room(
            outletId: outlet,
            onSeat: _seat,
            onMove: _move,
          );
        },
      ),
    );
  }
}

class _Room extends ConsumerWidget {
  const _Room({
    required this.outletId,
    required this.onSeat,
    required this.onMove,
  });

  final String outletId;
  final ValueChanged<Map<String, dynamic>> onSeat;
  final void Function(Map<String, dynamic>, List<Map<String, dynamic>>) onMove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(posFloorPlanProvider(outletId));
    return AsyncView<List<Map<String, dynamic>>>(
      value: plan,
      builder: (tables) {
        if (tables.isEmpty) {
          return const EmptyState(
            icon: Icons.table_restaurant_outlined,
            title: 'No tables yet',
            message:
                'Add areas and tables to this outlet and the room appears '
                'here.',
          );
        }
        // Grouped in the order the query returns them, which is the
        // order the areas were given: a floor plan that reshuffles
        // itself is one nobody can learn.
        final areas = <String, List<Map<String, dynamic>>>{};
        for (final t in tables) {
          areas.putIfAbsent((t['area'] as String?) ?? 'Floor', () => []).add(t);
        }
        final taken = tables.where((t) => t['sale_id'] != null).length;
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(posFloorPlanProvider(outletId));
          },
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 4),
                child: Text(
                  '$taken of ${tables.length} taken',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              for (final entry in areas.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
                  child: Text(
                    entry.key,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                LayoutBuilder(
                  builder: (context, box) {
                    // Tiles rather than a grid with a fixed column
                    // count, so the same room reflows from a phone held
                    // in one hand to a tablet on a stand.
                    final columns = (box.maxWidth / 170).floor().clamp(2, 6);
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: entry.value.length,
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            childAspectRatio: 1.15,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                      itemBuilder: (_, i) => _TableTile(
                        table: entry.value[i],
                        onTap: () => onSeat(entry.value[i]),
                        onMove: () => onMove(entry.value[i], tables),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _TableTile extends StatelessWidget {
  const _TableTile({
    required this.table,
    required this.onTap,
    required this.onMove,
  });

  final Map<String, dynamic> table;
  final VoidCallback onTap;
  final VoidCallback onMove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = table['sale_id'] != null;
    final minutes = (table['minutes_seated'] as num?)?.toInt();

    return Card(
      // The one piece of state a waiter reads from across the room.
      color: busy ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: busy ? onMove : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${table['table_name']}',
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (busy)
                    IconButton(
                      tooltip: 'Move this party',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      onPressed: onMove,
                    ),
                ],
              ),
              const Spacer(),
              if (busy) ...[
                Text(
                  // Covers, not seats: what the waiter counted beats
                  // what the furniture allows.
                  '${table['covers'] ?? table['seats']} covers',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  Fmt.money(posNum(table['total_amount'])),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  minutes == null ? '' : _sat(minutes),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ] else
                Text(
                  'Free · ${table['seats'] ?? 0} seats',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Minutes up to an hour, then hours. A table that has been sitting
  /// for 143 minutes is information nobody uses; "2h 23m" is.
  static String _sat(int minutes) {
    if (minutes < 60) return '${minutes}m';
    return '${minutes ~/ 60}h ${minutes % 60}m';
  }
}

/// How many are actually sitting down.
///
/// Defaults to the table's seats and says so, because the common case
/// is a full table and the uncommon one is worth a tap. `seat_table()`
/// makes the same assumption when it is given nothing, so the screen
/// and the server agree rather than one quietly overriding the other.
Future<int?> _askCovers(BuildContext context, {int? seats}) {
  var value = seats ?? 2;
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('How many are sitting?'),
      content: StatefulBuilder(
        builder: (context, setInner) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: value > 1
                  ? () => setInner(() => value = value - 1)
                  : null,
            ),
            Text('$value', style: Theme.of(context).textTheme.headlineMedium),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => setInner(() => value = value + 1),
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
          onPressed: () => Navigator.of(ctx).pop(value),
          child: const Text('Seat them'),
        ),
      ],
    ),
  );
}
