import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// The forecasting methods live in an extension on Repo, and a Dart
// extension is only in scope where its declaring library is imported.
import '../../data/models.dart';
import '../../data/repository.dart';
import 'forecast_settings_dialog.dart';
import 'item_params_dialog.dart';

/// PostgREST hands numerics back as strings so nothing is lost on the
/// way through JSON. Parsed in one place, because three copies of this
/// is how one of them ends up returning null and a quantity renders as
/// a dash.
double _num(Object? v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;

/// Replenishment.
///
/// The screen opens on what to buy, not on the whole catalogue. Every
/// other view of stock in this app already lists every item; the reason
/// to come here is the short list of things that need a decision today.
///
/// Two things it deliberately does not hide. The items the run skipped
/// for want of history are one segment away rather than absent, because
/// an item missing from a replenishment report is one nobody notices
/// they stopped ordering. And the working behind each number is one tap
/// away, because "order 78" is not something a buyer should have to
/// take on faith — the lead time, where it was measured from, the
/// buffer and the position are all on the sheet.
class ForecastScreen extends ConsumerStatefulWidget {
  const ForecastScreen({super.key});

  @override
  ConsumerState<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends ConsumerState<ForecastScreen> {
  String _view = 'order';

  /// Null is the company as a whole, not "no filter". A company that
  /// transfers stock freely forecasts centrally; one whose branches each
  /// hold their own forecasts per location. Both are legitimate, which
  /// is why this is a choice rather than a default.
  String? _warehouse;

  void _refresh() {
    ref
      ..invalidate(latestForecastRunProvider(_warehouse))
      ..invalidate(forecastSuggestionsProvider(_warehouse));
  }

  Future<void> _run() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      pendingMessage: 'Forecasting…',
      successMessage: 'Forecast run',
      action: () => repo.runForecast(warehouseId: _warehouse),
    );
    if (ok) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final run = ref.watch(latestForecastRunProvider(_warehouse));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Replenishment'),
        actions: [
          _WarehousePicker(
            selected: _warehouse,
            onChanged: (id) => setState(() => _warehouse = id),
          ),
          IconButton(
            tooltip: 'Run a forecast now',
            icon: const Icon(Icons.play_arrow_outlined),
            onPressed: _run,
          ),
          IconButton(
            tooltip: 'Forecast settings',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              final saved = await showForecastSettings(context, ref);
              if (saved) _refresh();
            },
          ),
        ],
      ),
      body: AsyncView<Map<String, dynamic>?>(
        value: run,
        onRetry: _refresh,
        // A run is a summary line and then a row to each item it
        // forecast. Whether there IS a run changes what is drawn; how a
        // run is drawn does not change.
        skeleton: const Padding(
          padding: EdgeInsets.all(Space.lg),
          child: CardRowsSkeleton(rows: 7, leading: false, trailing: 2),
        ),
        builder: (r) {
          if (r == null) {
            return EmptyState(
              icon: Icons.insights_outlined,
              title: _warehouse == null
                  ? 'No forecast yet'
                  : 'No forecast yet for this location',
              message:
                  'A run reads the last year of deliveries, measures how '
                  'long each supplier actually takes, and works out what '
                  'to order. Nothing is bought until you say so.',
              action: FilledButton.icon(
                onPressed: _run,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Run a forecast'),
              ),
            );
          }
          return _Loaded(
            run: r,
            view: _view,
            warehouseId: _warehouse,
            onView: (v) => setState(() => _view = v),
            onChanged: _refresh,
          );
        },
      ),
    );
  }
}

class _Loaded extends StatelessWidget {
  const _Loaded({
    required this.run,
    required this.view,
    required this.warehouseId,
    required this.onView,
    required this.onChanged,
  });

