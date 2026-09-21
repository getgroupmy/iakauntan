import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';

/// Batches and serial numbers: what is on hand, what is about to go out
/// of date, and where any of it went.
///
/// The middle tab is the one that earns the feature in a food or
/// pharmacy business, and it is deliberately first-glance: stock already
/// past its date is included with a negative number of days, because it
/// is still on the shelf and still on the balance sheet at cost.
///
/// The trace is the other half. It is the question a recall asks, and
/// answering it is the only thing that justifies making somebody type a
/// batch number on every receipt.
class LotsScreen extends ConsumerStatefulWidget {
  const LotsScreen({super.key});

  @override
  ConsumerState<LotsScreen> createState() => _LotsScreenState();
}

class _LotsScreenState extends ConsumerState<LotsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  Future<List<Map<String, dynamic>>>? _balances;
  Future<List<Map<String, dynamic>>>? _expiring;
  int _within = 90;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _reload() {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() {
      _balances = repo.lotBalances();
      _expiring = repo.expiringStock(withinDays: _within);
    });
  }

  Future<void> _trace(Map<String, dynamic> lot) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final rows = await repo.traceLot(lot['lot_id'] as String);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _TraceDialog(
        title: '${lot['item_code']} · ${lot['lot_ref']}',
        rows: rows,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Batches and serials'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: Space.sm),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'On hand'), Tab(text: 'Expiring')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _Table(
            future: _balances,
            empty: 'Nothing is tracked yet. Turn on batch or serial '
                'tracking for an item and it will appear here once some '
                'has been received.',
            onTrace: _trace,
          ),
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    Space.lg, Space.sm, Space.lg, 0),
                child: Row(children: [
                  const Text('Within'),
                  const SizedBox(width: Space.sm),
                  SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 30, label: Text('30 days')),
                      ButtonSegment(value: 90, label: Text('90 days')),
                      ButtonSegment(value: 365, label: Text('A year')),
                    ],
                    selected: {_within},
                    onSelectionChanged: (v) {
                      _within = v.first;
                      _reload();
                    },
                  ),
                ]),
              ),
              Expanded(
                child: _Table(
                  future: _expiring,
                  empty: 'Nothing expires in the next $_within days.',
                  expiring: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Table extends StatelessWidget {
  const _Table({
    required this.future,
    required this.empty,
    this.expiring = false,
    this.onTrace,
  });

  final Future<List<Map<String, dynamic>>>? future;
  final String empty;
  final bool expiring;
  final Future<void> Function(Map<String, dynamic>)? onTrace;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          // A list of lots, each a code and a line of detail. The shape
          // is decided before the rows arrive, so it is drawn.
          return const Padding(
            padding: EdgeInsets.all(Space.lg),
            child: ListSkeleton(rows: 7, leading: false),
          );
        }
        if (snap.hasError) {
          return Center(child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Text('${snap.error}'),
          ));
        }
        final rows = snap.data ?? const [];
        if (rows.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(Space.xxl),
              child: Text(empty, textAlign: TextAlign.center),
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(Space.lg),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = rows[i];
            final days = (r['days_to_expiry'] as num?)?.toInt();
            return ListTile(
              dense: true,
              title: Row(children: [
                Expanded(
                  child: Text(
                    '${r['item_code']} · ${r['lot_ref']}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(Fmt.qty(Fmt.toDouble(r['quantity']))),
              ]),
              subtitle: Text([
                r['item_name'],
                if (r['warehouse'] != null) r['warehouse'],
                if (days != null)
                  days < 0
                      ? 'expired ${-days} days ago'
                      : 'expires in $days days',
                if (expiring && r['value_at_average'] != null)
                  'at cost ${Fmt.money(Fmt.toDouble(r['value_at_average']))}',
              ].where((e) => e != null).join('  ·  ')),
              // Red only once it is actually a problem. Colouring
              // everything with a date teaches people to ignore the
              // colour.
              leading: days != null && days < 30
                  ? Icon(Icons.warning_amber_outlined,
                      color: days < 0
                          ? context.colors.danger
                          : context.colors.warning)
                  : const Icon(Icons.inventory_2_outlined, size: 20),
              trailing: onTrace == null
                  ? null
                  : TextButton(
                      onPressed: () => onTrace!(r),
                      child: const Text('Trace'),
                    ),
            );
          },
        );
      },
    );
  }
}

/// Both directions from one batch: the supplier it arrived from, and
/// every customer it went to.
class _TraceDialog extends StatelessWidget {
  const _TraceDialog({required this.title, required this.rows});

  final String title;
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 560,
        child: rows.isEmpty
            ? const Text('Nothing has moved.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Everywhere this has been. The outward lines are who '
                    'to call.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: Space.sm),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final r = rows[i];
                        final out = r['direction'] == 'out';
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            out ? Icons.north_east : Icons.south_west,
                            size: 18,
                            color: out
                                ? context.colors.danger
                                : context.colors.success,
                          ),
                          title: Text([
                            r['contact_name'] ?? Fmt.label(
                                r['movement_type']?.toString() ?? ''),
                            if (r['document_no'] != null) r['document_no'],
                          ].join('  ·  ')),
                          subtitle: Text([
                            Fmt.date(
                                DateTime.parse(r['movement_date'].toString())),
                            if (r['warehouse'] != null) r['warehouse'],
                          ].join('  ·  ')),
                          trailing: Text(
                            Fmt.qty(Fmt.toDouble(r['quantity']).abs()),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        );
                      },
                    ),
                  ),
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
