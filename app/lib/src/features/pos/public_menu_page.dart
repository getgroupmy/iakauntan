import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format.dart';
import '../../core/theme.dart';

/// One line of what somebody has tapped so far.
typedef BasketLine = ({
  String itemId,
  String name,
  double price,
  int quantity,
});

/// What the basket comes to, before the shop applies anything of its
/// own.
///
/// Pure and exported so the page and the tests agree — and deliberately
/// only an estimate: the price that gets charged is the server's, after
/// promotions, the delivery fee and rounding. The page says as much.
double basketTotal(List<BasketLine> lines) =>
    lines.fold(0, (sum, l) => sum + l.price * l.quantity);

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

  void _add(Map<String, dynamic> row) {
    final id = '${row['item_id']}';
    setState(() {
      final at = _basket.indexWhere((l) => l.itemId == id);
      if (at >= 0) {
        _basket[at] = (
          itemId: id,
          name: _basket[at].name,
          price: _basket[at].price,
          quantity: _basket[at].quantity + 1,
        );
      } else {
        _basket.add((
          itemId: id,
          name: '${row['name']}',
          price: Fmt.toDouble(row['unit_price']),
          quantity: 1,
        ));
      }
    });
  }

  void _remove(String itemId) {
    setState(() {
      final at = _basket.indexWhere((l) => l.itemId == itemId);
      if (at < 0) return;
      if (_basket[at].quantity <= 1) {
        _basket.removeAt(at);
      } else {
        _basket[at] = (
          itemId: _basket[at].itemId,
          name: _basket[at].name,
          price: _basket[at].price,
          quantity: _basket[at].quantity - 1,
        );
      }
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
          // An item and a quantity. No price: the shop's is the one
          // that counts, and a price from a browser is a price
          // somebody typed.
          'p_items': [
            for (final l in _basket)
              {'item': l.itemId, 'quantity': l.quantity},
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
  });

  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic> head;
  final List<BasketLine> basket;
  final bool sending;
  final void Function(Map<String, dynamic>) onAdd;
  final void Function(String) onRemove;
  final VoidCallback onOrder;
  final VoidCallback onRefresh;

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
