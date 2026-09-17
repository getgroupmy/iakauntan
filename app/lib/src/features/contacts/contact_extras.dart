import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/address_field.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/places_repository.dart';
import '../../data/repository.dart';

/// The people at a company and the places you deliver to.
///
/// `contact_persons` and `contact_addresses` have both been in the
/// schema, empty, with nothing able to write them — while
/// `sales_documents.contact_person_id` and `.shipping_address_id` are
/// carried through the transfer path and read by the e-Invoice
/// preparation. So an invoice could reference a delivery address that
/// no screen could create.
///
/// Both sections only appear on a saved contact: neither row can exist
/// without a `contact_id` to hang off.
class ContactExtras extends ConsumerWidget {
  const ContactExtras({super.key, required this.contactId});

  final String contactId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(contactPersonsProvider(contactId));
    final addresses = ref.watch(contactAddressesProvider(contactId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Row(children: [
          const Expanded(
            child: SectionHeader('People',
                subtitle: 'Who to address a document to'),
          ),
          TextButton.icon(
            onPressed: () => _editPerson(context, ref, null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
          ),
        ]),
        AsyncView(
          value: people,
          onRetry: () => ref.invalidate(contactPersonsProvider(contactId)),
          builder: (list) => list.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: Space.sm),
                  child: Text('Nobody named yet.',
                      style: TextStyle(fontSize: 12)),
                )
              : Column(
                  children: [
                    for (final p in list)
                      _PersonTile(
                        row: p,
                        onEdit: () => _editPerson(context, ref, p),
                        onPrimary: () => _makePrimary(context, ref, p),
                        onDelete: () =>
                            _delete(context, ref, 'contact_persons', p),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 24),
        Row(children: [
          const Expanded(
            child: SectionHeader('Delivery addresses',
                subtitle: 'Where the goods go, when that is not the '
                    'billing address'),
          ),
          TextButton.icon(
            onPressed: () => _editAddress(context, ref, null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
          ),
        ]),
        AsyncView(
          value: addresses,
          onRetry: () => ref.invalidate(contactAddressesProvider(contactId)),
          builder: (list) => list.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: Space.sm),
                  child: Text('None — documents use the billing address.',
                      style: TextStyle(fontSize: 12)),
                )
              : Column(
                  children: [
                    for (final a in list)
                      _AddressTile(
                        row: a,
                        onEdit: () => _editAddress(context, ref, a),
                        onDefault: () => _makeDefault(context, ref, a),
                        onDelete: () =>
                            _delete(context, ref, 'contact_addresses', a),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _editPerson(
      BuildContext context, WidgetRef ref, Map<String, dynamic>? row) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _PersonDialog(contactId: contactId, row: row),
    );
    if (saved == true) ref.invalidate(contactPersonsProvider(contactId));
  }

  Future<void> _editAddress(
      BuildContext context, WidgetRef ref, Map<String, dynamic>? row) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _AddressDialog(contactId: contactId, row: row),
    );
    if (saved == true) ref.invalidate(contactAddressesProvider(contactId));
  }

  Future<void> _makePrimary(
      BuildContext context, WidgetRef ref, Map<String, dynamic> row) async {
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .makePersonPrimary(contactId, row['id'] as String),
      successMessage: '${row['name']} is now the main contact',
    );
    ref.invalidate(contactPersonsProvider(contactId));
  }

  Future<void> _makeDefault(
      BuildContext context, WidgetRef ref, Map<String, dynamic> row) async {
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .makeAddressDefault(contactId, row['id'] as String),
      successMessage: 'Default delivery address set',
    );
    ref.invalidate(contactAddressesProvider(contactId));
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, String table,
      Map<String, dynamic> row) async {
    // Not confirmed: neither is referenced by anything posted — a
    // document that used one copies the address onto itself — so this
    // removes a convenience, not a record.
    await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.deleteSetupRow(table, row['id'] as String),
      successMessage: 'Removed',
    );
    ref.invalidate(contactPersonsProvider(contactId));
    ref.invalidate(contactAddressesProvider(contactId));
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({
    required this.row,
    required this.onEdit,
    required this.onPrimary,
    required this.onDelete,
  });

  final Map<String, dynamic> row;
  final VoidCallback onEdit;
  final VoidCallback onPrimary;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final primary = row['is_primary'] == true;

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: onEdit,
      title: Row(children: [
        Flexible(
          child: Text(row['name']?.toString() ?? '',
              overflow: TextOverflow.ellipsis),
        ),
        if (primary) ...[
          const SizedBox(width: Space.sm),
          const StatusChip('main', compact: true),
        ],
      ]),
      subtitle: Text(
        [
          row['designation'],
          row['email'],
          row['mobile'] ?? row['phone'],
        ].whereType<Object>().join(' · '),
        style: const TextStyle(fontSize: 12),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (!primary)
          TextButton(onPressed: onPrimary, child: const Text('Make main')),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          onPressed: onDelete,
        ),
      ]),
    );
  }
}

