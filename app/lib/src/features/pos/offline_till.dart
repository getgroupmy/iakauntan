import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
import 'offline_controller.dart';
import 'offline_store.dart';
import 'till_screen.dart' show posNum;

/// The till, with nothing behind it.
///
/// A separate surface rather than a mode woven through the online one,
/// because almost nothing is shared: there is no sale to open, no line
/// to price, no shift to check and no server to ask. What is left is a
/// list of things this outlet sold last time anybody looked, a basket
/// held in memory, and one write to disk when the money changes hands.
///
/// Everything it does is provisional. When the batch lands,
/// `complete_pos_sale` recomputes the totals, the rounding and the
/// change from the items as they are then — this screen's figures are
/// what the cashier needed in order to hand over coins, not what
/// reaches the ledger.
class OfflineTill extends ConsumerStatefulWidget {
  const OfflineTill({
    super.key,
    required this.registerId,
    required this.outletId,
  });

  final String registerId;
  final String? outletId;

  @override
  ConsumerState<OfflineTill> createState() => _OfflineTillState();
}

class _OfflineTillState extends ConsumerState<OfflineTill> {
  List<Map<String, dynamic>> _menu = const [];
  bool _loading = true;
  final _basket = <OfflineLine>[];

  @override
  void initState() {
    super.initState();
    _loadMenu();
  }

  Future<void> _loadMenu() async {
    final outlet = widget.outletId;
    if (outlet == null) {
      setState(() => _loading = false);
      return;
    }
    final rows = await ref.read(posOfflineProvider.notifier).cachedMenu(outlet);
    if (!mounted) return;
    setState(() {
      _menu = rows;
      _loading = false;
    });
  }

  num get _total => _basket.fold<num>(0, (n, l) => n + l.total);

  void _add(Map<String, dynamic> item) {
    setState(() {
      // Same item twice is one line with two on it, which is what a
      // cashier means by tapping it again — and it keeps the payload
      // small on a device that may hold a whole day.
      final at = _basket.indexWhere((l) => l.itemId == item['item_id']);
      if (at >= 0) {
        final old = _basket[at];
        _basket[at] = OfflineLine(
          itemId: old.itemId,
          description: old.description,
          quantity: old.quantity + 1,
          unitPrice: old.unitPrice,
        );
      } else {
        _basket.add(
          OfflineLine(
            itemId: '${item['item_id']}',
            description: '${item['name']}',
            quantity: 1,
            unitPrice: posNum(item['unit_price']),
          ),
        );
      }
    });
  }

  Future<void> _take() async {
    // Offline, so this usually fails, and that is survivable. The list
    // only names the tender; a sale recorded against no name is still a
    // sale, and refusing to take money because a lookup table could not
    // be read is the failure that would actually cost something.
    List<Map<String, dynamic>> tenders;
    try {
      tenders = await ref.read(posTenderTypesProvider.future);
    } catch (_) {
      tenders = const [];
    }
    if (!mounted) return;
    final result = await showModalBottomSheet<({String type, num given})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OfflinePaySheet(total: _total, tenders: tenders),
    );
    if (result == null || !mounted) return;

    final sale = OfflineSale(
      clientUuid: newClientUuid(),
      registerId: widget.registerId,
      outletId: widget.outletId ?? '',
      soldAt: DateTime.now(),
      lines: List.of(_basket),
      tenders: [OfflineTender(typeId: result.type, amount: result.given)],
    );
    await ref.read(posOfflineProvider.notifier).enqueue(sale);
    if (!mounted) return;

