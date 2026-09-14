import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../items/new_item_dialog.dart';

/// What a scale's label layout reads as, in the words a shopkeeper uses.
///
/// Pure and exported so the list and the tests agree. The digit counts
/// are the thing somebody gets wrong, so they are spelled out rather
/// than summarised.
String scaleLayout(Map<String, dynamic> row) {
  final kind = switch ('${row['value_kind']}') {
    'weight_grams' => 'grams',
    'weight_kg_3dp' => 'kilograms to three places',
    _ => 'ringgit',
  };
  return 'Starts ${row['prefix']} · ${row['code_digits']} digits of item · '
      '${row['value_digits']} of $kind · ${row['total_digits']} in all';
}

/// A label the given layout would produce, for the shop to scan and
/// check before trusting it.
///
/// The check digit is computed here the same way the server does, so a
/// sample the screen prints is a sample the parser will accept.
String sampleScaleBarcode(Map<String, dynamic> row, String plu, int value) {
  final code = plu.padLeft(row['code_digits'] as int, '0');
  final val = '$value'.padLeft(row['value_digits'] as int, '0');
  final body = '${row['prefix']}$code$val';
  if (row['has_check_digit'] != true) return body;
  return '$body${eanCheckDigit(body)}';
}

/// GS1's modulo 10, weighted from the right — the same arithmetic for
/// EAN-8, UPC-A and EAN-13.
int eanCheckDigit(String digits) {
  var sum = 0;
  for (var i = 1; i <= digits.length; i++) {
    final d = int.parse(digits[digits.length - i]);
    sum += d * (i.isOdd ? 3 : 1);
  }
  return (10 - (sum % 10)) % 10;
}

/// The counter scale: what its labels look like, and what this shop
/// sells by weight.
class ScalesScreen extends ConsumerStatefulWidget {
  const ScalesScreen({super.key});

  @override
  ConsumerState<ScalesScreen> createState() => _ScalesScreenState();
}

class _ScalesScreenState extends ConsumerState<ScalesScreen>
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
        title: const Text('Scales'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Sold by weight'), Tab(text: 'Labels')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_WeighedList(), _FormatList()],
      ),
    );
  }
}

class _WeighedList extends ConsumerStatefulWidget {
  const _WeighedList();

  @override
  ConsumerState<_WeighedList> createState() => _WeighedListState();
}

class _WeighedListState extends ConsumerState<_WeighedList> {
  void _reload() => ref.invalidate(weighedItemsProvider);

  Future<void> _add() async {
    final items = await ref.read(itemsProvider('').future);
    if (!mounted) return;
    final chosen = await showDialog<({String item, String plu})>(
      context: context,
      builder: (_) => _WeighedDialog(items: items),
    );
    if (chosen == null || !mounted) return;
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .setItemWeighed(chosen.item, weighed: true, plu: chosen.plu),
      successMessage: 'Sold by weight.',
    );
    if (ok) _reload();
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .setItemWeighed(row['item_id'] as String, weighed: false),
      successMessage: 'Back to being counted.',
    );
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(weighedItemsProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.scale_outlined),
        label: const Text('By weight'),
      ),
      body: AsyncView(
        value: items,
        onRetry: _reload,
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.scale_outlined,
              title: 'Everything here is counted',
              message:
                  'An item sold by weight is priced per kilogram or litre, '
                  'and the till takes a fraction of one rather than a whole '
                  'number. It needs a unit that measures something — a '
                  'piece will not do.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final row = rows[i];
              final plu = '${row['scale_plu'] ?? ''}';
              return ListTile(
                title: Text('${row['name']}'),
                subtitle: Text(
                  '${Fmt.money(num.tryParse('${row['unit_price'] ?? 0}'))} '
                  'per ${row['uom_code']}'
                  '${plu.isEmpty ? ' · no number on the scale' : ' · scale $plu'}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Count it instead',
                  onPressed: () => _remove(row),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _WeighedDialog extends StatefulWidget {
  const _WeighedDialog({required this.items});

  final List<Item> items;

  @override
  State<_WeighedDialog> createState() => _WeighedDialogState();
}

class _WeighedDialogState extends State<_WeighedDialog> {
  String? _item;
  final _plu = TextEditingController();

  @override
  void dispose() {
    _plu.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sold by weight'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SearchablePicker<String>(
            options: itemPickerOptions(widget.items),
            value: _item,
            label: 'What',
            hint: 'Type a name or a number',
            onChanged: (v) => setState(() => _item = v),
          ),
          TextField(
            controller: _plu,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Number on the scale',
              helperText:
                  'What the counter scale was programmed to call it. Leave '
                  'blank if there is no scale.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _item == null
              ? null
              : () => Navigator.of(
                  context,
                ).pop((item: _item!, plu: _plu.text.trim())),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _FormatList extends ConsumerStatefulWidget {
  const _FormatList();

  @override
  ConsumerState<_FormatList> createState() => _FormatListState();
}

class _FormatListState extends ConsumerState<_FormatList> {
  void _reload() => ref.invalidate(scaleFormatsProvider);

  Future<void> _edit(Map<String, dynamic>? existing) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _FormatSheet(format: existing),
    );
    if (saved == true) _reload();
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.deleteScaleFormat(row['id'] as String),
      successMessage: 'Removed.',
    );
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final formats = ref.watch(scaleFormatsProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('Scale'),
      ),
      body: AsyncView(
        value: formats,
        onRetry: _reload,
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.barcode_reader,
              title: 'No scale labels yet',
              message:
                  'A counter scale prints an ordinary barcode with the item '
                  'and its weight hidden in the digits. Every make lays them '
                  'out differently, so tell this one what yours does and the '
                  'gun will ring the right weight up by itself.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final row = rows[i];
              return ListTile(
                title: Text('${row['name']}'),
                subtitle: Text(scaleLayout(row)),
                isThreeLine: true,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (row['is_active'] != true)
                      const Chip(
                        label: Text('Off'),
                        visualDensity: VisualDensity.compact,
                      ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _remove(row),
                    ),
                  ],
                ),
                onTap: () => _edit(row),
              );
            },
          );
        },
      ),
    );
  }
}