class _AddressTile extends StatelessWidget {
  const _AddressTile({
    required this.row,
    required this.onEdit,
    required this.onDefault,
    required this.onDelete,
  });

  final Map<String, dynamic> row;
  final VoidCallback onEdit;
  final VoidCallback onDefault;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isDefault = row['is_default'] == true;

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: onEdit,
      title: Row(children: [
        Flexible(
          child: Text(row['label']?.toString() ?? '',
              overflow: TextOverflow.ellipsis),
        ),
        if (isDefault) ...[
          const SizedBox(width: Space.sm),
          const StatusChip('default', compact: true),
        ],
      ]),
      subtitle: Text(
        [
          row['attention'],
          row['address_line1'],
          row['postcode'],
          row['city'],
          row['state_code'],
        ].whereType<Object>().join(', '),
        style: const TextStyle(fontSize: 12),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (!isDefault)
          TextButton(onPressed: onDefault, child: const Text('Make default')),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          onPressed: onDelete,
        ),
      ]),
    );
  }
}

class _PersonDialog extends ConsumerStatefulWidget {
  const _PersonDialog({required this.contactId, this.row});

  final String contactId;
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_PersonDialog> createState() => _PersonDialogState();
}

class _PersonDialogState extends ConsumerState<_PersonDialog> {
  final _c = <String, TextEditingController>{};
  late bool _primary = widget.row?['is_primary'] == true;
  bool _saving = false;

  static const _fields = <(String, String)>[
    ('name', 'Name *'),
    ('designation', 'Designation'),
    ('department', 'Department'),
    ('email', 'Email'),
    ('phone', 'Phone'),
    ('mobile', 'Mobile'),
  ];

