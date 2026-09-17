import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/searchable_picker.dart';

/// Add a place to keep stock without leaving the transfer.
///
/// The same argument as `NewItemDialog` and `NewContactDialog`: somebody
/// writing the first transfer to a shop that opened last week had to
/// abandon it, go to Settings, add the warehouse, come back and start
/// again.
///
/// WHAT IT ASKS FOR is a code and a name, which is all `warehouses`
/// requires. The address is on the Settings card, where whoever
/// maintains the list fills it in afterwards; asking for it here would
/// be the Settings card wearing a dialog, and a transfer does not need
/// a postcode to be written.
///
/// Unlike a contact, the code is NOT drawn from a series — there is no
/// numbering series for warehouses, and a warehouse code is a word
/// people say ("KL", "JB2"), not a number they read off a document.
class NewWarehouseDialog extends ConsumerStatefulWidget {
  const NewWarehouseDialog({super.key, this.seedName});

  /// What was typed into the picker.
  final String? seedName;

  @override
  ConsumerState<NewWarehouseDialog> createState() =>
      _NewWarehouseDialogState();
}

class _NewWarehouseDialogState extends ConsumerState<NewWarehouseDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _code;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.seedName ?? '');
    // A first guess at the code from the name, because "Kuala Lumpur"
    // wants to be "KUALA" far more often than it wants to be blank, and
    // it is a text field somebody can overwrite in one keystroke.
    _code = TextEditingController(text: _suggestCode(widget.seedName ?? ''));
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New warehouse'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Not on the list yet. Fill this in and the transfer will '
                'use it. The address is set in Settings afterwards.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                autofocus: widget.seedName == null,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Shah Alam store',
                ),
                validator: (v) => (v ?? '').trim().isEmpty
                    ? 'A name. It is what the transfer will say.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _code,
                autofocus: widget.seedName != null,
                decoration: const InputDecoration(
                  labelText: 'Code',
                  hintText: 'SA',
                ),
                textCapitalization: TextCapitalization.characters,
                validator: (v) => (v ?? '').trim().isEmpty
                    ? 'And a short code. Stock reports are filed by it.'
                    : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
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
          child: const Text('Create and use'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created = await repo.createWarehouse(
        code: _code.text.trim().toUpperCase(),
        name: _name.text.trim(),
      );
      // The list every warehouse picker searches, so the row just made
      // is findable from the box it was made in.
      ref.invalidate(warehousesProvider);
      if (mounted) Navigator.pop(context, created);
    } catch (e) {
      // The likely failure is a code already in use, and "SA is taken"
      // is something the person can act on without losing the transfer
      // behind this dialog.
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// A first guess at a warehouse code from its name.
///
/// Pure, and asserted in `app/test/new_warehouse_code_test.dart`. The
/// rule is: the first word, letters and digits only, upper case, at most
/// six characters. It is a SUGGESTION in an editable box — it does not
/// have to be right, it has to save a keystroke and never produce
/// something the column would reject.
String suggestWarehouseCode(String name) {
  final first = name.trim().split(RegExp(r'\s+')).first;
  final letters = first.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  if (letters.isEmpty) return '';
  return letters.substring(0, letters.length > 6 ? 6 : letters.length)
      .toUpperCase();
}

String _suggestCode(String name) => suggestWarehouseCode(name);


/// The rows a warehouse picker offers.
///
/// Findable by CODE as well as name, because a storeman types "JB2" and
/// a clerk types "Johor". Neither should have to know which the list was
/// sorted by.
List<PickerOption<String>> warehouseOptions(
  List<Map<String, dynamic>> warehouses,
) => [
  for (final w in warehouses)
    PickerOption<String>(
      value: '${w['id']}',
      label: '${w['name']}',
      sublabel: '${w['code'] ?? ''}'.isEmpty ? null : '${w['code']}',
      keywords: ['${w['code'] ?? ''}'],
    ),
];
