import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// The questions a plate comes with, and their answers.
///
/// 0214 built modifiers and 0221 seeded two groups for the demo warung.
/// Nothing else could ever write them, so the only way to add "extra
/// cheese" was a SQL console. 0250 added the functions; this is where
/// a shopkeeper calls them.
///
/// ## It sits with the menu, not with the outlet
///
/// A question belongs to the company, not to a shop: "how spicy" is
/// asked the same way at both branches, and it is attached to a dish
/// rather than to a till. So it is reached from Items, beside prices
/// and variants, which is where somebody editing the menu already is.
///
/// ## Retired questions stay on the list
///
/// A list that hid them would leave somebody re-creating a question
/// under a code they cannot use — `pos_modifier_groups` is unique on
/// `(org_id, code)` — and there is no way back from a retirement you
/// cannot see. They are shown greyed, at the bottom, with the button
/// that brings them back.
Future<void> showModifierGroups(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _ModifierGroupsDialog(),
  );
}

/// "Choose one", "up to two", "any you like" — the rule as somebody
/// would say it out loud, rather than two numbers they have to read.
String modifierRule(int min, int? max) {
  if (max == 1 && min == 1) return 'choose one';
  if (max == 1) return 'one at most';
  if (max == null && min == 0) return 'any you like';
  if (max == null) return 'at least $min';
  if (min == max) return 'choose $min';
  if (min == 0) return 'up to $max';
  return '$min to $max';
}

class _ModifierGroupsDialog extends ConsumerWidget {
  const _ModifierGroupsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(posModifierGroupsProvider);

    return AlertDialog(
      title: const Text('Questions a dish comes with'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'A question is asked at the till when the dish it is '
                'attached to is tapped. Attach it on the item itself.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              AsyncView(
                value: groups,
                onRetry: () => ref.invalidate(posModifierGroupsProvider),
                builder: (list) {
                  if (list.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: Space.lg),
                      child: Text(
                        'No questions yet. "Pedas — kurang, biasa, extra" '
                        'is one; "Tambah — telur, ayam" is another.',
                      ),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final g in list) _GroupTile(group: g),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _editGroup(context, ref, null),
          child: const Text('Add question'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

Future<void> _editGroup(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic>? group,
) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _GroupDialog(group: group),
  );
  if (saved == true) ref.invalidate(posModifierGroupsProvider);
}

class _GroupTile extends ConsumerWidget {
  const _GroupTile({required this.group});

  final Map<String, dynamic> group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = group['id'] as String;
    final live = group['is_active'] == true;
    final options = ref.watch(posModifierOptionsProvider(id));
    final items = (group['item_count'] as num?)?.toInt() ?? 0;
    final answers = (group['option_count'] as num?)?.toInt() ?? 0;

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
        '${group['name']}',
        style: TextStyle(
          fontWeight: FontWeight.w500,
          color: live ? null : Theme.of(context).disabledColor,
        ),
      ),
      subtitle: Text(
        [
          if (!live) 'retired',
          modifierRule(
            (group['min_select'] as num?)?.toInt() ?? 0,
            (group['max_select'] as num?)?.toInt(),
          ),
          '$answers answer${answers == 1 ? '' : 's'}',
          // The number that decides whether retiring it is a small act
          // or a menu-wide one.
          'asked about $items dish${items == 1 ? '' : 'es'}',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () => _editGroup(context, ref, group),
          ),
          if (live)
            IconButton(
              tooltip: 'Stop asking it',
              icon: const Icon(Icons.block_outlined, size: 18),
              onPressed: () => _retire(context, ref, items),
            )
          else
            IconButton(
              tooltip: 'Ask it again',
              icon: const Icon(Icons.restore, size: 18),
              onPressed: () => _restore(context, ref),
            ),
        ],
      ),
      children: [
        AsyncView(
          value: options,
          onRetry: () => ref.invalidate(posModifierOptionsProvider(id)),
          builder: (list) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: Space.sm),
                  child: Text(
                    'No answers yet, so the till would ask a question '
                    'with nothing to tap.',
                  ),
                ),
              for (final o in list) _OptionRow(groupId: id, option: o),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _editOption(context, ref, id, null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add answer'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _retire(BuildContext context, WidgetRef ref, int items) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Stop asking ${group['name']}?'),
        content: Text(
          items == 0
              ? 'It is not attached to any dish, so nothing changes at '
                    'the till.'
              : 'The till stops asking it on $items '
                    'dish${items == 1 ? '' : 'es'}. Bills that already '
                    'carry an answer keep it, and the dishes stay '
                    'attached — bringing the question back brings them '
                    'with it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep asking'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Stop asking'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'No longer asked',
      action: () => repo.retirePosModifierGroup(group['id'] as String),
    );
    if (ok) ref.invalidate(posModifierGroupsProvider);
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Asked again',
      action: () => repo.savePosModifierGroup(
        id: group['id'] as String,
        code: '${group['code']}',
        name: '${group['name']}',
        minSelect: (group['min_select'] as num?)?.toInt() ?? 0,
        maxSelect: (group['max_select'] as num?)?.toInt(),
        sortOrder: (group['sort_order'] as num?)?.toInt() ?? 0,
      ),
    );
    if (ok) ref.invalidate(posModifierGroupsProvider);
  }
}

