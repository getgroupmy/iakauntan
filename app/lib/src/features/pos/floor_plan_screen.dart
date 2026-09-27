import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/widgets.dart';
// `RepoPos` is an extension, and a Dart extension is only in scope
// where its declaring library is imported.
import '../../data/repository.dart';
import 'table_cards_pdf.dart';
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
  String _outletName = '';

  void _pickRegister(Map<String, dynamic> reg) {
    final outlet = (reg['pos_outlets'] as Map?)?.cast<String, dynamic>();
    setState(() {
      _registerId = reg['id'] as String?;
      _outletId = outlet?['id'] as String?;
      _outletName = '${outlet?['name'] ?? ''}';
    });
  }

  /// Turning one long table into two.
  ///
  /// The case this is for: a twelve-seater down one wall with two
  /// unrelated parties at it, which is the ordinary Friday in a warung.
  /// The room needs two places where it had one — two bills, two cards,
  /// two tiles — and `split_pos_table` makes them real tables so
  /// everything that already knows about tables keeps working.
  Future<void> _split(Map<String, dynamic> t) async {
    final tableId = t['table_id'] as String?;
    if (tableId == null) return;
    final parts = await _askParts(
      context,
      code: '${t['table_code'] ?? t['table_name']}',
      seats: (t['seats'] as num?)?.toInt() ?? 2,
    );
    if (parts == null || !mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Split into $parts',
      action: () => repo.splitPosTable(tableId, parts),
    );
    if (!ok || !mounted) return;
    final outlet = _outletId;
    if (outlet != null) ref.invalidate(posFloorPlanProvider(outlet));
  }

  /// And putting it back.
  ///
  /// Asked first, because a party still sitting on one half comes back
  /// to the whole table with it — which is right, and is not something
  /// to do to somebody's service by accident. Two parties still sitting
  /// is refused by the server, not here, so the screen cannot disagree
  /// with the database about when it is safe.
  Future<void> _merge(Map<String, dynamic> t) async {
    final tableId = t['table_id'] as String?;
    if (tableId == null) return;
    final whole = '${t['table_code'] ?? ''}'.split('-').first;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Put $whole back together?'),
        content: const Text(
          'The halves come off the floor. Anybody still sitting at one '
          'moves to the whole table with their bill.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Leave it split'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Put it back'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: '$whole is one table again',
      action: () => repo.mergePosTable(tableId),
    );
    if (!ok || !mounted) return;
    final outlet = _outletId;
    if (outlet != null) ref.invalidate(posFloorPlanProvider(outlet));
  }

  /// The cards that go on the tables.
  ///
  /// Printing is the whole point of the codes: `pos_table_by_code` and
  /// the till's assign-table sheet can turn a scan into a table, but
  /// only once there is something in the room to scan. This is offered
  /// from the floor plan because that is where somebody setting a
  /// dining room up already is, and because the plan already carries
  /// every field a card needs.
  Future<void> _printCards() async {
    final outlet = _outletId;
    if (outlet == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgProvider).valueOrNull;
    if (org == null) return;
    // Read through `.future` rather than `valueOrNull`: the button can
    // be pressed while the plan is still in flight, and a sheet of
    // nought cards is a worse answer than a moment's wait.
    final tables = await ref.read(posFloorPlanProvider(outlet).future);
    if (!mounted) return;
    if (tables.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No tables to print cards for.')),
      );
      return;
    }
    try {
      final bytes = await buildTableCardsPdf(
        org: org,
        outletName: _outletName,
        tables: tables,
      );
      if (!mounted) return;
      final stem = (_outletName.isEmpty ? 'outlet' : _outletName)
          .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
          .toLowerCase();
      final saved = await exportBytesFile(
        ref,
        'table-cards-$stem.pdf',
        'application/pdf',
        bytes,
        what: 'Table cards',
        detail: _outletName,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(saved
              ? 'Table cards downloaded. Print, cut and stand them up.'
              // saveBytesFile only works in the browser, and a PDF is
              // not something the clipboard can hold, so this says what
              // to do rather than pretending something happened.
              : 'Printing table cards needs the browser. Open iAkauntan '
                  'on a computer and try again.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not make the cards: ${errorText(e)}')),
      );
    }
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
          IconButton(
            tooltip: 'Print table cards',
            icon: const Icon(Icons.qr_code_2),
            onPressed: _outletId == null ? null : _printCards,
          ),
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
            onSplit: _split,
            onMerge: _merge,
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
    required this.onSplit,
    required this.onMerge,
  });

  final String outletId;
  final ValueChanged<Map<String, dynamic>> onSeat;
  final void Function(Map<String, dynamic>, List<Map<String, dynamic>>) onMove;
  final ValueChanged<Map<String, dynamic>> onSplit;
  final ValueChanged<Map<String, dynamic>> onMerge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(posFloorPlanProvider(outletId));
    return AsyncView<List<Map<String, dynamic>>>(
      value: plan,
      skeleton: const ListSkeleton(rows: 6, subtitle: false),
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
                        onSplit: () => onSplit(entry.value[i]),
                        onMerge: () => onMerge(entry.value[i]),
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
    required this.onSplit,
    required this.onMerge,
  });

  final Map<String, dynamic> table;
  final VoidCallback onTap;
  final VoidCallback onMove;
  final VoidCallback onSplit;
  final VoidCallback onMerge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = table['sale_id'] != null;
    final minutes = (table['minutes_seated'] as num?)?.toInt();
    // A half of a long table. It can be put back; it cannot be split
    // again, and offering that would be offering something the server
    // refuses.
    final isHalf = table['parent_table_id'] != null;

    return Card(
      // The one piece of state a waiter reads from across the room.
      color: busy ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
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
                  // One affordance, always in the same corner,
                  // carrying whichever of the three actions apply.
                  // Two icon buttons would not fit beside a table name
                  // on a phone, and a hidden long-press is no way to
                  // find something a waiter needs mid-service.
                  PopupMenuButton<String>(
                    tooltip: 'What to do with this table',
                    icon: const Icon(Icons.more_vert, size: 18),
                    padding: EdgeInsets.zero,
                    onSelected: (v) => switch (v) {
                      'move' => onMove(),
                      'split' => onSplit(),
                      _ => onMerge(),
                    },
                    itemBuilder: (_) => [
                      if (busy)
                        const PopupMenuItem(
                          value: 'move',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.swap_horiz),
                            title: Text('Move this party'),
                          ),
                        ),
                      if (isHalf)
                        const PopupMenuItem(
                          value: 'merge',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.call_merge),
                            title: Text('Put the table back together'),
                          ),
                        )
                      else
                        const PopupMenuItem(
                          value: 'split',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.call_split),
                            title: Text('Split this table'),
                          ),
                        ),
                    ],
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

/// How many tables one table becomes.
///
/// Shows the codes it will produce rather than just the number,
/// because the codes are what goes on the cards and what a cashier
/// types, and "2" does not tell anybody that they are about to have a
/// T1-A and a T1-B.
Future<int?> _askParts(
  BuildContext context, {
  required String code,
  required int seats,
}) {
  var value = 2;
  String preview(int n) => [
        for (var i = 0; i < n; i++) '$code-${String.fromCharCode(65 + i)}',
      ].join('   ');

  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Split $code'),
      content: StatefulBuilder(
        builder: (context, setInner) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: value > 2
                      ? () => setInner(() => value = value - 1)
                      : null,
                ),
                Text(
                  '$value',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  // Eight is what the server takes. A table split nine
                  // ways is not a table.
                  onPressed: value < 8
                      ? () => setInner(() => value = value + 1)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(preview(value), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              // The seats are divided, remainder to the earlier parts.
              'The $seats seats are shared out between them.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
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
          child: const Text('Split it'),
        ),
      ],
    ),
  );
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
