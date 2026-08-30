import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'channels.dart';
import 'menu_links_screen.dart';
import 'receipt_settings_screen.dart';
import 'scales_screen.dart';

/// Setting a shop up: its counters, and how orders reach it.
///
/// Two per-outlet questions on one screen because they are asked at the
/// same moment by the same person — whoever opens a shop decides that
/// drinks go to the bar and that this one does deliveries, and neither
/// is daily work.
///
/// ## Why this screen exists at all
///
/// 0215 built the routing and asserted it, and left it reachable only
/// by writing SQL: a shop that wanted a bar had no way to say so. The
/// rules are unchanged here — the dish if somebody named a counter for
/// it, else its category, else the outlet's default — and this is the
/// place a shopkeeper states them.
///
/// ## It shows the reason, not just the answer
///
/// Every row says which of the three rules decided where it goes. That
/// is the difference between "this drink goes to the bar because I said
/// so" and "…because every drink does", and it is the difference
/// between changing one dish and changing the whole menu. A screen
/// showing only the destination would make somebody guess which they
/// were about to do.
///
/// ## Retire, never delete
///
/// `pos_kitchen_tickets.station_id` cascades, so deleting a counter
/// would delete every docket it ever received. The button says Retire
/// and the function refuses while anything is still cooking on it, or
/// while it is the one unrouted dishes fall back to.
class StationsScreen extends ConsumerStatefulWidget {
  const StationsScreen({super.key});

  @override
  ConsumerState<StationsScreen> createState() => _StationsScreenState();
}

class _StationsScreenState extends ConsumerState<StationsScreen> {
  String? _outletId;

  void _refresh() {
    final outlet = _outletId;
    if (outlet == null) return;
    ref
      ..invalidate(posKitchenStationsProvider(outlet))
      ..invalidate(posStationRoutingProvider(outlet));
  }

  Future<void> _editStation([Map<String, dynamic>? station]) async {
    final outlet = _outletId;
    if (outlet == null) return;
    final result = await showDialog<_StationDraft>(
      context: context,
      builder: (_) => _StationDialog(station: station),
    );
    if (result == null || !mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: station == null ? 'Counter added' : 'Counter saved',
      action: () => repo.upsertKitchenStation(
        outletId: outlet,
        code: result.code,
        name: result.name,
        id: station?['id'] as String?,
        sortOrder: result.sortOrder,
        isDefault: result.isDefault,
      ),
    );
    if (ok) _refresh();
  }

