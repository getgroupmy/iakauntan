import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'modifier_sheet.dart';
import 'till_screen.dart' show PosRegisterPicker, posNum;

/// The machine by the door.
///
/// ## The only screen here a stranger uses
///
/// Everything else in this application is used by somebody who was
/// trained on it and will use it again tomorrow. This one is used once,
/// by a person holding a tray, who will not read anything and cannot be
/// corrected. So it is built to a different standard: large targets,
/// one decision per screen, and no state that can strand somebody.
///
/// It also has no cashier to recover from a mistake, which decides most
/// of what follows.
///
/// ## Why it starts from an idle screen and returns to one
///
/// A kiosk left showing the last customer's basket is a kiosk that
/// charges the next person for food they did not order. So the screen
/// goes back to "Tap to order" after every finished order, and after a
/// stretch of inactivity: somebody who walks away mid-order has
/// abandoned it, and the next person must not inherit it.
///
/// Abandoning costs nothing. The sale is parked and never completed, so
/// no invoice exists, no stock moves, and no number is issued — which
/// is exactly what 0212 says about a redemption on a parked bill and is
/// true here for the same reason.
///
/// ## No cash, and the screen says so before it is asked
///
/// `complete_kiosk_order` refuses a cash tender, because a kiosk has no
/// drawer and nobody to open one. The screen filters cash out of the
/// list rather than offering it and reporting the refusal — a customer
/// told "no" by a machine has nobody to ask why.
///
/// ## The number comes before the thanks
///
/// `complete_kiosk_order` takes the order number *before* it completes
/// the sale, so a customer who has paid always has one. The screen
/// keeps that order: the big number is what fills the last panel, and
/// the receipt total sits under it.
class KioskScreen extends ConsumerStatefulWidget {
  const KioskScreen({super.key});

