import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format.dart';
import '../../core/theme.dart';

/// One answer somebody has given to a question a plate comes with.
typedef ChosenModifier = ({String id, String name, double delta});

/// One line of what somebody has tapped so far.
///
/// `mods` is what was chosen for this line. Two of the same dish with
/// different answers are two lines, not one with a quantity of two —
/// which is why [basketKey] and not `itemId` decides whether tapping
/// again adds to an existing line.
typedef BasketLine = ({
  String itemId,
  String name,
  double price,
  int quantity,
  List<ChosenModifier> mods,
});

/// What tells one basket line from another.
///
/// The item plus the answers, sorted so the same two answers given in a
/// different order are still the same line.
String basketKey(String itemId, Iterable<String> modifierIds) {
  final ids = modifierIds.toList()..sort();
  return ids.isEmpty ? itemId : '$itemId|${ids.join(',')}';
}

/// What one line costs, the dish plus whatever was added to it.
double lineTotal(BasketLine l) =>
    (l.price + l.mods.fold<double>(0, (s, m) => s + m.delta)) * l.quantity;

/// What the basket comes to, before the shop applies anything of its
/// own.
///
/// Pure and exported so the page and the tests agree — and deliberately
/// only an estimate: the price that gets charged is the server's, after
/// promotions, the delivery fee and rounding. The page says as much.
double basketTotal(List<BasketLine> lines) =>
    lines.fold(0, (sum, l) => sum + lineTotal(l));

/// What a line reads as once its questions have been answered.
String lineLabel(BasketLine l) => l.mods.isEmpty
    ? l.name
    : '${l.name} · ${l.mods.map((m) => m.name).join(', ')}';

/// The flat rows `public_pos_menu_modifiers` returns, gathered into the
/// groups they belong to and in the order the shop set.
///
/// A group with no live modifiers comes back as a single row with a
/// null `modifier_id`; it is kept, because a required group with
/// nothing in it is a thing somebody needs to see rather than a
/// question that silently disappears.
List<Map<String, dynamic>> modifierGroups(List<Map<String, dynamic>> rows) {
  final out = <String, Map<String, dynamic>>{};
  for (final r in rows) {
    final id = '${r['group_id']}';
    final g = out.putIfAbsent(
      id,
      () => {
        'group_id': id,
        'group_name': '${r['group_name']}',
        'min_select': r['min_select'],
        'max_select': r['max_select'],
        'modifiers': <Map<String, dynamic>>[],
      },
    );
    if (r['modifier_id'] != null) {
      (g['modifiers'] as List<Map<String, dynamic>>).add(r);
    }
  }
  return out.values.toList();
}

/// Whether the answers given to one group are enough and not too many.
bool groupSatisfied(Map<String, dynamic> group, Set<String> chosen) {
  final ids = {
    for (final m in group['modifiers'] as List<Map<String, dynamic>>)
      '${m['modifier_id']}',
  };
  final n = chosen.intersection(ids).length;
  final min = Fmt.toInt(group['min_select']);
  final max = Fmt.toInt(group['max_select']);
  if (n < min) return false;
  // A max of nought is "as many as you like", which is how the till
  // reads it too.
  return max <= 0 || n <= max;
}

/// The questions still unanswered, by name.
///
/// This is the client-side twin of `pos_line_modifier_gaps`, which
/// refuses to send an order to the kitchen while any of these are
/// outstanding. Asking here means the order is never placed in that
/// state — before this, a phone could order a dish whose questions
/// nobody had answered and the bill would sit on the till unable to go
/// to the cooks.
List<String> missingChoices(
  List<Map<String, dynamic>> groups,
  Set<String> chosen,
) => [
  for (final g in groups)
    if (!groupSatisfied(g, chosen)) '${g['group_name']}',
];

/// The menu rows grouped under their headings, in the order they came
/// back.
Map<String, List<Map<String, dynamic>>> menuGroups(
  List<Map<String, dynamic>> rows,
) {
  final out = <String, List<Map<String, dynamic>>>{};
  for (final r in rows) {
    out.putIfAbsent('${r['category'] ?? 'Uncategorised'}', () => []).add(r);
  }
  return out;
}

