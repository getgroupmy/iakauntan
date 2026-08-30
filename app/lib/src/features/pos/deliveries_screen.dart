import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'delivery_setup_screen.dart';
import 'delivery_sheet.dart';
import 'delivery_day_dialog.dart';

/// Everything that has left the kitchen and not arrived yet.
///
/// The board answers the two questions somebody standing at the pass is
/// asked all evening: whose bag is this, and how long has it been sat
/// there. Both come back computed from the server — a phone with a
/// wrong clock would otherwise show a different board from the tablet
/// beside it.
///
/// ## It re-reads itself
///
/// Sixty seconds. A run moves in tens of minutes rather than in
/// tickets, so the kitchen board's ten would be a refresh nobody needs
/// and a battery nobody has.
class DeliveriesScreen extends ConsumerStatefulWidget {
  const DeliveriesScreen({super.key});

  @override
  ConsumerState<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

class _DeliveriesScreenState extends ConsumerState<DeliveriesScreen> {
  String? _outletId;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 60), (_) {
      final id = _outletId;
      if (id != null && mounted) ref.invalidate(posDeliveryBoardProvider(id));
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _give(String outletId, Map<String, dynamic> run) async {
    final drivers = await ref.read(posDriversProvider.future);
    if (!mounted) return;
    final free = [
      for (final d in drivers)
        if (d['is_active'] == true &&
            (d['outlet_id'] == null || d['outlet_id'] == outletId))
          d,
    ];
    if (free.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nobody is set up to drive. Add a driver first.'),
        ),
      );
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Who is taking it?')),
            const Divider(height: 1),
            for (final d in free)
              ListTile(
                dense: true,
                leading: const Icon(Icons.two_wheeler_outlined, size: 18),
                title: Text('${d['name']}'),
                subtitle: Text(
                  [
                    if ('${d['vehicle'] ?? ''}'.isNotEmpty) '${d['vehicle']}',
                    if ('${d['plate_no'] ?? ''}'.isNotEmpty) '${d['plate_no']}',
                    // The number that decides who gets the next bag.
                    '${Fmt.toInt(d['out_now'])} out now',
                  ].join(' · '),
                ),
                onTap: () => Navigator.of(ctx).pop(d['id'] as String),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'On its way to a driver',
      action: () => repo.assignPosDelivery(run['id'] as String, picked),
    );
    if (ok && mounted) ref.invalidate(posDeliveryBoardProvider(outletId));
  }

