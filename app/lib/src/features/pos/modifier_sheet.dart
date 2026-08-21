import 'package:flutter/material.dart';

import '../../core/format.dart';
import 'till_screen.dart' show posNum;

/// The questions a plate comes with.
///
/// ## Asked once, at the moment they arise
///
/// "Kurang pedas, tambah telur" is decided when the plate is ordered
/// and never afterwards, so the sheet opens on the tap that adds the
/// line and closes when it is answered. There is no second route to it
/// on the basket, because a modifier changed after the kitchen was told
/// is a different plate, not an edit.
///
/// ## The database owns the rules, and this repeats them
///
/// `min_select` and `max_select` are enforced by `add_line_modifier`
/// and by `pos_line_modifier_gaps`. They are repeated here so a
/// required question cannot be skipped past — not to replace the
/// server's check but so the refusal never has to happen: a queue is a
/// bad place to learn that a form was incomplete.
///
/// "Choose one" (min 1, max 1) is drawn as radios and "any you like"
/// (max null) as checkboxes, because the shape of the control should
/// tell somebody the rule before they try to break it.
/// One answer, as the sheet hands it back.
///
/// Either a listed modifier — the id is all the server needs, since the
/// name and price come off the menu row — or something typed at the
/// counter, which carries its own name and price because there is no
/// menu row behind it. 0251.
class ModifierChoice {
  const ModifierChoice.listed(String this.modifierId)
    : groupId = null,
      name = null,
      priceDelta = 0;

  const ModifierChoice.typed({
    required String this.groupId,
    required String this.name,
    required this.priceDelta,
  }) : modifierId = null;

  final String? modifierId;
  final String? groupId;
  final String? name;
  final double priceDelta;
}

class ModifierSheet extends StatefulWidget {
  const ModifierSheet({
    super.key,
    required this.itemName,
    required this.basePrice,
    required this.options,
    this.allowTyped = false,
  });

  final String itemName;
  final double basePrice;

  /// Whether this surface may take an answer that is not on the list.
  /// The till may; the kiosk may not, and the reason is the price —
  /// a customer left alone with a field that adds money to their own
  /// bill is a customer who will put nought in it.
  final bool allowTyped;

  /// Rows from `item_modifier_options`, already ordered by the server.
  final List<Map<String, dynamic>> options;

  @override
  State<ModifierSheet> createState() => _ModifierSheetState();
}

class _ModifierSheetState extends State<ModifierSheet> {
  /// Modifier ids chosen, in the order they were tapped so the sheet
  /// can drop the oldest when a capped group overflows.
  final _chosen = <String>[];

  /// Answers typed at the counter, in the order they were entered.
  /// Kept apart from [_chosen] because they have no id to be kept by.
  final _typed = <ModifierChoice>[];

  @override
  void initState() {
    super.initState();
    // Defaults are the shop's answer to its own question, so they start
    // selected — a "regular spice" that has to be tapped every time is
    // a default in name only.
    for (final o in widget.options) {
      if (o['is_default'] == true && o['modifier_id'] != null) {
        _chosen.add(o['modifier_id'] as String);
      }
    }
  }

  List<_Group> get _groups {
    final out = <_Group>[];
    for (final o in widget.options) {
      final id = o['group_id'] as String?;
      if (id == null) continue;
      var g = out.where((e) => e.id == id).firstOrNull;
      if (g == null) {
        g = _Group(
          id: id,
          name: '${o['group_name']}',
          min: (o['min_select'] as num?)?.toInt() ?? 0,
          max: (o['max_select'] as num?)?.toInt(),
          open: o['allows_free_text'] == true,
        );
        out.add(g);
      }
      // A group with no active modifiers under it still returns one row,
      // with a null modifier. Nothing to offer, so nothing is added.
      if (o['modifier_id'] != null) g.options.add(o);
    }
    return out;
  }

  int _chosenIn(_Group g) =>
      g.options.where((o) => _chosen.contains(o['modifier_id'])).length +
      _typed.where((t) => t.groupId == g.id).length;

  /// Every required group answered. The same condition
  /// `pos_line_modifier_gaps` reports on a bill, checked before the
  /// line exists rather than after.
  bool get _complete =>
      _groups.where((g) => g.min > 0).every((g) => _chosenIn(g) >= g.min);

  double get _total {
    var t = widget.basePrice;
    for (final o in widget.options) {
      if (_chosen.contains(o['modifier_id'])) t += posNum(o['price_delta']);
    }
    for (final e in _typed) {
      t += e.priceDelta;
    }
    return t;
  }

  /// The whole answer, listed first because that is the order it was
  /// asked in and a typed one is always an afterthought.
  List<ModifierChoice> get _answer => [
    for (final id in _chosen) ModifierChoice.listed(id),
    ..._typed,
  ];

