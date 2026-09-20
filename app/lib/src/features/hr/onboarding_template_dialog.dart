import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// What a template is made of.
///
/// Items hold an offset in days rather than a date, because the same
/// template is used for everybody and only the start date differs.
/// Starting a checklist copies them; editing the template afterwards
/// changes nothing that has already begun.
Future<void> showTemplateItems(
    BuildContext context, Map<String, dynamic> template) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TemplateItemsDialog(template: template),
  );
}

class _TemplateItemsDialog extends ConsumerWidget {
  const _TemplateItemsDialog({required this.template});

  final Map<String, dynamic> template;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = template['id'] as String;
    final items = ref.watch(templateItemsProvider(id));

    return AlertDialog(
      title: Text('${template['name']} · items'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Day 0 is the start date. A mandatory item has to be ticked '
                'before the checklist counts as finished; an optional one '
                'does not.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              AsyncView(
                value: items,
                onRetry: () => ref.invalidate(templateItemsProvider(id)),
                skeleton: const ListSkeleton(rows: 4, leading: false),
                builder: (list) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (list.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: Space.lg),
                        // The database refuses to start a checklist from
                        // an empty template, so say so here rather than
                        // letting somebody find out later.
                        child: Text('Nothing in this template yet. A '
                            'checklist cannot be started from an empty one.'),
                      )
                    else
                      for (final i in list)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          onTap: () => _edit(context, ref, i, list.length),
                          title: Text(i['title']?.toString() ?? ''),
                          subtitle: Text(
                            [
                              if (i['category'] != null)
                                i['category'].toString(),
                              _dayLabel(Fmt.toInt(i['due_offset_days'])),
                              if (i['owner_role'] != null)
                                'for ${i['owner_role']}',
                              if (i['is_mandatory'] != true) 'optional',
                            ].join(' · '),
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () => _delete(context, ref, i),
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _edit(context, ref, null,
              (items.valueOrNull ?? const []).length),
          child: const Text('Add item'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  static String _dayLabel(int offset) => switch (offset) {
        0 => 'on the start date',
        1 => 'the next day',
        _ when offset < 0 => '${-offset} days before',
        _ => 'day $offset',
      };

  Future<void> _edit(BuildContext context, WidgetRef ref,
      Map<String, dynamic>? item, int existing) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ItemDialog(
        templateId: template['id'] as String,
        item: item,
        nextOrder: existing + 1,
      ),
    );
    if (saved == true) {
      ref.invalidate(templateItemsProvider(template['id'] as String));
    }
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, Map<String, dynamic> item) async {
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .deleteSetupRow('onboarding_template_items', item['id'] as String),
      successMessage: 'Removed',
    );
    ref.invalidate(templateItemsProvider(template['id'] as String));
  }
}

class _ItemDialog extends ConsumerStatefulWidget {
  const _ItemDialog({
    required this.templateId,
    required this.nextOrder,
    this.item,
  });

  final String templateId;
  final int nextOrder;
  final Map<String, dynamic>? item;

  @override
  ConsumerState<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends ConsumerState<_ItemDialog> {
  late final _title =
      TextEditingController(text: widget.item?['title']?.toString() ?? '');
  late final _description = TextEditingController(
      text: widget.item?['description']?.toString() ?? '');
  late final _category =
      TextEditingController(text: widget.item?['category']?.toString() ?? '');
  late final _owner =
      TextEditingController(text: widget.item?['owner_role']?.toString() ?? '');
  late final _offset = TextEditingController(
      text: (widget.item?['due_offset_days'] ?? 0).toString());
  late bool _mandatory = widget.item?['is_mandatory'] != false;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_title, _description, _category, _owner, _offset]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item == null ? 'Add item' : 'Edit item'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Task *', hintText: 'Create the IT account'),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _description,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Detail'),
              ),
              const SizedBox(height: Space.md),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _category,
                    decoration: const InputDecoration(
                        labelText: 'Category', hintText: 'IT, Statutory'),
                  ),
                ),
                const SizedBox(width: Space.md),
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: _offset,
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true),
                    decoration: const InputDecoration(
                      labelText: 'Day',
                      helperText: 'Negative is before',
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: Space.md),
              TextField(
                controller: _owner,
                decoration: const InputDecoration(
                  labelText: 'Whose job',
                  hintText: 'IT, Line manager, HR',
                  helperText: 'A role, since the person differs each time',
                ),
              ),
              const SizedBox(height: Space.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _mandatory,
                onChanged: (v) => setState(() => _mandatory = v),
                title: const Text('Mandatory'),
                subtitle: const Text(
                    'The checklist stays open until every mandatory item '
                    'is ticked'),
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
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Name the task')));
      return;
    }
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveTemplateItem(
            {
              'template_id': widget.templateId,
              'title': _title.text.trim(),
              'description': _description.text.trim().isEmpty
                  ? null
                  : _description.text.trim(),
              'category': _category.text.trim().isEmpty
                  ? null
                  : _category.text.trim(),
              'owner_role':
                  _owner.text.trim().isEmpty ? null : _owner.text.trim(),
              'due_offset_days': int.tryParse(_offset.text.trim()) ?? 0,
              'is_mandatory': _mandatory,
              'sort_order':
                  widget.item?['sort_order'] ?? widget.nextOrder,
            },
            id: widget.item?['id'] as String?,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}