  Future<void> _move(
    String outletId,
    Map<String, dynamic> run,
    String status,
  ) async {
    String? reason;
    if (status == 'failed') {
      reason = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final controller = TextEditingController();
          return AlertDialog(
            title: const Text('What happened?'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Nobody home, refused, address does not exist',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(ctx).pop(controller.text.trim()),
                child: const Text('Record it'),
              ),
            ],
          );
        },
      );
      // "Failed" on its own tells a shop nothing it can act on, and the
      // server refuses it — so the screen does not send it either.
      if (reason == null || reason.isEmpty || !mounted) return;
    }

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: switch (status) {
        'collected' => 'Out of the door',
        'delivered' => 'Delivered',
        _ => 'Recorded as not arrived',
      },
      action: () => repo.setPosDeliveryStatus(
        run['id'] as String,
        status,
        reason: reason,
      ),
    );
    if (ok && mounted) ref.invalidate(posDeliveryBoardProvider(outletId));
  }

  @override
  Widget build(BuildContext context) {
    if (!moduleEnabled(ref, 'pos')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Deliveries')),
        body: const EmptyState(
          icon: Icons.moped_outlined,
          title: 'The till is not switched on',
          message: 'A delivery is a bill going somewhere, and this company '
              'has no shop to take one in.',
        ),
      );
    }

    final outlets = ref.watch(posOutletsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Deliveries'),
        actions: [
          // What actually happened. The board shows what is out right
          // now; both day reports were written and neither reached a
          // screen, so a shop could not say how many runs it made.
          IconButton(
            key: const ValueKey('delivery-day'),
            tooltip: 'The day’s deliveries',
            icon: const Icon(Icons.insights_outlined),
            onPressed: () => showDeliveryDay(context),
          ),
          IconButton(
            tooltip: 'Zones and drivers',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DeliverySetupScreen(),
              ),
            ),
          ),
        ],
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: outlets,
        onRetry: () => ref.invalidate(posOutletsProvider),
        builder: (shops) {
          if (shops.isEmpty) {
            return const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No outlets',
              message: 'Set a shop up before sending anything out of it.',
            );
          }
          if (_outletId == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() => _outletId = shops.first['id'] as String?);
              }
            });
            return const Center(child: CircularProgressIndicator());
          }
          final outlet = _outletId!;
          final board = ref.watch(posDeliveryBoardProvider(outlet));

          return Column(
            children: [
              if (shops.length > 1)
                FilterBar(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final s in shops)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: ChoiceChip(
                            label: Text('${s['name']}'),
                            selected: s['id'] == outlet,
                            onSelected: (_) =>
                                setState(() => _outletId = s['id'] as String?),
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: AsyncView<List<Map<String, dynamic>>>(
                  value: board,
                  onRetry: () =>
                      ref.invalidate(posDeliveryBoardProvider(outlet)),
                  builder: (rows) {
                    if (rows.isEmpty) {
                      return const EmptyState(
                        icon: Icons.moped_outlined,
                        title: 'Nothing out',
                        message: 'Bills with an address on them show here '
                            'until they are delivered, with who has them and '
                            'how long they have been waiting.',
                      );
                    }
                    return ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _RunRow(
                        run: rows[i],
                        onGive: () => _give(outlet, rows[i]),
                        onCollected: () =>
                            _move(outlet, rows[i], 'collected'),
                        onDelivered: () =>
                            _move(outlet, rows[i], 'delivered'),
                        onFailed: () => _move(outlet, rows[i], 'failed'),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({
    required this.run,
    required this.onGive,
    required this.onCollected,
    required this.onDelivered,
    required this.onFailed,
  });

  final Map<String, dynamic> run;
  final VoidCallback onGive;
  final VoidCallback onCollected;
  final VoidCallback onDelivered;
  final VoidCallback onFailed;

  @override
  Widget build(BuildContext context) {
    final status = '${run['status']}';
    final waiting = Fmt.toInt(run['waiting_minutes']);
    final driver = '${run['driver_name'] ?? ''}';
    final paid = run['paid'] == true;

    // The one thing worth a colour: a bag that has been sat on the pass
    // longer than anybody would want to admit to a customer.
    final late = waiting >= 45;

    return ListTile(
      isThreeLine: true,
      leading: Icon(
        switch (status) {
          'pending' => Icons.pending_outlined,
          'assigned' => Icons.assignment_ind_outlined,
          _ => Icons.moped_outlined,
        },
        color: late ? context.colors.warning : null,
      ),
      title: Text(
        [
          '${run['sale_no']}',
          if ('${run['recipient'] ?? ''}'.isNotEmpty) '${run['recipient']}',
          Fmt.money(Fmt.toDouble(run['total_amount'])),
        ].join(' · '),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(deliveryLine(run)),
          Text(
            [
              deliveryStatus(status),
              if (driver.isNotEmpty) driver,
              '$waiting min',
              // A delivery is very often paid at the door, so whether
              // the money is in is not a detail — it is what the driver
              // has to be told before they go.
              if (paid) 'paid' else 'to collect on delivery',
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: late ? context.colors.warning : null,
            ),
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (choice) => switch (choice) {
          'give' => onGive(),
          'collected' => onCollected(),
          'delivered' => onDelivered(),
          _ => onFailed(),
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'give', child: Text('Give it to a driver')),
          if (status != 'pending')
            const PopupMenuItem(
              value: 'collected',
              child: Text('Out of the door'),
            ),
          if (status != 'pending')
            const PopupMenuItem(value: 'delivered', child: Text('Delivered')),
          const PopupMenuItem(value: 'failed', child: Text('Did not arrive')),
        ],
      ),
    );
  }
}
