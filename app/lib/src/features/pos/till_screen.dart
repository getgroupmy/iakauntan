import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// The POS methods live in an extension on Repo, and a Dart extension is
// only in scope where its declaring library is imported.
import '../../data/repository.dart';
import 'assign_table.dart';
import 'channels.dart';
import 'delivery_sheet.dart';
import 'sold_out_dialog.dart';
import 'take_it_off.dart';
import 'discount_sheet.dart';
import 'receipt_view.dart';
import 'modifier_sheet.dart';
import 'offline_controller.dart';
import 'offline_till.dart';
import 'split_sheet.dart';
import 'tender_sheet.dart';
import 'void_sheet.dart';

/// PostgREST hands numerics back as strings so nothing is lost on the
/// way through JSON.
double posNum(Object? v) => v == null ? 0 : double.tryParse(v.toString()) ?? 0;

/// The till.
///
/// One screen, three shapes. On a counter there is room for the search
/// beside the basket; on a tablet held in one hand there is room for
/// one of them at a time; on a phone the basket is a sheet that comes
/// up when there is something in it. The same widgets in all three,
/// because a cashier who learns the counter should not have to learn
/// the phone.
///
/// What it will not do is as much of the design as what it will. There
/// is no way to sell before a drawer is open, no way to type a total,
/// and no way to take money without the server saying what the money
/// comes to — every figure on the tender sheet comes back from
/// `complete_pos_sale`, because the arithmetic that decides what a
/// customer hands over is not something a screen should be doing.
class TillScreen extends ConsumerStatefulWidget {
  const TillScreen({super.key});

  @override
  ConsumerState<TillScreen> createState() => _TillScreenState();
}

class _TillScreenState extends ConsumerState<TillScreen> {
  String? _registerId;
  String? _outletId;
  String? _saleId;

  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  List<Map<String, dynamic>> _results = const [];
  bool _looking = false;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Both lists of open bills. The merge bar still asks per-register
  /// and the basket asks per-outlet, so anything that opens, moves or
  /// closes a bill has to unsettle both or one of them lies.
  void _refreshOrders() {
    final reg = _registerId;
    if (reg != null) ref.invalidate(parkedPosSalesProvider(reg));
    final outlet = _outletId;
    if (outlet != null) ref.invalidate(posOpenOrdersProvider(outlet));
  }

  void _pickRegister(Map<String, dynamic> reg) {
    setState(() {
      _registerId = reg['id'] as String?;
      _outletId = (reg['pos_outlets'] as Map?)?['id'] as String?;
      _saleId = null;
      _results = const [];
    });
  }

  Future<void> _openShift() async {
    final id = _registerId;
    if (id == null) return;
    final float = await _askAmount(
      context,
      title: 'Open the drawer',
      hint: 'What is in it to start with',
    );
    if (float == null || !mounted) return;
    final ok = await runWithFeedback(
      context,
      pendingMessage: 'Opening…',
      successMessage: 'Drawer open',
      action: () => ref.read(repoProvider)!.openPosShift(id, float),
    );
    if (ok) ref.invalidate(currentPosShiftProvider(id));
  }

  /// Counting the drawer. The declared figure is asked for BEFORE the
  /// expected one is shown, which is the whole point of a cash-up: a
  /// count taken after seeing the answer is not a count.
  Future<void> _closeShift(String shiftId) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    // Stopped before the figure is asked for, not after. A cash-up is
    // only meaningful if the count and the expected figure describe the
    // same drawer, and a sale rung up while somebody counts makes them
    // describe two different ones — with the difference recorded
    // against the person who counted. 0361.
    final stopped = await runWithFeedback(
      context,
      pendingMessage: 'Stopping the till…',
      successMessage: null,
      action: () => repo.beginPosCount(shiftId),
    );
    if (!stopped || !mounted) return;
    final stoppedOn = _registerId;
    if (stoppedOn != null) ref.invalidate(currentPosShiftProvider(stoppedOn));

    final declared = await _askAmount(
      context,
      title: 'Count the drawer',
      hint: 'What is actually in it',
    );
    if (declared == null) {
      // Changed their mind at the prompt. Putting the till back is the
      // whole reason `resume_pos_shift` exists: a stopped till nobody
      // can restart is how a shift gets closed early to take one
      // customer.
      if (!mounted) return;
      await runWithFeedback(
        context,
        successMessage: 'Back in service',
        action: () => repo.resumePosShift(shiftId),
      );
      final back = _registerId;
      if (mounted && back != null) {
        ref.invalidate(currentPosShiftProvider(back));
      }
      return;
    }
    if (!mounted) return;
    Map<String, dynamic>? result;
    final ok = await runWithFeedback(
      context,
      pendingMessage: 'Closing…',
      successMessage: 'Drawer counted',
      action: () async {
        result = await repo.closePosShift(shiftId, declared);
      },
    );
    if (!ok || !mounted) return;
    final id = _registerId;
    if (id != null) ref.invalidate(currentPosShiftProvider(id));
    final r = result;
    if (r == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cash up'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AmountRow('Expected', posNum(r['expected_cash'])),
            _AmountRow('Counted', posNum(r['declared_cash'])),
            const Divider(),
            _AmountRow('Difference', posNum(r['variance']), emphasise: true),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _look(String code) async {
    final outlet = _outletId;
    if (outlet == null || code.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _looking = true);
    try {
      final rows = await ref.read(repoProvider)!.posLookup(outlet, code.trim());
      if (!mounted) return;
      // A single barcode match is not a list to choose from — it is the
      // gun having done its job. Ring it up and clear the box, because
      // the next thing the cashier does is scan the next item.
      //
      // A scale label is the same: it already names the item and the
      // weight, so there is nothing left to ask. It arrives as its own
      // `matched_on` rather than as 'barcode' so a shop reading its
      // logs can tell the gun from the scale.
      if (rows.length == 1 &&
          (rows.first['matched_on'] == 'barcode' ||
              rows.first['matched_on'] == 'scale')) {
        setState(() => _results = const []);
        await _add(rows.first);
        return;
      }
      setState(() => _results = rows);
    } finally {
      if (mounted) setState(() => _looking = false);
    }
  }

  Future<void> _add(Map<String, dynamic> hit) async {
    final reg = _registerId;
    if (reg == null) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final itemId = hit['item_id'] as String;

    // Sold by weight and rung up by hand: the hanging scale says a
    // number and somebody types it. Asked before anything is written,
    // and skipped entirely when the weight already came off a printed
    // label — the scale did the asking at the counter.
    num? weight;
    if (hit['is_weighed'] == true && hit['matched_on'] != 'scale') {
      weight = await showDialog<num>(
        context: context,
        builder: (_) => _WeightDialog(
          name: '${hit['name']}',
          uom: '${hit['uom_code'] ?? ''}',
          unitPrice: posNum(hit['unit_price']),
        ),
      );
      // Dismissed rather than answered. Nothing is written yet.
      if (weight == null || !mounted) return;
    }

    // Asked before anything is written, because the answer changes the
    // line rather than following it. Most items have no questions, and
    // for those this costs one cheap round trip and opens nothing — a
    // sheet that appears for a tin of drink is a sheet in the way.
    List<ModifierChoice> mods = const [];
    final options = await ref.read(
      itemModifierOptionsProvider(itemId).future,
    );
    if (!mounted) return;
    if (options.isNotEmpty) {
      final picked = await showModalBottomSheet<List<ModifierChoice>>(
        context: context,
        isScrollControlled: true,
        builder: (_) => ModifierSheet(
          itemName: '${hit['name']}',
          basePrice: posNum(hit['unit_price']),
          options: options,
          // Staff, and a price they answer for. The kiosk does not get
          // this, and the reason is the same one.
          allowTyped: true,
        ),
      );
      // Dismissed rather than answered. Nothing has been written yet,
      // so backing out costs nothing and leaves no half-built line.
      if (picked == null || !mounted) return;
      mods = picked;
    }

    var sale = _saleId;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () async {
        sale ??= await repo.openPosSale(reg);
        final line = await repo.addPosSaleLine(
          sale!,
          itemId,
          quantity:
              weight ??
              (posNum(hit['quantity']) == 0 ? 1 : posNum(hit['quantity'])),
          price: posNum(hit['unit_price']),
        );
        // After the line, because a modifier is priced onto a line that
        // exists. `add_line_modifier` reprices as each one lands.
        for (final m in mods) {
          if (m.modifierId != null) {
            await repo.addLineModifier(line, m.modifierId!);
          } else {
            await repo.addLineFreeModifier(
              line,
              groupId: m.groupId!,
              name: m.name!,
              priceDelta: m.priceDelta,
            );
          }
        }
      },
    );
    if (!ok || !mounted) return;
    setState(() {
      _saleId = sale;
      _search.clear();
    });
    _searchFocus.requestFocus();
    ref
      ..invalidate(posSaleProvider(sale!))
      ..invalidate(posSaleLinesProvider(sale!))
      ..invalidate(posSaleLineModifiersProvider(sale!));
    await _refreshPromotions(sale!);
  }