/// What a customer sees when they point a phone at the sticker on their
/// table.
///
/// Like [SharedDocumentPage] this works with no account and does not use
/// `repoProvider`: there is no signed-in user and never will be. The
/// token authorises everything, and the three functions it calls take a
/// token and never an organization id.
///
/// The page shows prices but never sends one. What is ordered is an item
/// and a quantity; the shop's own price, its promotions and its delivery
/// fee are applied on the server, and the number this page shows before
/// ordering is labelled as the estimate it is.
class PublicMenuPage extends ConsumerStatefulWidget {
  const PublicMenuPage({super.key, required this.token});

  final String token;

  @override
  ConsumerState<PublicMenuPage> createState() => _PublicMenuPageState();
}

class _PublicMenuPageState extends ConsumerState<PublicMenuPage> {
  late Future<List<Map<String, dynamic>>> _menu = _load();
  final List<BasketLine> _basket = [];
  bool _sending = false;
  Map<String, dynamic>? _placed;

  Future<List<Map<String, dynamic>>> _load() async {
    final data = await Supabase.instance.client
        .rpc('public_pos_menu', params: {'p_token': widget.token});
    return [
      for (final r in (data as List? ?? const []))
        Map<String, dynamic>.from(r as Map),
    ];
  }

  /// The questions a dish comes with, fetched once and kept.
  ///
  /// Per item rather than for the whole menu: most dishes have none,
  /// and asking the server for every dish's options when a menu opens
  /// would fetch a great deal nobody will look at.
  final Map<String, List<Map<String, dynamic>>> _modifiers = {};

  Future<List<Map<String, dynamic>>> _loadModifiers(String itemId) async {
    final cached = _modifiers[itemId];
    if (cached != null) return cached;
    final data = await Supabase.instance.client.rpc(
      'public_pos_menu_modifiers',
      params: {'p_token': widget.token, 'p_item': itemId},
    );
    final rows = [
      for (final r in (data as List? ?? const []))
        Map<String, dynamic>.from(r as Map),
    ];
    _modifiers[itemId] = rows;
    return rows;
  }

  Future<void> _add(Map<String, dynamic> row) async {
    final id = '${row['item_id']}';
    List<Map<String, dynamic>> groups = const [];
    try {
      groups = modifierGroups(await _loadModifiers(id));
    } catch (_) {
      // A shop that has never set a modifier group, or a menu link
      // whose company does not have the module: the dish is still
      // orderable, it just has nothing to ask.
      groups = const [];
    }
    if (!mounted) return;

    var chosen = <ChosenModifier>[];
    if (groups.isNotEmpty) {
      final answered = await showModalBottomSheet<List<ChosenModifier>>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _ChoicesSheet(
          name: '${row['name']}',
          price: Fmt.toDouble(row['unit_price']),
          groups: groups,
        ),
      );
      // Backed out of the questions: nothing goes in the basket. An
      // order placed without them cannot reach the kitchen.
      if (answered == null || !mounted) return;
      chosen = answered;
    }

