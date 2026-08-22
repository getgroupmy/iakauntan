import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Where a transfer has got to, in the words a warehouse uses.
///
/// Pure and exported so the list, the detail sheet and the tests agree.
String transferState(String? status) => switch (status) {
  'draft' => 'Being written',
  'sent' => 'On its way',
  'received' => 'Arrived',
  'cancelled' => 'Cancelled',
  _ => '$status',
};

/// What a transfer's row says under its number.
///
/// The shortfall is only mentioned when there is one — every arrived
/// transfer saying "short by RM 0.00" is noise that trains people to
/// stop reading the line that matters.
String transferSummary(Map<String, dynamic> row) {
  final parts = <String>[
    '${row['from_warehouse']} → ${row['to_warehouse']}',
    '${row['line_count']} line${row['line_count'] == 1 ? '' : 's'}',
    Fmt.money(num.tryParse('${row['value'] ?? 0}')),
  ];
  final short = num.tryParse('${row['shortfall'] ?? 0}') ?? 0;
  if (short > 0) parts.add('short by ${Fmt.money(short)}');
  return parts.join(' · ');
}

/// Whether the shares of a conversion add up, and what they add up to.
///
/// Checked here as well as on the server so somebody typing a split
/// sees it go green rather than being told no when they press save.
/// The server's refusal is the one that counts.
({bool ok, num total}) shareTotal(List<Map<String, dynamic>> outputs) {
  num total = 0;
  for (final o in outputs) {
    total += num.tryParse('${o['share'] ?? 0}') ?? 0;
  }
  return (ok: total == 100, total: total);
}

/// Stock moving between stores, and one thing becoming several.
class TransfersScreen extends ConsumerStatefulWidget {
  const TransfersScreen({super.key});

  @override
  ConsumerState<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends ConsumerState<TransfersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfers'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Between stores'),
            Tab(text: 'Conversions'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_TransferList(), _ConversionList()],
      ),
    );
  }
}

class _TransferList extends ConsumerStatefulWidget {
  const _TransferList();

  @override
  ConsumerState<_TransferList> createState() => _TransferListState();
}

class _TransferListState extends ConsumerState<_TransferList> {
  void _reload() => ref.invalidate(stockTransfersProvider);