Future<void> _editOption(
  BuildContext context,
  WidgetRef ref,
  String groupId,
  Map<String, dynamic>? option,
) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _OptionDialog(groupId: groupId, option: option),
  );
  if (saved == true) {
    ref
      ..invalidate(posModifierOptionsProvider(groupId))
      // The count on the tile is part of the same answer.
      ..invalidate(posModifierGroupsProvider);
  }
}

class _OptionRow extends ConsumerWidget {
  const _OptionRow({required this.groupId, required this.option});

  final String groupId;
  final Map<String, dynamic> option;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = option['is_active'] == true;
    final delta = Fmt.toDouble(option['price_delta']);

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: Space.md),
      onTap: () => _editOption(context, ref, groupId, option),
      title: Text(
        '${option['name']}',
        style: TextStyle(color: live ? null : Theme.of(context).disabledColor),
      ),
      subtitle: Text(
        [
          '${option['code']}',
          if (!live) 'off the menu',
          if (option['is_default'] == true) 'ticked by default',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Nought is worth saying out loud: "no cucumber" costing
          // nothing is a choice somebody made, not a blank field.
          Text(
            delta == 0
                ? 'no charge'
                : '${delta > 0 ? '+' : '−'}${Fmt.money(delta.abs())}',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: delta < 0 ? context.colors.warning : null,
            ),
          ),
          if (live)
            IconButton(
              tooltip: 'Take it off',
              icon: const Icon(Icons.block_outlined, size: 18),
              onPressed: () => _retireOption(context, ref),
            ),
        ],
      ),
    );
  }

  Future<void> _retireOption(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Off the menu',
      action: () => repo.retirePosModifier(option['id'] as String),
    );
    if (ok) {
      ref
        ..invalidate(posModifierOptionsProvider(groupId))
        ..invalidate(posModifierGroupsProvider);
    }
  }
}

class _GroupDialog extends ConsumerStatefulWidget {
  const _GroupDialog({this.group});

  final Map<String, dynamic>? group;

