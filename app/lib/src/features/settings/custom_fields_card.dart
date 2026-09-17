import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/custom_fields_repository.dart';

/// Where a company names the fields it wants that this product does not
/// already have.
///
/// The refusals are the server's and are left to it. Three of them are
/// worth knowing about before somebody meets them:
///
///   * a field's KEY is frozen at creation, so renaming moves the label
///     and leaves the values where they are;
///   * what a field HOLDS cannot change once it holds something, because
///     every value already written was written under the old rule;
///   * a field is archived, never deleted — the definition is what keeps
///     the values already written readable and correctly typed.
class CustomFieldsCard extends ConsumerStatefulWidget {
  const CustomFieldsCard({super.key});

  @override
  ConsumerState<CustomFieldsCard> createState() => _CustomFieldsCardState();
}

class _CustomFieldsCardState extends ConsumerState<CustomFieldsCard> {
  String _entity = 'contact';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entities =
        ref.watch(customFieldEntitiesProvider).valueOrNull ??
        const <CustomFieldEntity>[];
    final carriers = entities.where((e) => e.canCarry).toList();
    final fields = ref.watch(customFieldsProvider(_entity));
    final canAdmin =
        ref.watch(memberRoleProvider).valueOrNull == 'owner' ||
        ref.watch(memberRoleProvider).valueOrNull == 'admin';

    Future<void> edit([CustomFieldDef? existing]) async {
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => _FieldDialog(
          entity: _entity,
          existing: existing,
          targets: entities.where((e) => e.canTarget).toList(),
        ),
      );
      if (saved == true) ref.invalidate(customFieldsProvider(_entity));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Your own fields',
              subtitle: 'Boxes this company keeps that we did not think of',
              action: canAdmin
                  ? TextButton.icon(
                      onPressed: () => edit(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add'),
                    )
                  : null,
            ),
            if (carriers.isNotEmpty)
              SearchablePicker<String>(
                key: const ValueKey('custom-field-entity'),
                label: 'On which record',
                value: _entity,
                helperText: 'A field belongs to one kind of record.',
                onChanged: (v) => setState(() => _entity = v ?? 'contact'),
                options: [
                  for (final e in carriers)
                    PickerOption(
                      value: e.entity,
                      label: e.label,
                      sublabel: e.isLineLevel
                          ? 'Filled in on every line'
                          : null,
                      keywords: [e.entity],
                    ),
                ],
              ),
            const SizedBox(height: Space.md),
            AsyncView(
              value: fields,
              builder: (list) {
                if (list.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.md),
                    child: Text(
                      'No fields of your own on this record yet.',
                      style: theme.textTheme.bodySmall,
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final d in list)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          d.label,
                          style: d.isActive
                              ? null
                              : TextStyle(
                                  color: theme.disabledColor,
                                  decoration: TextDecoration.lineThrough,
                                ),
                        ),
                        subtitle: Text(
                          [
                            _kindLabel(d),
                            d.key,
                            if (d.isRequired) 'must be filled in',
                            if (d.showOnList) 'on the list',
                            if (!d.isActive) 'archived',
                          ].join(' · '),
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: !canAdmin
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: d.isActive
                                        ? 'Put away'
                                        : 'Bring back',
                                    icon: Icon(
                                      d.isActive
                                          ? Icons.archive_outlined
                                          : Icons.unarchive_outlined,
                                      size: 18,
                                    ),
                                    onPressed: () async {
                                      final repo = ref.read(repoProvider);
                                      if (repo == null) return;
                                      final messenger = ScaffoldMessenger.of(
                                        context,
                                      );
                                      try {
                                        await repo.setCustomFieldActive(
                                          _entity,
                                          d.key,
                                          !d.isActive,
                                        );
                                        ref.invalidate(
                                          customFieldsProvider(_entity),
                                        );
                                      } catch (e) {
                                        messenger.showSnackBar(
                                          SnackBar(content: Text('$e')),
                                        );
                                      }
                                    },
                                  ),
                                  IconButton(
                                    tooltip: 'Edit',
                                    icon: const Icon(Icons.edit, size: 18),
                                    onPressed: () => edit(d),
                                  ),
                                ],
                              ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _kindLabel(CustomFieldDef d) => switch (d.kind) {
    'number' => 'Number',
    'date' => 'Date',
    'boolean' => 'Yes or no',
    'select' => 'One of ${d.options.length}',
    'lookup' => 'Points at a ${d.targetEntity}',
    _ => 'Text',
  };
}

class _FieldDialog extends ConsumerStatefulWidget {
  const _FieldDialog({
    required this.entity,
    required this.existing,
    required this.targets,
  });

  final String entity;
  final CustomFieldDef? existing;
  final List<CustomFieldEntity> targets;

