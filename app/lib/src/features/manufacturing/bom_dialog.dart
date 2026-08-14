import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// What a thing is made of, and the steps that turn the parts into it.
///
/// Two quantities are easy to confuse and expensive to confuse, so both
/// are labelled against the same thing: the components and the minutes
/// are per *batch* — per `output_quantity` of the finished item — not
/// per one. A recipe that makes a hundred is easier to write down than
/// one that makes a single unit, and rounding a hundredth of a component
/// is how quantities drift.
class BomDialog extends ConsumerStatefulWidget {
  const BomDialog({super.key, this.bomId});

  final String? bomId;

  @override
  ConsumerState<BomDialog> createState() => _BomDialogState();
}

class _Line {
  _Line({this.itemId, num quantity = 1, num scrap = 0})
    : quantity = TextEditingController(text: '$quantity'),
      scrap = TextEditingController(text: '$scrap');

  String? itemId;
  final TextEditingController quantity;
  final TextEditingController scrap;

  void dispose() {
    quantity.dispose();
    scrap.dispose();
  }
}

class _Step {
  _Step({this.workCentreId, String name = '', num minutes = 0})
    : name = TextEditingController(text: name),
      minutes = TextEditingController(text: '$minutes');

  String? workCentreId;
  final TextEditingController name;
  final TextEditingController minutes;

  void dispose() {
    name.dispose();
    minutes.dispose();
  }
}

