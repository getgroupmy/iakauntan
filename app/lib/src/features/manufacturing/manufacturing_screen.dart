import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../stock/new_warehouse_dialog.dart';
import 'bom_dialog.dart';
import 'work_centre_dialog.dart';

/// Making things, in the order somebody sets them up: what a thing is
/// made of, where the work happens, and orders to make some.
///
/// The arithmetic is all in the database. Confirming an order copies the
/// recipe onto it — a snapshot, because the recipe can change tomorrow
/// and this order was costed against today's — and posting moves the
/// stock and writes the journal in one transaction. Nothing on this
/// screen computes a cost, which is the only way the stock report and
/// the ledger can be relied on to agree.
class ManufacturingScreen extends ConsumerStatefulWidget {
  const ManufacturingScreen({super.key});

  @override
  ConsumerState<ManufacturingScreen> createState() =>
      _ManufacturingScreenState();
}

class _ManufacturingScreenState extends ConsumerState<ManufacturingScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  bool _openOnly = true;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(canPostProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manufacturing'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Orders'),
            Tab(text: 'Recipes'),
            Tab(text: 'Work centres'),
          ],
        ),
      ),
      floatingActionButton: canEdit
          ? AnimatedBuilder(
              animation: _tabs,
              builder: (context, _) => FloatingActionButton.extended(
                key: const ValueKey('mfg-new'),
                onPressed: () => _new(_tabs.index),
                icon: const Icon(Icons.add),
                label: Text(switch (_tabs.index) {
                  0 => 'New order',
                  1 => 'New recipe',
                  _ => 'New work centre',
                }),
              ),
            )
          : null,
      body: TabBarView(
        controller: _tabs,
        children: [
          _Orders(
            openOnly: _openOnly,
            onFilter: (v) => setState(() => _openOnly = v),
          ),
          const _Recipes(),
          const _WorkCentres(),
        ],
      ),
    );
  }

  Future<void> _new(int tab) async {
    switch (tab) {
      case 0:
        final id = await showDialog<String>(
          context: context,
          builder: (_) => const NewOrderDialog(),
        );
        if (id != null && mounted) {
          ref.invalidate(manufacturingOrdersProvider);
          if (mounted) context.push('/manufacturing/$id');
        }
      case 1:
        final saved = await showDialog<bool>(
          context: context,
          builder: (_) => const BomDialog(),
        );
        if (saved == true) ref.invalidate(bomsProvider);
      default:
        final saved = await showDialog<bool>(
          context: context,
          builder: (_) => const WorkCentreDialog(),
        );
        if (saved == true) ref.invalidate(workCentresProvider);
    }
  }
}

// ---------------------------------------------------------------------
// Orders
// ---------------------------------------------------------------------
class _Orders extends ConsumerWidget {
  const _Orders({required this.openOnly, required this.onFilter});

