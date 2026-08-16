import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// Every movement of one item, in order, with a running balance.
///
/// `docs/unreachable.md` carried this for a long time: `stock_movements`
/// could be written and never read, so "the shelf says 44 and the screen
/// says 47" had no answer anywhere in the app. 0155 added the report;
/// this is the screen that asks for it.
Future<void> showStockCard(BuildContext context, Item item) {
  return showDialog<void>(
    context: context,
    builder: (_) => _StockCardDialog(item: item),
  );
}

/// What the card closes on, said in words.
///
/// The average is derived rather than read: the movement carries
/// `average_cost_after` per warehouse, and a card spanning several of
/// them has no single one. Value over quantity is the only average that
/// is true of whatever was actually asked for.
String stockCardClosing(List<Map<String, dynamic>> rows, String uom) {
  if (rows.isEmpty) return 'Nothing has moved in this period.';
  final last = rows.last;
  final qty = Fmt.toDouble(last['balance_quantity']);
  final value = Fmt.toDouble(last['balance_value']);
  final closing = 'Closing ${Fmt.qty(qty)} $uom at ${Fmt.money(value)}';
  if (qty == 0) return '$closing.';
  return '$closing, an average of ${Fmt.money(value / qty)} each.';
}

/// The whole point of the screen, when it happens.
///
/// An unnarrowed card covers every movement in every warehouse, so its
/// closing quantity is what `items.quantity_on_hand` should be — the
/// same number by two routes, one summed here and one maintained by the
/// trigger on every movement. If they disagree, that is not a display
/// problem, and saying so beats letting somebody hunt for it.
///
/// Narrowed by date or warehouse the comparison is meaningless, so it is
/// not made. Returns null when there is nothing to report.
String? stockCardDisagreement({
  required List<Map<String, dynamic>> rows,
  required double onHand,
  required bool narrowed,
  required String uom,
}) {
  if (narrowed) return null;
  final closing = rows.isEmpty
      ? 0.0
      : Fmt.toDouble(rows.last['balance_quantity']);
  if ((closing - onHand).abs() < 0.00005) return null;
  return 'These movements add up to ${Fmt.qty(closing)} $uom, but the item '
      'record says ${Fmt.qty(onHand)}. One of the two is wrong and it is '
      'worth finding out which before anything is counted against it.';
}

class _StockCardDialog extends ConsumerStatefulWidget {
  const _StockCardDialog({required this.item});

  final Item item;

  @override
  ConsumerState<_StockCardDialog> createState() => _StockCardDialogState();
}

class _StockCardDialogState extends ConsumerState<_StockCardDialog> {
  DateTime? _from;
  DateTime? _to;
  String? _warehouseId;

  bool get _narrowed => _from != null || _to != null || _warehouseId != null;

  ({String itemId, DateTime? from, DateTime? to, String? warehouseId})
  get _query =>
      (itemId: widget.item.id, from: _from, to: _to, warehouseId: _warehouseId);

  Future<void> _pick(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : _to) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
      } else {
        _to = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final card = ref.watch(stockCardProvider(_query));
    final warehouses = ref.watch(warehousesProvider).valueOrNull ?? const [];

    return AlertDialog(
      title: Text('${item.name} · stock card'),
      content: SizedBox(
        width: 760,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${item.code} · every movement in order, with what the '
              'company held after each one.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    key: const ValueKey('stock-card-warehouse'),
                    value: _warehouseId,
                    isExpanded: true,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Warehouse',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Everywhere'),
                      ),
                      for (final w in warehouses)
                        DropdownMenuItem<String?>(
                          value: w['id'] as String,
                          child: Text('${w['code']} · ${w['name']}'),
                        ),
                    ],
                    onChanged: (v) => setState(() => _warehouseId = v),
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: _RangeButton(
                    key: const ValueKey('stock-card-from'),
                    label: 'From',
                    value: _from,
                    emptyLabel: 'The beginning',
                    onPick: () => _pick(true),
                    onClear: () => setState(() => _from = null),
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: _RangeButton(
                    key: const ValueKey('stock-card-to'),
                    label: 'To',
                    value: _to,
                    emptyLabel: 'Today',
                    onPick: () => _pick(false),
                    onClear: () => setState(() => _to = null),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            Flexible(
              child: AsyncView(
                value: card,
                onRetry: () => ref.invalidate(stockCardProvider(_query)),
                builder: (rows) {
                  if (rows.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: Space.lg),
                      child: Text(
                        'Nothing has moved for this item in this period. '
                        'Stock arrives on a bill, leaves on a delivery, and '
                        'is corrected by a stock take — none of those has '
                        'happened here yet.',
                      ),
                    );
                  }
                  final trouble = stockCardDisagreement(
                    rows: rows,
                    onHand: item.quantityOnHand,
                    narrowed: _narrowed,
                    uom: item.uomCode,
                  );
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _CardHeader(),
                        const Divider(height: 1),
                        for (final row in rows) _MovementRow(row: row),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.only(top: Space.sm),
                          child: Text(
                            stockCardClosing(rows, item.uomCode),
                            key: const ValueKey('stock-card-closing'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (trouble != null) ...[
                          const SizedBox(height: Space.sm),
                          Text(
                            trouble,
                            key: const ValueKey('stock-card-disagreement'),
                            style: TextStyle(color: context.colors.warning),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        children: [
          SizedBox(width: 84, child: Text('Date', style: style)),
          Expanded(flex: 3, child: Text('Movement', style: style)),
          Expanded(flex: 2, child: Text('Warehouse', style: style)),
          SizedBox(
            width: 80,
            child: Text('In / out', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 90,
            child: Text('Balance', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 110,
            child: Text('Value', style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    // The brought-forward line has no movement type because it is not a
    // movement — it is everything before the range, added up.
    final type = row['movement_type'] as String?;
    final opening = type == null;
    final qty = row['quantity'];
    final reference = row['reference'] as String?;
    final movementNo = row['movement_no'] as String?;

    return Padding(
      key: opening ? const ValueKey('stock-card-brought-forward') : null,
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              Fmt.date(Fmt.parseDate(row['movement_date'])),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              opening
                  ? 'Brought forward'
                  : [
                      Fmt.label(type),
                      if (reference != null && reference.isNotEmpty) reference,
                      if (movementNo != null) movementNo,
                    ].join(' · '),
              style: TextStyle(
                fontSize: 12,
                fontStyle: opening ? FontStyle.italic : null,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              (row['warehouse'] as String?) ?? '',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          SizedBox(
            width: 80,
            child: Text(
              qty == null ? '' : Fmt.qty(Fmt.toDouble(qty)),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                color: qty != null && Fmt.toDouble(qty) < 0
                    ? context.colors.danger
                    : null,
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              Fmt.qty(Fmt.toDouble(row['balance_quantity'])),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(
              Fmt.money(Fmt.toDouble(row['balance_value'])),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _RangeButton extends StatelessWidget {
  const _RangeButton({
    super.key,
    required this.label,
    required this.value,
    required this.emptyLabel,
    required this.onPick,
    required this.onClear,
  });

  final String label;
  final DateTime? value;
  final String emptyLabel;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onPick,
              child: Text(
                value == null ? emptyLabel : Fmt.date(value),
                style: TextStyle(
                  fontStyle: value == null ? FontStyle.italic : null,
                  color: value == null ? context.scheme.onSurfaceVariant : null,
                ),
              ),
            ),
          ),
          if (value != null)
            InkWell(onTap: onClear, child: const Icon(Icons.close, size: 16)),
        ],
      ),
    );
  }
}
