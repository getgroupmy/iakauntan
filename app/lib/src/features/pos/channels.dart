import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'till_screen.dart' show posNum;

/// How an order arrived.
///
/// `pos_outlets.business_type` says what shape of shop this is. It has
/// never said how an order reached it, and those are different
/// questions: one warung takes a bill at a table, a bag over the
/// counter, a phone call and a delivery app, and every one of those is
/// the same shop.
///
/// The labels live here rather than in the database because they are
/// wording, not data: the enum is the fact, and a shop that calls
/// takeaway "bungkus" is changing what a screen says, not what a report
/// groups by.
const posOrderChannels = <String, String>{
  'walk_in': 'Walk-in',
  'dine_in': 'Dine-in',
  'takeaway': 'Takeaway',
  'delivery': 'Delivery',
  'reservation': 'Reservation',
  'phone': 'Phone order',
  'online': 'Online',
  'mobile_app': 'Mobile app',
};

String channelLabel(Object? channel) =>
    posOrderChannels['$channel'] ?? '$channel';

IconData channelIcon(Object? channel) => switch ('$channel') {
  'dine_in' => Icons.restaurant_outlined,
  'takeaway' => Icons.shopping_bag_outlined,
  'delivery' => Icons.delivery_dining_outlined,
  'reservation' => Icons.event_available_outlined,
  'phone' => Icons.call_outlined,
  'online' => Icons.language_outlined,
  'mobile_app' => Icons.phone_iphone_outlined,
  _ => Icons.storefront_outlined,
};

/// The chip on an open bill, and the sheet behind it.
///
/// On the bill rather than in settings, because "this one is takeaway"
/// is a fact about this order. It shows the resolved channel even when
/// nobody chose it, so a cashier can see the till's assumption before
/// it becomes what the day gets reported as.
class SaleChannelChip extends ConsumerWidget {
  const SaleChannelChip({
    super.key,
    required this.saleId,
    required this.outletId,
    required this.channel,
  });

  final String saleId;
  final String? outletId;
  final Object? channel;

  Future<void> _change(BuildContext context, WidgetRef ref) async {
    final outlet = outletId;
    if (outlet == null) return;
    final accepted = await ref.read(
      posOutletChannelsProvider(outlet).future,
    );
    if (!context.mounted) return;
    final live = [for (final c in accepted) if (c['is_active'] == true) c];
    if (live.length < 2) return;

    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('How did this order arrive?'),
              ),
            ),
            for (final c in live)
              ListTile(
                leading: Icon(channelIcon(c['channel'])),
                title: Text(channelLabel(c['channel'])),
                selected: c['channel'] == channel,
                onTap: () =>
                    Navigator.of(ctx).pop('${c['channel']}'),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () => repo.setPosSaleChannel(saleId, picked),
    );
    if (ok) ref.invalidate(posSaleProvider(saleId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (channel == null) return const SizedBox.shrink();
    return ActionChip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(channelIcon(channel), size: 16),
      label: Text(channelLabel(channel)),
      onPressed: () => _change(context, ref),
    );
  }
}

/// Which kinds of order this outlet takes, and which one a sale gets
/// when nobody says.
class OutletChannels extends ConsumerWidget {
  const OutletChannels({super.key, required this.outletId});

  final String outletId;