  /// The kitchen has run out, or has some again.
  ///
  /// 0258 makes this a fact about one shop on one day, so there is no
  /// end date for anybody to forget to clear — the row belongs to today
  /// and today ends. What it does NOT do is stop the sale: a dish taken
  /// off is greyed on the grid, and a bill that already has one on it,
  /// or a van's sale landing an hour later, still goes through.
  Future<void> _stock(Map<String, dynamic> row) async {
    final outlet = _outletId;
    final item = row['item_id'] as String?;
    if (outlet == null || item == null) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    // Off for a rule rather than for stock. Putting it back is not this
    // button's job, and pretending otherwise would have a cashier
    // tapping at a timetable.
    final scheduled = row['available'] == false &&
        !'${row['off_reason'] ?? ''}'.toLowerCase().contains('sold out');

    final off = row['available'] == false;
    final go = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('${row['name']}'),
              subtitle: Text(
                off ? '${row['off_reason'] ?? ''}' : 'On the menu',
              ),
            ),
            const Divider(height: 1),
            if (off)
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('We have it again'),
                subtitle: scheduled
                    ? const Text('This one is off by its schedule, not by stock')
                    : null,
                onTap: () => Navigator.of(ctx).pop('resume'),
              )
            else
              ListTile(
                leading: const Icon(Icons.no_food_outlined),
                title: const Text('Sold out for today'),
                subtitle: const Text('Back on the menu tomorrow'),
                onTap: () => Navigator.of(ctx).pop('stop'),
              ),
          ],
        ),
      ),
    );
    if (go == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      successMessage: go == 'stop' ? 'Taken off for today' : 'Back on',
      action: () => go == 'stop'
          ? repo.stopPosItem(outlet, item)
          : repo.resumePosItem(outlet, item),
    );
    if (ok && mounted) ref.invalidate(posMenuProvider(outlet));
  }

  /// The basket changed, so the shop's own rules have to be worked out
  /// again.
  ///
  /// A rate on a bill that has grown is worth more and on one that has
  /// shrunk is worth less, and "spend fifty, get five off" has to stop
  /// applying the moment somebody takes the fiftieth ringgit back off.
  ///
  /// Best effort on purpose. `complete_pos_sale` refreshes again before
  /// it works out what to charge, so a failure here costs a stale
  /// number on a screen and never a wrong number in a drawer — and a
  /// till that refused to add a plate because a promotion could not be
  /// recalculated would be worse than either.
  Future<void> _refreshPromotions(String saleId) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    try {
      await repo.refreshPosSalePromotions(saleId);
    } catch (_) {
      // Deliberately swallowed. See above.
    }
    if (!mounted) return;
    ref
      ..invalidate(posSaleProvider(saleId))
      ..invalidate(posSalePromotionsProvider(saleId));
  }

  /// Typing a voucher off a printed slip.
  ///
  /// The server refuses a code that does not qualify rather than
  /// attaching it inert, so what matters here is showing what it said —
  /// "Raya five needs 50.00 and this bill is 43.00" is an answer a
  /// cashier can give the customer.
  /// The bill, on paper, before anybody has paid for it.
  ///
  /// "Bill please" is a print too, and it is the one a table asks for.
  /// The same server function renders it, so what the customer reads at
  /// the table and what comes out of the printer afterwards are the
  /// same document — it just says it has not been paid yet.
  Future<void> _printBill() async {
    final id = _saleId;
    if (id == null) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    String text = '';
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () async => text = await repo.posReceiptText(id),
    );
    if (!ok || !mounted) return;
    await showReceiptSheet(context, text: text, title: 'The bill');
  }

  /// Where this bill is going, and what the ride costs.
  ///
  /// The fee is not asked for here. It comes from the zone the postcode
  /// falls in and is recomputed on every change to the basket, so the
  /// free-delivery promise comes true the moment the qualifying plate
  /// is added rather than at the till's next guess.
  Future<void> _delivery() async {
    final id = _saleId;
    if (id == null) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    // Read first, so correcting an address starts from the one already
    // taken rather than from an empty form.
    final existing = await ref.read(posDeliveryForProvider(id).future);
    if (!mounted) return;
    final saleStatus =
        ref.read(posSaleProvider(id)).valueOrNull?['status'] as String?;
    final canClear = existing.isNotEmpty &&
        deliveryCanBeCleared(
          saleStatus: saleStatus,
          deliveryStatus: existing['status'] as String?,
        );
    final answer = await showDeliverySheet(
      context,
      existing: existing,
      onRemove: canClear ? () => _clearDelivery(id) : null,
    );
    if (answer == null || !mounted) return;

    Map<String, dynamic> got = const {};
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () async {
        got = await repo.setPosDelivery(
          saleId: id,
          line1: answer.line1,
          phone: answer.phone,
          line2: answer.line2.isEmpty ? null : answer.line2,
          city: answer.city.isEmpty ? null : answer.city,
          state: answer.state.isEmpty ? null : answer.state,
          postcode: answer.postcode.isEmpty ? null : answer.postcode,
          recipient: answer.recipient.isEmpty ? null : answer.recipient,
          notes: answer.notes.isEmpty ? null : answer.notes,
        );
      },
    );
    if (!ok || !mounted) return;
    ref
      ..invalidate(posSaleProvider(id))
      ..invalidate(posDeliveryForProvider(id));

    // Said back once: which zone it fell in, what the ride costs, and
    // the shortfall if the order is under that zone's minimum — while
    // the customer is still on the phone and can add to it.
    final blocked = got['blocked_reason'] as String?;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          blocked ??
              [
                if ('${got['zone_name'] ?? ''}'.isNotEmpty)
                  '${got['zone_name']}',
                'delivery ${Fmt.money(posNum(got['fee']))}',
                if (Fmt.toInt(got['eta_minutes']) > 0)
                  'about ${Fmt.toInt(got['eta_minutes'])} minutes',
              ].join(' · '),
        ),
      ),
    );
  }

  Future<void> _coupon() async {
    final id = _saleId;
    if (id == null) return;
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Voucher'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Code',
              hintText: 'RAYA5',
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );
    if (code == null || code.isEmpty || !mounted) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Voucher applied',
      action: () => repo.applyPosCoupon(id, code),
    );
    if (!ok || !mounted) return;
    ref
      ..invalidate(posSaleProvider(id))
      ..invalidate(posSalePromotionsProvider(id));
  }

  /// Take the run back off the bill.
  ///
  /// `clear_pos_delivery` will only do it while the bill is parked and
  /// no driver has it — after that "the run happened", and the way to
  /// record what went wrong is to mark it failed.
  Future<void> _clearDelivery(String id) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Taken off — nothing is being delivered',
      action: () => repo.clearPosDelivery(id),
    );
    if (!ok || !mounted) return;
    ref
      ..invalidate(posSaleProvider(id))
      ..invalidate(posDeliveryForProvider(id));
  }

  /// Take a voucher back off. Deleting the row is the whole of it: no
  /// line was ever rewritten, so there is no price to put back.
  Future<void> _removePromotion(Map<String, dynamic> promo) async {
    final id = _saleId;
    final repo = ref.read(repoProvider);
    if (id == null || repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Taken off',
      action: () => repo.removePosSalePromotion('${promo['id']}'),
    );
    if (!ok || !mounted) return;
    ref
      ..invalidate(posSaleProvider(id))
      ..invalidate(posSalePromotionsProvider(id));
  }

  Future<void> _tender() async {
    final sale = _saleId;
    if (sale == null) return;
    final done = await showTenderSheet(context, saleId: sale);
    if (done != true || !mounted) return;
    setState(() {
      _saleId = null;
      _results = const [];
    });
    _refreshOrders();
    _searchFocus.requestFocus();
  }

  /// Telling the kitchen.
  ///
  /// Separate from tendering on purpose: an order is cooked long before
  /// it is paid for, and a till that only spoke to the kitchen at the
  /// moment money changed hands would be a till that served cold food.
  ///
  /// `send_order_to_kitchen` sends only what has not already gone, so
  /// this is safe to press again after adding a course — which is
  /// exactly how it gets used.
  Future<void> _send() async {
    final id = _saleId;
    if (id == null) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    List<Map<String, dynamic>> sent = const [];
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () async {
        sent = await repo.sendOrderToKitchen(id);
      },
    );
    if (!ok || !mounted) return;
    final lines = sent.fold<int>(
      0,
      (n, r) => n + ((r['line_count'] as num?)?.toInt() ?? 0),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          // Named stations rather than a bare "sent", because a waiter
          // who ordered a plate and a drink needs to know both halves
          // went somewhere.
          sent.isEmpty
              ? 'Everything on this bill has already gone to the kitchen.'
              : '$lines to ${sent.map((r) => r['station']).join(', ')}',
        ),
      ),
    );
    ref.invalidate(posSaleLinesProvider(id));
  }

  /// Two people, two bills. The lines move; nothing is re-priced and
  /// no line is recreated, so the modifiers and the kitchen docket that
  /// point at them still do.
  Future<void> _split() async {
    final id = _saleId;
    if (id == null) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final lines = await ref.read(posSaleLinesProvider(id).future);
    if (!mounted) return;
    if (lines.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A bill needs two lines before it can be split.'),
        ),
      );
      return;
    }
    final moving = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SplitSheet(lines: lines),
    );
    if (moving == null || !mounted) return;

    String? made;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () async {
        made = await repo.splitPosSale(id, moving);
      },
    );
    if (!ok || !mounted) return;
    ref
      ..invalidate(posSaleProvider(id))
      ..invalidate(posSaleLinesProvider(id));
    _refreshOrders();
    final other = made;
    if (other == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Second bill created and parked.'),
        // Offered rather than forced: the person who asked to split is
        // usually still settling the first bill, and jumping the till
        // to the second one would take the screen away mid-payment.
        action: SnackBarAction(
          label: 'Open it',
          onPressed: () => setState(() => _saleId = other),
        ),
      ),
    );
  }

  /// One bill, N cards. Nothing moves — see 0216 on why this is not the
  /// same question as splitting by item, even though a customer asks
  /// both with the same words.
  Future<void> _evenSplit() async {
    final id = _saleId;
    if (id == null) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ways = await _askWays(context);
    if (ways == null || ways < 2 || !mounted) return;
    List<Map<String, dynamic>> shares = const [];
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () async {
        shares = await repo.posEvenSplit(id, ways);
      },
    );
    if (!ok || !mounted || shares.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (_) => EvenSplitDialog(shares: shares),
    );
  }

  /// Putting one back together — the table that decided to pay as one
  /// after all.
  ///
  /// Takes the whole row rather than an id so the confirmation can name
  /// what went in. "Merged" on its own leaves a cashier holding two
  /// printed bills with no way to tell which one is now inside the
  /// other.
  Future<void> _merge(Map<String, dynamic> row) async {
    final into = _saleId;
    final from = row['id'] as String?;
    if (into == null || from == null || into == from) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: '${billLabel(row)} merged in',
      action: () => repo.mergePosSales(into, from),
    );
    if (!ok || !mounted) return;
    ref
      ..invalidate(posSaleProvider(into))
      ..invalidate(posSaleLinesProvider(into))
      ..invalidate(posSaleLineModifiersProvider(into));
    _refreshOrders();
  }

  /// Writing off the whole bill.
  ///
  /// The case it is for: a party walks out on six lines. Before this
  /// they were voided one at a time — six reasons, six records, for one
  /// event — and 0206 had been telling cashiers to "finish or void"
  /// a parked bill before closing a shift since long before there was
  /// a way to void one.
  ///
  /// Asked before the reason, not after. 0247 made the `pos_void` grant
  /// unconditional here, so whether this will be refused is knowable
  /// without asking the server about the bill — and being turned down
  /// after choosing a reason and typing an explanation is a worse
  /// moment to find out. The database still refuses either way; this
  /// only stops the wasted work.
  /// Says no once, in words, rather than hiding the button.
  ///
  /// Same shape as the void refusal above it and for the same reason: a
  /// cashier who tapped something is owed an answer, and a control that
  /// silently does nothing teaches people to tap harder.
  Future<bool> _mayDiscount() async {
    final held = await permissionHeld(ref, 'pos_discount');
    if (!mounted) return false;
    if (held) return true;
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => const SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('Taking money off needs permission'),
              subtitle: Text(
                'This account has not been given it. A manager can, '
                'under Team.',
              ),
            ),
          ],
        ),
      ),
    );
    return false;
  }

  /// Ten per cent off the table, or five ringgit off because the food
  /// was late.
  ///
  /// The rate is the one worth having on a bill: it survives the waiter
  /// bringing another round, which a fixed amount cannot. Both go to
  /// the same function and the server decides which of them to keep
  /// re-applying.
  Future<void> _discountBill() async {
    final id = _saleId;
    if (id == null) return;
    if (!await _mayDiscount()) return;

    final row = ref.read(posSaleProvider(id)).valueOrNull;
    if (row == null || !mounted) return;
    // Before anything came off, which is what a percentage is a
    // percentage of. `total_amount` already has the discount and any
    // redemption taken out of it, so using that would shrink the base
    // every time the sheet was opened.
    final full = posNum(row['subtotal']) + posNum(row['tax_amount']);

    final answer = await showDiscountSheet(
      context,
      subject: 'The whole bill',
      full: full,
      currentPercent: posNum(row['bill_discount_percent']),
      currentAmount: posNum(row['bill_discount']),
      currentReason: row['bill_discount_reason'] as String?,
    );
    if (answer == null || !mounted) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: answer.clear ? 'Back to full price' : 'Taken off',
      action: () => repo.discountPosSale(
        id,
        percent: answer.answer?.percent,
        amount: answer.answer?.amount,
        reason: answer.answer?.reason,
      ),
    );
    if (!ok || !mounted) return;
    ref.invalidate(posSaleProvider(id));
  }

  /// The same, on one line.
  ///
  /// Reachable whether or not the kitchen has the plate, which is the
  /// difference between this and voiding: a steak that arrived burnt
  /// has already been cooked, and taking money off it is the ordinary
  /// answer where taking it off the bill is not.
  Future<void> _discountLine(Map<String, dynamic> line) async {
    final id = _saleId;
    final lineId = line['id'] as String?;
    if (id == null || lineId == null) return;
    if (!await _mayDiscount()) return;
    if (!mounted) return;

    final answer = await showDiscountSheet(
      context,
      subject: '${line['description']}',
      full: posNum(line['unit_price']) * posNum(line['quantity']),
      currentPercent: posNum(line['discount_percent']),
      currentAmount: posNum(line['discount_amount']),
      currentReason: line['discount_reason'] as String?,
    );
    if (answer == null || !mounted) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: answer.clear ? 'Back to full price' : 'Taken off',
      action: () => repo.discountPosSaleLine(
        lineId,
        percent: answer.answer?.percent,
        amount: answer.answer?.amount,
        reason: answer.answer?.reason,
      ),
    );
    if (!ok || !mounted) return;
    ref
      ..invalidate(posSaleProvider(id))
      ..invalidate(posSaleLinesProvider(id));
  }

  Future<void> _voidBill() async {
    final id = _saleId;
    if (id == null) return;
    final mayVoid = await permissionHeld(ref, 'pos_void');
    if (!mounted) return;
    if (!mayVoid) {
      await showModalBottomSheet<void>(
        context: context,
        builder: (_) => const SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.lock_outline),
                title: Text('Writing off a bill needs permission'),
                subtitle: Text(
                  'This account has not been given it. A manager can, '
                  'under Team.',
                ),
              ),
            ],
          ),
        ),
      );
      return;
    }
    // The question comes next and the repository after it: asking why
    // is a screen's job and needs nothing from the server, so a till
    // that has lost its connection still gets as far as saying what it
    // was about to do.
    final no = '${ref.read(posSaleProvider(id)).valueOrNull?['sale_no'] ?? ''}';
    final what = no.isEmpty ? 'this bill' : no;

    final answer = await showModalBottomSheet<({String reason, String note})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => VoidReasonSheet(
        description: what,
        title: 'Write off $what',
        prompt:
            'The whole bill comes off. What was on it is kept as the '
            'record, and anything the kitchen cooked is counted as a '
            'loss.',
        confirmLabel: 'Write it off',
      ),
    );
    if (answer == null || !mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    var lost = 0;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () async {
        lost = await repo.voidPosSale(id, answer.reason, note: answer.note);
      },
    );
    if (!ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          // Said only when there is something to say. A bill nobody
          // cooked from cost nothing, and announcing a loss of nought
          // is noise on a busy counter.
          lost == 0
              ? '$what written off'
              : '$what written off · $lost cooked '
                    '${lost == 1 ? 'item' : 'items'} recorded as a loss',
        ),
      ),
    );
    final outlet = _outletId;
    final reg = _registerId;
    ref.invalidate(posSaleProvider(id));
    if (reg != null) ref.invalidate(parkedPosSalesProvider(reg));
    if (outlet != null) ref.invalidate(posFloorPlanProvider(outlet));
    setState(() {
      _saleId = null;
      _results = const [];
    });
    _refreshOrders();
  }

  /// Taking a line off, which is two different acts depending on one
  /// column. Before `sent_to_kitchen_at` the line is a keystroke and
  /// comes off free; after it, food exists and somebody has to say why
  /// it is not being charged for. The database enforces both — this
  /// only makes sure the right one is offered.
  /// Stepping back to the list without settling.
  ///
  /// Nothing is written. A sale is already `parked` from the moment it
  /// is opened — this only stops looking at it, which is why it can be
  /// offered while the kitchen has half the order.
  void _park() {
    setState(() {
      _saleId = null;
      _results = const [];
    });
    _refreshOrders();
  }

  /// Opening a bill off the shop-wide list.
  ///
  /// One of these is a plain resume and the other moves money between
  /// drawers, so they are not the same tap. A bill already on this till
  /// simply opens. A bill on another till is claimed first — register
  /// and shift together — and the question is asked out loud, because
  /// the cashier is about to become the person whose drawer has to
  /// account for it.
  Future<void> _openOrder(Map<String, dynamic> row) async {
    final reg = _registerId;
    final saleId = row['sale_id'] as String?;
    if (reg == null || saleId == null) return;

    if (row['register_id'] == reg) {
      setState(() => _saleId = saleId);
      return;
    }

    final where = row['register_name'] ?? row['register_code'] ?? 'another till';
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Take this bill?'),
        content: Text(
          '${row['sale_no']} is open on $where. Taking it moves it to '
          'this till, so this drawer is the one that has to account for '
          'it at cash-up.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Leave it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Take it'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Bill moved to this till',
      action: () => repo.claimPosSale(saleId, reg),
    );
    if (!ok || !mounted) return;
    _refreshOrders();
    setState(() => _saleId = saleId);
  }

  /// What is currently on a line, from the sale-wide read the basket
  /// already holds. No extra round trip to answer a question the screen
  /// can already see.
  List<Map<String, dynamic>> _modifiersOn(String lineId) {
    final id = _saleId;
    if (id == null) return const [];
    final all = ref
        .read(posSaleLineModifiersProvider(id))
        .maybeWhen(data: (rows) => rows, orElse: () => const <Map<String, dynamic>>[]);
    return [
      for (final m in all)
        if (m['line_id'] == lineId) m,
    ];
  }

  /// Takes one modifier back off a parked line.
  ///
  /// The server reprices the line afterwards, so nothing here adjusts a
  /// total — a till that subtracted the modifier's price itself would
  /// be a second opinion on what the plate costs, and the bill is the
  /// thing the customer is holding.
  Future<void> _removeModifier(String saleId, String lineId) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final mods = _modifiersOn(lineId);
    if (mods.isEmpty) return;

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in mods)
              ListTile(
                leading: const Icon(Icons.remove_circle_outline),
                title: Text('${m['name']}'),
                onTap: () => Navigator.of(ctx).pop(m['id'] as String),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      // The line repricing in front of them is the message.
      successMessage: null,
      action: () => repo.removeLineModifier(chosen),
    );
    if (!ok || !mounted) return;
    ref
      ..invalidate(posSaleProvider(saleId))
      ..invalidate(posSaleLinesProvider(saleId))
      ..invalidate(posSaleLineModifiersProvider(saleId));
  }

  /// Takes a class, a wash or a treatment on the membership the
  /// customer is already paying for.
  ///
  /// The line stays on the bill and goes to zero rather than coming
  /// off it — a receipt reading "Yoga 45.00 / Membership -45.00" is one
  /// the member can check, and one showing nothing looks like they were
  /// never there. `cover_line_with_membership` decides all of that and
  /// returns what the line came to; nothing here works out whether the
  /// membership covers the item or whether a session is left, because a
  /// second opinion on that would be wrong at exactly the counter where
  /// it is being argued.
  Future<void> _coverWithMembership(String saleId, String lineId) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    final sale = await ref.read(posSaleProvider(saleId).future);
    final contactId = sale?['contact_id'] as String?;
    if (!mounted) return;
    if (contactId == null) {
      // Said here rather than let the server say it, because the fix is
      // on this screen: the cashier has to name the customer first.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Say who the customer is first.'),
        ),
      );
      return;
    }

    final subs = await repo.contactMemberships(contactId);
    if (!mounted) return;
    if (subs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This customer is not on a membership.')),
      );
      return;
    }

    final chosen = subs.length == 1
        ? subs.first['id'] as String
        : await showModalBottomSheet<String>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final sub in subs)
                    ListTile(
                      title: Text(
                        ((sub['pos_memberships']
                                as Map<String, dynamic>?)?['name'] ??
                            'Membership') as String,
                      ),
                      onTap: () =>
                          Navigator.of(ctx).pop(sub['id'] as String),
                    ),
                ],
              ),
            ),
          );
    if (chosen == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      successMessage: 'Covered by the membership',
      action: () => repo.coverLineWithMembership(lineId, chosen),
    );
    if (!ok || !mounted) return;
    ref
      ..invalidate(posSaleProvider(saleId))
      ..invalidate(posSaleLinesProvider(saleId));
  }

  Future<void> _lineAction(Map<String, dynamic> line) async {
    final id = _saleId;
    final lineId = line['id'] as String?;
    if (id == null || lineId == null) return;
    final sent = line['sent_to_kitchen_at'] != null;

    // What the line offers is decided by whether the kitchen has it,
    // and asked before anything is looked up. The repository is
    // fetched at the point of writing instead: a sheet that silently
    // refuses to open is a fault nobody can describe, whereas a write
    // that stops is one the cashier sees.
    String? reason;
    String? note;
    if (!sent) {
      final go = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text('${line['description']}'),
                subtitle: const Text('Not sent yet'),
              ),
              const Divider(height: 1),
              // Offered only where it can work. Covering needs the
              // memberships module and a named customer, and a button
              // that is always there and usually refuses teaches a
              // cashier to stop reading what it says.
              if (moduleEnabledNow(ref, 'memberships'))
                ListTile(
                  leading: const Icon(Icons.card_membership_outlined),
                  title: const Text('Cover with membership'),
                  onTap: () => Navigator.of(ctx).pop('cover'),
                ),
              // Offered only when there is one to take off. A waiter who
              // tapped "extra cheese" by mistake could previously only
              // void the whole line and ring it again — `add_line_modifier`
              // has had a caller since the till was built and its
              // opposite never did.
              if (_modifiersOn(lineId).isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.playlist_remove),
                  title: const Text('Take a modifier off'),
                  onTap: () => Navigator.of(ctx).pop('modifier'),
                ),
              ListTile(
                leading: const Icon(Icons.percent),
                title: const Text('Take money off'),
                onTap: () => Navigator.of(ctx).pop('discount'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Take off the bill'),
                onTap: () => Navigator.of(ctx).pop('remove'),
              ),
            ],
          ),
        ),
      );
      if (!mounted) return;
      if (go == 'cover') {
        await _coverWithMembership(id, lineId);
        return;
      }
      if (go == 'modifier') {
        await _removeModifier(id, lineId);
        return;
      }
      if (go == 'discount') {
        await _discountLine(line);
        return;
      }
      if (go != 'remove') return;
    } else {
      // Two things can be done to a plate the kitchen has cooked, and
      // until now the till offered one of them. A burnt steak is
      // usually discounted, not voided: the food was made, the cost was
      // incurred, and pretending the line never existed loses both
      // facts. Asked as a choice rather than assumed, because the two
      // answers report differently and a shop reads both reports.
      final go = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text('${line['description']}'),
                subtitle: const Text('Already with the kitchen'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.percent),
                title: const Text('Take money off'),
                subtitle: const Text('The plate stays on the bill'),
                onTap: () => Navigator.of(ctx).pop('discount'),
              ),
              ListTile(
                leading: const Icon(Icons.block),
                title: const Text('Void it'),
                subtitle: const Text('The plate comes off, with a reason'),
                onTap: () => Navigator.of(ctx).pop('void'),
              ),
            ],
          ),
        ),
      );
      if (!mounted) return;
      if (go == 'discount') {
        await _discountLine(line);
        return;
      }
      if (go != 'void') return;

      // Asked here rather than before the choice above, because the two
      // answers are granted separately: a cashier who may discount and
      // may not void has to be able to reach the first without being
      // stopped for the second. Taking food off a bill the kitchen
      // already has is the oldest way to steal from a till, so a shop
      // can hand that one out on its own.
      //
      // Awaited rather than read, because nothing else on this screen
      // watches the access map: a read would find it unstarted, fall
      // back to "held", and walk somebody into a refusal from the
      // database. One round trip on the rarest action buys an answer
      // that is true.
      final mayVoid = await permissionHeld(ref, 'pos_void');
      if (!mounted) return;
      if (!mayVoid) {
        await showModalBottomSheet<void>(
          context: context,
          builder: (_) => const SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.lock_outline),
                  title: Text('Voiding needs permission'),
                  subtitle: Text(
                    'This account has not been given it. A manager can, '
                    'under Team. Taking money off the plate may still be '
                    'open to you.',
                  ),
                ),
              ],
            ),
          ),
        );
        return;
      }

      final answer = await showModalBottomSheet<({String reason, String note})>(
        context: context,
        isScrollControlled: true,
        builder: (_) => VoidReasonSheet(description: '${line['description']}'),
      );
      if (answer == null || !mounted) return;
      reason = answer.reason;
      note = answer.note.isEmpty ? null : answer.note;
    }

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final held = reason;
    final ok = await runWithFeedback(
      context,
      // Nothing is said when an unsent line comes off: the line
      // disappearing is the whole message. A void is different — it
      // has been written down, and the cashier should know that.
      successMessage: held == null ? null : 'Taken off, and recorded',
      action: () => held == null
          ? repo.removePosSaleLine(lineId)
          : repo.voidPosSaleLine(lineId, held, note: note),
    );
    if (!ok || !mounted) return;

    ref
      ..invalidate(posSaleProvider(id))
      ..invalidate(posSaleLinesProvider(id))
      ..invalidate(posSaleLineModifiersProvider(id));
    await _refreshPromotions(id);
  }

  @override
  Widget build(BuildContext context) {
    final registers = ref.watch(posRegistersProvider);
    final offline = ref.watch(posOfflineProvider);

    // Kept the moment it is read, because that is the only moment the
    // device is certain the menu is current. A till that cached on a
    // schedule would be caching whatever it happened to have.
    final outlet = _outletId;
    if (outlet != null) {
      ref.listen(posMenuProvider(outlet), (_, next) {
        final rows = next.asData?.value;
        if (rows != null && rows.isNotEmpty) {
          ref.read(posOfflineProvider.notifier).cacheMenu(outlet, rows);
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Till'),
        actions: [
          // The 86 list, whole. Stopping and resuming a dish have been
          // reachable from a long press on the menu; the list of what
          // is off — and who took it off — was not, so it existed only
          // as greyed tiles scattered through a menu.
          if (_outletId != null)
            IconButton(
              key: const ValueKey('sold-out'),
              tooltip: 'Sold out today',
              icon: const Icon(Icons.no_food_outlined),
              onPressed: () => showSoldOut(context, _outletId!),
            ),
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
      body: Column(
        children: [
          // Above everything, and shown while there is a queue even
          // after signal returns: sales still on the device are the
          // most important thing about a till holding them, and a
          // banner that vanished the moment the bars came back would
          // hide exactly that.
          const OfflineBanner(),
          Expanded(child: _body(offline.offline, registers)),
        ],
      ),
    );
  }

  /// Split out of [build] so the offline banner can sit above it
  /// without the register plumbing being indented one level further
  /// into an already deep tree.
  Widget _body(
    bool offline,
    AsyncValue<List<Map<String, dynamic>>> registers,
  ) => AsyncView<List<Map<String, dynamic>>>(
        value: registers,
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.point_of_sale_outlined,
              title: 'No tills yet',
              message:
                  'Add an outlet and a register in settings, and this '
                  'screen becomes one.',
            );
          }
          // Landing on the first register saves a tap on a device that
          // only ever has one, which is most of them.
          final reg = _registerId ?? rows.first['id'] as String?;
          if (_registerId == null && reg != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _pickRegister(rows.first);
            });
          }
          if (reg == null) return const SizedBox.shrink();
          // A separate surface rather than a mode woven through this
          // one, because with no server there is no sale to open, no
          // line to price and no shift to check — almost nothing is
          // shared.
          if (offline) {
            return OfflineTill(registerId: reg, outletId: _outletId);
          }
          return _Register(
            registerId: reg,
            outletId: _outletId,
            saleId: _saleId,
            search: _search,
            searchFocus: _searchFocus,
            results: _results,
            looking: _looking,
            onSearch: _look,
            onPick: _add,
            onStock: _stock,
            onOpenShift: _openShift,
            onCloseShift: _closeShift,
            onTender: _tender,
            onSend: _send,
            onSplit: _split,
            onEvenSplit: _evenSplit,
            onMerge: _merge,
            onVoidBill: _voidBill,
            onDiscountBill: _discountBill,
            onCoupon: _coupon,
            onDelivery: _delivery,
            onPrintBill: _printBill,
            onLineAction: _lineAction,
            onOpenOrder: _openOrder,
            onPark: _park,
            onRemovePromotion: _removePromotion,
          );
        },
      );
}