  final bool openOnly;
  final ValueChanged<bool> onFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(manufacturingOrdersProvider(openOnly));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
          child: Row(
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, label: Text('Still to make')),
                  ButtonSegment(value: false, label: Text('Everything')),
                ],
                selected: {openOnly},
                onSelectionChanged: (v) => onFilter(v.first),
              ),
            ],
          ),
        ),
        Expanded(
          child: AsyncView(
            value: orders,
            onRetry: () => ref.invalidate(manufacturingOrdersProvider),
            builder: (list) => list.isEmpty
                ? EmptyState(
                    icon: Icons.precision_manufacturing_outlined,
                    title: openOnly
                        ? 'Nothing on the line'
                        : 'No manufacturing orders yet',
                    message:
                        'An order says what to make and how many. '
                        'Confirming it works out the parts; posting it '
                        'takes them off the shelf and puts the finished '
                        'thing on, at what it cost to make.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(Space.lg),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final o = list[i];
                      final item =
                          o['items'] as Map<String, dynamic>? ?? const {};
                      final done = Fmt.toDouble(o['quantity_done']);
                      final qty = Fmt.toDouble(o['quantity']);
                      final posted = o['posted_at'] != null;
                      return ListTile(
                        key: ValueKey('mo-${o['order_no']}'),
                        dense: true,
                        onTap: () => context.push('/manufacturing/${o['id']}'),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${o['order_no']}  ·  ${item['code'] ?? ''}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            StatusChip(
                              o['status']?.toString() ?? 'draft',
                              compact: true,
                            ),
                          ],
                        ),
                        subtitle: Text(
                          [
                            item['name'] ?? '',
                            posted
                                ? '${Fmt.qty(done)} of ${Fmt.qty(qty)} made'
                                : '${Fmt.qty(qty)} to make',
                            if (posted)
                              'cost ${Fmt.money(Fmt.toDouble(o['component_cost']) + Fmt.toDouble(o['conversion_cost']))}',
                          ].where((e) => '$e'.isNotEmpty).join('  ·  '),
                        ),
                        trailing: const Icon(Icons.chevron_right, size: 18),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Recipes
// ---------------------------------------------------------------------
class _Recipes extends ConsumerWidget {
  const _Recipes();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boms = ref.watch(bomsProvider);
    final canEdit = ref.watch(canPostProvider);

    return AsyncView(
      value: boms,
      onRetry: () => ref.invalidate(bomsProvider),
      builder: (list) => list.isEmpty
          ? const EmptyState(
              icon: Icons.account_tree_outlined,
              title: 'No recipes yet',
              message:
                  'A bill of materials is what a thing is made of, '
                  'and the steps that turn the parts into it. Everything '
                  'else here is built on one.',
            )
          : ListView.separated(
              padding: const EdgeInsets.all(Space.lg),
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final b = list[i];
                final item = b['items'] as Map<String, dynamic>? ?? const {};
                final per = Fmt.toDouble(b['output_quantity']);
                return ListTile(
                  key: ValueKey('bom-${b['code']}'),
                  dense: true,
                  onTap: canEdit
                      ? () async {
                          final saved = await showDialog<bool>(
                            context: context,
                            builder: (_) => BomDialog(bomId: b['id'] as String),
                          );
                          if (saved == true) ref.invalidate(bomsProvider);
                        }
                      : null,
                  title: Text(
                    '${b['code']}  ·  ${item['code'] ?? ''}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    [
                      b['name'] ?? item['name'] ?? '',
                      // Said out loud, because a recipe written per 100 and
                      // read as per 1 is out by two orders of magnitude.
                      'makes ${Fmt.qty(per)} at a time',
                    ].where((e) => '$e'.isNotEmpty).join('  ·  '),
                  ),
                  trailing: canEdit
                      ? const Icon(Icons.chevron_right, size: 18)
                      : null,
                );
              },
            ),
    );
  }
}

// ---------------------------------------------------------------------
// Work centres
// ---------------------------------------------------------------------
class _WorkCentres extends ConsumerWidget {
  const _WorkCentres();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final centres = ref.watch(workCentresProvider);
    final canEdit = ref.watch(canPostProvider);

    return AsyncView(
      value: centres,
      onRetry: () => ref.invalidate(workCentresProvider),
      builder: (list) => list.isEmpty
          ? const EmptyState(
              icon: Icons.factory_outlined,
              title: 'No work centres yet',
              message:
                  'A work centre is where a step happens and what an '
                  'hour of it costs — labour and overhead together. One '
                  'honest rate beats two invented ones.',
            )
          : ListView.separated(
              padding: const EdgeInsets.all(Space.lg),
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final w = list[i];
                return ListTile(
                  key: ValueKey('wc-${w['code']}'),
                  dense: true,
                  onTap: canEdit
                      ? () async {
                          final saved = await showDialog<bool>(
                            context: context,
                            builder: (_) => WorkCentreDialog(existing: w),
                          );
                          if (saved == true) {
                            ref.invalidate(workCentresProvider);
                          }
                        }
                      : null,
                  title: Text(
                    '${w['code']}  ·  ${w['name']}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${Fmt.money(Fmt.toDouble(w['cost_per_hour']))} an hour  '
                    '·  ${Fmt.qty(Fmt.toDouble(w['capacity_hours_per_day']))} hours a day',
                  ),
                  trailing: canEdit
                      ? const Icon(Icons.chevron_right, size: 18)
                      : null,
                );
              },
            ),
    );
  }
}