  final Map<String, dynamic> run;
  final String view;
  final String? warehouseId;
  final ValueChanged<String> onView;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    // The header and the switch are fixed and the list scrolls under
    // them. Nesting the list inside a scrolling column instead would
    // hand every child unbounded height, and the first spinner or empty
    // state — both of which centre themselves — would overflow before
    // anybody saw a row.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageBody(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RunHeader(run: run),
              const SizedBox(height: Space.lg),
              Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: 'order',
                        label: Text(
                          'To order (${run['items_suggested'] ?? 0})',
                        ),
                      ),
                      const ButtonSegment(
                        value: 'everything',
                        label: Text('Everything'),
                      ),
                      ButtonSegment(
                        value: 'skipped',
                        label: Text('Skipped (${run['items_skipped'] ?? 0})'),
                      ),
                    ],
                    selected: {view},
                    onSelectionChanged: (s) => onView(s.first),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: PageBody(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.md,
              Space.lg,
              Space.lg,
            ),
            child: view == 'order'
                ? _Suggestions(
                    warehouseId: warehouseId,
                    onChanged: onChanged,
                  )
                : _AllLines(
                    runId: run['id'] as String,
                    skippedOnly: view == 'skipped',
                  ),
          ),
        ),
      ],
    );
  }
}

/// What the run was asked for, alongside what it found.
///
/// The parameters are on the card rather than buried in settings because
/// a suggestion is only defensible if the service level and the horizon
/// that produced it are visible beside it.
class _RunHeader extends StatelessWidget {
  const _RunHeader({required this.run});

  final Map<String, dynamic> run;

  @override
  Widget build(BuildContext context) {
    final asOf = DateTime.tryParse((run['as_of_date'] ?? '') as String);
    final service = double.tryParse('${run['service_level'] ?? 0}') ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'As at ${Fmt.longDate(asOf)}',
              subtitle:
                  '${Fmt.label('${run['bucket']}')} buckets · '
                  '${run['horizon_buckets']} ahead · '
                  '${run['history_days']} days of history · '
                  '${(service * 100).toStringAsFixed(0)}% service level',
            ),
            Wrap(
              spacing: Space.xl,
              runSpacing: Space.sm,
              children: [
                _Count('Considered', run['items_considered']),
                _Count('Forecast', run['items_forecast']),
                _Count('Skipped', run['items_skipped']),
                _Count('To order', run['items_suggested']),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.label, this.value);

  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${value ?? 0}', style: Theme.of(context).textTheme.titleLarge),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _Suggestions extends ConsumerWidget {
  const _Suggestions({required this.warehouseId, required this.onChanged});

  final String? warehouseId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggestions = ref.watch(forecastSuggestionsProvider(warehouseId));

    return AsyncView<List<Map<String, dynamic>>>(
      value: suggestions,
      onRetry: () => ref.invalidate(forecastSuggestionsProvider(warehouseId)),
      skeleton: const ListSkeleton(rows: 6),
      builder: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.inventory_2_outlined,
            title: 'Nothing to order',
            message:
                'Every stocked item has enough on hand or on the way to '
                'cover the lead time and the horizon.',
          );
        }
        final outstanding = list
            .where((s) => _num(s['outstanding']) > 0)
            .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (outstanding.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.md),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.shopping_cart_checkout),
                    label: Text(
                      'Create draft orders (${outstanding.length} item'
                      '${outstanding.length == 1 ? '' : 's'})',
                    ),
                    onPressed: () => _createOrders(context, ref),
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) => _SuggestionRow(
                  list[i],
                  warehouseId: warehouseId,
                  onChanged: onChanged,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _createOrders(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    List<Map<String, dynamic>> result = const [];
    final ok = await runWithFeedback(
      context,
      pendingMessage: 'Raising orders…',
      // The result is the confirmation, and it is shown below.
      successMessage: null,
      action: () async {
        result = await repo.createPurchaseOrdersFromSuggestions(
          warehouseId: warehouseId,
        );
      },
    );
    if (!ok || !context.mounted) return;

    ref.invalidate(forecastSuggestionsProvider(warehouseId));
    onChanged();
    await showDialog<void>(
      context: context,
      builder: (ctx) => _OrdersRaised(result),
    );
  }

}

