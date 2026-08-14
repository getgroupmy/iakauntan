import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Where stock is kept.
///
/// `ensure_default_warehouse` has been quietly making one since 0059,
/// because a stock adjustment needs somewhere to go and an empty
/// `warehouses` table is not a state the client can fix on its own. That
/// was the only way a warehouse had ever come into existence — so a
/// company with a shop and a store room could see "Main", could file
/// everything against it, and had nowhere to say the second one exists.
class WarehousesCard extends ConsumerWidget {
  const WarehousesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final warehouses = ref.watch(warehousesProvider);
    final canEdit = ref.watch(canPostProvider);

    Future<void> edit([Map<String, dynamic>? existing]) async {
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => _WarehouseDialog(existing: existing),
      );
      if (saved == true) {
        ref.invalidate(warehousesProvider);
        ref.invalidate(stockOnHandProvider);
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Warehouses',
              subtitle: 'Where stock is held and counted',
              action: canEdit
                  ? TextButton.icon(
                      key: const ValueKey('add-warehouse'),
                      onPressed: () => edit(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add'),
                    )
                  : null,
            ),
            AsyncView(
              value: warehouses,
              onRetry: () => ref.invalidate(warehousesProvider),
              loading: const LinearProgressIndicator(),
              builder: (list) => list.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'None yet. One is created automatically the first '
                        'time stock is adjusted.',
                        style: TextStyle(fontSize: 13),
                      ),
                    )
                  : Column(
                      children: [
                        for (final w in list)
                          InkWell(
                            key: ValueKey('warehouse-${w['code']}'),
                            onTap: canEdit ? () => edit(w) : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 72,
                                    child: Text(
                                      w['code']?.toString() ?? '',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(w['name']?.toString() ?? ''),
                                  ),
                                  if (w['is_default'] == true)
                                    const Padding(
                                      padding: EdgeInsets.only(right: 8),
                                      child: StatusChip(
                                        'default',
                                        compact: true,
                                      ),
                                    ),
                                  if (canEdit)
                                    const Icon(Icons.chevron_right, size: 18),
                                ],
                              ),
                            ),
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

class _WarehouseDialog extends ConsumerStatefulWidget {
  const _WarehouseDialog({this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_WarehouseDialog> createState() => _WarehouseDialogState();
}

class _WarehouseDialogState extends ConsumerState<_WarehouseDialog> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _line1 = TextEditingController();
  final _postcode = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  bool _saving = false;

  bool get _isNew => widget.existing == null;
  String get _id => widget.existing!['id'] as String;

  @override
  void initState() {
    super.initState();
    final w = widget.existing;
    _code.text = w?['code']?.toString() ?? '';
    _name.text = w?['name']?.toString() ?? '';
    _line1.text = w?['address_line1']?.toString() ?? '';
    _postcode.text = w?['postcode']?.toString() ?? '';
    _city.text = w?['city']?.toString() ?? '';
    _state.text = w?['state_code']?.toString() ?? '';
  }

  @override
  void dispose() {
    for (final c in [_code, _name, _line1, _postcode, _city, _state]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid =>
      _code.text.trim().isNotEmpty && _name.text.trim().isNotEmpty;

  Future<void> _save() async {
    setState(() => _saving = true);
    final repo = ref.read(repoProvider)!;
    final ok = await runWithFeedback(
      context,
      action: () => _isNew
          ? repo.createWarehouse(
              code: _code.text.trim().toUpperCase(),
              name: _name.text.trim(),
              addressLine1: _line1.text,
              postcode: _postcode.text,
              city: _city.text,
              stateCode: _state.text,
            )
          : repo.updateWarehouse(
              _id,
              code: _code.text.trim().toUpperCase(),
              name: _name.text.trim(),
              addressLine1: _line1.text,
              postcode: _postcode.text,
              city: _city.text,
              stateCode: _state.text,
            ),
      successMessage: _isNew ? 'Warehouse added' : 'Warehouse saved',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isNew ? 'New warehouse' : 'Edit ${_code.text}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: TextField(
                      key: const ValueKey('warehouse-code'),
                      controller: _code,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.characters,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Code'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('warehouse-name'),
                      controller: _name,
                      enabled: !_saving,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _line1,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'Address'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _postcode,
                      enabled: !_saving,
                      decoration: const InputDecoration(labelText: 'Postcode'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _city,
                      enabled: !_saving,
                      decoration: const InputDecoration(labelText: 'City'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _state,
                      enabled: !_saving,
                      decoration: const InputDecoration(labelText: 'State'),
                    ),
                  ),
                ],
              ),
              if (!_isNew) ...[
                const Divider(height: Space.xl),
                Row(
                  children: [
                    if (widget.existing!['is_default'] != true)
                      TextButton(
                        onPressed: _saving ? null : _makeDefault,
                        child: const Text('Make default'),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: _saving ? null : _retire,
                      child: Text(
                        'Close',
                        style: TextStyle(color: context.colors.danger),
                      ),
                    ),
                  ],
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
          onPressed: _valid && !_saving ? _save : null,
          child: Text(_isNew ? 'Add' : 'Save'),
        ),
      ],
    );
  }

  Future<void> _makeDefault() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.setDefaultWarehouse(_id),
      successMessage: 'Default warehouse changed',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _retire() async {
    final sure = await confirm(
      context,
      title: 'Close ${_code.text}?',
      message:
          'It stops being offered on new documents. Stock movements '
          'already filed against it are kept, so last year still explains '
          'itself.',
      confirmLabel: 'Close',
      destructive: true,
    );
    if (!sure || !mounted) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.retireWarehouse(_id),
      successMessage: 'Warehouse closed',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }
}
