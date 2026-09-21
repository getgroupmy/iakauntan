import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// Putting a dine-in bill on a table, from the till.
///
/// The floor plan already does this and is the right screen for a
/// waiter walking the room: it draws the tables where they are and a
/// tap seats the party. It is the wrong screen for a cashier at a
/// counter taking an order for table seven, who has the bill in front
/// of them and would have to leave it to go and find a picture of the
/// room.
///
/// ## What the shop puts on the table
///
/// A printed code, a QR sticker, an NFC tag under the edge. Every
/// reader sold into this market for those — the tag readers, the
/// barcode guns, the QR pads — presents to the device as a keyboard:
/// it types what it read and presses enter. So this needs no new
/// hardware path and no new permission. It is the same arrangement the
/// item search already relies on, pointed at a different question.
///
/// A phone camera pointed at a QR code is a different thing and is not
/// this: it needs a scanner package the app does not carry. What is
/// here covers wedge readers and typing, which is what a counter has.
///
/// ## And the list, because a card can be missing
///
/// A sticker peels off, a tag stops reading, a new table has no card
/// yet. The list underneath is not a fallback bolted on — for a shop
/// with eight tables it is faster than any card, and the scan is what
/// helps the shop with forty.
class SaleTableChip extends ConsumerWidget {
  const SaleTableChip({
    super.key,
    required this.saleId,
    required this.outletId,
    required this.tableId,
  });

  final String saleId;
  final String? outletId;

  /// What the bill points at now, or null while it points at nothing.
  final Object? tableId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outlet = outletId;
    if (outlet == null) return const SizedBox.shrink();

    // The plan is read here rather than passed in because it answers
    // both questions at once: whether this shop has tables at all, and
    // what the one on this bill is called. A shop with no tables is
    // never offered a table.
    final plan = ref.watch(posFloorPlanProvider(outlet));
    final rows = plan.valueOrNull ?? const <Map<String, dynamic>>[];
    if (rows.isEmpty) return const SizedBox.shrink();

    String? name;
    for (final r in rows) {
      if (tableId != null && r['table_id'] == tableId) {
        name = '${r['table_name']}';
        break;
      }
    }

    return ActionChip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        name == null ? Icons.table_bar_outlined : Icons.table_restaurant,
        size: 16,
      ),
      label: Text(name ?? 'Assign a table'),
      onPressed: () => assignTable(
        context,
        ref,
        saleId: saleId,
        outletId: outlet,
        current: tableId,
      ),
    );
  }
}

/// Opens the sheet and writes what it comes back with.
///
/// Separate from the chip so the floor plan, an open-orders list or a
/// waiter's tablet can put the same sheet behind their own affordance
/// without one of them owning it.
Future<void> assignTable(
  BuildContext context,
  WidgetRef ref, {
  required String saleId,
  required String outletId,
  Object? current,
}) async {
  final picked = await showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => AssignTableSheet(outletId: outletId, current: current),
  );
  if (picked == null || !context.mounted) return;
  final repo = ref.read(repoProvider);
  if (repo == null) return;
  final id = picked['table_id'] as String?;
  if (id == null) return;
  final ok = await runWithFeedback(
    context,
    successMessage: 'On ${picked['table_name']}',
    action: () => repo.movePosSale(saleId, id),
  );
  if (!ok) return;
  ref
    ..invalidate(posSaleProvider(saleId))
    ..invalidate(posFloorPlanProvider(outletId));
}

/// Scan a card, or tap a table.
class AssignTableSheet extends ConsumerStatefulWidget {
  const AssignTableSheet({
    super.key,
    required this.outletId,
    this.current,
  });

  final String outletId;
  final Object? current;

  @override
  ConsumerState<AssignTableSheet> createState() => _AssignTableSheetState();
}

class _AssignTableSheetState extends ConsumerState<AssignTableSheet> {
  final _code = TextEditingController();
  final _focus = FocusNode();
  bool _looking = false;

  /// Said on the sheet rather than in a snack bar that slides away
  /// under the sheet itself, where a cashier holding a card would
  /// never see it.
  String? _missed;

  @override
  void dispose() {
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _scan(String raw) async {
    if (raw.trim().isEmpty) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() {
      _looking = true;
      _missed = null;
    });
    Map<String, dynamic>? hit;
    try {
      hit = await repo.posTableByCode(widget.outletId, raw);
    } finally {
      if (mounted) setState(() => _looking = false);
    }
    if (!mounted) return;
    if (hit == null) {
      // The field keeps focus and clears itself, because the next
      // thing that happens is somebody scanning again — either the
      // same card straighter or a different one.
      setState(() => _missed = raw.trim());
      _code.clear();
      _focus.requestFocus();
      return;
    }
    Navigator.of(context).pop(hit);
  }

  @override
  Widget build(BuildContext context) {
    final plan = ref.watch(posFloorPlanProvider(widget.outletId));

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Which table?'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _code,
                focusNode: _focus,
                autofocus: true,
                textInputAction: TextInputAction.search,
                // A card reader types and presses enter. Submitting on
                // enter is not a convenience here, it is the whole
                // interface for the reader this sheet exists for.
                onSubmitted: _scan,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.qr_code_scanner),
                  hintText: 'Scan the table card, or type its code',
                  border: const OutlineInputBorder(),
                  errorText: _missed == null
                      ? null
                      : 'No table here answers to "$_missed".',
                  suffixIcon: _looking
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.search),
                          onPressed: () => _scan(_code.text),
                        ),
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: AsyncView<List<Map<String, dynamic>>>(
                value: plan,
                skeleton: const ListSkeleton(rows: 6),
                builder: (rows) {
                  // A table with two bills on it appears twice on the
                  // plan, which is the truth there and a duplicate
                  // here. Folded by table, keeping the count.
                  final byTable = <String, Map<String, dynamic>>{};
                  final bills = <String, int>{};
                  for (final r in rows) {
                    final id = '${r['table_id']}';
                    byTable.putIfAbsent(id, () => r);
                    if (r['sale_id'] != null) {
                      bills[id] = (bills[id] ?? 0) + 1;
                    }
                  }
                  if (byTable.isEmpty) {
                    return const EmptyState(
                      icon: Icons.table_bar_outlined,
                      title: 'No tables yet',
                      message:
                          'Set the room up in Floor, and the cards on the '
                          'tables will find them here.',
                    );
                  }
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      for (final e in byTable.entries)
                        ListTile(
                          leading: const Icon(Icons.table_restaurant_outlined),
                          title: Text('${e.value['table_name']}'),
                          subtitle: Text(
                            [
                              if (e.value['area'] != null) '${e.value['area']}',
                              '${e.value['seats']} seats',
                              // Two bills on one table is legitimate —
                              // a split leaves exactly that — so this
                              // is said, not prevented.
                              if ((bills[e.key] ?? 0) > 0)
                                '${bills[e.key]} open',
                            ].join('  ·  '),
                          ),
                          selected: e.key == '${widget.current}',
                          onTap: () => Navigator.of(context).pop(e.value),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