class _Register extends ConsumerWidget {
  const _Register({
    required this.registerId,
    required this.outletId,
    required this.saleId,
    required this.search,
    required this.searchFocus,
    required this.results,
    required this.looking,
    required this.onSearch,
    required this.onPick,
    required this.onStock,
    required this.onOpenShift,
    required this.onCloseShift,
    required this.onTender,
    required this.onSend,
    required this.onSplit,
    required this.onEvenSplit,
    required this.onMerge,
    required this.onVoidBill,
    required this.onDiscountBill,
    required this.onCoupon,
    required this.onDelivery,
    required this.onPrintBill,
    required this.onLineAction,
    required this.onOpenOrder,
    required this.onPark,
    required this.onRemovePromotion,
  });

  final String registerId;
  final String? outletId;
  final String? saleId;
  final TextEditingController search;
  final FocusNode searchFocus;
  final List<Map<String, dynamic>> results;
  final bool looking;
  final ValueChanged<String> onSearch;
  final ValueChanged<Map<String, dynamic>> onPick;

  /// Holding a menu tile takes the dish off for today, or puts it back.
  final ValueChanged<Map<String, dynamic>>? onStock;

  final VoidCallback onOpenShift;
  final ValueChanged<String> onCloseShift;
  final VoidCallback onTender;
  final VoidCallback onSend;
  final VoidCallback onSplit;
  final VoidCallback onEvenSplit;
  final ValueChanged<Map<String, dynamic>> onMerge;
  final VoidCallback onVoidBill;

