import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/platform_catalog_repository.dart';

/// What each module is called, what it costs, and where it sits in the
/// menu.
///
/// `platform_modules.monthly_price` has existed since 0018 and nothing
/// ever wrote to it: changing what a module costs meant SQL against
/// production, on the table that decides what every tenant is billed.
///
/// There is no delete. A module any company has ever enabled is
/// referenced by `org_modules`, so it goes inactive and stops being
/// offered rather than disappearing from under its own history.
class ModulesAdminTab extends ConsumerWidget {
  const ModulesAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modules = ref.watch(platformModulesAdminProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add a module'),
      ),
      body: Column(
        children: [
          const _NavGroupingCard(),
          Expanded(
            child: AsyncView<List<Map<String, dynamic>>>(
              value: modules,
              onRetry: () => ref.invalidate(platformModulesAdminProvider),
              builder: (rows) => ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  for (final r in rows)
                    ListTile(
                      title: Row(
                        children: [
                          Flexible(child: Text('${r['name']}')),
                          if (r['is_core'] == true) ...[
                            const SizedBox(width: Space.sm),
                            const StatusChip('core', compact: true),
                          ],
                          if (r['is_active'] != true) ...[
                            const SizedBox(width: Space.sm),
                            const StatusChip('inactive', compact: true),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        [
                          '${r['code']}',
                          if (r['nav_group'] != null) 'under ${r['nav_group']}',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: Text(
                        r['is_core'] == true
                            ? 'included'
                            : '${Fmt.money(Fmt.toDouble(r['monthly_price']))} / month',
                      ),
                      onTap: () => _edit(context, ref, r),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ModuleDialog(existing: existing),
    );
    if (saved == true) ref.invalidate(platformModulesAdminProvider);
  }
}

/// One list of everything, or gathered under module headings.
class _NavGroupingCard extends ConsumerWidget {
  const _NavGroupingCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grouped = ref.watch(navGroupingProvider).valueOrNull ?? false;
    return Card(
      margin: const EdgeInsets.all(Space.md),
      child: SwitchListTile(
        value: grouped,
        title: const Text('Group the side menu by module'),
        subtitle: const Text(
          'Off, every destination a company holds is one flat list. On, '
          'they are gathered under the module headings set below.',
        ),
        onChanged: (v) async {
          final ok = await runWithFeedback(
            context,
            successMessage: v ? 'Menu grouped by module' : 'Menu shows one list',
            action: () => ref.read(repoProvider)!.setNavGrouping(v),
          );
          if (ok) ref.invalidate(navGroupingProvider);
        },
      ),
    );
  }
}

class _ModuleDialog extends ConsumerStatefulWidget {
  const _ModuleDialog({required this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_ModuleDialog> createState() => _ModuleDialogState();
}

class _ModuleDialogState extends ConsumerState<_ModuleDialog> {
  late final _code = TextEditingController(
    text: '${widget.existing?['code'] ?? ''}',
  );
  late final _name = TextEditingController(
    text: '${widget.existing?['name'] ?? ''}',
  );
  late final _description = TextEditingController(
    text: '${widget.existing?['description'] ?? ''}',
  );
  late final _group = TextEditingController(
    text: '${widget.existing?['nav_group'] ?? ''}',
  );
  late final _price = TextEditingController(
    text: widget.existing == null
        ? ''
        : Fmt.toDouble(widget.existing!['monthly_price']).toStringAsFixed(2),
  );
  late final _order = TextEditingController(
    text: '${widget.existing?['sort_order'] ?? ''}',
  );
  late bool _active = widget.existing?['is_active'] != false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_code, _name, _description, _group, _price, _order]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _changed(TextEditingController c, String key) {
    final now = c.text.trim();
    final before = '${widget.existing?[key] ?? ''}'.trim();
    return now == before ? null : now;
  }

  Future<void> _save() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('A module needs a code.')));
      return;
    }
    final priceNow = double.tryParse(_price.text.trim());
    final priceBefore = widget.existing == null
        ? null
        : Fmt.toDouble(widget.existing!['monthly_price']);

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Module saved',
      action: () => ref.read(repoProvider)!.savePlatformModule(
        code,
        name: _changed(_name, 'name'),
        description: _changed(_description, 'description'),
        navGroup: _changed(_group, 'nav_group'),
        monthlyPrice: priceNow != priceBefore ? priceNow : null,
        sortOrder: int.tryParse(_order.text.trim()),
        isActive: _active != (widget.existing?['is_active'] != false)
            ? _active
            : (widget.existing == null ? _active : null),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    final isCore = widget.existing?['is_core'] == true;
    return AlertDialog(
      title: Text(isNew ? 'Add a module' : '${widget.existing!['code']}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _code,
                // The code is what every company's entitlement row points
                // at. Changing it would strand them on a module that no
                // longer exists, so it is set once.
                enabled: isNew,
                decoration: const InputDecoration(
                  labelText: 'Code',
                  helperText: 'What org_modules stores. Cannot be changed.',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'What a company sees this called',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _description,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _group,
                decoration: const InputDecoration(
                  labelText: 'Menu heading',
                  helperText: 'What its destinations sit under when the '
                      'menu is grouped. Blank uses the module name.',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                enabled: !isCore,
                decoration: InputDecoration(
                  labelText: 'Monthly price',
                  helperText: isCore
                      ? 'A core module is part of keeping books and is not '
                            'sold separately.'
                      : 'What a company is billed a month for holding it',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _order,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Order'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: isCore ? null : (v) => setState(() => _active = v),
                title: const Text('Offered to companies'),
                subtitle: Text(
                  isCore
                      ? 'A core module is always offered.'
                      : 'Off retires it. Companies that hold it keep it; '
                            'nobody new is offered it.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
