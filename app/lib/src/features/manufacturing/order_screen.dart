import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// One manufacturing order: what it will take, what is missing, and —
/// once it is posted — what it actually cost.
///
/// The two buttons are the whole feature. **Confirm** copies the recipe
/// onto the order, which is when "40 boards" becomes a fact about this
/// order rather than a fact about the recipe. **Post** moves the stock
/// and writes the journal in the same transaction: components out at the
/// weighted average they are carried at, conversion absorbed at each
/// work centre's rate, and the finished item in at the sum of the two.
///
/// A short run is costed proportionally, which is the difference between
/// a finished item carried at what it cost and one carried at twice
/// that.
class ManufacturingOrderScreen extends ConsumerWidget {
  const ManufacturingOrderScreen({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(manufacturingOrderProvider(orderId));

    return Scaffold(
      appBar: AppBar(
        title: Text(order.value?['order_no']?.toString() ?? 'Order'),
      ),
      body: AsyncView(
        value: order,
        onRetry: () => ref.invalidate(manufacturingOrderProvider(orderId)),
        builder: (mo) => _Body(orderId: orderId, mo: mo),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.orderId, required this.mo});

  final String orderId;
  final Map<String, dynamic> mo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canPost = ref.watch(canPostProvider);
    final status = mo['status']?.toString() ?? 'draft';
    final posted = mo['posted_at'] != null;
    final item = mo['items'] as Map<String, dynamic>? ?? const {};
    final components = ((mo['mo_components'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final operations =
        ((mo['mo_operations'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
          ..sort(
            (a, b) => (a['step_no'] as int).compareTo(b['step_no'] as int),
          );

    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${item['code'] ?? ''} · ${item['name'] ?? ''}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    StatusChip(status),
                  ],
                ),
                const SizedBox(height: Space.sm),
                FieldRow(
                  label: 'To make',
                  value:
                      '${Fmt.qty(Fmt.toDouble(mo['quantity']))} '
                      '${item['name'] ?? ''}',
                ),
                if (posted)
                  FieldRow(
                    label: 'Made',
                    value: Fmt.qty(Fmt.toDouble(mo['quantity_done'])),
                  ),
                FieldRow(
                  label: 'Warehouse',
                  value: (mo['warehouses'] as Map?)?['name']?.toString() ?? '',
                ),
                FieldRow(
                  label: 'Recipe',
                  value:
                      (mo['bills_of_materials'] as Map?)?['code']?.toString() ??
                      'none',
                ),
                if (mo['planned_start'] != null)
                  FieldRow(
                    label: 'Planned start',
                    value: Fmt.date(
                      DateTime.parse(mo['planned_start'].toString()),
                    ),
                  ),
                if ((mo['notes'] ?? '').toString().isNotEmpty)
                  FieldRow(label: 'Notes', value: mo['notes'].toString()),
              ],
            ),
          ),
        ),

        if (posted) ...[const SizedBox(height: Space.md), _CostCard(mo: mo)],

        if (status == 'draft') ...[
          const SizedBox(height: Space.md),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader(
                    'Not started',
                    subtitle: 'Confirm it to work out the parts',
                  ),
                  const Text(
                    'Confirming copies the recipe onto this order. It is a '
                    'snapshot on purpose: change the recipe tomorrow and '
                    'this order keeps the version it was costed against.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: Space.md),
                  Row(
                    children: [
                      FilledButton(
                        key: const ValueKey('mo-confirm'),
                        onPressed: canPost
                            ? () => _confirm(context, ref)
                            : null,
                        child: const Text('Confirm'),
                      ),
                      const SizedBox(width: Space.sm),
                      TextButton(
                        onPressed: canPost ? () => _cancel(context, ref) : null,
                        child: Text(
                          'Cancel the order',
                          style: TextStyle(color: context.colors.danger),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],

        if (components.isNotEmpty) ...[
          const SizedBox(height: Space.md),
          _ComponentsCard(
            orderId: orderId,
            components: components,
            posted: posted,
          ),
        ],

        if (operations.isNotEmpty) ...[
          const SizedBox(height: Space.md),
          _OperationsCard(
            orderId: orderId,
            operations: operations,
            posted: posted,
            editable: canPost && !posted,
          ),
        ],

        if (!posted && (status == 'confirmed' || status == 'in_progress')) ...[
          const SizedBox(height: Space.md),
          _PostCard(orderId: orderId, mo: mo, enabled: canPost),
        ],
      ],
    );
  }

  Future<void> _confirm(BuildContext context, WidgetRef ref) async {
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.confirmManufacturingOrder(orderId),
      successMessage: 'Confirmed',
    );
    if (ok) {
      ref.invalidate(manufacturingOrderProvider(orderId));
      ref.invalidate(manufacturingShortagesProvider(orderId));
      ref.invalidate(manufacturingOrdersProvider);
    }
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final sure = await confirm(
      context,
      title: 'Cancel this order?',
      message:
          'Nothing has moved yet, so nothing is undone. The order '
          'stays on the list as cancelled.',
      confirmLabel: 'Cancel it',
      destructive: true,
    );
    if (!sure || !context.mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.cancelManufacturingOrder(orderId),
      successMessage: 'Cancelled',
    );
    if (ok) {
      ref.invalidate(manufacturingOrderProvider(orderId));
      ref.invalidate(manufacturingOrdersProvider);
    }
  }
}

/// What it cost, once it is a fact rather than a plan.
class _CostCard extends StatelessWidget {
  const _CostCard({required this.mo});

  final Map<String, dynamic> mo;

  @override
  Widget build(BuildContext context) {
    final components = Fmt.toDouble(mo['component_cost']);
    final conversion = Fmt.toDouble(mo['conversion_cost']);
    final done = Fmt.toDouble(mo['quantity_done']);
    final total = components + conversion;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'What it cost',
              subtitle: 'Posted to the ledger and to stock together',
            ),
            FieldRow(label: 'Components', value: Fmt.money(components)),
            FieldRow(label: 'Conversion', value: Fmt.money(conversion)),
            const Divider(),
            FieldRow(label: 'Total', value: Fmt.money(total)),
            if (done > 0)
              FieldRow(label: 'Each', value: Fmt.money(total / done)),
            const SizedBox(height: Space.sm),
            // The sentence that explains why the labour is not counted
            // twice, where somebody looking at the numbers will read it.
            const Text(
              'The conversion cost is credited to Manufacturing Cost '
              'Absorbed, not charged again as an expense — the wages were '
              'already an expense when they were paid. Absorbing them '
              'into stock takes them back out of the profit and loss.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// The parts, and whether they are actually there.
class _ComponentsCard extends ConsumerWidget {
  const _ComponentsCard({
    required this.orderId,
    required this.components,
    required this.posted,
  });

  final String orderId;
  final List<Map<String, dynamic>> components;
  final bool posted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shortages = ref.watch(manufacturingShortagesProvider(orderId));
    final short = <String, double>{
      for (final s in shortages.value ?? const <Map<String, dynamic>>[])
        s['item_id'] as String: Fmt.toDouble(s['quantity_short']),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Parts',
              subtitle: posted
                  ? 'What was issued, and what it was carried at'
                  : 'What this order needs, in this warehouse',
            ),
            for (final c in components)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (c['items'] as Map?)?['code']?.toString() ?? '',
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                          Text(
                            (c['items'] as Map?)?['name']?.toString() ?? '',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    // Only shown while it still matters. Once the order
                    // is posted the parts have gone, and a shortage
                    // warning about stock that already moved is noise.
                    if (!posted && (short[c['item_id'] as String] ?? 0) > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.warning_amber_outlined,
                              size: 16,
                              color: context.colors.warning,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${Fmt.qty(short[c['item_id'] as String]!)} short',
                              style: TextStyle(
                                fontSize: 12,
                                color: context.colors.warning,
                              ),
                            ),
                          ],
                        ),
                      ),
                    Text(
                      posted
                          ? '${Fmt.qty(Fmt.toDouble(c['quantity_issued']))}  '
                                '·  ${Fmt.money(Fmt.toDouble(c['total_cost']))}'
                          : Fmt.qty(Fmt.toDouble(c['quantity_required'])),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            if (!posted && short.values.any((v) => v > 0)) ...[
              const SizedBox(height: Space.sm),
              const Text(
                'Short parts are counted in this order\'s warehouse only. '
                'Stock sitting in another one is a transfer somebody has '
                'to make, not stock this order can consume.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The steps, and the time booked against them.
class _OperationsCard extends ConsumerWidget {
  const _OperationsCard({
    required this.orderId,
    required this.operations,
    required this.posted,
    required this.editable,
  });

  final String orderId;
  final List<Map<String, dynamic>> operations;
  final bool posted;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Steps',
              subtitle: 'Time booked here is what the order absorbs',
            ),
            for (final o in operations)
              InkWell(
                onTap: editable ? () => _book(context, ref, o) : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          '${o['step_no']}.',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(o['name']?.toString() ?? ''),
                            Text(
                              (o['work_centres'] as Map?)?['name']
                                      ?.toString() ??
                                  '',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        _minutes(o),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (editable)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.edit_outlined, size: 16),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: Space.sm),
            Text(
              posted
                  ? 'Where no time was booked the plan was used, because a '
                        'shop that has not booked its hours still has to '
                        'cost its output.'
                  : 'Leave a step at zero and the plan stands in when the '
                        'order is posted.',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  String _minutes(Map<String, dynamic> o) {
    final actual = Fmt.toDouble(o['actual_minutes']);
    final planned = Fmt.toDouble(o['planned_minutes']);
    if (actual > 0) return '${Fmt.qty(actual)} min';
    return '${Fmt.qty(planned)} min planned';
  }

  Future<void> _book(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> o,
  ) async {
    final controller = TextEditingController(
      text: Fmt.toDouble(o['actual_minutes']) > 0
          ? Fmt.toDouble(o['actual_minutes']).toString()
          : '',
    );
    final minutes = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(o['name']?.toString() ?? 'Step'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Minutes actually taken',
            helperText:
                '${Fmt.qty(Fmt.toDouble(o['planned_minutes']))} planned',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              ctx,
            ).pop(double.tryParse(controller.text.trim()) ?? 0),
            child: const Text('Book'),
          ),
        ],
      ),
    );
    if (minutes == null || !context.mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .bookOperationMinutes(o['id'] as String, minutes),
      successMessage: 'Time booked',
    );
    if (ok) ref.invalidate(manufacturingOrderProvider(orderId));
  }
}

/// Posting: the moment the stock and the ledger both move.
class _PostCard extends ConsumerStatefulWidget {
  const _PostCard({
    required this.orderId,
    required this.mo,
    required this.enabled,
  });

  final String orderId;
  final Map<String, dynamic> mo;
  final bool enabled;

  @override
  ConsumerState<_PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<_PostCard> {
  late final TextEditingController _done = TextEditingController(
    text: Fmt.toDouble(widget.mo['quantity']).toString(),
  );
  bool _busy = false;

  @override
  void dispose() {
    _done.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ordered = Fmt.toDouble(widget.mo['quantity']);
    final done = double.tryParse(_done.text.trim()) ?? 0;
    final shortages = ref.watch(manufacturingShortagesProvider(widget.orderId));
    final anyShort = (shortages.value ?? const <Map<String, dynamic>>[]).any(
      (s) => Fmt.toDouble(s['quantity_short']) > 0,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Record production',
              subtitle: 'Takes the parts off and puts the finished item on',
            ),
            Row(
              children: [
                SizedBox(
                  width: 140,
                  child: TextField(
                    key: const ValueKey('mo-done'),
                    controller: _done,
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'How many'),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Text(
                    done > 0 && done < ordered
                        ? 'A short run. The parts and the time are costed at '
                              '${Fmt.qty(done / ordered * 100)}% of the order, '
                              'so each one still costs what one costs.'
                        : '$ordered were ordered.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            if (anyShort) ...[
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    size: 16,
                    color: context.colors.warning,
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Some parts are short in this warehouse. Posting will '
                      'take the stock negative, which is allowed but is a '
                      'sign something has not been received yet.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: Space.md),
            FilledButton(
              key: const ValueKey('mo-post'),
              onPressed: widget.enabled && done > 0 && !_busy ? _post : null,
              child: const Text('Post'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _post() async {
    final ordered = Fmt.toDouble(widget.mo['quantity']);
    final done = double.tryParse(_done.text.trim()) ?? 0;

    final sure = await confirm(
      context,
      title: 'Post this order?',
      message: done < ordered
          ? 'Records ${Fmt.qty(done)} of ${Fmt.qty(ordered)} made. The '
                'parts come off stock and the journal is written; neither '
                'can be undone from here.'
          : 'The parts come off stock and the journal is written. Neither '
                'can be undone from here.',
      confirmLabel: 'Post',
    );
    if (!sure || !mounted) return;

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .postManufacturingOrder(widget.orderId, quantityDone: done),
      successMessage: 'Posted',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(manufacturingOrderProvider(widget.orderId));
      ref.invalidate(manufacturingOrdersProvider);
      ref.invalidate(itemsProvider);
    }
  }
}