  @override
  void initState() {
    super.initState();
    for (final (key, _) in _fields) {
      _c[key] = TextEditingController(text: widget.row?[key]?.toString() ?? '');
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.row == null ? 'Add person' : 'Edit person'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (key, label) in _fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.md),
                  child: TextField(
                    controller: _c[key],
                    autofocus: key == 'name',
                    keyboardType: key == 'email'
                        ? TextInputType.emailAddress
                        : TextInputType.text,
                    decoration: InputDecoration(labelText: label),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _primary,
                onChanged: (v) => setState(() => _primary = v),
                title: const Text('Main contact'),
                subtitle: const Text('The one documents are addressed to'),
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
    if (_c['name']!.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Give the person a name')));
      return;
    }
    setState(() => _saving = true);

    final values = <String, dynamic>{
      'contact_id': widget.contactId,
      'is_primary': _primary,
      for (final (key, _) in _fields)
        key: _c[key]!.text.trim().isEmpty ? null : _c[key]!.text.trim(),
    };

    final repo = ref.read(repoProvider)!;
    final ok = await runWithFeedback(
      context,
      action: () async {
        await repo.saveContactPerson(values, id: widget.row?['id'] as String?);
        // Only one person can be the main contact, and the flag is an
        // ordinary boolean column with nothing enforcing that.
        if (_primary) {
          final all = await repo.contactPersons(widget.contactId);
          final me = widget.row?['id'] as String? ??
              all.firstWhere((p) => p['name'] == values['name'],
                  orElse: () => const {})['id'] as String?;
          if (me != null) await repo.makePersonPrimary(widget.contactId, me);
        }
      },
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}

class _AddressDialog extends ConsumerStatefulWidget {
  const _AddressDialog({required this.contactId, this.row});

  final String contactId;
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends ConsumerState<_AddressDialog> {
  final _c = <String, TextEditingController>{};
  late String? _state = widget.row?['state_code'] as String?;
  late bool _default = widget.row?['is_default'] == true;
  bool _saving = false;

  static const _fields = <(String, String)>[
    ('label', 'Label *'),
    ('attention', 'For the attention of'),
    ('address_line1', 'Address line 1'),
    ('address_line2', 'Address line 2'),
    ('address_line3', 'Address line 3'),
    ('postcode', 'Postcode'),
    ('city', 'City'),
    ('phone', 'Phone'),
  ];

  @override
  void initState() {
    super.initState();
    for (final (key, _) in _fields) {
      _c[key] = TextEditingController(
          text: widget.row?[key]?.toString() ?? (key == 'label' ? 'Shipping' : ''));
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final states = ref.watch(statesProvider).valueOrNull ?? const [];

    return AlertDialog(
      title: Text(widget.row == null ? 'Add address' : 'Edit address'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (key, label) in _fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.md),
                  // The street line suggests; the rest are boxes it
                  // fills. A delivery address is the one somebody types
                  // fastest and checks least, which is the address a
                  // suggestion is worth most on.
                  child: key == 'address_line1'
                      ? AddressField(
                          controller: _c[key]!,
                          label: label,
                          country: ref.watch(orgCountryAlpha2Provider),
                          onChosen: (a) {
                            fillAddressBoxes(
                              a,
                              states,
                              postcode: _c['postcode'],
                              city: _c['city'],
                            );
                            final code = stateCodeFor(states, a.state);
                            if (code != null) setState(() => _state = code);
                          },
                        )
                      : TextField(
                          controller: _c[key],
                          autofocus: key == 'label',
                          decoration: InputDecoration(labelText: label),
                        ),
                ),
              DropdownButtonFormField<String?>(
                initialValue: _state,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'State'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('—')),
                  for (final s in states)
                    DropdownMenuItem(
                      value: s['code'] as String,
                      child: Text(s['name']?.toString() ?? '',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _state = v),
              ),
              const SizedBox(height: Space.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _default,
                onChanged: (v) => setState(() => _default = v),
                title: const Text('Default delivery address'),
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
    if (_c['label']!.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Give the address a label')));
      return;
    }
    setState(() => _saving = true);

    final values = <String, dynamic>{
      'contact_id': widget.contactId,
      'address_type': 'shipping',
      'state_code': _state,
      'is_default': _default,
      for (final (key, _) in _fields)
        key: _c[key]!.text.trim().isEmpty ? null : _c[key]!.text.trim(),
    };
    values['label'] = _c['label']!.text.trim();

    final repo = ref.read(repoProvider)!;
    final ok = await runWithFeedback(
      context,
      action: () async {
        await repo.saveContactAddress(values, id: widget.row?['id'] as String?);
        // Two default addresses is the same as none: whichever the query
        // returns first wins, and deliveries go wherever that is.
        if (_default) {
          final all = await repo.contactAddresses(widget.contactId);
          final me = widget.row?['id'] as String? ??
              all.firstWhere((a) => a['label'] == values['label'],
                  orElse: () => const {})['id'] as String?;
          if (me != null) await repo.makeAddressDefault(widget.contactId, me);
        }
      },
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}