/// What came back, including the rows that are not orders.
///
/// A row with no document is the function telling you it could not act:
/// an item with no supplier, or a supplier whose currency has no rate on
/// file. Showing only the successes would leave those items quietly
/// unordered.
class _OrdersRaised extends StatelessWidget {
  const _OrdersRaised(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final raised = rows.where((r) => r['document_id'] != null).toList();
    final notes = rows.where((r) => r['document_id'] == null).toList();

    return AlertDialog(
      title: Text(
        raised.isEmpty
            ? 'No orders raised'
            : '${raised.length} draft order${raised.length == 1 ? '' : 's'}',
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in raised)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.description_outlined),
                title: Text('${r['doc_no']} · ${r['supplier_name']}'),
                subtitle: Text(
                  '${r['line_count']} line'
                  '${r['line_count'] == 1 ? '' : 's'}, '
                  '${Fmt.qty(double.tryParse('${r['total_quantity']}'))} units',
                ),
              ),
            for (final n in notes) ...[
              const SizedBox(height: Space.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    size: 18,
                    color: context.colors.warning,
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(child: Text('${n['note']}')),
                ],
              ),
            ],
            if (raised.isNotEmpty) ...[
              const SizedBox(height: Space.md),
              Text(
                'They are drafts. Nothing has been sent to a supplier — '
                'open Purchases to check and approve them.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow(
    this.s, {
    required this.warehouseId,
    required this.onChanged,
  });

  final Map<String, dynamic> s;
  final String? warehouseId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final outstanding = _num(s['outstanding']);
    final drafted = _num(s['already_drafted']);
    final cover = s['days_cover'];
    final supplier = s['supplier_name'] as String?;

    return Card(
      margin: const EdgeInsets.only(bottom: Space.sm),
      child: ListTile(
        onTap: () => showForecastLineSheet(
          context,
          s,
          warehouseId: warehouseId,
          onChanged: onChanged,
        ),
        title: Text('${s['item_code']} · ${s['item_name']}'),
        subtitle: Text(
          [
            if (supplier != null) supplier else 'No supplier set',
            if (cover != null)
              '${Fmt.plain(double.tryParse('$cover'))} days of cover',
            'have ${Fmt.qty(_num(s['available']))}',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: _StateChip('${s['state']}'),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              outstanding > 0
                  ? 'order ${Fmt.qty(outstanding)}'
                  : 'ordered ${Fmt.qty(drafted)}',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: outstanding > 0 ? null : context.colors.success,
              ),
            ),
            if (drafted > 0 && outstanding > 0)
              Text(
                '${Fmt.qty(drafted)} already drafted',
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
      ),
    );
  }

}

/// Every line of the run, or only the ones it could not forecast.
class _AllLines extends ConsumerWidget {
  const _AllLines({required this.runId, required this.skippedOnly});

  final String runId;
  final bool skippedOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(forecastLinesProvider(runId));
    final items = ref.watch(itemsProvider(''));
    final names = <String, String>{
      for (final Item i in items.value ?? const <Item>[])
        i.id: '${i.code} · ${i.name}',
    };

    return AsyncView<List<Map<String, dynamic>>>(
      value: lines,
      onRetry: () => ref.invalidate(forecastLinesProvider(runId)),
      skeleton: const ListSkeleton(rows: 6),
      builder: (list) {
        final shown = skippedOnly
            ? list.where((l) => l['skipped_reason'] != null).toList()
            : list;
        if (shown.isEmpty) {
          return EmptyState(
            icon: skippedOnly ? Icons.check_circle_outline : Icons.inventory_2,
            title: skippedOnly ? 'Nothing was skipped' : 'No lines',
            message: skippedOnly
                ? 'Every stocked item had enough history to forecast.'
                : null,
          );
        }
        return ListView.builder(
          itemCount: shown.length,
          itemBuilder: (_, i) {
            final l = shown[i];
            return ListTile(
              title: Text(names[l['item_id']] ?? 'Item'),
              subtitle: Text(
                l['skipped_reason'] as String? ??
                    'have ${Fmt.qty(double.tryParse('${l['available']}'))}'
                        ' · ${Fmt.qty(double.tryParse('${l['reorder_point']}'))}'
                        ' is the reorder point',
                maxLines: 2,
              ),
              leading: _StateChip('${l['state']}'),
              trailing: Text(
                Fmt.qty(double.tryParse('${l['suggested_qty']}')),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            );
          },
        );
      },
    );
  }
}

/// The replenishment states, coloured by how bad they are.
///
/// Its own chip rather than [StatusChip]: `ok` and `overstocked` mean
/// nothing outside a stockroom, and putting them in the shared document
/// vocabulary would leave every other screen carrying two words it can
/// never show.
class _StateChip extends StatelessWidget {
  const _StateChip(this.state);