  void _toggle(_Group g, String id) {
    setState(() {
      if (_chosen.contains(id)) {
        _chosen.remove(id);
        return;
      }
      // Exactly one: the tap replaces rather than refuses, because a
      // radio that does nothing until you deselect is a radio nobody
      // understands.
      if (g.max == 1) {
        _chosen.removeWhere(
          (c) => g.options.any((o) => o['modifier_id'] == c),
        );
        _chosen.add(id);
        return;
      }
      if (g.max != null && _chosenIn(g) >= g.max!) {
        // Capped and full: drop the one chosen longest ago, so the tap
        // still does what was asked instead of being swallowed.
        final oldest = _chosen.firstWhere(
          (c) => g.options.any((o) => o['modifier_id'] == c),
        );
        _chosen.remove(oldest);
      }
      _chosen.add(id);
    });
  }

  /// "Tambah sotong, empat ringgit." Two fields, because that is what
  /// the answer is: what to cook and what to charge for it.
  Future<void> _typeOne(_Group g) async {
    final entry = await showDialog<ModifierChoice>(
      context: context,
      builder: (_) => _TypedAnswerDialog(groupId: g.id, question: g.name),
    );
    if (entry != null) setState(() => _typed.add(entry));
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.itemName,
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
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final g in groups) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Row(
                        children: [
                          Text(
                            g.name,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(width: 8),
                          // The rule, in words, next to the question.
                          Text(
                            g.rule,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    for (final o in g.options)
                      CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _chosen.contains(o['modifier_id']),
                        onChanged: (_) =>
                            _toggle(g, o['modifier_id'] as String),
                        title: Text('${o['name']}'),
                        secondary: posNum(o['price_delta']) == 0
                            ? null
                            : Text(
                                '+${Fmt.money(posNum(o['price_delta']))}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                      ),
                    // What was typed for this question, listed with the
                    // answers it stands beside. Removable, because it
                    // is the one thing here that can be a typo.
                    for (final t in _typed.where((t) => t.groupId == g.id))
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.edit_note, size: 20),
                        title: Text('${t.name}'),
                        subtitle: const Text(
                          'typed in',
                          style: TextStyle(fontSize: 12),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (t.priceDelta != 0)
                              Text('+${Fmt.money(t.priceDelta)}'),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => setState(() => _typed.remove(t)),
                            ),
                          ],
                        ),
                      ),
                    if (widget.allowTyped && g.open)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.add, size: 20),
                        title: const Text('Something else'),
                        // Full is full: the maximum is the shop's rule
                        // and typing past it would be refused by the
                        // same trigger that refuses tapping past it.
                        enabled: g.max == null || _chosenIn(g) < g.max!,
                        onTap: () => _typeOne(g),
                      ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  // Disabled rather than refusing on tap: the server
                  // would refuse it, and finding that out at the counter
                  // with a queue behind you is the worst moment to.
                  onPressed: _complete
                      ? () => Navigator.of(context).pop(_answer)
                      : null,
                  child: Text(
                    _complete
                        ? 'Add · ${Fmt.money(_total)}'
                        : 'Choose ${groups.firstWhere((g) => _chosenIn(g) < g.min).name}',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Group {
  _Group({
    required this.id,
    required this.name,
    required this.min,
    required this.max,
    this.open = false,
  });

  final String id;
  final String name;
  final int min;
  final int? max;

  /// Whether this question takes an answer that is not on its list.
  final bool open;
  final List<Map<String, dynamic>> options = [];

  /// Said plainly. "Choose 1" and "up to 2" are the two a shop actually
  /// configures; everything else falls back to naming both bounds.
  String get rule {
    if (min == 1 && max == 1) return 'Choose one';
    if (min == 0 && max == null) return 'Optional';
    if (min == 0 && max != null) return 'Up to $max';
    if (max == null) return 'Choose at least $min';
    return 'Choose $min to $max';
  }
}

/// What the counter types when the answer is not on the list.
///
/// The price only goes up. A negative is a discount given by whoever is
/// holding the till, with no reason recorded and no grant behind it —
/// 0251 refuses it, and this refuses it here so nobody finds out at the
/// counter with a queue behind them.
class _TypedAnswerDialog extends StatefulWidget {
  const _TypedAnswerDialog({required this.groupId, required this.question});

  final String groupId;
  final String question;

  @override
  State<_TypedAnswerDialog> createState() => _TypedAnswerDialogState();
}

class _TypedAnswerDialogState extends State<_TypedAnswerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _price = TextEditingController(text: '0');

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.question),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: true,
                // The same sixty the server allows: it goes on a kitchen
                // docket and on a receipt, and both are narrow.
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'What is it?',
                  hintText: 'Tambah sotong',
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Say what it is' : null,
              ),
              TextFormField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Adds to the plate',
                  prefixText: 'RM ',
                  helperText: 'Nought if it costs nothing.',
                ),
                validator: (v) {
                  final n = double.tryParse((v ?? '').trim());
                  if (n == null) return 'A number';
                  if (n < 0) return 'This cannot take money off the plate';
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(
              context,
              ModifierChoice.typed(
                groupId: widget.groupId,
                name: _name.text.trim(),
                priceDelta: double.tryParse(_price.text.trim()) ?? 0,
              ),
            );
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
