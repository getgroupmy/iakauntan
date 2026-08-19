import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
// The POS methods live in an extension on Repo, and a Dart extension is
// only in scope where its declaring library is imported.
import '../../data/repository.dart';
import 'modifier_sheet.dart';
import 'split_sheet.dart';
import 'tender_sheet.dart';

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
    final declared = await _askAmount(
      context,
      title: 'Count the drawer',
      hint: 'What is actually in it',
    );
    if (declared == null || !mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
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
      if (rows.length == 1 && rows.first['matched_on'] == 'barcode') {
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

    // Asked before anything is written, because the answer changes the
    // line rather than following it. Most items have no questions, and
    // for those this costs one cheap round trip and opens nothing — a
    // sheet that appears for a tin of drink is a sheet in the way.
    List<String> mods = const [];
    final options = await ref.read(
      itemModifierOptionsProvider(itemId).future,
    );
    if (!mounted) return;
    if (options.isNotEmpty) {
      final picked = await showModalBottomSheet<List<String>>(
        context: context,
        isScrollControlled: true,
        builder: (_) => ModifierSheet(
          itemName: '${hit['name']}',
          basePrice: posNum(hit['unit_price']),
          options: options,
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
          quantity: posNum(hit['quantity']) == 0 ? 1 : posNum(hit['quantity']),
          price: posNum(hit['unit_price']),
        );
        // After the line, because a modifier is priced onto a line that
        // exists. `add_line_modifier` reprices as each one lands.
        for (final m in mods) {
          await repo.addLineModifier(line, m);
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
    final reg = _registerId;
    if (reg != null) ref.invalidate(parkedPosSalesProvider(reg));
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
      ..invalidate(posSaleLinesProvider(id))
      ..invalidate(parkedPosSalesProvider(_registerId!));
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
  Future<void> _merge(String from) async {
    final into = _saleId;
    if (into == null || into == from) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Merged',
      action: () => repo.mergePosSales(into, from),
    );
    if (!ok || !mounted) return;
    ref
      ..invalidate(posSaleProvider(into))
      ..invalidate(posSaleLinesProvider(into))
      ..invalidate(posSaleLineModifiersProvider(into))
      ..invalidate(parkedPosSalesProvider(_registerId!));
  }

  @override
  Widget build(BuildContext context) {
    final registers = ref.watch(posRegistersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Till'),
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
            onOpenShift: _openShift,
            onCloseShift: _closeShift,
            onTender: _tender,
            onSend: _send,
            onSplit: _split,
            onEvenSplit: _evenSplit,
            onMerge: _merge,
            onResume: (id) => setState(() => _saleId = id),
          );
        },
      ),
    );
  }
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
    required this.onOpenShift,
    required this.onCloseShift,
    required this.onTender,
    required this.onSend,
    required this.onSplit,
    required this.onEvenSplit,
    required this.onMerge,
    required this.onResume,
    required this.compact,
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
  final VoidCallback onOpenShift;
  final ValueChanged<String> onCloseShift;
  final VoidCallback onTender;
  final VoidCallback onSend;
  final VoidCallback onSplit;
  final VoidCallback onEvenSplit;
  final ValueChanged<String> onMerge;
  final ValueChanged<String> onResume;

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
          saleId: saleId,
          onTender: onTender,
          onSend: onSend,
          onSplit: onSplit,
          onEvenSplit: onEvenSplit,
          onMerge: onMerge,
          onResume: onResume,
          compact: compact,
        );
        final finder = _Finder(
          outletId: outletId,
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
    required this.search,
    required this.searchFocus,
    required this.results,
    required this.looking,
    required this.onSearch,
    required this.onPick,
    required this.shiftId,
    required this.shiftNo,
    required this.onCloseShift,
  });

  final String? outletId;
  final TextEditingController search;
  final FocusNode searchFocus;
  final List<Map<String, dynamic>> results;
  final bool looking;
  final ValueChanged<String> onSearch;
  final ValueChanged<Map<String, dynamic>> onPick;
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
                    : _Browse(outletId: outletId!, onPick: onPick))
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
    required this.saleId,
    required this.onTender,
    required this.onSend,
    required this.onSplit,
    required this.onEvenSplit,
    required this.onMerge,
    required this.onResume,
  });

  final String registerId;
  final String? saleId;
  final VoidCallback onTender;
  final VoidCallback onSend;
  final VoidCallback onSplit;
  final VoidCallback onEvenSplit;
  final ValueChanged<String> onMerge;
  final ValueChanged<String> onResume;

  /// True on a phone, where the bill cannot share the screen with the
  /// menu and becomes a tappable summary instead.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = saleId;
    if (id == null) {
      final parked = ref.watch(parkedPosSalesProvider(registerId));
      final list = AsyncView<List<Map<String, dynamic>>>(
        value: parked,
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
                  // Parked baskets are money that has been set aside,
                  // so they are listed rather than left to be
                  // remembered.
                  for (final s in rows)
                    ListTile(
                      leading: const Icon(Icons.pause_circle_outline),
                      title: Text('${s['sale_no']}'),
                      trailing: Text(Fmt.money(posNum(s['total_amount']))),
                      onTap: () => onResume(s['id'] as String),
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
          const SectionHeader('Nothing on the counter'),
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

    final rows = lines.maybeWhen(
      data: (r) => r,
      orElse: () => const <Map<String, dynamic>>[],
    );
    final count = rows.fold<double>(
      0,
      (n, l) => n + posNum(l['quantity']),
    );

    return Column(
      children: [
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
                      scrollable: true,
                    ),
                  ),
          )
        else
          Expanded(
            child: AsyncView<List<Map<String, dynamic>>>(
              value: lines,
              builder: (r) => _BasketLines(rows: r, mods: mods, total: total),
            ),
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              if (!compact) ...[
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
                  onPressed: total > 0 ? onSend : null,
                  icon: const Icon(Icons.soup_kitchen_outlined),
                  label: const Text('Send to kitchen'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: total > 0 ? onTender : null,
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
  const _Browse({required this.outletId, required this.onPick});

  final String outletId;
  final ValueChanged<Map<String, dynamic>> onPick;

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
                                    subtitle: Fmt.money(
                                      posNum(r['unit_price']),
                                    ),
                                    onTap: () => widget.onPick(r),
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

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An offer to put two bills back together, shown only when there is
/// another bill to put this one together with.
class _MergeBar extends ConsumerWidget {
  const _MergeBar({
    required this.registerId,
    required this.saleId,
    required this.onMerge,
  });

  final String registerId;
  final String saleId;
  final ValueChanged<String> onMerge;

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
        child: PopupMenuButton<String>(
          tooltip: 'Merge another bill into this one',
          onSelected: onMerge,
          itemBuilder: (_) => [
            for (final o in others)
              PopupMenuItem(
                value: o['id'] as String,
                child: Text(
                  '${o['sale_no']}  ·  ${Fmt.money(posNum(o['total_amount']))}',
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
            Text(
              count == 0
                  ? 'Nothing on the counter'
                  : '${Fmt.qty(count)} item${count == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (onTap != null) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.keyboard_arrow_up,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
            const Spacer(),
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
    this.scrollable = false,
  });

  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> mods;
  final double total;

  /// True in the phone's sheet, where the list is the whole point and
  /// has to scroll however long the bill gets.
  final bool scrollable;

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
        return ListTile(
          dense: true,
          isThreeLine: chosen.isNotEmpty,
          title: Text('${l['description']}'),
          subtitle: Text(
            [
              '${Fmt.qty(posNum(l['quantity']))} × '
                  '${Fmt.money(posNum(l['unit_price']))}',
              // Under the plate rather than beside it: a modifier read
              // as its own line is a modifier somebody cooks
              // separately.
              if (chosen.isNotEmpty) chosen.join(', '),
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
            child: _AmountRow('Total', total, emphasise: true),
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