class _BomDialogState extends ConsumerState<BomDialog> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _output = TextEditingController(text: '1');
  String? _itemId;
  final _lines = <_Line>[];
  final _steps = <_Step>[];
  bool _loading = false;
  bool _saving = false;

  bool get _isNew => widget.bomId == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      _lines.add(_Line());
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    for (final c in [_code, _name, _output]) {
      c.dispose();
    }
    for (final l in _lines) {
      l.dispose();
    }
    for (final s in _steps) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final bom = await ref.read(repoProvider)!.billOfMaterials(widget.bomId!);
    if (!mounted) return;
    setState(() {
      _code.text = bom['code']?.toString() ?? '';
      _name.text = bom['name']?.toString() ?? '';
      _output.text = Fmt.toDouble(bom['output_quantity']).toString();
      _itemId = bom['item_id'] as String?;

      final lines =
          (bom['bom_lines'] as List? ?? const []).cast<Map<String, dynamic>>()
            ..sort(
              (a, b) => (a['line_no'] as int).compareTo(b['line_no'] as int),
            );
      for (final l in lines) {
        _lines.add(
          _Line(
            itemId: l['item_id'] as String?,
            quantity: Fmt.toDouble(l['quantity']),
            scrap: Fmt.toDouble(l['scrap_percent']),
          ),
        );
      }
      if (_lines.isEmpty) _lines.add(_Line());

      final ops =
          (bom['bom_operations'] as List? ?? const [])
              .cast<Map<String, dynamic>>()
            ..sort(
              (a, b) => (a['step_no'] as int).compareTo(b['step_no'] as int),
            );
      for (final o in ops) {
        _steps.add(
          _Step(
            workCentreId: o['work_centre_id'] as String?,
            name: o['name']?.toString() ?? '',
            minutes: Fmt.toDouble(o['minutes']),
          ),
        );
      }
      _loading = false;
    });
  }

  bool get _valid =>
      _code.text.trim().isNotEmpty &&
      _itemId != null &&
      (double.tryParse(_output.text.trim()) ?? 0) > 0 &&
      _lines.any((l) => l.itemId != null);

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(itemsProvider('')).value ?? const <Item>[];
    final centres = ref.watch(workCentresProvider).value ?? const [];

    return AlertDialog(
      title: Text(_isNew ? 'New recipe' : 'Edit ${_code.text}'),
      content: SizedBox(
        width: 620,
        child: _loading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(Space.xl),
                  child: CircularProgressIndicator(),
                ),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 140,
                          child: TextField(
                            key: const ValueKey('bom-code'),
                            controller: _code,
                            enabled: !_saving,
                            textCapitalization: TextCapitalization.characters,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Code',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _name,
                            enabled: !_saving,
                            decoration: const InputDecoration(
                              labelText: 'Description',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _ItemPicker(
                            key: const ValueKey('bom-item'),
                            label: 'Makes',
                            items: items,
                            value: _itemId,
                            enabled: !_saving,
                            onChanged: (v) => setState(() => _itemId = v),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 140,
                          child: TextField(
                            key: const ValueKey('bom-output'),
                            controller: _output,
                            enabled: !_saving,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'At a time',
                            ),
                          ),
                        ),
                      ],
                    ),

                    const Divider(height: Space.xl),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'What goes into it',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        TextButton.icon(
                          key: const ValueKey('bom-add-line'),
                          onPressed: _saving
                              ? null
                              : () => setState(() => _lines.add(_Line())),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add'),
                        ),
                      ],
                    ),
                    Text(
                      'Quantities are per ${Fmt.qty(double.tryParse(_output.text.trim()) ?? 1)} made. Scrap is added to what is issued, not '
                      'taken off — a process that wastes one board in '
                      'twenty needs twenty-one.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: Space.sm),
                    for (var i = 0; i < _lines.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _ItemPicker(
                                label: 'Part',
                                items: items,
                                value: _lines[i].itemId,
                                enabled: !_saving,
                                onChanged: (v) =>
                                    setState(() => _lines[i].itemId = v),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 96,
                              child: TextField(
                                controller: _lines[i].quantity,
                                enabled: !_saving,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  labelText: 'Qty',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 88,
                              child: TextField(
                                controller: _lines[i].scrap,
                                enabled: !_saving,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  labelText: 'Scrap',
                                  suffixText: '%',
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              onPressed: _saving || _lines.length == 1
                                  ? null
                                  : () => setState(() {
                                      _lines.removeAt(i).dispose();
                                    }),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ),

                    const Divider(height: Space.xl),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'How it is made',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        TextButton.icon(
                          key: const ValueKey('bom-add-step'),
                          onPressed: _saving || centres.isEmpty
                              ? null
                              : () => setState(() => _steps.add(_Step())),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add step'),
                        ),
                      ],
                    ),
                    Text(
                      centres.isEmpty
                          ? 'No work centres yet. Add one and the steps '
                                'become available — without them a finished '
                                'item is carried at the cost of its parts '
                                'alone, with none of the work in it.'
                          : 'Minutes are per ${Fmt.qty(double.tryParse(_output.text.trim()) ?? 1)} made, like the quantities above.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: Space.sm),
                    for (var i = 0; i < _steps.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 180,
                              child: DropdownButtonFormField<String>(
                                value: _steps[i].workCentreId,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Where',
                                ),
                                items: [
                                  for (final w in centres)
                                    DropdownMenuItem(
                                      value: w['id'] as String,
                                      child: Text(
                                        w['code']?.toString() ?? '',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: _saving
                                    ? null
                                    : (v) => setState(
                                        () => _steps[i].workCentreId = v,
                                      ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _steps[i].name,
                                enabled: !_saving,
                                decoration: const InputDecoration(
                                  labelText: 'Step',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 96,
                              child: TextField(
                                controller: _steps[i].minutes,
                                enabled: !_saving,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  labelText: 'Minutes',
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              onPressed: _saving
                                  ? null
                                  : () => setState(() {
                                      _steps.removeAt(i).dispose();
                                    }),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        if (!_isNew)
          TextButton(
            onPressed: _saving ? null : _retire,
            child: Text(
              'Retire it',
              style: TextStyle(color: context.colors.danger),
            ),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid && !_saving ? _save : null,
          child: Text(_isNew ? 'Create' : 'Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveBillOfMaterials(
            id: widget.bomId,
            code: _code.text.trim().toUpperCase(),
            itemId: _itemId!,
            name: _name.text,
            outputQuantity: double.parse(_output.text.trim()),
            lines: [
              for (final l in _lines)
                if (l.itemId != null)
                  {
                    'item_id': l.itemId,
                    'quantity': double.tryParse(l.quantity.text.trim()) ?? 0,
                    'scrap_percent': double.tryParse(l.scrap.text.trim()) ?? 0,
                  },
            ],
            operations: [
              for (final s in _steps)
                if (s.workCentreId != null)
                  {
                    'work_centre_id': s.workCentreId,
                    'name': s.name.text.trim().isEmpty
                        ? 'Step'
                        : s.name.text.trim(),
                    'minutes': double.tryParse(s.minutes.text.trim()) ?? 0,
                  },
            ],
          ),
      successMessage: _isNew ? 'Recipe created' : 'Recipe saved',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _retire() async {
    final sure = await confirm(
      context,
      title: 'Retire ${_code.text}?',
      message:
          'It stops being offered on new orders. Orders already '
          'costed against it keep the version they were costed against.',
      confirmLabel: 'Retire',
      destructive: true,
    );
    if (!sure || !mounted) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.retireBillOfMaterials(widget.bomId!),
      successMessage: 'Recipe retired',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }
}

/// An item chooser that stays usable with a few thousand items, which a
/// plain dropdown does not.
class _ItemPicker extends StatelessWidget {
  const _ItemPicker({
    super.key,
    required this.label,
    required this.items,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final List<Item> items;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final selected = items.cast<Item?>().firstWhere(
      (i) => i?.id == value,
      orElse: () => null,
    );
    return InkWell(
      onTap: enabled ? () => _pick(context) : null,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: Text(
          selected == null ? 'Choose' : '${selected.code} · ${selected.name}',
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => _ItemSearchDialog(items: items),
    );
    if (chosen != null) onChanged(chosen);
  }
}

class _ItemSearchDialog extends StatefulWidget {
  const _ItemSearchDialog({required this.items});

  final List<Item> items;

  @override
  State<_ItemSearchDialog> createState() => _ItemSearchDialogState();
}

class _ItemSearchDialogState extends State<_ItemSearchDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final matches = q.isEmpty
        ? widget.items
        : widget.items.where((i) {
            return '${i.code} ${i.name}'.toLowerCase().contains(q);
          }).toList();

    return AlertDialog(
      title: const Text('Choose an item'),
      content: SizedBox(
        width: 440,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Code or name',
              ),
            ),
            const SizedBox(height: Space.sm),
            Expanded(
              child: matches.isEmpty
                  ? const Center(child: Text('Nothing matches'))
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, i) => ListTile(
                        dense: true,
                        title: Text(matches[i].code),
                        subtitle: Text(matches[i].name),
                        onTap: () => Navigator.of(context).pop(matches[i].id),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
