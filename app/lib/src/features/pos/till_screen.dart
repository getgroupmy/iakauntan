import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
// The POS methods live in an extension on Repo, and a Dart extension is
// only in scope where its declaring library is imported.
import '../../data/repository.dart';
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
    var sale = _saleId;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () async {
        sale ??= await repo.openPosSale(reg);
        await repo.addPosSaleLine(
          sale!,
          hit['item_id'] as String,
          quantity: posNum(hit['quantity']) == 0 ? 1 : posNum(hit['quantity']),
          price: posNum(hit['unit_price']),
        );
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
      ..invalidate(posSaleLinesProvider(sale!));
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
    required this.onResume,
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

        final basket = _Basket(
          registerId: registerId,
          saleId: saleId,
          onTender: onTender,
          onSend: onSend,
          onResume: onResume,
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
                  SizedBox(width: 360, child: basket),
                ],
              );
            }
            return Column(
              children: [
                Expanded(child: finder),
                const Divider(height: 1),
                SizedBox(height: box.maxHeight * 0.42, child: basket),
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
    required this.onResume,
  });

  final String registerId;
  final String? saleId;
  final VoidCallback onTender;
  final VoidCallback onSend;
  final ValueChanged<String> onResume;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = saleId;
    if (id == null) {
      final parked = ref.watch(parkedPosSalesProvider(registerId));
      return Column(
        children: [
          const SectionHeader('Nothing on the counter'),
          Expanded(
            child: AsyncView<List<Map<String, dynamic>>>(
              value: parked,
              builder: (rows) => rows.isEmpty
                  ? const EmptyState(
                      icon: Icons.shopping_basket_outlined,
                      title: 'Empty',
                      message: 'Scan something to start a sale.',
                    )
                  : ListView(
                      children: [
                        // Parked baskets are money that has been set
                        // aside, so they are listed rather than left to
                        // be remembered.
                        for (final s in rows)
                          ListTile(
                            leading: const Icon(Icons.pause_circle_outline),
                            title: Text('${s['sale_no']}'),
                            trailing: Text(
                              Fmt.money(posNum(s['total_amount'])),
                            ),
                            onTap: () => onResume(s['id'] as String),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      );
    }

    final sale = ref.watch(posSaleProvider(id));
    final lines = ref.watch(posSaleLinesProvider(id));
    final total = sale.maybeWhen(
      data: (row) => posNum(row?['total_amount']),
      orElse: () => 0.0,
    );

    return Column(
      children: [
        Expanded(
          child: AsyncView<List<Map<String, dynamic>>>(
            value: lines,
            builder: (rows) => ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final l = rows[i];
                return ListTile(
                  dense: true,
                  title: Text('${l['description']}'),
                  subtitle: Text(
                    '${Fmt.qty(posNum(l['quantity']))} × '
                    '${Fmt.money(posNum(l['unit_price']))}',
                  ),
                  trailing: Text(Fmt.money(posNum(l['line_total']))),
                );
              },
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              _AmountRow('Total', total, emphasise: true),
              const SizedBox(height: 12),
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