    final key = basketKey(id, chosen.map((m) => m.id));
    setState(() {
      final at = _basket.indexWhere(
        (l) => basketKey(l.itemId, l.mods.map((m) => m.id)) == key,
      );
      if (at >= 0) {
        _basket[at] = (
          itemId: _basket[at].itemId,
          name: _basket[at].name,
          price: _basket[at].price,
          quantity: _basket[at].quantity + 1,
          mods: _basket[at].mods,
        );
      } else {
        _basket.add((
          itemId: id,
          name: '${row['name']}',
          price: Fmt.toDouble(row['unit_price']),
          quantity: 1,
          mods: chosen,
        ));
      }
    });
  }

  /// Takes one off the most recently added line of that dish.
  ///
  /// The minus button on a menu row cannot know which set of answers
  /// somebody meant, so it takes from the last one they built. The
  /// basket sheet below is where a specific line is removed.
  void _remove(String itemId) {
    setState(() {
      final at = _basket.lastIndexWhere((l) => l.itemId == itemId);
      if (at < 0) return;
      if (_basket[at].quantity <= 1) {
        _basket.removeAt(at);
      } else {
        _basket[at] = (
          itemId: _basket[at].itemId,
          name: _basket[at].name,
          price: _basket[at].price,
          quantity: _basket[at].quantity - 1,
          mods: _basket[at].mods,
        );
      }
    });
  }

  void _removeLine(int index) {
    setState(() {
      if (index >= 0 && index < _basket.length) _basket.removeAt(index);
    });
  }

  Future<void> _order(String kind) async {
    final who = await showModalBottomSheet<_Who>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _WhoSheet(needsAddress: kind == 'delivery'),
      ),
    );
    if (who == null || !mounted) return;

    setState(() => _sending = true);
    try {
      final data = await Supabase.instance.client.rpc(
        'place_public_pos_order',
        params: {
          'p_token': widget.token,
          // An item, a quantity and what was chosen on it. No price:
          // the shop's is the one that counts, and a price from a
          // browser is a price somebody typed — which goes for a
          // modifier's price delta as much as for the dish's.
          'p_items': [
            for (final l in _basket)
              {
                'item': l.itemId,
                'quantity': l.quantity,
                if (l.mods.isNotEmpty)
                  'modifiers': [
                    for (final m in l.mods) {'modifier': m.id, 'quantity': 1},
                  ],
              },
          ],
          'p_name': who.name.isEmpty ? null : who.name,
          'p_phone': who.phone.isEmpty ? null : who.phone,
          'p_note': who.note.isEmpty ? null : who.note,
          'p_line1': who.line1.isEmpty ? null : who.line1,
          'p_city': who.city.isEmpty ? null : who.city,
          'p_postcode': who.postcode.isEmpty ? null : who.postcode,
        },
      );
      final rows = (data as List? ?? const []);
      if (!mounted) return;
      setState(() {
        _placed = rows.isEmpty
            ? const {}
            : Map<String, dynamic>.from(rows.first as Map);
        _basket.clear();
        _sending = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      // The server's refusals are already sentences written for a
      // person — the shop is closed, that dish is off, the zone needs
      // another eight ringgit — so they are shown rather than replaced.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_clean('$e'))),
      );
    }
  }

  /// PostgREST wraps the message; the sentence inside it is the useful
  /// part.
  static String _clean(String raw) {
    final match = RegExp(r'message: ([^,]+)').firstMatch(raw);
    return match?.group(1) ?? raw;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scheme.surfaceContainerLowest,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _menu,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return _Message(
                    icon: Icons.qr_code_scanner,
                    title: 'This menu is not available',
                    body: _clean('${snap.error}'),
                  );
                }
                final rows = snap.data ?? const [];
                if (rows.isEmpty) {
                  return const _Message(
                    icon: Icons.restaurant_menu,
                    title: 'Nothing on the menu',
                    body: 'Ask at the counter.',
                  );
                }
                if (_placed != null) return _Placed(order: _placed!);

                final head = rows.first;
                return _Menu(
                  rows: rows,
                  head: head,
                  basket: _basket,
                  sending: _sending,
                  onAdd: _add,
                  onRemove: _remove,
                  onOrder: () => _order('${head['kind']}'),
                  onRemoveLine: _removeLine,
                  onRefresh: () => setState(() => _menu = _load()),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu({
    required this.rows,
    required this.head,
    required this.basket,
    required this.sending,
    required this.onAdd,
    required this.onRemove,
    required this.onOrder,
    required this.onRefresh,
    required this.onRemoveLine,
  });

  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic> head;
  final List<BasketLine> basket;
  final bool sending;
  final void Function(Map<String, dynamic>) onAdd;
  final void Function(String) onRemove;
  final VoidCallback onOrder;
  final VoidCallback onRefresh;
  final void Function(int) onRemoveLine;

  @override
  Widget build(BuildContext context) {
    final groups = menuGroups(rows);
    final table = '${head['table_code'] ?? ''}';
    final kind = '${head['kind']}';

    return Column(
      children: [
        ListTile(
          title: Text(
            '${head['outlet_name']}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          subtitle: Text(
            switch (kind) {
              'table' => table.isEmpty ? 'Order from your table' : 'Table $table',
              'delivery' => 'Delivery',
              _ => 'Takeaway',
            },
          ),
          trailing: IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: onRefresh,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final entry in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    entry.key,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                for (final r in entry.value)
                  _ItemTile(
                    row: r,
                    ordered: basket
                        .where((l) => l.itemId == '${r['item_id']}')
                        .fold(0, (n, l) => n + l.quantity),
                    onAdd: () => onAdd(r),
                    onRemove: () => onRemove('${r['item_id']}'),
                  ),
              ],
              const SizedBox(height: 96),
            ],
          ),
        ),
        if (basket.isNotEmpty)
          Material(
            elevation: 8,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    // Tappable, because two of the same dish with
                    // different answers are now two lines and a
                    // customer has to be able to see which is which.
                    child: InkWell(
                      onTap: () => showModalBottomSheet<void>(
                        context: context,
                        builder: (_) => _BasketSheet(
                          basket: basket,
                          onRemoveLine: onRemoveLine,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${basket.fold<int>(0, (n, l) => n + l.quantity)} '
                            'item(s)',
                          ),
                          // Called an estimate because it is one: the
                          // shop's promotions, its delivery fee and its
                          // rounding all happen on the server.
                          Text(
                            'About ${Fmt.money(basketTotal(basket))}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: sending ? null : onOrder,
                    child: Text(sending ? 'Sending…' : 'Order'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The questions one plate comes with, asked before it goes in the
/// basket.
///
/// The confirm button stays dead while a required group is unanswered,
/// and says which one — the same rule `pos_line_modifier_gaps` applies
/// on the server, said early enough to be useful rather than after the
/// order has been placed.
/// What is in the basket, line by line.
///
/// One line per set of answers: "Nasi lemak · Telur mata" and "Nasi
/// lemak · Telur dadar" are two things a kitchen cooks differently, so
/// they are two rows here rather than one row saying two.
class _BasketSheet extends StatelessWidget {
  const _BasketSheet({required this.basket, required this.onRemoveLine});

  final List<BasketLine> basket;
  final void Function(int) onRemoveLine;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Your order')),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < basket.length; i++)
                  ListTile(
                    dense: true,
                    title: Text(lineLabel(basket[i])),
                    subtitle: Text('${basket[i].quantity} × '
                        '${Fmt.money(lineTotal(basket[i]) / basket[i].quantity)}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(Fmt.money(lineTotal(basket[i]))),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            onRemoveLine(i);
                            Navigator.of(context).pop();
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChoicesSheet extends StatefulWidget {
  const _ChoicesSheet({
    required this.name,
    required this.price,
    required this.groups,
  });

  final String name;
  final double price;
  final List<Map<String, dynamic>> groups;

  @override
  State<_ChoicesSheet> createState() => _ChoicesSheetState();
}

class _ChoicesSheetState extends State<_ChoicesSheet> {
  final _chosen = <String, ChosenModifier>{};

  /// One choice or several, decided by the group's own maximum.
  void _pick(Map<String, dynamic> group, Map<String, dynamic> mod) {
    final id = '${mod['modifier_id']}';
    final max = Fmt.toInt(group['max_select']);
    setState(() {
      if (_chosen.containsKey(id)) {
        _chosen.remove(id);
        return;
      }
      if (max == 1) {
        // "Choose one" replaces rather than adds, which is what a
        // customer expects from a group that takes a single answer.
        for (final m in group['modifiers'] as List<Map<String, dynamic>>) {
          _chosen.remove('${m['modifier_id']}');
        }
      }
      _chosen[id] = (
        id: id,
        name: '${mod['name']}',
        delta: Fmt.toDouble(mod['price_delta']),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final missing = missingChoices(widget.groups, _chosen.keys.toSet());
    final extra = _chosen.values.fold<double>(0, (s, m) => s + m.delta);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              title: Text(
                widget.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              trailing: Text(Fmt.money(widget.price + extra)),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final g in widget.groups) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        [
                          '${g['group_name']}',
                          if (Fmt.toInt(g['min_select']) > 0) 'required',
                        ].join(' · '),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    if ((g['modifiers'] as List).isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text('Nothing to choose from — ask at the counter.'),
                      ),
                    for (final m
                        in g['modifiers'] as List<Map<String, dynamic>>)
                      CheckboxListTile(
                        dense: true,
                        value: _chosen.containsKey('${m['modifier_id']}'),
                        title: Text('${m['name']}'),
                        subtitle: Fmt.toDouble(m['price_delta']) == 0
                            ? null
                            : Text(
                                '+${Fmt.money(Fmt.toDouble(m['price_delta']))}',
                              ),
                        onChanged: (_) => _pick(g, m),
                      ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      missing.isEmpty
                          ? 'Ready'
                          : 'Still to choose: ${missing.join(', ')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: missing.isEmpty
                        ? () => Navigator.of(context).pop(
                            _chosen.values.toList(),
                          )
                        : null,
                    child: const Text('Add'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.row,
    required this.ordered,
    required this.onAdd,
    required this.onRemove,
  });

  final Map<String, dynamic> row;
  final int ordered;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final off = row['available'] != true;
    final reason = '${row['off_reason'] ?? ''}';

    return Opacity(
      opacity: off ? 0.5 : 1,
      child: ListTile(
        title: Text('${row['name']}'),
        // The shop's own words for why it is off — sold out, or not
        // served at this hour. A greyed-out row with no reason is a row
        // customers ask staff about.
        subtitle: off && reason.isNotEmpty ? Text(reason) : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Fmt.money(Fmt.toDouble(row['unit_price']))),
            const SizedBox(width: 8),
            if (ordered > 0) ...[
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: onRemove,
              ),
              Text('$ordered'),
            ],
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: off ? null : onAdd,
            ),
          ],
        ),
      ),
    );
  }
}

class _Placed extends StatelessWidget {
  const _Placed({required this.order});

  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final blocked = order['blocked_reason'] as String?;
    return _Message(
      icon: Icons.check_circle_outline,
      title: 'Order ${order['sale_no']}',
      body: [
        'The kitchen has it.',
        'Total ${Fmt.money(Fmt.toDouble(order['total']))}',
        if (Fmt.toDouble(order['fee']) > 0)
          'including ${Fmt.money(Fmt.toDouble(order['fee']))} delivery',
        if (blocked != null) blocked,
      ].join('\n'),
    );
  }
}

typedef _Who = ({
  String name,
  String phone,
  String note,
  String line1,
  String city,
  String postcode,
});

class _WhoSheet extends StatefulWidget {
  const _WhoSheet({required this.needsAddress});

  final bool needsAddress;

  @override
  State<_WhoSheet> createState() => _WhoSheetState();
}

class _WhoSheetState extends State<_WhoSheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();
  final _line1 = TextEditingController();
  final _city = TextEditingController();
  final _postcode = TextEditingController();

  @override
  void dispose() {
    for (final c in [_name, _phone, _note, _line1, _city, _postcode]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _ready => !widget.needsAddress || _line1.text.trim().isNotEmpty;

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
              widget.needsAddress ? 'Where is it going?' : 'Who is it for?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone'),
            ),
            if (widget.needsAddress) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _line1,
                decoration: const InputDecoration(labelText: 'Address'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _postcode,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Postcode',
                        helperText: 'Sets the fee',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _city,
                      decoration: const InputDecoration(labelText: 'Town'),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                labelText: 'Anything the kitchen should know',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _ready
                  ? () => Navigator.of(context).pop((
                      name: _name.text.trim(),
                      phone: _phone.text.trim(),
                      note: _note.text.trim(),
                      line1: _line1.text.trim(),
                      city: _city.text.trim(),
                      postcode: _postcode.text.trim(),
                    ))
                  : null,
              child: const Text('Send the order'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: context.scheme.outline),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