  Future<void> _set(
    BuildContext context,
    WidgetRef ref,
    String channel, {
    required bool isActive,
    required bool isDefault,
    required int sortOrder,
  }) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () => repo.setOutletChannel(
        outletId,
        channel,
        isActive: isActive,
        isDefault: isDefault,
        sortOrder: sortOrder,
      ),
    );
    if (ok) ref.invalidate(posOutletChannelsProvider(outletId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(posOutletChannelsProvider(outletId));

    return AsyncView<List<Map<String, dynamic>>>(
      value: channels,
      skeleton: const CardRowsSkeleton(
          rows: 4, leadingSize: 24, lines: 1, trailing: 2),
      builder: (rows) {
        final byChannel = {for (final r in rows) '${r['channel']}': r};
        var order = 0;
        return Column(
          children: [
            for (final entry in posOrderChannels.entries)
              Builder(
                builder: (context) {
                  final row = byChannel[entry.key];
                  final on = row?['is_active'] == true;
                  final isDefault = row?['is_default'] == true;
                  order += 1;
                  final at = order;
                  return SwitchListTile(
                    value: on,
                    onChanged: (v) => _set(
                      context,
                      ref,
                      entry.key,
                      isActive: v,
                      // Switching one off cannot leave it the default,
                      // and switching one on does not steal the
                      // default from whatever has it.
                      isDefault: false,
                      sortOrder: (row?['sort_order'] as num?)?.toInt() ?? at,
                    ),
                    secondary: Icon(channelIcon(entry.key)),
                    title: Row(
                      children: [
                        Flexible(child: Text(entry.value)),
                        if (isDefault) ...[
                          const SizedBox(width: 8),
                          const Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text('Default'),
                          ),
                        ],
                      ],
                    ),
                    subtitle: on && !isDefault
                        ? InkWell(
                            onTap: () => _set(
                              context,
                              ref,
                              entry.key,
                              isActive: true,
                              isDefault: true,
                              sortOrder:
                                  (row?['sort_order'] as num?)?.toInt() ?? at,
                            ),
                            child: const Text('Make this the default'),
                          )
                        : isDefault
                        // Said where it applies, because the default
                        // is what nearly every sale silently becomes.
                        ? const Text('What a sale is unless the till says otherwise')
                        : null,
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

/// The kinds of order this outlet accepts, in the order it lists them.
///
/// A till cannot assume a channel the shop does not take: the outlet's
/// list is what `set_pos_sale_channel` checks, and a default outside it
/// would put a row in the day's report that can only be a mistake.
List<String> choosableChannels(Iterable<Map<String, dynamic>> outletChannels) =>
    [
      for (final c in outletChannels)
        if (c['is_active'] == true) '${c['channel']}',
    ];

/// The outlet's own default, or nothing.
String? outletDefaultChannel(Iterable<Map<String, dynamic>> outletChannels) {
  for (final c in outletChannels) {
    if (c['is_default'] == true && c['is_active'] == true) {
      return '${c['channel']}';
    }
  }
  return null;
}

/// What a sale opened on this till will actually be.
///
/// The same three steps `app.pos_sale_channel_default` takes on insert:
/// whatever the register is for, else whatever the outlet's default is,
/// else `walk_in`. Written out here so the screen can show the answer
/// rather than the setting — a blank field on a till is not "no
/// channel", it is the outlet's channel, and a shop cannot check its
/// own assumption from a blank.
String registerAssumption(
  Map<String, dynamic> register,
  Iterable<Map<String, dynamic>> outletChannels,
) {
  final own = register['default_channel'];
  if (own != null) return '$own';
  return outletDefaultChannel(outletChannels) ?? 'walk_in';
}

/// Whether this till says something the shop does not.
bool registerOverrides(Map<String, dynamic> register) =>
    register['default_channel'] != null;

/// What a till's row says under its name.
String registerChannelLine(
  Map<String, dynamic> register,
  Iterable<Map<String, dynamic>> outletChannels,
) {
  final resolved = channelLabel(registerAssumption(register, outletChannels));
  return registerOverrides(register)
      ? '$resolved — set on this till'
      : '$resolved — whatever the shop says';
}

/// The tills standing in one outlet.
List<Map<String, dynamic>> registersAt(
  Iterable<Map<String, dynamic>> registers,
  String outletId,
) => [
  for (final r in registers)
    if ((r['pos_outlets'] as Map?)?['id'] == outletId) r,
];

/// What each till on this outlet assumes an order is.
///
/// `pos_registers.default_channel` was added by 0229 with the reason
/// written on it — "a kiosk is takeaway, a waiter's tablet is dine-in,
/// so nobody has to say so on every sale" — and
/// `setRegisterDefaultChannel` had no caller. The screen above says
/// twice that a sale is the outlet's default "unless the till says
/// otherwise", and there was nowhere to make a till say otherwise.
class RegisterChannels extends ConsumerWidget {
  const RegisterChannels({super.key, required this.outletId});

  final String outletId;

  Future<void> _set(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> register,
    List<Map<String, dynamic>> accepted,
  ) async {
    final choices = choosableChannels(accepted);
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('What is ${register['name']} usually for?'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: const Text('Whatever the shop says'),
              subtitle: Text(
                channelLabel(outletDefaultChannel(accepted) ?? 'walk_in'),
              ),
              selected: !registerOverrides(register),
              onTap: () => Navigator.of(ctx).pop(''),
            ),
            const Divider(height: 1),
            for (final c in choices)
              ListTile(
                leading: Icon(channelIcon(c)),
                title: Text(channelLabel(c)),
                selected: register['default_channel'] == c,
                onTap: () => Navigator.of(ctx).pop(c),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () => repo.setRegisterDefaultChannel(
        register['id'] as String,
        picked.isEmpty ? null : picked,
      ),
    );
    if (ok) ref.invalidate(posRegistersProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registers = ref.watch(posRegistersProvider);
    final accepted =
        ref.watch(posOutletChannelsProvider(outletId)).valueOrNull ??
        const <Map<String, dynamic>>[];

    return AsyncView<List<Map<String, dynamic>>>(
      value: registers,
      skeleton: const CardRowsSkeleton(rows: 3, trailing: 1),
      builder: (all) {
        final here = registersAt(all, outletId);
        if (here.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No tills in this shop yet.'),
          );
        }
        return Column(
          children: [
            for (final r in here)
              ListTile(
                dense: true,
                leading: Icon(
                  channelIcon(registerAssumption(r, accepted)),
                ),
                title: Text('${r['name']}'),
                subtitle: Text(registerChannelLine(r, accepted)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => _set(context, ref, r, accepted),
              ),
          ],
        );
      },
    );
  }
}

/// The last thirty days, split by how the orders came in.
///
/// Beside the switches on purpose: "is this channel worth keeping on"
/// is the question somebody is holding when they look at this list, and
/// answering it somewhere else means they answer it from memory.
class ChannelMix extends ConsumerWidget {
  const ChannelMix({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mix = ref.watch(posChannelMixProvider);
    return AsyncView<List<Map<String, dynamic>>>(
      value: mix,
      skeleton: const CardRowsSkeleton(
          rows: 4, leading: false, lines: 1, trailing: 2),
      builder: (rows) {
        if (rows.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Nothing sold in the last thirty days.'),
          );
        }
        return Column(
          children: [
            for (final r in rows)
              ListTile(
                dense: true,
                leading: Icon(channelIcon(r['channel'])),
                title: Text(channelLabel(r['channel'])),
                subtitle: Text(
                  [
                    '${r['sales']} sale${r['sales'] == 1 ? '' : 's'}',
                    'average ${Fmt.money(posNum(r['average']))}',
                    if (r['covers'] != null) '${r['covers']} covers',
                  ].join(' · '),
                ),
                trailing: Text(Fmt.money(posNum(r['total']))),
              ),
          ],
        );
      },
    );
  }
}
