import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'new_warehouse_dialog.dart';

/// Counting the shelf and telling the books about it.
///
/// Opens on what the system thinks it holds, with a box beside each item
/// for what was actually found. Only the lines that differ become an
/// adjustment — a stock take where everything agrees is a stock take
/// with nothing to post, and the database says so rather than writing an
/// empty journal.
class StockTakeScreen extends ConsumerStatefulWidget {
  const StockTakeScreen({super.key});

  @override
  ConsumerState<StockTakeScreen> createState() => _StockTakeScreenState();
}

class _StockTakeScreenState extends ConsumerState<StockTakeScreen> {
  final _reason = TextEditingController(text: 'Stock take');

  String? _warehouseId;
  DateTime _date = DateTime.now();

  /// Counted quantity per item, seeded from the system figure so an
  /// untouched line contributes nothing.
  final Map<String, double> _counted = {};
  bool _seeded = false;
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final warehouses = ref.watch(warehousesProvider).value ?? const [];
    final onHand = ref.watch(stockOnHandProvider(_warehouseId));
    final canPost = ref.watch(canPostProvider);

    if (_warehouseId == null && warehouses.isNotEmpty) {
      _warehouseId = warehouses.first['id'] as String;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock take'),
        actions: [
          if (canPost)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FilledButton.icon(
                onPressed: _saving ? null : _post,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Post count'),
              ),
            ),
        ],
      ),
      body: AsyncView(
        value: onHand,
        onRetry: () => ref.invalidate(stockOnHandProvider),
        builder: (items) {
          if (!_seeded && items.isNotEmpty) {
            _seeded = true;
            for (final i in items) {
              _counted[i['item_id'] as String] = Fmt.toDouble(i['quantity']);
            }
          }

          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.inventory_outlined,
              title: 'Nothing to count',
              message: 'Only items that track inventory appear here.',
            );
          }

          final differences = [
            for (final i in items)
              if ((_counted[i['item_id'] as String] ?? 0) !=
                  Fmt.toDouble(i['quantity']))
                i,
          ];

          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 900,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                    warehouses: warehouses,
                    warehouseId: _warehouseId,
                    date: _date,
                    reason: _reason,
                    onWarehouse: (v) => setState(() {
                      _warehouseId = v;
                      _seeded = false;
                      _counted.clear();
                    }),
                    onNewWarehouse: (typed) async {
                      final created =
                          await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (_) =>
                            NewWarehouseDialog(seedName: typed),
                      );
                      if (created == null || !mounted) return null;
                      // A shelf with nothing counted against it yet, so
                      // the seeding starts again from an empty count.
                      setState(() {
                        _seeded = false;
                        _counted.clear();
                      });
                      return '${created['id']}';
                    },
                    onDate: (d) => setState(() => _date = d),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SectionHeader(
                            'Count',
                            subtitle: differences.isEmpty
                                ? 'Nothing differs from the system yet'
                                : '${differences.length} of ${items.length} '
                                    'differ',
                          ),
                          for (final item in items)
                            _CountRow(
                              item: item,
                              counted:
                                  _counted[item['item_id'] as String] ?? 0,
                              onChanged: (v) => setState(() =>
                                  _counted[item['item_id'] as String] = v),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _post() async {
    final items = ref.read(stockOnHandProvider(_warehouseId)).valueOrNull;
    if (items == null) return;

    final lines = [
      for (final i in items)
        (
          itemId: i['item_id'] as String,
          system: Fmt.toDouble(i['quantity']),
          counted: _counted[i['item_id'] as String] ?? 0,
        ),
    ];
    final changed = lines.where((l) => l.counted != l.system).toList();

    if (changed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Every line matches what the system holds — '
            'there is nothing to post.'),
      ));
      return;
    }

    final ok = await confirm(
      context,
      title: 'Post the count?',
      message: '${changed.length} item${changed.length == 1 ? '' : 's'} will '
          'be adjusted and a journal posted at the current average cost.',
      confirmLabel: 'Post',
    );
    if (!ok || !mounted) return;

    setState(() => _saving = true);
    final repo = ref.read(repoProvider)!;
    final done = await runWithFeedback(
      context,
      action: () async {
        final warehouse = _warehouseId ?? await repo.ensureDefaultWarehouse();
        final id = await repo.saveStockAdjustment(
          warehouseId: warehouse,
          date: _date,
          reason: _reason.text.trim().isEmpty ? 'Stock take' : _reason.text.trim(),
          lines: lines,
        );
        await repo.postStockAdjustment(id);
      },
      successMessage: 'Count posted',
      pendingMessage: 'Posting…',
    );

    if (mounted) setState(() => _saving = false);
    if (done && mounted) {
      setState(() {
        _seeded = false;
        _counted.clear();
      });
      ref.invalidate(stockOnHandProvider);
      ref.invalidate(stockAdjustmentsProvider);
      refreshLedgerData(ref);
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.warehouses,
    required this.warehouseId,
    required this.date,
    required this.reason,
    required this.onWarehouse,
    required this.onNewWarehouse,
    required this.onDate,
  });

  final List<Map<String, dynamic>> warehouses;
  final String? warehouseId;
  final DateTime date;
  final TextEditingController reason;
  final ValueChanged<String> onWarehouse;

  /// Add one from the box, and select it.
  final Future<String?> Function(String typed) onNewWarehouse;
  final ValueChanged<DateTime> onDate;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;

    final fields = <Widget>[
      SearchablePicker<String>(
        options: warehouseOptions(warehouses),
        value: warehouseId,
        label: 'Warehouse',
        createLabel: 'Add warehouse',
        // Reversing what this said an hour ago. I argued a count is of
        // a shelf that already exists, so a warehouse created here
        // would hold nothing. That is the wrong way round: a shop that
        // opened last week has a shelf full of stock and no warehouse
        // on file, and the FIRST thing anybody does with it is count
        // it in.
        onCreate: onNewWarehouse,
        onChanged: (v) => v == null ? null : onWarehouse(v),
      ),
      InkWell(
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: date,
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
          );
          if (picked != null) onDate(picked);
        },
        child: InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Count date',
            suffixIcon: Icon(Icons.calendar_today, size: 18),
          ),
          child: Text(Fmt.date(date)),
        ),
      ),
      TextField(
        controller: reason,
        decoration: const InputDecoration(labelText: 'Reason'),
      ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: narrow
            ? Column(
                children: [
                  for (final f in fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: f,
                    ),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: fields[0]),
                  const SizedBox(width: 14),
                  Expanded(child: fields[1]),
                  const SizedBox(width: 14),
                  Expanded(flex: 2, child: fields[2]),
                ],
              ),
      ),
    );
  }
}