  @override
  ConsumerState<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends ConsumerState<_GroupDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _code = TextEditingController(
    text: '${widget.group?['code'] ?? ''}',
  );
  late final _name = TextEditingController(
    text: '${widget.group?['name'] ?? ''}',
  );
  late final _min = TextEditingController(
    text: '${(widget.group?['min_select'] as num?)?.toInt() ?? 0}',
  );
  late final _max = TextEditingController(
    text: (widget.group?['max_select'] as num?)?.toInt().toString() ?? '',
  );
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_code, _name, _min, _max]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    final ok = await runWithFeedback(
      context,
      successMessage: 'Question saved',
      action: () => repo.savePosModifierGroup(
        id: widget.group?['id'] as String?,
        code: _code.text.trim(),
        name: _name.text.trim(),
        minSelect: int.tryParse(_min.text.trim()) ?? 0,
        // Empty is "as many as you like", which is what the column
        // means by null. Zero would be a question nobody can answer,
        // and 0250 refuses it by name.
        maxSelect: int.tryParse(_max.text.trim()),
      ),
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final min = int.tryParse(_min.text.trim()) ?? 0;
    final max = int.tryParse(_max.text.trim());

    return AlertDialog(
      title: Text(widget.group == null ? 'New question' : 'Edit question'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _code,
                      decoration: const InputDecoration(labelText: 'Code *'),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Name *',
                        hintText: 'Pedas',
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Required' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _min,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'At least',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _max,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'At most',
                        hintText: 'any',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  // The rule read back in words, because two number
                  // fields are easy to fill in and hard to check.
                  'At the till: ${modifierRule(min, max)}.'
                  '${min > 0 ? ' The order cannot go to the kitchen until it is answered.' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _OptionDialog extends ConsumerStatefulWidget {
  const _OptionDialog({required this.groupId, this.option});

  final String groupId;
  final Map<String, dynamic>? option;

  @override
  ConsumerState<_OptionDialog> createState() => _OptionDialogState();
}

class _OptionDialogState extends ConsumerState<_OptionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _code = TextEditingController(
    text: '${widget.option?['code'] ?? ''}',
  );
  late final _name = TextEditingController(
    text: '${widget.option?['name'] ?? ''}',
  );
  late final _price = TextEditingController(
    text: widget.option == null
        ? '0'
        : Fmt.toDouble(widget.option!['price_delta']).toString(),
  );
  late bool _isDefault = widget.option?['is_default'] == true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_code, _name, _price]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    final ok = await runWithFeedback(
      context,
      successMessage: 'Answer saved',
      action: () => repo.savePosModifier(
        groupId: widget.groupId,
        id: widget.option?['id'] as String?,
        code: _code.text.trim(),
        name: _name.text.trim(),
        priceDelta: double.tryParse(_price.text.trim()) ?? 0,
        isDefault: _isDefault,
        // Editing a retired answer puts it back. There is no other way
        // to undo taking one off, and the alternative is a second
        // button that does nothing else.
        isActive: true,
      ),
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.option == null ? 'New answer' : 'Edit answer'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _code,
                      decoration: const InputDecoration(labelText: 'Code *'),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Name *',
                        hintText: 'Extra telur',
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Required' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Adds to the price',
                  prefixText: 'RM ',
                  helperText:
                      'Nought for a choice that costs nothing. Negative '
                      'for a smaller portion.',
                ),
              ),
              const SizedBox(height: Space.sm),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _isDefault,
                onChanged: (v) => setState(() => _isDefault = v ?? false),
                title: const Text('Tick it by default'),
                // Said here because the server enforces it and a refusal
                // read at the counter is read too late.
                subtitle: const Text(
                  'The till opens with it already chosen. A choose-one '
                  'question can only have one.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// The questions attached to one dish, edited where the dish is.
///
/// Order matters and is the order they were added: `sort_order` in
/// `item_modifier_groups` decides which the till asks first, and a
/// screen handing over a list has already decided that. Deleting a chip
/// detaches; nothing here edits the question itself, which is what
/// [showModifierGroups] is for.
class ItemModifierField extends ConsumerWidget {
  const ItemModifierField({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(posModifierGroupsProvider).valueOrNull ?? const [];
    final byId = {for (final g in groups) '${g['id']}': g};
    // Retired ones are not offered, but one already attached still
    // shows: it is on the dish, and hiding it would make the field
    // disagree with what the database holds.
    final available = groups
        .where((g) => g['is_active'] == true && !selected.contains('${g['id']}'))
        .toList();

    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Questions asked at the till',
        helperText: 'Asked in this order when the dish is tapped.',
      ),
      child: Wrap(
        spacing: Space.sm,
        runSpacing: Space.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final id in selected)
            InputChip(
              label: Text(
                byId[id] == null ? 'Question' : '${byId[id]!['name']}',
              ),
              // A question that has been retired since it was attached
              // still applies to nothing at the till, and saying so
              // here is cheaper than wondering why the sheet is empty.
              avatar: byId[id]?['is_active'] == false
                  ? const Icon(Icons.block_outlined, size: 16)
                  : null,
              onDeleted: () =>
                  onChanged([...selected]..removeWhere((s) => s == id)),
            ),
          if (available.isNotEmpty)
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('Add'),
              onPressed: () async {
                final picked = await showDialog<String>(
                  context: context,
                  builder: (ctx) => SimpleDialog(
                    title: const Text('Which question?'),
                    children: [
                      for (final g in available)
                        SimpleDialogOption(
                          onPressed: () =>
                              Navigator.pop(ctx, '${g['id']}'),
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${g['name']}'),
                            subtitle: Text(
                              modifierRule(
                                (g['min_select'] as num?)?.toInt() ?? 0,
                                (g['max_select'] as num?)?.toInt(),
                              ),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
                if (picked != null) onChanged([...selected, picked]);
              },
            ),
          TextButton(
            onPressed: () async {
              await showModifierGroups(context);
              ref.invalidate(posModifierGroupsProvider);
            },
            child: Text(
              groups.isEmpty ? 'Set up questions' : 'Manage questions',
            ),
          ),
        ],
      ),
    );
  }
}
