import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// How far a shop will go, what it charges, and who carries it.
///
/// Two lists rather than two screens: a zone with no drivers delivers
/// nothing and a driver with no zones has nowhere to go, so a shop
/// setting this up for the first time should not have to find the
/// second page to finish the job.
class DeliverySetupScreen extends ConsumerWidget {
  const DeliverySetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Zones and drivers'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Zones'),
              Tab(text: 'Drivers'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_Zones(), _Drivers()],
        ),
      ),
    );
  }
}

/// What a zone charges, in one line.
///
/// Pure and exported so the list and the tests read the same sentence.
String zoneRule(Map<String, dynamic> zone) {
  final fee = Fmt.toDouble(zone['fee']);
  final min = Fmt.toDouble(zone['min_order']);
  final free = zone['free_above'];
  return [
    fee == 0 ? 'Free' : Fmt.money(fee),
    if (min > 0) 'over ${Fmt.money(min)}',
    if (free != null) 'free above ${Fmt.money(Fmt.toDouble(free))}',
  ].join(' · ');
}

/// The postcodes a zone covers, or the fact that it covers what is left.
String zoneCovers(Map<String, dynamic> zone) {
  final codes = (zone['postcodes'] as List?) ?? const [];
  if (codes.isEmpty) return 'Anywhere not named by another zone';
  return codes.join(', ');
}