  /// Taking money off the whole bill. Beside writing it off in the
  /// same menu, because they are the two things somebody does to a
  /// bill rather than to a line on it.
  final VoidCallback onDiscountBill;

  /// Typing a voucher code. Separate from discounting: honouring a code
  /// the shop printed is not a cashier's decision, and the two are
  /// granted differently.
  final VoidCallback onCoupon;

  /// Taking one back off. A code typed against the wrong bill is the
  /// ordinary reason, and until this reached the screen the only way
  /// out was to void the bill and start it again.
  final ValueChanged<Map<String, dynamic>> onRemovePromotion;

  /// Taking the address a bill is going to. On the same menu as the
  /// voucher and the discount, because all three are things done to a
  /// bill rather than to a line on it.
  final VoidCallback onDelivery;

  /// The bill on paper before the money. The same document the till
  /// prints afterwards, marked as not paid.
  final VoidCallback onPrintBill;
  final ValueChanged<Map<String, dynamic>> onLineAction;
  final ValueChanged<Map<String, dynamic>> onOpenOrder;
  final VoidCallback onPark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shift = ref.watch(currentPosShiftProvider(registerId));

    return AsyncView<Map<String, dynamic>?>(
      value: shift,
      builder: (row) {
        if (row == null) {
          // Not an error state and not an empty one. A closed drawer is
          // the normal condition of a till before the shop opens, and
          // the only thing to do about it is on the screen.
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline, size: 40),
                      const SizedBox(height: 12),
                      Text(
                        'The drawer is closed',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Count what is in it and open a shift. Nothing '
                        'can be sold until takings have somewhere to '
                        'belong.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: onOpenShift,
                        icon: const Icon(Icons.lock_open),
                        label: const Text('Open the drawer'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        _Basket basket({required bool compact}) => _Basket(
          registerId: registerId,
          outletId: outletId,
          saleId: saleId,
          onTender: onTender,
          onSend: onSend,
          onSplit: onSplit,
          onEvenSplit: onEvenSplit,
          onMerge: onMerge,
          onVoidBill: onVoidBill,
          onDiscountBill: onDiscountBill,
          onCoupon: onCoupon,
          onDelivery: onDelivery,
          onPrintBill: onPrintBill,
          onLineAction: onLineAction,
          onOpenOrder: onOpenOrder,
          onPark: onPark,
          onRemovePromotion: onRemovePromotion,
          compact: compact,
        );
        final finder = _Finder(
          onStock: onStock,
          outletId: outletId,
          saleId: saleId,
          search: search,
          searchFocus: searchFocus,
          results: results,
          looking: looking,
          onSearch: onSearch,
          onPick: onPick,
          shiftId: row['id'] as String,
          shiftNo: '${row['shift_no'] ?? ''}',
          onCloseShift: onCloseShift,
        );

        return LayoutBuilder(
          builder: (context, box) {
            // The counter and the tablet get both halves side by side.
            // A phone gets the finder, with the basket underneath it —
            // stacked rather than hidden, because a basket a cashier
            // cannot see is one they cannot check against the goods on
            // the counter.
            if (box.maxWidth >= 900) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: finder),
                  const VerticalDivider(width: 1),
                  SizedBox(width: 360, child: basket(compact: false)),
                ],
              );
            }
            // The bill no longer takes a fixed share of the height.
            // It is as tall as its own controls and no taller, which
            // gives the menu the rest — the menu being the thing a
            // phone is short of room for.
            return Column(
              children: [
                Expanded(child: finder),
                const Divider(height: 1),
                basket(compact: true),
              ],
            );
          },
        );
      },
    );
  }
}