  final String state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = switch (state) {
      'stocked_out' => c.danger,
      'below_safety' => c.danger,
      'order_now' => c.warning,
      'order_soon' => c.info,
      'ok' => c.success,
      // Not a fault, and not nothing: cash sitting on a shelf.
      _ => const Color(0xFF94A3B8),
    };
    return Container(
      width: 96,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        Fmt.label(state),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The working behind one number.
///
/// A buyer asked to spend money on a figure a model produced is entitled
/// to see where it came from — particularly the lead time, because
/// "measured" and "the default nobody revisited" are worth very
/// different amounts of trust.
Future<void> showForecastLineSheet(
  BuildContext context,
  Map<String, dynamic> s, {
  required String? warehouseId,
  required VoidCallback onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) =>
        _LineSheet(s, warehouseId: warehouseId, onChanged: onChanged),
  );
}

class _LineSheet extends ConsumerWidget {
  const _LineSheet(
    this.s, {
    required this.warehouseId,
    required this.onChanged,
  });

  final Map<String, dynamic> s;
  final String? warehouseId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leadSource = '${s['lead_time_source']}';
    final stockout = DateTime.tryParse('${s['stockout_on']}');

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SectionHeader(
              '${s['item_code']} · ${s['item_name']}',
              subtitle: s['supplier_name'] as String? ?? 'No supplier set',
              action: _StateChip('${s['state']}'),
            ),
            const Divider(),
            _row('Suggested order', Fmt.qty(_num(s['suggested_qty']))),
            _row('Already on a draft order', Fmt.qty(_num(s['already_drafted']))),
            _row('Still to raise', Fmt.qty(_num(s['outstanding']))),
            const Divider(),
            _row('On hand', Fmt.qty(_num(s['on_hand']))),
            _row('Reserved for customers', Fmt.qty(_num(s['reserved']))),
            _row('On order', Fmt.qty(_num(s['on_order']))),
            _row('Available', Fmt.qty(_num(s['available']))),
            const Divider(),
            _row(
              'Demand',
              '${Fmt.plain(_num(s['mean_daily_demand']))} a day',
            ),
            _row(
              'Lead time',
              '${Fmt.plain(_num(s['lead_time_days']))} days '
              '(${switch (leadSource) {
                'measured' => 'measured from deliveries',
                'item' => 'set on this item',
                _ => 'the company default',
              }})',
            ),
            _row('Safety stock', Fmt.qty(_num(s['safety_stock']))),
            _row('Reorder point', Fmt.qty(_num(s['reorder_point']))),
            if (s['days_cover'] != null)
              _row('Days of cover', Fmt.plain(_num(s['days_cover']))),
            if (stockout != null) _row('Runs out about', Fmt.longDate(stockout)),
            const SizedBox(height: Space.lg),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.tune),
                label: const Text('Parameters for this item'),
                onPressed: () async {
                  final saved = await showItemForecastParams(
                    context,
                    ref,
                    itemId: s['item_id'] as String,
                    itemLabel: '${s['item_code']} · ${s['item_name']}',
                    warehouseId: warehouseId,
                  );
                  if (saved) onChanged();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) =>
      FieldRow(label: label, value: value);
}


/// Which stock the question is about.
///
/// Null is "the company", and it is a real answer rather than the
/// absence of one: a business that transfers freely between locations
/// forecasts centrally, and one whose branches each hold their own does
/// not. Both are correct, so neither is assumed.
///
/// Hidden when there is nothing to choose between. One warehouse is
/// every small business in the country, and a picker with a single
/// entry is a control that can only ever confirm what is already true.
class _WarehousePicker extends ConsumerWidget {
  const _WarehousePicker({required this.selected, required this.onChanged});

  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final warehouses = ref.watch(warehousesProvider);
    final list = warehouses.value ?? const <Map<String, dynamic>>[];
    if (list.length < 2) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: selected,
          borderRadius: BorderRadius.circular(Radii.md),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Whole company'),
            ),
            for (final w in list)
              DropdownMenuItem<String?>(
                value: w['id'] as String,
                child: Text('${w['code']} · ${w['name']}'),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