class _CountRow extends StatefulWidget {
  const _CountRow({
    required this.item,
    required this.counted,
    required this.onChanged,
  });

  final Map<String, dynamic> item;
  final double counted;
  final ValueChanged<double> onChanged;

  @override
  State<_CountRow> createState() => _CountRowState();
}

class _CountRowState extends State<_CountRow> {
  late final TextEditingController _controller =
      TextEditingController(text: Fmt.qty(widget.counted));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final system = Fmt.toDouble(widget.item['quantity']);
    final difference = widget.counted - system;
    final cost = Fmt.toDouble(widget.item['average_cost']);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${widget.item['code']} · ${widget.item['name']}'),
                Text(
                  'system ${Fmt.qty(system)} · '
                  'at ${Fmt.money(cost)} each',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _controller,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true),
              onChanged: (v) => widget.onChanged(double.tryParse(v) ?? 0),
            ),
          ),
          SizedBox(
            width: 110,
            child: Padding(
              padding: const EdgeInsets.only(top: 10, left: 8),
              child: Text(
                difference == 0
                    ? '—'
                    : '${difference > 0 ? '+' : ''}${Fmt.qty(difference)}',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: difference == 0
                      ? null
                      : (difference > 0
                          ? context.colors.success
                          : context.colors.danger),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