class _Finder extends StatelessWidget {
  const _Finder({
    required this.outletId,
    required this.saleId,
    required this.search,
    required this.searchFocus,
    required this.results,
    required this.looking,
    required this.onSearch,
    required this.onPick,
    required this.onStock,
    required this.shiftId,
    required this.shiftNo,
    required this.onCloseShift,
  });

  final String? outletId;
  final String? saleId;
  final TextEditingController search;
  final FocusNode searchFocus;
  final List<Map<String, dynamic>> results;
  final bool looking;
  final ValueChanged<String> onSearch;
  final ValueChanged<Map<String, dynamic>> onPick;

  /// Holding a menu tile takes the dish off for today, or puts it back.
  /// The kitchen runs out; the counter is where somebody notices.
  final ValueChanged<Map<String, dynamic>>? onStock;

  final String shiftId;
  final String shiftNo;
  final ValueChanged<String> onCloseShift;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: search,
                  focusNode: searchFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  // A barcode gun types and presses enter. Submitting on
                  // enter is not a convenience here, it is the entire
                  // interface for the most common way of using this
                  // screen.
                  onSubmitted: onSearch,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.qr_code_scanner),
                    hintText: 'Scan, or type a code or a name',
                    border: const OutlineInputBorder(),
                    suffixIcon: looking
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.search),
                            onPressed: () => onSearch(search.text),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Count the drawer',
                icon: const Icon(Icons.point_of_sale),
                onPressed: () => onCloseShift(shiftId),
              ),
            ],
          ),
        ),
        if (shiftNo.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Shift $shiftNo',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
        Expanded(
          // Nothing searched for yet is the normal state of a till, not
          // an empty one. It used to render "Ready — scan an item",
          // which is true and useless to most shops this is sold to: a
          // barcode is a retail assumption, and nasi lemak, a haircut
          // and a roti john all have no label. So the resting state is
          // the menu.
          child: results.isEmpty
              ? (outletId == null
                    ? const SizedBox.shrink()
                    : _Browse(
                        onStock: onStock,
                        outletId: outletId!,
                        saleId: saleId,
                        onPick: onPick,
                      ))
              : ListView.separated(
                  itemCount: results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = results[i];
                    final onHand = posNum(r['on_hand']);
                    return ListTile(
                      title: Text('${r['name']}'),
                      subtitle: Text(
                        [
                          '${r['code']}',
                          if ((r['variant_attributes'] as Map?)?.isNotEmpty ??
                              false)
                            (r['variant_attributes'] as Map).values.join(' / '),
                          '${Fmt.qty(onHand)} on hand',
                        ].join('  ·  '),
                      ),
                      trailing: Text(
                        Fmt.money(posNum(r['unit_price'])),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      onTap: () => onPick(r),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Basket extends ConsumerWidget {
  const _Basket({
    required this.registerId,
    required this.outletId,
    required this.saleId,
    required this.onTender,
    required this.onSend,
    required this.onSplit,
    required this.onEvenSplit,
    required this.onMerge,
    required this.onVoidBill,
    required this.onDiscountBill,
    required this.onCoupon,
    required this.onDelivery,
    required this.onPrintBill,
    required this.onLineAction,
    required this.onOpenOrder,
    required this.onPark,
    required this.onRemovePromotion,
    required this.compact,
  });

  final String registerId;
  final String? outletId;
  final String? saleId;
  final VoidCallback onTender;
  final VoidCallback onSend;
  final VoidCallback onSplit;
  final VoidCallback onEvenSplit;
  final ValueChanged<Map<String, dynamic>> onMerge;
  final VoidCallback onVoidBill;

  /// Taking money off the whole bill. Beside writing it off in the
  /// same menu, because they are the two things somebody does to a
  /// bill rather than to a line on it.
  final VoidCallback onDiscountBill;

  /// Typing a voucher code. Separate from discounting: honouring a code
  /// the shop printed is not a cashier's decision, and the two are
  /// granted differently.
  final VoidCallback onCoupon;

  /// Taking one back off. A code typed against the wrong bill is the
  /// ordinary reason, and until this reached the screen the only way
  /// out was to void the bill and start it again.
  final ValueChanged<Map<String, dynamic>> onRemovePromotion;

  /// Taking the address a bill is going to. On the same menu as the
  /// voucher and the discount, because all three are things done to a
  /// bill rather than to a line on it.
  final VoidCallback onDelivery;

  /// The bill on paper before the money. The same document the till
  /// prints afterwards, marked as not paid.
  final VoidCallback onPrintBill;
  final ValueChanged<Map<String, dynamic>> onLineAction;

  /// A whole row rather than an id, because what the till does next
  /// depends on which register the bill is on and the row is what says
  /// so.
  final ValueChanged<Map<String, dynamic>> onOpenOrder;

  /// Steps back to the shop-wide list, leaving the bill exactly where
  /// it is. Nothing is written: a parked sale is already parked.
  final VoidCallback onPark;

  /// True on a phone, where the bill cannot share the screen with the
  /// menu and becomes a tappable summary instead.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = saleId;
    if (id == null) {
      // The whole shop, not this till. A counter that could only see
      // its own parked baskets could not find the bill a waiter opened
      // on a tablet, which is the bill the customer is standing there
      // holding.
      final open = outletId == null
          ? const AsyncValue<List<Map<String, dynamic>>>.data(
              <Map<String, dynamic>>[],
            )
          : ref.watch(posOpenOrdersProvider(outletId!));
      final list = AsyncView<List<Map<String, dynamic>>>(
        value: open,
        builder: (rows) => rows.isEmpty
            ? (compact
                  // On a phone this branch is one line under a full
                  // menu, so the illustrated empty state has nowhere to
                  // go and would only push the menu off the screen.
                  ? const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Nothing on the counter'),
                      ),
                    )
                  : const EmptyState(
                      icon: Icons.shopping_basket_outlined,
                      title: 'Empty',
                      message: 'Scan something to start a sale.',
                    ))
            : ListView(
                shrinkWrap: compact,
                children: [
                  for (final s in rows)
                    _OpenOrderTile(
                      row: s,
                      mine: s['register_id'] == registerId,
                      onTap: () => onOpenOrder(s),
                    ),
                ],
              ),
      );

      // The phone's basket is as tall as its contents, so it cannot use
      // Expanded — there is no bounded height to expand into. Capped
      // instead, so a shift with eight parked bills does not take the
      // whole screen.
      if (compact) {
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: list,
        );
      }
      return Column(
        children: [
          const SectionHeader('Open in this shop'),
          Expanded(child: list),
        ],
      );
    }

    final sale = ref.watch(posSaleProvider(id));
    final lines = ref.watch(posSaleLinesProvider(id));
    // What was chosen on each line. Read once for the sale rather than
    // once per line, and from the snapshot on the line rather than the
    // menu — a bill printed at seven must still read correctly after
    // somebody edits the menu at nine.
    final mods = ref
        .watch(posSaleLineModifiersProvider(id))
        .maybeWhen(data: (rows) => rows, orElse: () => const <Map<String, dynamic>>[]);
    final total = sale.maybeWhen(
      data: (row) => posNum(row?['total_amount']),
      orElse: () => 0.0,
    );
    final billDiscount = sale.maybeWhen(
      data: (row) => posNum(row?['bill_discount']),
      orElse: () => 0.0,
    );
    final billDiscountReason = sale.maybeWhen(
      data: (row) => row?['bill_discount_reason'] as String?,
      orElse: () => null,
    );
    final saleStatus = sale.maybeWhen(
      data: (row) => row?['status'] as String?,
      orElse: () => null,
    );
    // What the shop's own rules took off, one row each. Read as a list
    // rather than only as `promo_discount`, because a bill showing
    // "less RM 6.00" and nothing else leaves a cashier unable to say
    // which promotion that was.
    final promos = ref
        .watch(posSalePromotionsProvider(id))
        .maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );

    // Empty when the bill is not going anywhere, which is most bills.
    final delivery = ref
        .watch(posDeliveryForProvider(id))
        .maybeWhen(
          data: (row) => row,
          orElse: () => const <String, dynamic>{},
        );

    final rows = lines.maybeWhen(
      data: (r) => r,
      orElse: () => const <Map<String, dynamic>>[],
    );
    final count = rows.fold<double>(
      0,
      (n, l) => n + posNum(l['quantity']),
    );

    /// On a phone the bill is behind a tap, so the two actions that
    /// leave the till — telling the kitchen, taking the money — would
    /// otherwise fire on a list nobody has seen. A cashier who cannot
    /// check what is about to be cooked is a cashier who finds out from
    /// the customer.
    ///
    /// Not done on a counter or a tablet: the lines are already on
    /// screen there, and a confirmation that repeats what you are
    /// looking at is ceremony rather than a check.
    Future<void> review(String label, VoidCallback then) async {
      final agreed = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _BasketLines(
          rows: rows,
          mods: mods,
          total: total,
          scrollable: true,
          confirmLabel: label,
        ),
      );
      if (agreed == true) then();
    }

    return Column(
      children: [
        // Which bill this is, and the way back to the others.
        //
        // Without this the till is a one-way street: once a sale is
        // open the only exit is taking money for it. A waiter who has
        // started table 3 and is called to table 5 has to be able to
        // leave the first one where it is — which is what parking has
        // always meant, and what the shop-wide list is for.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Which bill, and the way out of it. These two are on
              // their own line because they are the only two that must
              // be reachable at any width — the basket panel is 344
              // logical pixels on a counter terminal and narrower on a
              // phone, and a row that also carried the chips ran off
              // the end of it.
              Row(
                children: [
                  Expanded(
                    child: Text(
                      sale.maybeWhen(
                        data: (r) => '${r?['sale_no'] ?? 'Open bill'}',
                        orElse: () => 'Open bill',
                      ),
                      style: Theme.of(context).textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onPark,
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: const Text('Leave it open'),
                  ),
                  // Behind a menu rather than beside the button that
                  // walks away from the bill. Writing one off and
                  // leaving it open are one tap apart and opposite in
                  // consequence, and a destructive action should not be
                  // the thing a thumb finds by accident.
                  PopupMenuButton<String>(
                    tooltip: 'What to do with this bill',
                    icon: const Icon(Icons.more_vert, size: 18),
                    padding: EdgeInsets.zero,
                    onSelected: (v) => switch (v) {
                      'discount' => onDiscountBill(),
                      'coupon' => onCoupon(),
                      'delivery' => onDelivery(),
                      'bill' => onPrintBill(),
                      _ => onVoidBill(),
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'bill',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.receipt_long_outlined),
                          title: Text('Print the bill'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delivery',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.moped_outlined),
                          title: Text('Where is it going?'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'coupon',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.confirmation_number_outlined),
                          title: Text('Voucher'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'discount',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.percent),
                          title: Text('Take money off'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'void',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.block),
                          title: Text('Write off this bill'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              // And underneath, what is true about this order. A Wrap
              // rather than a Row: there are two chips today and the
              // second only sometimes, so the width they need is not
              // something this layout can be built around.
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  // How the order arrived, on the bill rather than in
                  // settings, because it is a fact about this order.
                  // Shown even when nobody chose it, so a cashier can
                  // see the till's assumption before it becomes what
                  // the day gets reported as.
                  sale.maybeWhen(
                    data: (r) => r == null
                        ? const SizedBox.shrink()
                        : SaleChannelChip(
                            saleId: id,
                            outletId: outletId,
                            channel: r['order_channel'],
                          ),
                    orElse: () => const SizedBox.shrink(),
                  ),
                  // Which table, beside how the order arrived, because
                  // for a dine-in bill they are one fact: it arrived
                  // at a table, and the bill has to say which. Only on
                  // dine-in — a bag over the counter has no table, and
                  // offering one would be asking a question with no
                  // answer.
                  sale.maybeWhen(
                    data: (r) =>
                        r == null || '${r['order_channel']}' != 'dine_in'
                        ? const SizedBox.shrink()
                        : SaleTableChip(
                            saleId: id,
                            outletId: outletId,
                            tableId: r['table_id'],
                          ),
                    orElse: () => const SizedBox.shrink(),
                  ),
                ],
              ),
            ],
          ),
        ),
        // On a counter or a tablet the bill is read continuously, so it
        // stays on screen. On a phone there is not room for both the
        // menu and the bill, and the old split gave the bill a strip
        // four lines tall that clipped its own contents — a list that
        // cannot show what is in it is worse than a number that says
        // how much there is.
        if (compact)
          _BasketBar(
            count: count,
            total: total,
            onTap: rows.isEmpty
                ? null
                : () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _BasketLines(
                      rows: rows,
                      mods: mods,
                      total: total,
                      promos: promos,
                      scrollable: true,
                      onLineAction: onLineAction,
                    ),
                  ),
          )
        else
          Expanded(
            child: AsyncView<List<Map<String, dynamic>>>(
              value: lines,
              builder: (r) => _BasketLines(
                rows: r,
                mods: mods,
                total: total,
                onLineAction: onLineAction,
              ),
            ),
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              if (!compact) ...[
                // A discount on the whole bill is not visible anywhere
                // else — it is not on a line and it is not in the
                // total, it is the difference between them. Shown as
                // its own row above the total, which is where a
                // customer looks for it and where a receipt puts it.
                if (billDiscount > 0) ...[
                  _AmountRow(
                    billDiscountReason == null
                        ? 'Less discount'
                        : 'Less discount · $billDiscountReason',
                    -billDiscount,
                  ),
                  const SizedBox(height: 4),
                ],
                // Named, one per row. A voucher taking nothing off is
                // still shown, with the reason, because it was typed in
                // and a cashier who cannot see it cannot explain it.
                for (final p in promos) ...[
                  Row(
                    children: [
                      Expanded(
                        child: posNum(p['amount']) > 0
                            ? _AmountRow(
                                '${p['name']}',
                                -posNum(p['amount']),
                              )
                            : Text(
                                '${p['name']} · ${p['blocked_reason'] ?? ''}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.colors.warning,
                                ),
                              ),
                      ),
                      // A blocked voucher is still a row somebody typed
                      // in, so it comes off the same way a live one
                      // does: taking it back is how they undo it.
                      if (promotionCanBeRemoved(saleStatus))
                        IconButton(
                          key: ValueKey('remove-promo-${p['id']}'),
                          tooltip: 'Take it off',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => onRemovePromotion(p),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                // The ride, on its own row above the total. It is added
                // rather than taken off, and a customer looking for
                // "why is this six ringgit more" looks exactly here.
                if (posNum(delivery['fee']) > 0) ...[
                  _AmountRow(
                    'Delivery'
                    '${'${delivery['zone_name'] ?? ''}'.isEmpty ? '' : ' · ${delivery['zone_name']}'}',
                    posNum(delivery['fee']),
                  ),
                  const SizedBox(height: 4),
                ],
                // The zone's minimum, while the customer can still add
                // to the order. The till refuses it at the tender sheet
                // either way, and finding out then is finding out too
                // late.
                if ((delivery['blocked_reason'] as String?) != null) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${delivery['blocked_reason']}',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.colors.warning,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                _AmountRow('Total', total, emphasise: true),
                const SizedBox(height: 12),
              ],
              // Splitting sits with the bill rather than with the
              // tender sheet, because "can we pay separately?" is asked
              // while looking at what was eaten, not while holding a
              // card.
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: total > 0 ? onSplit : null,
                      icon: const Icon(Icons.call_split, size: 18),
                      label: const Text('Split items'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: total > 0 ? onEvenSplit : null,
                      icon: const Icon(Icons.groups_outlined, size: 18),
                      label: const Text('Split evenly'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Sending and paying are two different moments and two
              // different people. A kitchen is told when the order is
              // taken; the money is taken when the meal is over. Making
              // one button do both would mean either cooking on credit
              // or serving a cold plate.
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: total > 0
                      ? (compact
                            ? () => review('Send to kitchen', onSend)
                            : onSend)
                      : null,
                  icon: const Icon(Icons.soup_kitchen_outlined),
                  label: const Text('Send to kitchen'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: total > 0
                      ? (compact
                            ? () => review('Take payment', onTender)
                            : onTender)
                      : null,
                  icon: const Icon(Icons.payments),
                  label: const Text('Take payment'),
                ),
              ),
              // The table that split and then decided to pay as one
              // after all. Only offered when there is something to
              // merge, which is why it hangs off the parked list rather
              // than sitting as a permanent button.
              _MergeBar(
                registerId: registerId,
                saleId: id,
                onMerge: onMerge,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One open bill in the shop, on the list every till shows.
///
/// The row has to answer "is this the one?" without being opened, so it
/// carries the things people actually say out loud: the table, how many
/// are on it, how long it has been open, and whose name is on it. The
/// register only appears when the bill is somebody else's — on your own
/// till it is noise, and on another's it is the reason the next tap
/// asks a question.
class _OpenOrderTile extends StatelessWidget {
  const _OpenOrderTile({
    required this.row,
    required this.mine,
    required this.onTap,
  });

  final Map<String, dynamic> row;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final table = row['table_name'];
    final covers = row['covers'];
    final lines = (row['line_count'] as num?)?.toInt() ?? 0;
    final sent = (row['sent_count'] as num?)?.toInt() ?? 0;
    final minutes = (row['minutes'] as num?)?.toInt() ?? 0;
    final contact = row['contact_name'];

    final parts = <String>[
      if (table != null) 'Table $table',
      if (covers != null) '$covers cover${covers == 1 ? '' : 's'}',
      '$lines item${lines == 1 ? '' : 's'}',
      // Only when it is true. "0 sent" on every row would train people
      // to stop reading the column that matters.
      if (sent > 0) '$sent with the kitchen',
      if (minutes > 0) '${minutes}m',
      if (contact != null) '$contact',
      if (!mine) 'on ${row['register_name'] ?? row['register_code']}',
    ];

    return ListTile(
      leading: Icon(
        mine
            ? Icons.pause_circle_outline
            // Another till's bill. A different glyph rather than a
            // different colour, because the difference has to survive
            // being read at arm's length on a bright counter.
            : Icons.devices_other_outlined,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              '${row['sale_no']}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (row['order_no'] != null) ...[
            const SizedBox(width: 8),
            _Pill('#${row['order_no']}'),
          ],
          if (row['is_kiosk'] == true) ...[
            const SizedBox(width: 8),
            const _Pill('Kiosk'),
          ],
        ],
      ),
      subtitle: Text(parts.join(' · '), overflow: TextOverflow.ellipsis),
      trailing: Text(Fmt.money(posNum(row['total']))),
      onTap: onTap,
    );
  }
}

/// A short label that has to stay legible next to a number.
class _Pill extends StatelessWidget {
  const _Pill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// The menu, when nothing has been scanned.
///
/// ## Items, or categories, decided by what actually fits
///
/// A stall with six things sells them off one screen and should never
/// make anybody tap a category to reach them. A minimart with four
/// hundred cannot show them at all, and a grid that scrolls for a
/// minute is a grid nobody uses.
///
/// So the choice is not a hard-coded threshold but a measurement: the
/// tiles that fit in the space this pane has been given are counted,
/// and if the whole menu fits it is shown whole. Otherwise the
/// categories are shown and tapping one drills in. The same rule
/// therefore gives a phone categories where a counter terminal shows
/// items, which is the right answer on both — and it is why this works
/// the same on desktop web, mobile web and the app without any of them
/// being special-cased.
///
/// ## Nothing here can raise when tapped
///
/// `pos_menu` applies the same sellability rules as the scan path, so a
/// style with variants under it never becomes a tile. That matters more
/// on a grid than in a search result: a search is something you typed
/// and can re-read, a tile is something you hit with your thumb.
class _Browse extends StatefulWidget {
  const _Browse({
    required this.outletId,
    required this.saleId,
    required this.onPick,
    this.onStock,
  });

  final String outletId;

  /// The bill being rung up, or null before one is opened. Only used to
  /// count what is already on it, so a tile can say so.
  final String? saleId;

  final ValueChanged<Map<String, dynamic>> onPick;

  /// Holding a tile takes the dish off for today, or puts it back.
  final ValueChanged<Map<String, dynamic>>? onStock;

  @override
  State<_Browse> createState() => _BrowseState();
}

class _BrowseState extends State<_Browse> {
  /// Null while showing the top level. Holds the category name rather
  /// than its id because `pos_menu` already coalesces an unset category
  /// to a real heading, so the name is the thing that groups.
  String? _category;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final menu = ref.watch(posMenuProvider(widget.outletId));
        // How many of each item are already on the bill. The basket
        // watches the same family, so this is the provider it has
        // already fetched rather than a second round trip.
        //
        // Summed by item rather than counted by line, because two taps
        // on the same tile may land as one line of two or as two lines
        // of one depending on whether a modifier was chosen — and the
        // number a cashier wants is how many of the thing they sold.
        final onBill = <String, num>{};
        if (widget.saleId != null) {
          final lines =
              ref.watch(posSaleLinesProvider(widget.saleId!)).valueOrNull ??
              const <Map<String, dynamic>>[];
          for (final l in lines) {
            final id = l['item_id'];
            if (id == null) continue;
            onBill['$id'] = (onBill['$id'] ?? 0) + posNum(l['quantity']);
          }
        }
        return AsyncView<List<Map<String, dynamic>>>(
          value: menu,
          builder: (rows) {
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.sell_outlined,
                title: 'Nothing to sell yet',
                message:
                    'Items marked as sold show up here, ready to tap. '
                    'Until then, scanning still works.',
              );
            }
            return LayoutBuilder(
              builder: (context, box) {
                // Tile sizes chosen for a thumb rather than a cursor:
                // the same grid is used on a counter terminal and a
                // phone, and the phone is the harder constraint.
                const tileWidth = 150.0;
                const tileHeight = 96.0;
                final columns = (box.maxWidth / tileWidth).floor().clamp(2, 8);
                final visibleRows =
                    (box.maxHeight / tileHeight).floor().clamp(1, 20);
                final fits = rows.length <= columns * visibleRows;

                final categories = <String>[];
                for (final r in rows) {
                  final c = '${r['category']}';
                  if (!categories.contains(c)) categories.add(c);
                }

                // One category is not a choice, so it is never made
                // into one however long the list is.
                final showItems =
                    fits || categories.length < 2 || _category != null;
                final shown = _category == null
                    ? rows
                    : [
                        for (final r in rows)
                          if (r['category'] == _category) r,
                      ];

                return Column(
                  children: [
                    if (_category != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                          child: TextButton.icon(
                            onPressed: () => setState(() => _category = null),
                            icon: const Icon(Icons.arrow_back, size: 18),
                            label: Text('$_category'),
                          ),
                        ),
                      ),
                    Expanded(
                      child: showItems
                          ? _Grid(
                              columns: columns,
                              children: [
                                for (final r in shown)
                                  _MenuTile(
                                    title: '${r['name']}',
                                    subtitle: tileSubtitle(
                                      Fmt.money(posNum(r['unit_price'])),
                                      r['portions'],
                                    ),
                                    count: onBill['${r['item_id']}'],
                                    offReason: r['available'] == false
                                        ? '${r['off_reason'] ?? 'Not on now'}'
                                        : null,
                                    onTap: () => widget.onPick(r),
                                    onLongPress: widget.onStock == null
                                        ? null
                                        : () => widget.onStock!(r),
                                  ),
                              ],
                            )
                          : _Grid(
                              columns: columns,
                              children: [
                                for (final c in categories)
                                  _MenuTile(
                                    title: c,
                                    // A door with nothing written on it
                                    // is a door nobody opens.
                                    subtitle:
                                        '${rows.where((r) => r['category'] == c).length} items',
                                    onTap: () => setState(() => _category = c),
                                  ),
                              ],
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      padding: const EdgeInsets.all(8),
      crossAxisCount: columns,
      childAspectRatio: 1.55,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      children: children,
    );
  }
}

/// How much of it, for a shop with a hanging scale and no printer.
///
/// The running total is shown as it is typed, because the number a
/// customer is about to be charged is the thing being decided and a
/// cashier reading it back out loud is how a weight typo gets caught.
class _WeightDialog extends StatefulWidget {
  const _WeightDialog({
    required this.name,
    required this.uom,
    required this.unitPrice,
  });

  final String name;
  final String uom;
  final num unitPrice;

  @override
  State<_WeightDialog> createState() => _WeightDialogState();
}

class _WeightDialogState extends State<_WeightDialog> {
  final _weight = TextEditingController();

  @override
  void dispose() {
    _weight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typed = num.tryParse(_weight.text.trim()) ?? 0;
    return AlertDialog(
      title: Text(widget.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _weight,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'How much',
              suffixText: widget.uom,
              helperText: '${Fmt.money(widget.unitPrice)} per ${widget.uom}',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (typed > 0) Navigator.of(context).pop(typed);
            },
          ),
          const SizedBox(height: 12),
          Text(
            weighedLine(typed, widget.unitPrice),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: typed <= 0 ? null : () => Navigator.of(context).pop(typed),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// What a weight comes to, at the price per unit.
///
/// Pure and exported so the dialog and the tests agree. Rounded to the
/// sen the same way the line will be, so the number a cashier reads out
/// is the number the customer is charged rather than one that is close
/// to it.
String weighedLine(num weight, num unitPrice) {
  if (weight <= 0) return '—';
  return Fmt.money(
    (weight * unitPrice * 100).round() / 100,
  );
}

/// What goes under a dish's name on the grid.
///
/// The price, and — when the kitchen keeps a recipe for it — how many
/// more it can make. Pure so the till and its tests agree. Null
/// portions is a dish nothing counted limits, and saying "unlimited"
/// there would be a promise nobody made.
String tileSubtitle(String price, Object? portions) {
  if (portions == null) return price;
  final n = num.tryParse('$portions');
  if (n == null || n <= 0) return price;
  return '$price · ${Fmt.qty(n)} left';
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.count,
    this.offReason,
    this.onLongPress,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// Why this dish is not being offered right now, or null when it is.
  ///
  /// Greyed and explained rather than removed: a tile that vanishes
  /// reads as a broken menu, and "From 07:00" is the only version a
  /// cashier can answer a customer from. 0258 keeps the row in
  /// `pos_menu` for exactly this.
  final String? offReason;

  /// Holding a tile takes the dish off for today, or puts it back. On a
  /// long press rather than a button: the grid is tapped hundreds of
  /// times an hour and eighty-sixing is a thing that happens twice.
  final VoidCallback? onLongPress;

  /// How many of this are already on the bill, or null on a tile that
  /// is not an item. Zero is not drawn: a badge on every tile is a
  /// badge nobody reads, and the question a cashier asks the grid is
  /// "have I rung this up yet", which only a number can answer.
  final num? count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = count ?? 0;
    final off = offReason != null;
    return Card(
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: off ? 0.5 : 1,
        child: InkWell(
        // Still long-pressable when off, because putting a dish back is
        // done from the same tile that took it away.
        onTap: off ? null : onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (n > 0) ...[
                    const SizedBox(width: 6),
                    // A bare number next to a name reads as a price, a
                    // stock level or a table — so it says which it is
                    // on hover, and to a screen reader.
                    Tooltip(
                      message: '${Fmt.qty(n)} on this bill',
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 22),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(
                          Fmt.qty(n),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: scheme.onPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                // The reason takes the price's place rather than
                // sitting beside it: a dish nobody can order does not
                // need its price read out, and it does need somebody to
                // be told why.
                off ? offReason! : subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: off ? context.colors.warning : null,
                  fontWeight: off ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

/// An offer to put two bills back together, shown only when there is
/// another bill to put this one together with.
/// What to call a bill out loud.
///
/// The number, and the table it is sitting at when it is sitting at
/// one. Two parked bills for RM 34.00 are indistinguishable by amount,
/// and the thing the cashier can see from where they are standing is
/// which table the party is at — so it belongs next to the number
/// wherever a bill has to be picked out of a list.
///
/// Takeaway and delivery have no table and get no separator: an empty
/// middle field reads as missing data rather than as an order nobody
/// sat down for.
String billLabel(Map<String, dynamic> sale) {
  final table = (sale['pos_tables'] as Map?)?['code'];
  final code = table == null ? '' : '$table'.trim();
  return [
    '${sale['sale_no'] ?? ''}',
    if (code.isNotEmpty) code,
  ].join('  ·  ');
}

class _MergeBar extends ConsumerWidget {
  const _MergeBar({
    required this.registerId,
    required this.saleId,
    required this.onMerge,
  });

  final String registerId;
  final String saleId;
  final ValueChanged<Map<String, dynamic>> onMerge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parked = ref.watch(parkedPosSalesProvider(registerId));
    final others = parked.maybeWhen(
      data: (rows) => [
        for (final r in rows)
          if (r['id'] != saleId) r,
      ],
      orElse: () => const <Map<String, dynamic>>[],
    );
    if (others.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: PopupMenuButton<Map<String, dynamic>>(
          tooltip: 'Merge another bill into this one',
          onSelected: onMerge,
          itemBuilder: (_) => [
            for (final o in others)
              PopupMenuItem(
                value: o,
                child: Text(
                  '${billLabel(o)}  ·  '
                  '${Fmt.money(posNum(o['total_amount']))}',
                ),
              ),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.merge, size: 18),
              const SizedBox(width: 6),
              Text(
                'Merge another bill in',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How many people are paying. A number pad rather than a text field,
/// for the same reason the float dialog is one.
Future<int?> _askWays(BuildContext context) {
  var value = 2;
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('How many ways?'),
      content: StatefulBuilder(
        builder: (context, setInner) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: value > 2
                  ? () => setInner(() => value = value - 1)
                  : null,
            ),
            Text('$value', style: Theme.of(context).textTheme.headlineMedium),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => setInner(() => value = value + 1),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(value),
          child: const Text('Work it out'),
        ),
      ],
    ),
  );
}

/// The bill, as a line at the top of the buttons.
///
/// A phone has room for the menu or the bill, not both. The old layout
/// gave the bill a fixed 42% of the height, which on an ordinary phone
/// was four lines tall and clipped its own contents — the customer's
/// last item half visible under the total. A list that cannot show what
/// is in it is worse than a number saying how much there is, so this
/// says the count and the money and opens the rest on a tap.
class _BasketBar extends StatelessWidget {
  const _BasketBar({
    required this.count,
    required this.total,
    required this.onTap,
  });

  final double count;
  final double total;

  /// Null when the bill is empty. Nothing to look at, so nothing to
  /// tap — an affordance that opens an empty sheet is a small lie.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Icon(
              Icons.shopping_basket_outlined,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            // Expanded rather than a Spacer between two natural-width
            // texts. The money must never be pushed off: with a Spacer
            // both sides size to their content and collide on a narrow
            // phone — "Nothing on the counter" beside a total is the
            // widest case, and it is the one that appears for a frame
            // while a resumed bill loads. Giving the label the slack
            // and letting it ellipsize makes the row fit at any width.
            Expanded(
              child: Text(
                count == 0
                    ? 'Nothing on the counter'
                    : '${Fmt.qty(count)} item${count == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.keyboard_arrow_up,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
            const SizedBox(width: 8),
            Text(
              Fmt.money(total),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
      ),
    );
  }
}

/// What is on the bill.
///
/// One widget for both places it is read: the side panel on a counter,
/// and the sheet a phone opens. Written once so the two cannot drift —
/// a modifier shown in one and missing from the other would be the
/// same bill telling two stories.
class _BasketLines extends StatelessWidget {
  const _BasketLines({
    required this.rows,
    required this.mods,
    required this.total,
    this.promos = const [],
    this.scrollable = false,
    this.confirmLabel,
    this.onLineAction,
  });

  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> mods;
  final double total;

  /// What the shop's own rules took off, one row each. On the phone's
  /// sheet as well as the counter's panel: a promotion visible only on
  /// a wide screen is a promotion a phone till cannot explain.
  final List<Map<String, dynamic>> promos;

  /// True in the phone's sheet, where the list is the whole point and
  /// has to scroll however long the bill gets.
  final bool scrollable;

  /// Tapping a line offers to take it off. Null on the confirmation
  /// sheet: that one is shown to be read and agreed with, and an
  /// editable list is a list somebody edits by accident while checking
  /// it.
  final ValueChanged<Map<String, dynamic>>? onLineAction;

  /// Set when the sheet is being shown to be agreed with rather than
  /// merely read — "Send to kitchen", "Take payment". Popping true is
  /// the agreement.
  final String? confirmLabel;

  @override
  Widget build(BuildContext context) {
    final list = ListView.separated(
      shrinkWrap: scrollable,
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final l = rows[i];
        final chosen = [
          for (final m in mods)
            if (m['line_id'] == l['id']) '${m['name']}',
        ];
        final sent = l['sent_to_kitchen_at'] != null;
        return ListTile(
          dense: true,
          isThreeLine:
              chosen.isNotEmpty || posNum(l['discount_amount']) > 0,
          onTap: onLineAction == null ? null : () => onLineAction!(l),
          leading: onLineAction == null
              ? null
              // The one column the rule turns on, said on the row: a
              // plate the kitchen has is not a plate you can simply
              // un-order. A padlock rather than a cooking pot, because
              // what the row is reporting is not where the plate is but
              // what may still be done to it.
              : Icon(
                  sent ? Icons.lock_outline : Icons.remove_circle_outline,
                  size: 18,
                ),
          title: Text('${l['description']}'),
          subtitle: Text(
            [
              '${Fmt.qty(posNum(l['quantity']))} × '
                  '${Fmt.money(posNum(l['unit_price']))}',
              // Under the plate rather than beside it: a modifier read
              // as its own line is a modifier somebody cooks
              // separately.
              if (chosen.isNotEmpty) chosen.join(', '),
              // What came off, and why. On the bill rather than only in
              // the report, because the customer is standing there and
              // the cashier has to be able to answer "what's this?".
              if (posNum(l['discount_amount']) > 0)
                'less ${Fmt.money(posNum(l['discount_amount']))}'
                    '${l['discount_reason'] == null ? '' : ' · ${l['discount_reason']}'}',
            ].join('\n'),
          ),
          trailing: Text(Fmt.money(posNum(l['line_total']))),
        );
      },
    );
    if (!scrollable) return list;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'On the counter',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          // Capped rather than free, so a long bill scrolls inside the
          // sheet instead of pushing the sheet off the screen.
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.7,
              ),
              child: list,
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                for (final p in promos) ...[
                  if (posNum(p['amount']) > 0)
                    _AmountRow('${p['name']}', -posNum(p['amount']))
                  else
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${p['name']} · ${p['blocked_reason'] ?? ''}',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.colors.warning,
                        ),
                      ),
                    ),
                  const SizedBox(height: 4),
                ],
                _AmountRow('Total', total, emphasise: true),
                if (confirmLabel != null) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(confirmLabel!),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Which till this device is.
///
/// Public, and shared with the floor plan, because "which register am I"
/// is the same question on every POS screen and answering it twice
/// invites the two answers to differ.
class PosRegisterPicker extends StatelessWidget {
  const PosRegisterPicker({
    super.key,
    required this.registers,
    required this.selectedId,
    required this.onPicked,
  });

  final List<Map<String, dynamic>> registers;
  final String? selectedId;
  final ValueChanged<Map<String, dynamic>> onPicked;

  @override
  Widget build(BuildContext context) {
    // A shop with one till has nothing to choose between, and a picker
    // showing one option is a control that only ever wastes a tap.
    if (registers.length < 2) return const SizedBox.shrink();
    return PopupMenuButton<Map<String, dynamic>>(
      tooltip: 'Which till',
      icon: const Icon(Icons.devices_other),
      onSelected: onPicked,
      itemBuilder: (_) => [
        for (final r in registers)
          PopupMenuItem(
            value: r,
            child: Row(
              children: [
                if (r['id'] == selectedId)
                  const Icon(Icons.check, size: 16)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text('${(r['pos_outlets'] as Map?)?['name'] ?? ''} · '
                    '${r['name']}'),
              ],
            ),
          ),
      ],
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow(this.label, this.amount, {this.emphasise = false});

  final String label;
  final double amount;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final style = emphasise
        ? Theme.of(context).textTheme.titleLarge
        : Theme.of(context).textTheme.bodyMedium;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: style),
        Text(Fmt.money(amount), style: style),
      ],
    );
  }
}

/// A number pad rather than a text field, because a till is used with a
/// thumb and often with a queue behind it.
Future<num?> _askAmount(
  BuildContext context, {
  required String title,
  required String hint,
}) {
  final controller = TextEditingController();
  return showDialog<num>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        decoration: InputDecoration(
          prefixText: Fmt.prefix('MYR'),
          labelText: hint,
        ),
        onSubmitted: (v) => Navigator.of(ctx).pop(num.tryParse(v) ?? 0),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(ctx).pop(num.tryParse(controller.text) ?? 0),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}