// ---------------------------------------------------------------------
// A new order
// ---------------------------------------------------------------------
class NewOrderDialog extends ConsumerStatefulWidget {
  const NewOrderDialog({super.key});

  @override
  ConsumerState<NewOrderDialog> createState() => _NewOrderDialogState();
}

class _NewOrderDialogState extends ConsumerState<NewOrderDialog> {
  final _quantity = TextEditingController(text: '1');
  final _notes = TextEditingController();
  String? _bomId;
  String? _warehouseId;
  DateTime? _start;
  bool _saving = false;

  @override
  void dispose() {
    _quantity.dispose();
    _notes.dispose();
    super.dispose();
  }

  double get _qty => double.tryParse(_quantity.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final boms = ref.watch(bomsProvider).value ?? const [];
    final warehouses = ref.watch(warehousesProvider).value ?? const [];

    // A warehouse nobody chose is the default one, which is what a
    // company with a single store has and never thinks about.
    _warehouseId ??=
        (warehouses.firstWhere(
              (w) => w['is_default'] == true,
              orElse: () => warehouses.isEmpty ? const {} : warehouses.first,
            )['id'])
            as String?;

    return AlertDialog(
      title: const Text('New manufacturing order'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (boms.isEmpty)
                const Text(
                  'There are no recipes yet. A manufacturing order is an '
                  'instruction to follow one, so write the recipe first.',
                  style: TextStyle(fontSize: 13),
                )
              else ...[
                SearchablePicker<String>(
                  key: const ValueKey('mo-bom'),
                  options: [
                    for (final b in boms)
                      PickerOption<String>(
                        value: b['id'] as String,
                        label: '${(b['items'] as Map?)?['name'] ?? ''}',
                        sublabel: '${b['code']}',
                        keywords: ['${b['code']}'],
                      ),
                  ],
                  value: _bomId,
                  label: 'Make',
                  enabled: !_saving,
                  onChanged: (v) => setState(() => _bomId = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('mo-quantity'),
                  controller: _quantity,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'How many',
                    helperText: 'Of the finished item, not of the recipe',
                  ),
                ),
                const SizedBox(height: 12),
                if (warehouses.length > 1)
                  SearchablePicker<String>(
                    options: warehouseOptions(warehouses),
                    value: _warehouseId,
                    label: 'From and into',
                    helperText: 'Parts come off here and the finished '
                        'item goes back here',
                    enabled: !_saving,
                    onChanged: (v) => setState(() => _warehouseId = v),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _start == null
                            ? 'No planned start'
                            : 'Starts ${Fmt.date(_start!)}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    TextButton(
                      onPressed: _saving ? null : _pickStart,
                      child: Text(_start == null ? 'Plan a start' : 'Change'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _notes,
                  enabled: !_saving,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              _bomId != null && _qty > 0 && _warehouseId != null && !_saving
              ? _save
              : null,
          child: const Text('Create'),
        ),
      ],
    );
  }

  Future<void> _pickStart() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _start ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _save() async {
    final boms = ref.read(bomsProvider).value ?? const [];
    final bom = boms.firstWhere((b) => b['id'] == _bomId);

    setState(() => _saving = true);
    String? id;
    final ok = await runWithFeedback(
      context,
      action: () async {
        id = await ref
            .read(repoProvider)!
            .createManufacturingOrder(
              bomId: _bomId!,
              itemId: bom['item_id'] as String,
              warehouseId: _warehouseId!,
              quantity: _qty,
              plannedStart: _start,
              notes: _notes.text,
            );
      },
      successMessage: 'Order created',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(id);
  }
}