  Future<void> _new() async {
    final warehouses = await ref.read(warehousesProvider.future);
    final items = await ref.read(itemsProvider('').future);
    if (!mounted) return;
    if (warehouses.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'A transfer needs two stores. Set up a second warehouse first.',
          ),
        ),
      );
      return;
    }
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TransferSheet(warehouses: warehouses, items: items),
    );
    if (saved == true) _reload();
  }

  Future<void> _send(Map<String, dynamic> row) async {
    final done = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.sendStockTransfer(row['id'] as String),
      successMessage: 'Sent. The value is in goods in transit until it lands.',
    );
    if (done) _reload();
  }

  Future<void> _receive(Map<String, dynamic> row) async {
    final lines = await ref
        .read(repoProvider)!
        .stockTransferLines(row['id'] as String);
    if (!mounted) return;
    final counts = await showModalBottomSheet<List<Map<String, dynamic>>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReceiveSheet(lines: lines),
    );
    if (counts == null || !mounted) return;
    final done = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .receiveStockTransfer(row['id'] as String, counts: counts),
      successMessage: 'Counted in.',
    );
    if (done) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final transfers = ref.watch(stockTransfersProvider(null));
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _new,
        icon: const Icon(Icons.local_shipping_outlined),
        label: const Text('Transfer'),
      ),
      body: AsyncView(
        value: transfers,
        onRetry: _reload,
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.local_shipping_outlined,
              title: 'Nothing has moved between stores',
              message:
                  'A transfer takes stock out of one store at what it cost '
                  'there and puts it into another at the same price, with '
                  'the value sitting in goods in transit until it arrives.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final row = rows[i];
              final status = '${row['status']}';
              final short = num.tryParse('${row['shortfall'] ?? 0}') ?? 0;
              return ListTile(
                title: Text('${row['transfer_no']}'),
                subtitle: Text(transferSummary(row)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Chip(
                      label: Text(transferState(status)),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: short > 0
                          ? context.colors.warning.withValues(alpha: 0.15)
                          : null,
                    ),
                    if (status == 'draft')
                      IconButton(
                        icon: const Icon(Icons.send_outlined),
                        tooltip: 'Load the van',
                        onPressed: () => _send(row),
                      ),
                    if (status == 'sent')
                      IconButton(
                        icon: const Icon(Icons.inventory_2_outlined),
                        tooltip: 'Count it in',
                        onPressed: () => _receive(row),
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

/// Writing a transfer: where from, where to, and what is on it.
class _TransferSheet extends ConsumerStatefulWidget {
  const _TransferSheet({required this.warehouses, required this.items});

  final List<Map<String, dynamic>> warehouses;
  final List<Item> items;

  @override
  ConsumerState<_TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends ConsumerState<_TransferSheet> {
  String? _from;
  String? _to;
  final List<Map<String, dynamic>> _lines = [];
  final _notes = TextEditingController();

  @override
  void initState() {
    super.initState();
    _from = widget.warehouses.first['id'] as String?;
    _to = widget.warehouses[1]['id'] as String?;
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _addLine() async {
    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _StockLineDialog(items: widget.items),
    );
    if (chosen == null) return;
    setState(() => _lines.add(chosen));
  }

  Future<void> _save() async {
    final from = _from, to = _to;
    if (from == null || to == null) return;
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveStockTransfer(
            fromWarehouse: from,
            toWarehouse: to,
            date: DateTime.now(),
            lines: _lines
                .map(
                  (l) => {
                    'item': l['item'],
                    'quantity': l['quantity'],
                    'uom': l['uom'],
                  },
                )
                .toList(),
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          ),
      successMessage: 'Saved as a draft. Send it when the van is loaded.',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(Space.lg),
          children: [
            Text(
              'A transfer',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Space.md),
            DropdownButtonFormField<String>(
              value: _from,
              decoration: const InputDecoration(labelText: 'Leaving'),
              items: [
                for (final w in widget.warehouses)
                  DropdownMenuItem(
                    value: w['id'] as String,
                    child: Text('${w['name']}'),
                  ),
              ],
              onChanged: (v) => setState(() => _from = v),
            ),
            const SizedBox(height: Space.md),
            DropdownButtonFormField<String>(
              value: _to,
              decoration: const InputDecoration(labelText: 'Arriving'),
              items: [
                for (final w in widget.warehouses)
                  DropdownMenuItem(
                    value: w['id'] as String,
                    child: Text('${w['name']}'),
                  ),
              ],
              onChanged: (v) => setState(() => _to = v),
            ),
            const SizedBox(height: Space.md),
            for (final line in _lines)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${line['name']}'),
                subtitle: Text('${line['quantity']} ${line['uom']}'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _lines.remove(line)),
                ),
              ),
            TextButton.icon(
              onPressed: _addLine,
              icon: const Icon(Icons.add),
              label: const Text('Line'),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
            const SizedBox(height: Space.lg),
            FilledButton(
              onPressed: _lines.isEmpty || _from == _to ? null : _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Counting a delivery in. Everything is filled with what was sent, so
/// a shop that only has two short lines edits two fields.
class _ReceiveSheet extends StatefulWidget {
  const _ReceiveSheet({required this.lines});

  final List<Map<String, dynamic>> lines;

  @override
  State<_ReceiveSheet> createState() => _ReceiveSheetState();
}

class _ReceiveSheetState extends State<_ReceiveSheet> {
  final Map<String, TextEditingController> _fields = {};

  @override
  void initState() {
    super.initState();
    for (final l in widget.lines) {
      _fields['${l['id']}'] = TextEditingController(
        text: '${l['sent_quantity'] ?? 0}',
      );
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(Space.lg),
          children: [
            Text(
              'What arrived',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Space.xs),
            Text(
              'Filled in with what was sent. Change only the lines that '
              'came up short — anything missing is written off to '
              'inventory adjustment against this transfer.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            for (final l in widget.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: TextField(
                  controller: _fields['${l['id']}'],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: '${l['item_name']}',
                    helperText: 'Sent ${l['sent_quantity']} ${l['base_uom']}',
                  ),
                ),
              ),
            const SizedBox(height: Space.md),
            FilledButton(
              onPressed: () => Navigator.of(context).pop([
                for (final l in widget.lines)
                  {
                    'line': l['id'],
                    'quantity':
                        num.tryParse(_fields['${l['id']}']!.text.trim()) ?? 0,
                  },
              ]),
              child: const Text('Count it in'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One item and a quantity, in whatever unit somebody writes it in.
class _StockLineDialog extends ConsumerStatefulWidget {
  const _StockLineDialog({required this.items, this.wantsShare = false});

  final List<Item> items;

  /// A conversion output carries a share of the input's value; a
  /// transfer line does not. One dialog, because the rest of it — which
  /// item, how much, in what unit — is the same question either way.
  final bool wantsShare;

  @override
  ConsumerState<_StockLineDialog> createState() => _StockLineDialogState();
}

class _StockLineDialogState extends ConsumerState<_StockLineDialog> {
  String? _item;
  String? _uom;
  final _qty = TextEditingController();
  final _share = TextEditingController();

  @override
  void dispose() {
    _qty.dispose();
    _share.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = _item == null
        ? const AsyncValue<List<Map<String, dynamic>>>.data([])
        : ref.watch(itemUomOptionsProvider(_item!));

    return AlertDialog(
      title: const Text('A line'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: _item,
              decoration: const InputDecoration(labelText: 'What'),
              items: [
                for (final i in widget.items)
                  DropdownMenuItem(value: i.id, child: Text(i.name)),
              ],
              onChanged: (v) => setState(() {
                _item = v;
                _uom = null;
              }),
            ),
            TextField(
              controller: _qty,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'How much'),
            ),
            DropdownButtonFormField<String>(
              value: _uom,
              decoration: const InputDecoration(labelText: 'In what unit'),
              items: [
                for (final o in options.valueOrNull ?? const [])
                  DropdownMenuItem(
                    value: '${o['uom_code']}',
                    child: Text('${o['uom_name']}'),
                  ),
              ],
              onChanged: (v) => setState(() => _uom = v),
            ),
            if (widget.wantsShare)
              TextField(
                controller: _share,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Share of value %'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _item == null || _uom == null
              ? null
              : () {
                  final name = widget.items
                      .firstWhere((i) => i.id == _item)
                      .name;
                  Navigator.of(context).pop({
                    'item': _item,
                    'name': name,
                    'quantity': num.tryParse(_qty.text.trim()) ?? 0,
                    'uom': _uom,
                    'share': num.tryParse(_share.text.trim()) ?? 0,
                  });
                },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _ConversionList extends ConsumerStatefulWidget {
  const _ConversionList();

  @override
  ConsumerState<_ConversionList> createState() => _ConversionListState();
}

class _ConversionListState extends ConsumerState<_ConversionList> {
  void _reload() => ref.invalidate(itemConversionsProvider);

  Future<void> _new() async {
    final items = await ref.read(itemsProvider('').future);
    if (!mounted) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ConversionSheet(items: items),
    );
    if (saved == true) _reload();
  }

  Future<void> _run(Map<String, dynamic> row) async {
    final times = await showDialog<num>(
      context: context,
      builder: (ctx) => _TimesDialog(name: '${row['name']}'),
    );
    if (times == null || !mounted) return;
    final done = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .runItemConversion(row['id'] as String, times: times),
      successMessage: 'Done. The value moved with it.',
    );
    if (done) _reload();
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    final done = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.deleteItemConversion(row['id'] as String),
      successMessage: 'Removed.',
    );
    if (done) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final conversions = ref.watch(itemConversionsProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _new,
        icon: const Icon(Icons.call_split),
        label: const Text('Conversion'),
      ),
      body: AsyncView(
        value: conversions,
        onRetry: _reload,
        builder: (rows) {
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.call_split,
            title: 'Nothing is cut up here',
            message:
                'A conversion turns what a shop buys into what it sells — a '
                'whole chicken into pieces, a sack into packs — carrying the '
                'value across so nothing is invented by picking up a knife.',
          );
        }
        return ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final row = rows[i];
            return ListTile(
              title: Text('${row['name']}'),
              subtitle: Text(
                '${row['from_quantity']} ${row['from_uom_code']} '
                '${row['from_item']} → ${row['output_count']} things · '
                '${Fmt.qty(num.tryParse('${row['on_hand'] ?? 0}'))} on hand',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (row['is_active'] == true)
                    IconButton(
                      icon: const Icon(Icons.play_arrow_outlined),
                      tooltip: 'Do it',
                      onPressed: () => _run(row),
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _remove(row),
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

/// Writing a conversion down: what goes in, what comes out, and how the
/// value is split between them.
class _ConversionSheet extends ConsumerStatefulWidget {
  const _ConversionSheet({required this.items});

  final List<Item> items;

  @override
  ConsumerState<_ConversionSheet> createState() => _ConversionSheetState();
}

class _ConversionSheetState extends ConsumerState<_ConversionSheet> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _qty = TextEditingController(text: '1');
  String? _item;
  String? _uom;
  final List<Map<String, dynamic>> _outputs = [];

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _qty.dispose();
    super.dispose();
  }

  Future<void> _addOutput() async {
    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _StockLineDialog(items: widget.items, wantsShare: true),
    );
    if (chosen == null) return;
    setState(() => _outputs.add(chosen));
  }

  Future<void> _save() async {
    final item = _item, uom = _uom;
    if (item == null || uom == null) return;
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveItemConversion(
            code: _code.text.trim(),
            name: _name.text.trim(),
            fromItem: item,
            fromQuantity: num.tryParse(_qty.text.trim()) ?? 1,
            fromUom: uom,
            outputs: _outputs
                .map(
                  (o) => {
                    'item': o['item'],
                    'quantity': o['quantity'],
                    'uom': o['uom'],
                    'share': o['share'],
                  },
                )
                .toList(),
          ),
      successMessage: 'Saved.',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final options = _item == null
        ? const AsyncValue<List<Map<String, dynamic>>>.data([])
        : ref.watch(itemUomOptionsProvider(_item!));
    final shares = shareTotal(_outputs);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(Space.lg),
          children: [
            Text(
              'A conversion',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Called'),
            ),
            TextField(
              controller: _code,
              decoration: const InputDecoration(labelText: 'Code'),
            ),
            const SizedBox(height: Space.md),
            DropdownButtonFormField<String>(
              value: _item,
              decoration: const InputDecoration(labelText: 'What goes in'),
              items: [
                for (final i in widget.items)
                  DropdownMenuItem(value: i.id, child: Text(i.name)),
              ],
              onChanged: (v) => setState(() {
                _item = v;
                _uom = null;
              }),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _qty,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'How much'),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _uom,
                    decoration: const InputDecoration(labelText: 'Unit'),
                    items: [
                      for (final o in options.valueOrNull ?? const [])
                        DropdownMenuItem(
                          value: '${o['uom_code']}',
                          child: Text('${o['uom_name']}'),
                        ),
                    ],
                    onChanged: (v) => setState(() => _uom = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            for (final o in _outputs)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${o['name']}'),
                subtitle: Text('${o['quantity']} ${o['uom']} · ${o['share']}%'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _outputs.remove(o)),
                ),
              ),
            TextButton.icon(
              onPressed: _addOutput,
              icon: const Icon(Icons.add),
              label: const Text('What comes out'),
            ),
            // Shown before the save is attempted, because being told no
            // after typing six lines is worse than being told as you go.
            // The server refuses either way; this is only the warning.
            if (_outputs.isNotEmpty && !shares.ok)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  'The shares come to ${shares.total}%, not 100. What a '
                  'thing is worth cannot change by cutting it up.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.colors.warning,
                  ),
                ),
              ),
            const SizedBox(height: Space.lg),
            FilledButton(
              onPressed:
                  _item == null ||
                      _uom == null ||
                      _outputs.isEmpty ||
                      !shares.ok ||
                      _name.text.trim().isEmpty ||
                      _code.text.trim().isEmpty
                  ? null
                  : _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimesDialog extends StatefulWidget {
  const _TimesDialog({required this.name});

  final String name;

  @override
  State<_TimesDialog> createState() => _TimesDialogState();
}

class _TimesDialogState extends State<_TimesDialog> {
  final _times = TextEditingController(text: '1');

  @override
  void dispose() {
    _times.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.name),
      content: TextField(
        controller: _times,
        keyboardType: TextInputType.number,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'How many times'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(num.tryParse(_times.text.trim()) ?? 1),
          child: const Text('Do it'),
        ),
      ],
    );
  }
}