class _Zones extends ConsumerWidget {
  const _Zones();

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, {
    Map<String, dynamic>? zone,
    String? outletId,
  }) async {
    final outlets = await ref.read(posOutletsProvider.future);
    if (!context.mounted) return;
    final shop = zone?['outlet_id'] as String? ?? outletId ??
        (outlets.isEmpty ? null : outlets.first['id'] as String?);
    if (shop == null) return;

    final answer = await showModalBottomSheet<_ZoneAnswer>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _ZoneSheet(zone: zone ?? const {}),
      ),
    );
    if (answer == null || !context.mounted) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => repo.savePosDeliveryZone(
        id: zone?['id'] as String?,
        outletId: shop,
        name: answer.name,
        postcodes: answer.postcodes,
        fee: answer.fee,
        minOrder: answer.minOrder,
        freeAbove: answer.freeAbove,
        etaMinutes: answer.eta,
      ),
    );
    if (ok && context.mounted) ref.invalidate(posDeliveryZonesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zones = ref.watch(posDeliveryZonesProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('Add a zone'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: zones,
        onRetry: () => ref.invalidate(posDeliveryZonesProvider),
        skeleton: const ListSkeleton(rows: 6, leading: false),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.map_outlined,
              title: 'No zones yet',
              message: 'A zone is a name, a list of postcodes and a fee. '
                  'One with no postcodes is the catch-all — anywhere else '
                  'the shop will go.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final z = rows[i];
              final live = z['is_active'] == true;
              return ListTile(
                isThreeLine: true,
                title: Text(
                  '${z['name']}',
                  style: live
                      ? null
                      : const TextStyle(
                          decoration: TextDecoration.lineThrough,
                        ),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(zoneRule(z)),
                    Text(
                      zoneCovers(z),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (choice) async {
                    if (choice == 'edit') {
                      await _edit(context, ref, zone: z);
                      return;
                    }
                    final repo = ref.read(repoProvider);
                    if (repo == null || !context.mounted) return;
                    final ok = await runWithFeedback(
                      context,
                      successMessage: 'Retired',
                      action: () =>
                          repo.retirePosDeliveryZone(z['id'] as String),
                    );
                    if (ok && context.mounted) {
                      ref.invalidate(posDeliveryZonesProvider);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    if (live)
                      const PopupMenuItem(
                        value: 'retire',
                        child: Text('Stop delivering here'),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

typedef _ZoneAnswer = ({
  String name,
  List<String> postcodes,
  double fee,
  double minOrder,
  double? freeAbove,
  int? eta,
});

class _ZoneSheet extends StatefulWidget {
  const _ZoneSheet({required this.zone});

  final Map<String, dynamic> zone;

  @override
  State<_ZoneSheet> createState() => _ZoneSheetState();
}

class _ZoneSheetState extends State<_ZoneSheet> {
  late final TextEditingController _name;
  late final TextEditingController _postcodes;
  late final TextEditingController _fee;
  late final TextEditingController _min;
  late final TextEditingController _free;
  late final TextEditingController _eta;

  @override
  void initState() {
    super.initState();
    final z = widget.zone;
    _name = TextEditingController(text: '${z['name'] ?? ''}');
    _postcodes = TextEditingController(
      text: ((z['postcodes'] as List?) ?? const []).join(', '),
    );
    _fee = TextEditingController(text: Fmt.plain(Fmt.toDouble(z['fee'])));
    _min = TextEditingController(text: Fmt.plain(Fmt.toDouble(z['min_order'])));
    _free = TextEditingController(
      text: z['free_above'] == null
          ? ''
          : Fmt.plain(Fmt.toDouble(z['free_above'])),
    );
    _eta = TextEditingController(
      text: z['eta_minutes'] == null ? '' : '${Fmt.toInt(z['eta_minutes'])}',
    );
  }

  @override
  void dispose() {
    for (final c in [_name, _postcodes, _fee, _min, _free, _eta]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.zone.isEmpty ? 'A new zone' : 'The zone',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Taman Sri, Bandar Baru, anywhere else',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _postcodes,
              decoration: const InputDecoration(
                labelText: 'Postcodes',
                helperText: 'Comma separated. Leave empty for the catch-all.',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _fee,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Fee',
                      prefixText: 'RM ',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _min,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Minimum order',
                      prefixText: 'RM ',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _free,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Free above',
                      prefixText: 'RM ',
                      helperText: 'Empty means never',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _eta,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Usually takes',
                      suffixText: 'min',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _name.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop((
                      name: _name.text.trim(),
                      postcodes: [
                        for (final p in _postcodes.text.split(','))
                          if (p.trim().isNotEmpty) p.trim(),
                      ],
                      fee: double.tryParse(_fee.text.trim()) ?? 0,
                      minOrder: double.tryParse(_min.text.trim()) ?? 0,
                      freeAbove: double.tryParse(_free.text.trim()),
                      eta: int.tryParse(_eta.text.trim()),
                    )),
              child: const Text('Save the zone'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Drivers extends ConsumerWidget {
  const _Drivers();

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, {
    Map<String, dynamic>? driver,
  }) async {
    final answer = await showDialog<({String name, String phone, String vehicle, String plate})>(
      context: context,
      builder: (ctx) {
        final name = TextEditingController(text: '${driver?['name'] ?? ''}');
        final phone = TextEditingController(text: '${driver?['phone'] ?? ''}');
        final vehicle = TextEditingController(
          text: '${driver?['vehicle'] ?? ''}',
        );
        final plate = TextEditingController(
          text: '${driver?['plate_no'] ?? ''}',
        );
        return AlertDialog(
          title: Text(driver == null ? 'A new driver' : 'The driver'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone'),
              ),
              TextField(
                controller: vehicle,
                decoration: const InputDecoration(
                  labelText: 'Vehicle',
                  hintText: 'Honda EX5',
                ),
              ),
              TextField(
                controller: plate,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Plate'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop((
                name: name.text.trim(),
                phone: phone.text.trim(),
                vehicle: vehicle.text.trim(),
                plate: plate.text.trim(),
              )),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (answer == null || answer.name.isEmpty || !context.mounted) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => repo.savePosDriver(
        id: driver?['id'] as String?,
        name: answer.name,
        phone: answer.phone.isEmpty ? null : answer.phone,
        vehicle: answer.vehicle.isEmpty ? null : answer.vehicle,
        plateNo: answer.plate.isEmpty ? null : answer.plate,
        outletId: driver?['outlet_id'] as String?,
      ),
    );
    if (ok && context.mounted) ref.invalidate(posDriversProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers = ref.watch(posDriversProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add a driver'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: drivers,
        onRetry: () => ref.invalidate(posDriversProvider),
        skeleton: const ListSkeleton(rows: 6),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.two_wheeler_outlined,
              title: 'Nobody driving',
              message: 'Add the people who carry the orders. Their runs are '
                  'kept afterwards, so a driver is stood down rather than '
                  'deleted.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final d = rows[i];
              final live = d['is_active'] == true;
              final out = Fmt.toInt(d['out_now']);
              return ListTile(
                leading: const Icon(Icons.two_wheeler_outlined),
                title: Text(
                  '${d['name']}',
                  style: live
                      ? null
                      : const TextStyle(
                          decoration: TextDecoration.lineThrough,
                        ),
                ),
                subtitle: Text(
                  [
                    if ('${d['phone'] ?? ''}'.isNotEmpty) '${d['phone']}',
                    if ('${d['vehicle'] ?? ''}'.isNotEmpty) '${d['vehicle']}',
                    if ('${d['plate_no'] ?? ''}'.isNotEmpty) '${d['plate_no']}',
                    if ('${d['outlet_name'] ?? ''}'.isNotEmpty)
                      '${d['outlet_name']} only'
                    else
                      'every outlet',
                    if (out > 0) '$out out now',
                  ].join(' · '),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (choice) async {
                    if (choice == 'edit') {
                      await _edit(context, ref, driver: d);
                      return;
                    }
                    final repo = ref.read(repoProvider);
                    if (repo == null || !context.mounted) return;
                    final ok = await runWithFeedback(
                      context,
                      successMessage: 'Stood down',
                      action: () => repo.retirePosDriver(d['id'] as String),
                    );
                    if (ok && context.mounted) {
                      ref.invalidate(posDriversProvider);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    if (live)
                      const PopupMenuItem(
                        value: 'retire',
                        child: Text('Stand them down'),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