  @override
  ConsumerState<_FieldDialog> createState() => _FieldDialogState();
}

class _FieldDialogState extends ConsumerState<_FieldDialog> {
  final _label = TextEditingController();
  final _help = TextEditingController();
  final _options = TextEditingController();
  final _min = TextEditingController();
  final _max = TextEditingController();
  final _maxLength = TextEditingController();
  String _kind = 'text';
  String? _target;
  bool _required = false;
  bool _showOnList = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _label.text = e.label;
      _help.text = e.helpText ?? '';
      _options.text = e.options.join('\n');
      _min.text = e.minValue?.toString() ?? '';
      _max.text = e.maxValue?.toString() ?? '';
      _maxLength.text = e.maxLength?.toString() ?? '';
      _kind = e.kind;
      _target = e.targetEntity;
      _required = e.isRequired;
      _showOnList = e.showOnList;
    }
  }

  @override
  void dispose() {
    _label.dispose();
    _help.dispose();
    _options.dispose();
    _min.dispose();
    _max.dispose();
    _maxLength.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await repo.upsertCustomField(
        entity: widget.entity,
        label: _label.text.trim(),
        key: widget.existing?.key,
        kind: _kind,
        isRequired: _required,
        options: _kind != 'select'
            ? null
            : _options.text
                  .split('\n')
                  .map((o) => o.trim())
                  .where((o) => o.isNotEmpty)
                  .toList(),
        targetEntity: _kind == 'lookup' ? _target : null,
        helpText: _help.text.trim().isEmpty ? null : _help.text.trim(),
        minValue: _kind == 'number' ? num.tryParse(_min.text.trim()) : null,
        maxValue: _kind == 'number' ? num.tryParse(_max.text.trim()) : null,
        maxLength: _kind == 'text'
            ? int.tryParse(_maxLength.text.trim())
            : null,
        showOnList: _showOnList,
        sortOrder: widget.existing?.sortOrder ?? 100,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return AlertDialog(
      title: Text(existing == null ? 'Add a field' : 'Edit ${existing.label}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _label,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Name',
                  helperText: existing == null
                      ? 'What people will see above the box.'
                      : 'Stored under "${existing.key}", which does not '
                            'change — every value already written is '
                            'beneath it.',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: Space.md),
              SearchablePicker<String>(
                label: 'What it holds',
                value: _kind,
                helperText: existing == null
                    ? null
                    : 'Once a field holds something this can no longer '
                          'change. Archive it and add another instead.',
                onChanged: (v) => setState(() => _kind = v ?? 'text'),
                options: const [
                  PickerOption(value: 'text', label: 'Text'),
                  PickerOption(value: 'number', label: 'A number'),
                  PickerOption(value: 'date', label: 'A date'),
                  PickerOption(value: 'boolean', label: 'Yes or no'),
                  PickerOption(
                    value: 'select',
                    label: 'One of a list you write',
                  ),
                  PickerOption(
                    value: 'lookup',
                    label: 'Another record in here',
                  ),
                ],
              ),
              if (_kind == 'lookup') ...[
                const SizedBox(height: Space.md),
                SearchablePicker<String>(
                  label: 'Which kind of record',
                  value: _target,
                  helperText:
                      'Only this company’s records may be '
                      'chosen, and only ones that still exist.',
                  onChanged: (v) => setState(() => _target = v),
                  options: [
                    for (final t in widget.targets)
                      PickerOption(
                        value: t.entity,
                        label: t.label,
                        keywords: [t.entity],
                      ),
                  ],
                ),
              ],
              if (_kind == 'select') ...[
                const SizedBox(height: Space.md),
                TextField(
                  controller: _options,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'The choices',
                    helperText: 'One to a line.',
                  ),
                ),
              ],
              if (_kind == 'number') ...[
                const SizedBox(height: Space.md),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _min,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Smallest allowed',
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: TextField(
                        controller: _max,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Largest allowed',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (_kind == 'text') ...[
                const SizedBox(height: Space.md),
                TextField(
                  controller: _maxLength,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Longest allowed',
                    helperText: 'Leave empty for no limit.',
                  ),
                ),
              ],
              const SizedBox(height: Space.md),
              TextField(
                controller: _help,
                decoration: const InputDecoration(
                  labelText: 'A line of help',
                  helperText: 'Shown under the box. Optional.',
                ),
              ),
              const SizedBox(height: Space.sm),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _required,
                onChanged: (v) => setState(() => _required = v ?? false),
                title: const Text('It has to be filled in'),
                subtitle: const Text(
                  'Records written before today are not asked for it.',
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _showOnList,
                onChanged: (v) => setState(() => _showOnList = v ?? false),
                title: const Text('Show it on the list as well'),
              ),
              if (_error != null) ...[
                const SizedBox(height: Space.md),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