class _FormatSheet extends ConsumerStatefulWidget {
  const _FormatSheet({required this.format});

  final Map<String, dynamic>? format;

  @override
  ConsumerState<_FormatSheet> createState() => _FormatSheetState();
}

class _FormatSheetState extends ConsumerState<_FormatSheet> {
  late final _name = TextEditingController(
    text: '${widget.format?['name'] ?? ''}',
  );
  late final _prefix = TextEditingController(
    text: '${widget.format?['prefix'] ?? '20'}',
  );
  late final _code = TextEditingController(
    text: '${widget.format?['code_digits'] ?? 5}',
  );
  late final _value = TextEditingController(
    text: '${widget.format?['value_digits'] ?? 5}',
  );
  late String _kind = '${widget.format?['value_kind'] ?? 'weight_grams'}';
  late bool _check = widget.format?['has_check_digit'] != false;

  @override
  void dispose() {
    _name.dispose();
    _prefix.dispose();
    _code.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveScaleFormat(
            id: widget.format?['id'] as String?,
            name: _name.text.trim(),
            prefix: _prefix.text.trim(),
            codeDigits: int.tryParse(_code.text.trim()) ?? 5,
            valueDigits: int.tryParse(_value.text.trim()) ?? 5,
            kind: _kind,
            checkDigit: _check,
          ),
      successMessage: 'Saved.',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final row = {
      'prefix': _prefix.text.trim(),
      'code_digits': int.tryParse(_code.text.trim()) ?? 0,
      'value_digits': int.tryParse(_value.text.trim()) ?? 0,
      'has_check_digit': _check,
    };
    final total =
        _prefix.text.trim().length +
        (row['code_digits'] as int) +
        (row['value_digits'] as int) +
        (_check ? 1 : 0);
    final sensible =
        total == 8 || total == 12 || total == 13;

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
              'A scale',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Called'),
            ),
            TextField(
              controller: _prefix,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Every label starts with',
                helperText: 'GS1 keeps 02 and 20 to 29 free for in-store use.',
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Digits of item',
                    ),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: TextField(
                    controller: _value,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Digits of number',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            DropdownButtonFormField<String>(
              isExpanded: true,
              value: _kind,
              decoration: const InputDecoration(labelText: 'That number is'),
              items: const [
                DropdownMenuItem(
                  value: 'weight_grams',
                  child: Text('Grams'),
                ),
                DropdownMenuItem(
                  value: 'weight_kg_3dp',
                  child: Text('Kilograms, to three places'),
                ),
                DropdownMenuItem(
                  value: 'price_sen',
                  child: Text('Sen — what the sticker says'),
                ),
              ],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _check,
              title: const Text('Last digit is a check digit'),
              subtitle: const Text(
                'Almost always. A label whose check digit disagrees is '
                'refused rather than rung up at a plausible wrong weight.',
              ),
              onChanged: (v) => setState(() => _check = v),
            ),
            const SizedBox(height: Space.sm),
            // A layout is easy to get wrong and impossible to check by
            // reading, so the screen prints one and the shop scans it.
            Text(
              sensible
                  ? 'A label would look like '
                        '${sampleScaleBarcode(row, '1', 246)} — scan it to '
                        'be sure.'
                  : 'Those come to $total digits, which is not a barcode. A '
                        'scale prints 8, 12 or 13.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.lg),
            FilledButton(
              onPressed: !sensible || _name.text.trim().isEmpty ? null : _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
