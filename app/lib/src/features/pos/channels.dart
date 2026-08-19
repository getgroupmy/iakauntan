import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
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