  @override
  ConsumerState<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends ConsumerState<KioskScreen> {
  String? _registerId;
  String? _outletId;
  String? _saleId;
  String? _category;
  int? _orderNo;

  /// Whether somebody is standing here. Client-side only — nothing is
  /// written until an item is tapped, so an abandoned "start" costs
  /// nothing and, crucially, leaves no empty parked sale behind. An
  /// empty sale would be worse than untidy: `close_pos_shift` refuses
  /// while anything is parked, so a day of people tapping the screen
  /// and walking away would stop the shop closing its drawer.
  bool _started = false;
  double? _paidTotal;
  bool _busy = false;

  /// Nobody is standing behind this one to notice it has been left
  /// half-finished, so it clears itself.
  Timer? _idle;

  static const _idleAfter = Duration(minutes: 2);

  @override
  void dispose() {
    _idle?.cancel();
    super.dispose();
  }

  void _touched() {
    _idle?.cancel();
    if (!_started) setState(() => _started = true);
    _idle = Timer(_idleAfter, () {
      if (mounted) _reset();
    });
  }

  /// Back to the attract screen. The parked sale is deliberately left
  /// where it is rather than voided: it holds no money and no number,
  /// and a till can settle it if the customer turns up at the counter
  /// saying the machine ate their order — which is the one recovery a
  /// kiosk has.
  void _reset() {
    _idle?.cancel();
    setState(() {
      _started = false;
      _saleId = null;
      _category = null;
      _orderNo = null;
      _paidTotal = null;
    });
  }

  void _pickRegister(Map<String, dynamic> reg) {
    setState(() {
      _registerId = reg['id'] as String?;
      _outletId = (reg['pos_outlets'] as Map?)?['id'] as String?;
      _saleId = null;
    });
  }

  Future<void> _add(Map<String, dynamic> item) async {
    final reg = _registerId;
    final repo = ref.read(repoProvider);
    if (reg == null || repo == null || _busy) return;
    _touched();
    final itemId = item['item_id'] as String;

    // Asked before anything is written, exactly as at the till. On a
    // kiosk the reason is sharper: there is nobody to ask afterwards
    // whether the customer wanted it spicy.
    List<ModifierChoice> mods = const [];
    final options = await ref.read(itemModifierOptionsProvider(itemId).future);
    if (!mounted) return;
    if (options.isNotEmpty) {
      final picked = await showModalBottomSheet<List<ModifierChoice>>(
        context: context,
        isScrollControlled: true,
        builder: (_) => ModifierSheet(
          itemName: '${item['name']}',
          basePrice: posNum(item['unit_price']),
          options: options,
        ),
      );
      if (picked == null || !mounted) return;
      mods = picked;
    }

    setState(() => _busy = true);
    var sale = _saleId;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () async {
        // `start_kiosk_order` rather than `open_pos_sale`: it refuses on
        // a staff till, which is what stops a screen pointed at the
        // wrong register selling with nobody behind it.
        sale ??= await repo.startKioskOrder(reg);
        final line = await repo.addPosSaleLine(
          sale!,
          itemId,
          price: posNum(item['unit_price']),
        );
        // Listed answers only. `allowTyped` is off on a kiosk, so
        // nothing else can be here — and a customer who could type
        // their own price would type nought.
        for (final m in mods) {
          if (m.modifierId != null) {
            await repo.addLineModifier(line, m.modifierId!);
          }
        }
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    final id = sale;
    if (id == null) return;
    setState(() => _saleId = id);
    ref
      ..invalidate(posSaleProvider(id))
      ..invalidate(posSaleLinesProvider(id));
    _touched();
  }

  Future<void> _remove(String lineId) async {
    final repo = ref.read(repoProvider);
    final id = _saleId;
    if (repo == null || id == null) return;
    _touched();
    // Always free. Nothing on a kiosk basket has been sent anywhere —
    // `complete_kiosk_order` is what tells the kitchen, and it has not
    // run yet.
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () => repo.removePosSaleLine(lineId),
    );
    if (!ok || !mounted) return;
    ref
      ..invalidate(posSaleProvider(id))
      ..invalidate(posSaleLinesProvider(id));
  }

  Future<void> _pay(List<Map<String, dynamic>> tenders, double total) async {
    final id = _saleId;
    final repo = ref.read(repoProvider);
    if (id == null || repo == null || tenders.isEmpty) return;
    _touched();

    final chosen = tenders.length == 1
        ? tenders.first
        : await showModalBottomSheet<Map<String, dynamic>>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'How would you like to pay?',
                      style: TextStyle(fontSize: 24),
                    ),
                  ),
                  for (final t in tenders)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 8,
                      ),
                      leading: const Icon(Icons.credit_card, size: 32),
                      title: Text(
                        '${t['name']}',
                        style: const TextStyle(fontSize: 22),
                      ),
                      onTap: () => Navigator.of(ctx).pop(t),
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
    if (chosen == null || !mounted) return;

    setState(() => _busy = true);
    Map<String, dynamic>? done;
    final ok = await runWithFeedback(
      context,
      pendingMessage: 'Taking payment…',
      successMessage: null,
      action: () async {
        done = await repo.completeKioskOrder(id, chosen['id'] as String);
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok || done == null) return;

    _idle?.cancel();
    setState(() {
      _orderNo = (done!['order_no'] as num?)?.toInt();
      _paidTotal = posNum(done!['total']);
      _saleId = null;
      _category = null;
    });
    final outlet = _outletId;
    if (outlet != null) ref.invalidate(kioskOrderBoardProvider(outlet));

    // Long enough to write the number down, short enough that the next
    // customer is not kept waiting by somebody else's receipt.
    _idle = Timer(const Duration(seconds: 20), () {
      if (mounted) _reset();
    });
  }

  @override
  Widget build(BuildContext context) {
    final registers = ref.watch(posRegistersProvider);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<List<Map<String, dynamic>>>(
          value: registers,
          builder: (rows) {
            // Only the kiosks. Pointing this screen at a staff till
            // would be a sale with nobody behind it, and
            // `start_kiosk_order` refuses one — better not to offer the
            // choice than to make the refusal reachable.
            final kiosks = [for (final r in rows) if (r['is_kiosk'] == true) r];
            if (kiosks.isEmpty) {
              return const EmptyState(
                icon: Icons.storefront_outlined,
                title: 'No kiosk here',
                message:
                    'Mark a register as a kiosk before pointing a screen '
                    'at this.',
              );
            }
            _registerId ??= kiosks.first['id'] as String?;
            _outletId ??=
                (kiosks.first['pos_outlets'] as Map?)?['id'] as String?;

            final picker = PosRegisterPicker(
              registers: kiosks,
              selectedId: _registerId,
              onPicked: _pickRegister,
            );

            final number = _orderNo;
            if (number != null) return _Thanks(orderNo: number, total: _paidTotal);

            if (!_started) return _Attract(picker: picker, onStart: _touched);

            return _Ordering(
              outletId: _outletId,
              saleId: _saleId,
              category: _category,
              busy: _busy,
              onCategory: (c) => setState(() => _category = c),
              onPick: _add,
              onRemove: _remove,
              onPay: _pay,
              onCancel: _reset,
            );
          },
        ),
      ),
    );
  }
}