  Future<void> _retire(Map<String, dynamic> station) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Retire ${station['name']}?'),
        content: const Text(
          'It stops receiving orders. Nothing it has already been sent '
          'is lost — the dockets stay, which is why this retires the '
          'counter rather than deleting it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Retire'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Retired',
      action: () => repo.retireKitchenStation(station['id'] as String),
    );
    if (ok) _refresh();
  }

  /// One row, two rules. Setting the dish overrides its category;
  /// clearing it hands the dish back to whatever the category says.
  Future<void> _route(
    Map<String, dynamic> row,
    List<Map<String, dynamic>> stations, {
    required bool wholeCategory,
  }) async {
    final outlet = _outletId;
    if (outlet == null) return;
    final categoryId = row['category_id'] as String?;
    if (wholeCategory && categoryId == null) return;

    final picked = await showModalBottomSheet<_Pick>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _StationPicker(
        title: wholeCategory
            ? 'Everything in ${row['category']}'
            : '${row['item_name']}',
        subtitle: wholeCategory
            ? 'Every dish in this category that has no counter of its own'
            : 'This dish only — it will override its category',
        stations: stations,
        // "Follow the category" and "follow the outlet default" are the
        // same act at two levels: clearing the rule.
        clearLabel: wholeCategory
            ? 'No rule — use the outlet default'
            : 'No rule — follow the category',
      ),
    );
    if (picked == null || !mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () => wholeCategory
          ? repo.routeCategoryToStation(categoryId!, outlet, picked.stationId)
          : repo.routeItemToStation(
              row['item_id'] as String,
              outlet,
              picked.stationId,
            ),
    );
    if (ok) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final outlets = ref.watch(posOutletsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Outlet setup'),
        actions: [
          // The third per-outlet question the same person asks at the
          // same moment: what the paper says.
          // The fourth per-outlet question, and the one that reaches a
          // customer's phone rather than a member of staff.
          IconButton(
            tooltip: 'Published menus',
            icon: const Icon(Icons.qr_code_2),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MenuLinksScreen(),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Scales',
            icon: const Icon(Icons.scale_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ScalesScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Receipt',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ReceiptSettingsScreen(),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: _outletId == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _editStation,
              icon: const Icon(Icons.add),
              label: const Text('Counter'),
            ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: outlets,
        builder: (shops) {
          if (shops.isEmpty) {
            return const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No outlets yet',
              message: 'Add an outlet before setting up its counters.',
            );
          }
          _outletId ??= shops.first['id'] as String?;
          final outlet = _outletId;
          if (outlet == null) return const SizedBox.shrink();

          return Column(
            children: [
              if (shops.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: DropdownButtonFormField<String>(
                    value: outlet,
                    decoration: const InputDecoration(
                      labelText: 'Outlet',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final o in shops)
                        DropdownMenuItem(
                          value: o['id'] as String,
                          child: Text('${o['name']}'),
                        ),
                    ],
                    onChanged: (v) => setState(() => _outletId = v),
                  ),
                ),
              Expanded(child: _Body(outletId: outlet, parent: this)),
            ],
          );
        },
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.outletId, required this.parent});

  final String outletId;
  final _StationsScreenState parent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stations = ref.watch(posKitchenStationsProvider(outletId));
    final routing = ref.watch(posStationRoutingProvider(outletId));

    return AsyncView<List<Map<String, dynamic>>>(
      value: stations,
      builder: (sts) => ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          const SectionHeader('Counters'),
          if (sts.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                'No counters here yet. A shop with one kitchen still '
                'needs one, because a docket has to be routed somewhere '
                '— add it and mark it the default.',
              ),
            ),
          for (final st in sts)
            ListTile(
              leading: Icon(
                st['is_default'] == true
                    ? Icons.star
                    : Icons.soup_kitchen_outlined,
              ),
              title: Text('${st['name']}'),
              subtitle: Text(
                [
                  '${st['code']}',
                  if (st['is_default'] == true) 'takes anything unrouted',
                ].join(' · '),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Rename',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => parent._editStation(st),
                  ),
                  IconButton(
                    tooltip: 'Retire',
                    icon: const Icon(Icons.block_outlined),
                    onPressed: () => parent._retire(st),
                  ),
                ],
              ),
            ),
          const SectionHeader('How orders arrive'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'What this shop takes, and what a sale is unless the till '
              'says otherwise. A kind of order that is switched off '
              'cannot be recorded at all, which is what keeps a report '
              'free of rows that can only be mistakes.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          OutletChannels(outletId: outletId),
          const SectionHeader('And what each till assumes'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'A kiosk in the corner is takeaway and the waiter\u2019s tablet '
              'is dine-in, so nobody has to say so on every sale \u2014 and a '
              'control set on every sale is a control that gets set wrong. '
              'A till left as the shop\u2019s default follows it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          RegisterChannels(outletId: outletId),
          const SectionHeader('The last thirty days'),
          const ChannelMix(),
          const SectionHeader('What goes where'),
          AsyncView<List<Map<String, dynamic>>>(
            value: routing,
            builder: (rows) {
              if (rows.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Nothing sellable in this outlet yet.'),
                );
              }
              // Grouped by category, because "drinks go to the bar" is
              // the rule a shop actually sets. The category header is
              // where that rule lives; the rows under it are the
              // exceptions.
              final byCategory = <String?, List<Map<String, dynamic>>>{};
              for (final r in rows) {
                byCategory
                    .putIfAbsent(r['category'] as String?, () => [])
                    .add(r);
              }
              return Column(
                children: [
                  for (final entry in byCategory.entries)
                    _CategoryBlock(
                      category: entry.key,
                      rows: entry.value,
                      stations: sts,
                      parent: parent,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CategoryBlock extends StatelessWidget {
  const _CategoryBlock({
    required this.category,
    required this.rows,
    required this.stations,
    required this.parent,
  });

  final String? category;
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> stations;
  final _StationsScreenState parent;

  @override
  Widget build(BuildContext context) {
    final first = rows.first;
    // Whether the category itself carries a rule, read off any of its
    // items: they all resolve the same way unless the dish overrides
    // it, and an overridden dish says 'item'.
    final categoryRule = rows.any((r) => r['decided_by'] == 'category');

    return ExpansionTile(
      title: Text(category ?? 'No category'),
      subtitle: Text(
        category == null
            // A dish with no category has nothing to inherit from, so
            // the only rules available to it are its own and the
            // outlet's default.
            ? 'No category rule possible — each dish or the default'
            : categoryRule
            ? 'Goes to ${_stationOf(rows, 'category')}'
            : 'No rule — dishes fall through to the outlet default',
      ),
      children: [
        if (category != null)
          ListTile(
            dense: true,
            leading: const Icon(Icons.rule),
            title: const Text('Set the rule for this whole category'),
            onTap: () =>
                parent._route(first, stations, wholeCategory: true),
          ),
        for (final r in rows)
          ListTile(
            dense: true,
            title: Text('${r['item_name']}'),
            subtitle: Text(_why(r)),
            trailing: Text('${r['station'] ?? '—'}'),
            onTap: () => parent._route(r, stations, wholeCategory: false),
          ),
      ],
    );
  }

  static String _stationOf(List<Map<String, dynamic>> rows, String rule) {
    for (final r in rows) {
      if (r['decided_by'] == rule) return '${r['station']}';
    }
    return '—';
  }

  /// The sentence that makes the row honest. Without it a default and a
  /// deliberate rule look identical, and somebody about to change one
  /// dish changes every drink on the menu instead.
  static String _why(Map<String, dynamic> r) => switch (r['decided_by']) {
    'item' => 'Set on this dish',
    'category' => 'From its category',
    'default' => 'The outlet default',
    _ => 'Nowhere to send it — this outlet has no default counter',
  };
}

class _StationDraft {
  const _StationDraft({
    required this.code,
    required this.name,
    required this.sortOrder,
    required this.isDefault,
  });

  final String code;
  final String name;
  final int sortOrder;
  final bool isDefault;
}

class _StationDialog extends StatefulWidget {
  const _StationDialog({this.station});

  final Map<String, dynamic>? station;

  @override
  State<_StationDialog> createState() => _StationDialogState();
}

class _StationDialogState extends State<_StationDialog> {
  late final _code = TextEditingController(
    text: '${widget.station?['code'] ?? ''}',
  );
  late final _name = TextEditingController(
    text: '${widget.station?['name'] ?? ''}',
  );
  late final _sort = TextEditingController(
    text: '${widget.station?['sort_order'] ?? 0}',
  );
  late bool _default = widget.station?['is_default'] == true;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _sort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.station == null ? 'New counter' : 'Counter'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Bar, Dapur, Grill',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            decoration: const InputDecoration(
              labelText: 'Code',
              hintText: 'BAR',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _sort,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Order on the screen',
              border: OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _default,
            onChanged: (v) => setState(() => _default = v),
            title: const Text('Takes anything unrouted'),
            // The rule stated where it is set, because turning this on
            // silently turns it off somewhere else.
            subtitle: const Text(
              'One counter per outlet. Turning this on moves it off '
              'whichever one has it now.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final code = _code.text.trim();
            final name = _name.text.trim();
            if (code.isEmpty || name.isEmpty) return;
            Navigator.of(context).pop(
              _StationDraft(
                code: code,
                name: name,
                sortOrder: int.tryParse(_sort.text.trim()) ?? 0,
                isDefault: _default,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _Pick {
  const _Pick(this.stationId);

  /// Null means "no rule at this level", which hands the decision back
  /// to the level below.
  final String? stationId;
}

class _StationPicker extends StatelessWidget {
  const _StationPicker({
    required this.title,
    required this.subtitle,
    required this.stations,
    required this.clearLabel,
  });

  final String title;
  final String subtitle;
  final List<Map<String, dynamic>> stations;
  final String clearLabel;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final st in stations)
            ListTile(
              leading: const Icon(Icons.soup_kitchen_outlined),
              title: Text('${st['name']}'),
              onTap: () =>
                  Navigator.of(context).pop(_Pick(st['id'] as String)),
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.layers_clear_outlined),
            title: Text(clearLabel),
            onTap: () => Navigator.of(context).pop(const _Pick(null)),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
