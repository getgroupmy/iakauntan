import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/widgets.dart';
// `RepoPos` is an extension, and a Dart extension is only in scope
// where its declaring library is imported.
import '../../data/repository.dart';
import 'till_screen.dart' show PosRegisterPicker;

/// The kitchen display.
///
/// The screen with the least in common with the rest of this app. It is
/// read by somebody holding a pan, from further away than any other
/// screen here, and it is never touched except to say a plate has
/// moved. So: big type, one column of tickets, and exactly one control
/// per ticket.
///
/// ## The clock is the only sort
///
/// Tickets are ordered by when they were sent and by nothing else.
/// A kitchen works oldest-first, and any other order — by table, by
/// station, by size — is a way of serving somebody who arrived later.
///
/// ## Forward only
///
/// The bump advances new → cooking → ready → served and cannot go
/// back, because `bump_kitchen_ticket` refuses to. That refusal is the
/// point: a mis-tap in a kitchen should cost a plate going out early,
/// not a plate being un-cooked and made twice.
///
/// ## It refreshes itself
///
/// Every other screen here reloads when somebody asks. This one cannot:
/// nobody is going to pull-to-refresh with their hands full, and a
/// board that is thirty seconds stale is a board that sends the wrong
/// plate. So it polls, and says when it last looked.
class KitchenScreen extends ConsumerStatefulWidget {
  const KitchenScreen({super.key});

  @override
  ConsumerState<KitchenScreen> createState() => _KitchenScreenState();
}

class _KitchenScreenState extends ConsumerState<KitchenScreen> {
  String? _registerId;
  String? _outletId;
  String? _stationId;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Ten seconds is a compromise between a board that lags and a
    // kitchen tablet that spends the night talking to the server. A
    // ticket takes minutes to cook; ten seconds is inside the noise.
    _tick = Timer.periodic(const Duration(seconds: 10), (_) {
      final station = _stationId;
      if (station != null && mounted) {
        ref.invalidate(kitchenDisplayProvider(station));
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _pickRegister(Map<String, dynamic> reg) {
    setState(() {
      _registerId = reg['id'] as String?;
      _outletId = (reg['pos_outlets'] as Map?)?['id'] as String?;
      _stationId = null;
    });
  }

  Future<void> _bump(Map<String, dynamic> ticket) async {
    final id = ticket['ticket_id'] as String?;
    final next = _next('${ticket['status']}');
    if (id == null || next == null) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      // The ticket visibly moving is the confirmation. A snackbar over
      // a kitchen board is a thing covering the board.
      successMessage: null,
      action: () => repo.bumpKitchenTicket(id, next),
    );
    if (!ok || !mounted) return;
    final station = _stationId;
    if (station != null) ref.invalidate(kitchenDisplayProvider(station));
  }

  /// The next state, or null at the end of the line. Mirrors the order
  /// `bump_kitchen_ticket` enforces rather than inventing a second one.
  static String? _next(String status) => switch (status) {
    'new' => 'cooking',
    'cooking' => 'ready',
    'ready' => 'served',
    _ => null,
  };

  static String _verb(String status) => switch (status) {
    'new' => 'Start',
    'cooking' => 'Ready',
    'ready' => 'Away',
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final registers = ref.watch(posRegistersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kitchen'),
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
              icon: Icons.soup_kitchen_outlined,
              title: 'No tills yet',
              message:
                  'A kitchen belongs to an outlet, and an outlet needs a '
                  'register before anything can be ordered for it.',
            );
          }
          if (_outletId == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _pickRegister(rows.first);
            });
          }
          final outlet = _outletId;
          if (outlet == null) return const SizedBox.shrink();
          return _Stations(
            outletId: outlet,
            stationId: _stationId,
            onStation: (id) => setState(() => _stationId = id),
            onBump: _bump,
            verb: _verb,
          );
        },
      ),
    );
  }
}

class _Stations extends ConsumerWidget {
  const _Stations({
    required this.outletId,
    required this.stationId,
    required this.onStation,
    required this.onBump,
    required this.verb,
  });