    final change = result.given - cashDue(_total);
    setState(_basket.clear);
    if (change > 0) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Change'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                Fmt.money(change),
                style: Theme.of(ctx).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              // Said plainly rather than left to be discovered. The
              // receipt does not exist yet and will be numbered when
              // the batch lands.
              const Text(
                'Held on this device until there is signal. No receipt '
                'number yet.',
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Next customer'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_menu.isEmpty) {
      return const EmptyState(
        icon: Icons.wifi_off_outlined,
        title: 'Nothing cached to sell',
        message:
            'This device has never loaded this outlet’s menu, so it '
            'has nothing to sell from. Connect once and it will keep a '
            'copy.',
      );
    }

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => GridView.count(
              crossAxisCount: box.maxWidth ~/ 160 < 2 ? 2 : box.maxWidth ~/ 160,
              padding: const EdgeInsets.all(12),
              childAspectRatio: 1.4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (final i in _menu)
                  Card(
                    child: InkWell(
                      onTap: () => _add(i),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '${i['name']}',
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              Fmt.money(posNum(i['unit_price'])),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        if (_basket.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < _basket.length; i++)
                  ListTile(
                    dense: true,
                    title: Text(_basket[i].description),
                    subtitle: Text(
                      '${Fmt.qty(_basket[i].quantity)} × '
                      '${Fmt.money(_basket[i].unitPrice)}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(Fmt.money(_basket[i].total)),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => setState(() => _basket.removeAt(i)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  Fmt.money(_total),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              FilledButton.icon(
                onPressed: _basket.isEmpty ? null : _take,
                icon: const Icon(Icons.payments),
                label: const Text('Take payment'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Taking the money with nothing to ask.
///
/// The five-sen rounding is worked out here by [cashDue], a mirror of
/// `app.pos_cash_due`. It has to be: a cashier cannot wait for a server
/// to say what coins to hand back. The server computes it again when
/// the batch lands and that answer is the one that posts.
class _OfflinePaySheet extends StatefulWidget {
  const _OfflinePaySheet({required this.total, required this.tenders});

  final num total;
  final List<Map<String, dynamic>> tenders;

  @override
  State<_OfflinePaySheet> createState() => _OfflinePaySheetState();
}

class _OfflinePaySheetState extends State<_OfflinePaySheet> {
  final _amount = TextEditingController();
  String? _type;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _type ??= widget.tenders.isEmpty
        ? null
        : widget.tenders.first['id'] as String?;
    final due = cashDue(widget.total);
    final given = num.tryParse(_amount.text) ?? due;
    final change = given - due;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'To pay',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(
                  Fmt.money(due),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ],
            ),
            if (due != widget.total)
              Text(
                'Rounded from ${Fmt.money(widget.total)} to the nearest '
                'five sen',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 12),
            if (widget.tenders.isEmpty)
              const Text(
                'No tender list on this device, so this is recorded as '
                'cash and can be corrected once it lands.',
              )
            else
              Wrap(
                spacing: 8,
                children: [
                  for (final t in widget.tenders)
                    ChoiceChip(
                      label: Text('${t['name']}'),
                      selected: t['id'] == _type,
                      onSelected: (_) =>
                          setState(() => _type = t['id'] as String?),
                    ),
                ],
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Handed over',
                helperText: 'Leave blank to take the exact amount',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Text(
              change > 0 ? 'Change ${Fmt.money(change)}' : 'No change',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _type == null || change < 0
                  ? null
                  : () => Navigator.of(context).pop(
                      (type: _type!, given: given),
                    ),
              child: const Text('Take it'),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the till says about signal, and what is waiting because of it.
///
/// Always on the till, not only when offline: a queue that has not been
/// sent is the single most important thing about a till holding one,
/// and a banner that disappears the moment signal returns is a banner
/// that hides the sales still on the device.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(posOfflineProvider);
    if (!state.offline && state.queue.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final waiting = state.waiting;
    return Material(
      color: state.offline
          ? scheme.errorContainer
          : scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(
              state.offline ? Icons.wifi_off : Icons.cloud_upload_outlined,
              size: 18,
              color: state.offline
                  ? scheme.onErrorContainer
                  : scheme.onTertiaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  if (state.offline) 'Offline',
                  if (waiting > 0)
                    '$waiting sale${waiting == 1 ? '' : 's'} waiting '
                        '(${Fmt.money(state.held)})',
                ].join(' · '),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: state.offline
                      ? scheme.onErrorContainer
                      : scheme.onTertiaryContainer,
                ),
              ),
            ),
            if (waiting > 0)
              TextButton(
                onPressed: state.sending
                    ? null
                    : () async {
                        final rows = await ref
                            .read(posOfflineProvider.notifier)
                            .flush();
                        if (rows == null || !context.mounted) return;
                        final landed = rows
                            .where((r) => r['outcome'] == 'landed')
                            .length;
                        final already = rows
                            .where((r) => r['outcome'] == 'already')
                            .length;
                        final bad = rows
                            .where((r) => r['outcome'] == 'rejected')
                            .length;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              [
                                '$landed landed',
                                // Not an error, and said anyway: a
                                // retry that finds the sale already
                                // there is the idempotence working, and
                                // hiding it makes a resend look like a
                                // double charge.
                                if (already > 0) '$already already there',
                                if (bad > 0) '$bad rejected',
                              ].join(', '),
                            ),
                          ),
                        );
                      },
                child: Text(state.sending ? 'Sending…' : 'Send now'),
              ),
            IconButton(
              tooltip: state.offline ? 'Back online' : 'Work offline',
              icon: Icon(
                state.offline ? Icons.cloud_done_outlined : Icons.cloud_off,
                size: 18,
              ),
              onPressed: () => ref
                  .read(posOfflineProvider.notifier)
                  .setOffline(!state.offline),
            ),
          ],
        ),
      ),
    );
  }
}
