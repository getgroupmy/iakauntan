import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'queue_day_dialog.dart';

/// The line at the door.
///
/// What this replaces is a scrap of paper, which cannot tell the next
/// customer how long they are likely to stand there, cannot be read
/// from the floor by the waiter who just cleared table 6, and does not
/// exist by Monday — so nobody ever learns whether Saturday's wait is
/// twenty minutes or fifty.
///
/// ## Two numbers a host is asked for
///
/// How long this party has been waiting, and how many are in front of
/// them. Both come back computed from the server: a phone with a wrong
/// clock would otherwise show a different queue from the tablet beside
/// it, and the argument that follows is with a customer.
///
/// ## It re-reads itself
///
/// A queue is stale the moment somebody else seats a party, and the
/// host is holding a tablet rather than watching for a refresh button.
/// Thirty seconds, which is slower than the kitchen board's ten because
/// a queue moves in minutes rather than in tickets.
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key});

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
  String? _outletId;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      final id = _outletId;
      if (id != null && mounted) ref.invalidate(posQueueProvider(id));
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _join(String outletId) async {
    final party = await showDialog<({int size, String name, String phone})>(
      context: context,
      builder: (_) => const _JoinDialog(),
    );
    if (party == null || !mounted) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    Map<String, dynamic> got = const {};
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () async {
        got = await repo.joinPosQueue(
          outletId: outletId,
          party: party.size,
          name: party.name.isEmpty ? null : party.name,
          phone: party.phone.isEmpty ? null : party.phone,
        );
      },
    );
    if (!ok || !mounted) return;
    ref.invalidate(posQueueProvider(outletId));

    // The number and the wait, said back once and loudly. It is what
    // the host reads out, and a snackbar that only said "Saved" would
    // make them go and find the row.
    final quoted = Fmt.toInt(got['quoted_minutes']);
    final ahead = Fmt.toInt(got['ahead']);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          [
            'Number ${got['ticket_no']}',
            if (ahead > 0) '$ahead ahead' else 'next in line',
            // Nothing rather than a guess when the shop has not served
            // enough parties today to know.
            if (quoted > 0) 'about $quoted minutes',
          ].join(' · '),
        ),
      ),
    );
  }

  Future<void> _move(
    String outletId,
    Map<String, dynamic> entry,
    String status, {
    String? tableId,
  }) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: switch (status) {
        'called' => 'Called',
        'seated' => 'Seated',
        'left' => 'Marked as walked away',
        _ => 'Marked as a no-show',
      },
      action: () => repo.setPosQueueStatus(
        entry['id'] as String,
        status,
        tableId: tableId,
      ),
    );
    if (ok && mounted) ref.invalidate(posQueueProvider(outletId));
  }

  Future<void> _seat(String outletId, Map<String, dynamic> entry) async {
    final tables = await ref.read(posFloorPlanProvider(outletId).future);
    if (!mounted) return;
    // A shop with no floor plan still seats people; it just cannot say
    // where. Skipping the picker beats showing an empty one.
    if (tables.isEmpty) {
      await _move(outletId, entry, 'seated');
      return;
    }
    final free = [
      for (final t in tables)
        if (Fmt.toInt(t['open_bills']) == 0) t,
    ];
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text('Seat ${_who(entry)}'),
              subtitle: Text(
                free.isEmpty
                    ? 'Every table has a bill on it'
                    : '${free.length} free',
              ),
            ),
            const Divider(height: 1),
            for (final t in free)
              ListTile(
                dense: true,
                leading: const Icon(Icons.table_restaurant_outlined, size: 18),
                title: Text('${t['code']}'),
                subtitle: Text('${Fmt.toInt(t['seats'])} seats'),
                onTap: () => Navigator.of(ctx).pop(t['id'] as String),
              ),
            ListTile(
              leading: const Icon(Icons.check),
              title: const Text('Seat them without saying where'),
              onTap: () => Navigator.of(ctx).pop(''),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _move(
      outletId,
      entry,
      'seated',
      tableId: picked.isEmpty ? null : picked,
    );
  }

  static String _who(Map<String, dynamic> e) {
    final name = '${e['name'] ?? ''}';
    return name.isEmpty ? 'number ${e['ticket_no']}' : name;
  }

  @override
  Widget build(BuildContext context) {
    if (!moduleEnabled(ref, 'pos')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Queue')),
        body: const EmptyState(
          icon: Icons.people_outline,
          title: 'The till is not switched on',
          message: 'A queue is a line for a table, and this company has no '
              'shop to keep one in.',
        ),
      );
    }

    final outlets = ref.watch(posOutletsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Queue'),
        actions: [
          // The line is only half of it. The other half is what the
          // line did, which the paper by the door could never say.
          IconButton(
            key: const ValueKey('queue-day'),
            icon: const Icon(Icons.insights_outlined),
            tooltip: 'What the line did',
            onPressed: () => showQueueDay(context),
          ),
        ],
      ),
      floatingActionButton: _outletId == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _join(_outletId!),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add to the line'),
            ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: outlets,
        onRetry: () => ref.invalidate(posOutletsProvider),
        builder: (shops) {
          if (shops.isEmpty) {
            return const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No outlets',
              message: 'Set a shop up before keeping a line outside it.',
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
          final queue = ref.watch(posQueueProvider(outlet));

          return Column(
            children: [
              // Only where there is a choice. A picker showing one shop
              // is a control that only ever wastes a tap.
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
                  value: queue,
                  onRetry: () => ref.invalidate(posQueueProvider(outlet)),
                  builder: (rows) {
                    if (rows.isEmpty) {
                      return const EmptyState(
                        icon: Icons.people_outline,
                        title: 'Nobody waiting',
                        message: 'Parties added to the line show here with '
                            'their number, how long they have waited and how '
                            'many are in front of them.',
                      );
                    }
                    return ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _QueueRow(
                        entry: rows[i],
                        onCall: () => _move(outlet, rows[i], 'called'),
                        onSeat: () => _seat(outlet, rows[i]),
                        onLeft: () => _move(outlet, rows[i], 'left'),
                        onNoShow: () => _move(outlet, rows[i], 'no_show'),
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

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.entry,
    required this.onCall,
    required this.onSeat,
    required this.onLeft,
    required this.onNoShow,
  });

  final Map<String, dynamic> entry;
  final VoidCallback onCall;
  final VoidCallback onSeat;
  final VoidCallback onLeft;
  final VoidCallback onNoShow;

  @override
  Widget build(BuildContext context) {
    final called = '${entry['status']}' == 'called';
    final waited = Fmt.toInt(entry['waited_minutes']);
    final quoted = Fmt.toInt(entry['quoted_minutes']);
    final ahead = Fmt.toInt(entry['ahead']);
    final name = '${entry['name'] ?? ''}';

    // The one thing on the row worth a colour: a party who has been
    // waiting longer than they were told they would.
    final over = quoted > 0 && waited > quoted;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: called
            ? context.colors.warning.withValues(alpha: 0.15)
            : null,
        child: Text('${entry['ticket_no']}'),
      ),
      title: Text(
        [
          if (name.isNotEmpty) name,
          '${Fmt.toInt(entry['party_size'])} people',
        ].join(' · '),
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        [
          if (called) 'called',
          '$waited min waited',
          if (quoted > 0) 'told about $quoted',
          if (ahead > 0)
            '$ahead ahead'
          else
            'next',
          if ('${entry['phone'] ?? ''}'.isNotEmpty) '${entry['phone']}',
        ].join(' · '),
        style: TextStyle(
          fontSize: 12,
          color: over ? context.colors.warning : null,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!called)
            IconButton(
              tooltip: 'Call them',
              icon: const Icon(Icons.campaign_outlined),
              onPressed: onCall,
            ),
          IconButton(
            tooltip: 'Seat them',
            icon: const Icon(Icons.table_restaurant_outlined),
            onPressed: onSeat,
          ),
          PopupMenuButton<String>(
            tooltip: 'They have gone',
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (v) => v == 'left' ? onLeft() : onNoShow(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'left',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.directions_walk),
                  title: Text('Walked away'),
                ),
              ),
              // Kept apart from walking away, because they are two
              // different problems: one is the wait being too long and
              // the other is somebody outside on the phone.
              PopupMenuItem(
                value: 'no_show',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.phone_missed_outlined),
                  title: Text('Called, did not come'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _JoinDialog extends StatefulWidget {
  const _JoinDialog();

  @override
  State<_JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends State<_JoinDialog> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  int _size = 2;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add to the line'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The party size first, and as buttons: it is the only
            // answer the queue actually needs, and a host with a family
            // in front of them should not be typing.
            Text(
              'How many?',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: 4,
              children: [
                for (final n in [1, 2, 3, 4, 5, 6, 8, 10])
                  ChoiceChip(
                    label: Text('$n'),
                    selected: _size == n,
                    onSelected: (_) => setState(() => _size = n),
                  ),
              ],
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'Optional. Easier to call than a number.',
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+ -]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Phone',
                helperText: 'Optional.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            size: _size,
            name: _name.text.trim(),
            phone: _phone.text.trim(),
          )),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