  final String outletId;
  final String? stationId;
  final ValueChanged<String> onStation;
  final ValueChanged<Map<String, dynamic>> onBump;
  final String Function(String) verb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stations = ref.watch(posKitchenStationsProvider(outletId));
    return AsyncView<List<Map<String, dynamic>>>(
      value: stations,
      builder: (rows) {
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.soup_kitchen_outlined,
            title: 'No kitchen stations',
            message:
                'Add a station to this outlet and orders start arriving '
                'on it.',
          );
        }
        final station = stationId ?? rows.first['id'] as String;
        return Column(
          children: [
            // A pass and a bar are two boards, not two filters on one:
            // whoever is standing at the bar should never see a plate.
            if (rows.length > 1)
              SizedBox(
                height: 56,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final s in rows)
                      Padding(
                        padding: const EdgeInsets.only(right: 8, top: 8),
                        child: ChoiceChip(
                          label: Text('${s['name']}'),
                          selected: s['id'] == station,
                          onSelected: (_) => onStation(s['id'] as String),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: _Board(
                stationId: station,
                onBump: onBump,
                verb: verb,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Board extends ConsumerWidget {
  const _Board({
    required this.stationId,
    required this.onBump,
    required this.verb,
  });

  final String stationId;
  final ValueChanged<Map<String, dynamic>> onBump;
  final String Function(String) verb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(kitchenDisplayProvider(stationId));
    return AsyncView<List<Map<String, dynamic>>>(
      value: board,
      builder: (tickets) {
        if (tickets.isEmpty) {
          return const EmptyState(
            icon: Icons.done_all,
            title: 'Nothing waiting',
            message: 'Every ticket sent to this station has gone out.',
          );
        }
        return LayoutBuilder(
          builder: (context, box) {
            // Tickets are read as columns on a mounted screen and as a
            // list on a tablet somebody is holding.
            final columns = (box.maxWidth / 320).floor().clamp(1, 5);
            return GridView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: tickets.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                childAspectRatio: 0.85,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemBuilder: (_, i) => _Ticket(
                ticket: tickets[i],
                onBump: () => onBump(tickets[i]),
                verb: verb,
              ),
            );
          },
        );
      },
    );
  }
}

class _Ticket extends StatelessWidget {
  const _Ticket({
    required this.ticket,
    required this.onBump,
    required this.verb,
  });

  final Map<String, dynamic> ticket;
  final VoidCallback onBump;
  final String Function(String) verb;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = '${ticket['status']}';
    final waiting = (ticket['minutes_waiting'] as num?)?.toInt() ?? 0;
    final items = (ticket['items'] as List?) ?? const [];
    final label = verb(status);

    return Card(
      // Age, not status. A kitchen does not need to be told a ticket is
      // "new"; it needs to be told which one has been waiting.
      color: waiting >= 15
          ? scheme.errorContainer
          : waiting >= 8
          ? scheme.tertiaryContainer
          : scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '#${ticket['ticket_no']}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(width: 8),
                if (ticket['table_code'] != null)
                  Text(
                    '${ticket['table_code']}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                const Spacer(),
                Text(
                  '${waiting}m',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            if (status == 'cooking')
              Text('On', style: Theme.of(context).textTheme.labelMedium)
            else if (status == 'ready')
              Text('Pass', style: Theme.of(context).textTheme.labelMedium),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  for (final item in items.cast<Map<String, dynamic>>())
                    _Line(item: item),
                ],
              ),
            ),
            if (label.isNotEmpty)
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onBump,
                  child: Text(label),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.item});

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final qty = item['quantity'];
    final mods = '${item['modifiers'] ?? ''}';
    final note = '${item['note'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_qty(qty)} × ${item['description']}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          // Indented under the plate it changes, because a modifier read
          // as its own line is a modifier somebody cooks separately.
          if (mods.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                mods,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          if (note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                note,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Whole plates read as whole numbers. "2 × nasi lemak" is an order;
  /// "2.0000 × nasi lemak" is a database.
  static String _qty(Object? v) {
    final n = double.tryParse('$v') ?? 0;
    return n == n.roundToDouble() ? '${n.toInt()}' : '$n';
  }
}