/// Nothing on the screen but an invitation.
///
/// The register picker is here and nowhere else, because it is the one
/// control meant for staff: whoever sets the machine up picks the till
/// once, and a customer standing in front of a started order should
/// never be able to change which register they are buying from.
class _Attract extends StatelessWidget {
  const _Attract({required this.picker, required this.onStart});

  final Widget picker;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Align(alignment: Alignment.topRight, child: picker),
        Expanded(
          // The whole surface, because a first tap on a kiosk should
          // land wherever a thumb lands rather than on a button
          // somebody has to find.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onStart,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.touch_app_outlined,
                    size: 96,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Tap to order',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pay by card or e-wallet. You will get a number to '
                    'watch for.',
                    style: Theme.of(context).textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The menu, the basket and the way to pay.
class _Ordering extends ConsumerWidget {
  const _Ordering({
    required this.outletId,
    required this.saleId,
    required this.category,
    required this.busy,
    required this.onCategory,
    required this.onPick,
    required this.onRemove,
    required this.onPay,
    required this.onCancel,
  });

  final String? outletId;

  /// Null until the first item is tapped. The sale is opened by the
  /// tap, not by somebody walking up — see `_started`.
  final String? saleId;
  final String? category;
  final bool busy;
  final ValueChanged<String?> onCategory;
  final ValueChanged<Map<String, dynamic>> onPick;
  final ValueChanged<String> onRemove;
  final void Function(List<Map<String, dynamic>>, double) onPay;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outlet = outletId;
    final menu = outlet == null
        ? const AsyncValue<List<Map<String, dynamic>>>.data(
            <Map<String, dynamic>>[],
          )
        : ref.watch(posMenuProvider(outlet));
    final id = saleId;
    final sale = id == null
        ? const AsyncValue<Map<String, dynamic>?>.data(null)
        : ref.watch(posSaleProvider(id));
    final lines = id == null
        ? const AsyncValue<List<Map<String, dynamic>>>.data(
            <Map<String, dynamic>>[],
          )
        : ref.watch(posSaleLinesProvider(id));
    final tenders = ref.watch(posTenderTypesProvider);

    final total = sale.maybeWhen(
      data: (r) => posNum(r?['total_amount']),
      orElse: () => 0.0,
    );
    // Cash is not on this list. `complete_kiosk_order` refuses it and
    // there is nobody here to explain the refusal to.
    final ways = tenders.maybeWhen(
      data: (r) => [for (final t in r) if (t['kind'] != 'cash') t],
      orElse: () => const <Map<String, dynamic>>[],
    );

    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 2,
                child: AsyncView<List<Map<String, dynamic>>>(
                  value: menu,
                  builder: (rows) => _Menu(
                    rows: rows,
                    category: category,
                    onCategory: onCategory,
                    onPick: busy ? (_) {} : onPick,
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: _Tray(
                  lines: lines,
                  total: total,
                  onRemove: onRemove,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onCancel,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                  ),
                  child: const Text(
                    'Start again',
                    style: TextStyle(fontSize: 20),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: busy || total <= 0 || ways.isEmpty
                      ? null
                      : () => onPay(ways, total),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                  ),
                  child: Text(
                    'Pay ${Fmt.money(total)}',
                    style: const TextStyle(fontSize: 22),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Categories first, then what is in one.
///
/// Unlike the till's grid, which measures whether the whole menu fits,
/// this always goes through a category. A cashier knows the menu and a
/// customer does not: a wall of ninety tiles is how somebody gives up
/// and joins the queue instead.
class _Menu extends StatelessWidget {
  const _Menu({
    required this.rows,
    required this.category,
    required this.onCategory,
    required this.onPick,
  });

  final List<Map<String, dynamic>> rows;
  final String? category;
  final ValueChanged<String?> onCategory;
  final ValueChanged<Map<String, dynamic>> onPick;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const EmptyState(
        icon: Icons.no_food_outlined,
        title: 'Nothing to sell',
        message: 'This outlet has no sellable items.',
      );
    }

    final groups = <String>{
      for (final r in rows) '${r['category'] ?? 'Everything else'}',
    }.toList()..sort();

    // One category is not a choice. Skipping it saves a tap that
    // teaches nothing.
    final showing = category ?? (groups.length == 1 ? groups.first : null);
    if (showing == null) {
      return GridView.count(
        crossAxisCount: 3,
        padding: const EdgeInsets.all(16),
        childAspectRatio: 1.6,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        children: [
          for (final g in groups)
            Card(
              child: InkWell(
                onTap: () => onCategory(g),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      g,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    final items = [
      for (final r in rows)
        if ('${r['category'] ?? 'Everything else'}' == showing) r,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (groups.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: TextButton.icon(
              onPressed: () => onCategory(null),
              icon: const Icon(Icons.arrow_back),
              label: const Text('All categories'),
            ),
          ),
        Expanded(
          child: GridView.count(
            crossAxisCount: 3,
            padding: const EdgeInsets.all(16),
            childAspectRatio: 1.2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (final i in items)
                Card(
                  child: InkWell(
                    onTap: () => onPick(i),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '${i['name']}',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            Fmt.money(posNum(i['unit_price'])),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What the customer has picked, and the one way to change their mind.
class _Tray extends StatelessWidget {
  const _Tray({
    required this.lines,
    required this.total,
    required this.onRemove,
  });

  final AsyncValue<List<Map<String, dynamic>>> lines;
  final double total;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Your order',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        Expanded(
          child: AsyncView<List<Map<String, dynamic>>>(
            value: lines,
            skeleton: const ListSkeleton(rows: 6, leading: false),
            builder: (rows) => rows.isEmpty
                ? const Center(child: Text('Nothing yet'))
                : ListView(
                    children: [
                      for (final l in rows)
                        ListTile(
                          title: Text('${l['description']}'),
                          subtitle: Text(
                            '${Fmt.qty(posNum(l['quantity']))} × '
                            '${Fmt.money(posNum(l['unit_price']))}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(Fmt.money(posNum(l['line_total']))),
                              IconButton(
                                tooltip: 'Take it off',
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () => onRemove(l['id'] as String),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total', style: Theme.of(context).textTheme.titleLarge),
              Text(
                Fmt.money(total),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The number, and nothing competing with it.
class _Thanks extends StatelessWidget {
  const _Thanks({required this.orderNo, required this.total});

  final int orderNo;
  final double? total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Your order number', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '$orderNo',
            style: Theme.of(context).textTheme.displayLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (total != null)
            Text(
              'Paid ${Fmt.money(total!)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          const SizedBox(height: 24),
          Text(
            'Watch the board — we will call this number.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
