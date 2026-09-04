import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models.dart';

/// Add a customer or supplier without leaving the document.
///
/// The same argument as `NewItemDialog`: somebody typing an invoice for
/// a customer who is not on file had to abandon it, go to Contacts, add
/// them, come back and start again. A half-typed invoice is the thing
/// people least want to leave.
///
/// WHAT IT ASKS FOR is the shortest list that makes a contact billable.
/// The code is drawn from the series rather than asked for — 0479 made
/// a blank code mean "give me the next one", so asking would be asking
/// somebody to do by hand what the system does better. The TIN is here
/// and nothing else statutory is, because it is the one field whose
/// absence stops an e-Invoice, and being told that at posting time is
/// too late to be useful.
class NewContactDialog extends ConsumerStatefulWidget {
  const NewContactDialog({
    super.key,
    required this.contactType,
    this.seedName,
  });

  /// `customer`, `supplier` or `prospect` — what this document needs.
  final String contactType;

  /// What was typed into the picker.
  final String? seedName;

  @override
  ConsumerState<NewContactDialog> createState() => _NewContactDialogState();
}

class _NewContactDialogState extends ConsumerState<NewContactDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _tin = TextEditingController();
  bool _saving = false;
  String? _error;

  String get _noun => switch (widget.contactType) {
    'supplier' => 'supplier',
    'prospect' => 'prospect',
    _ => 'customer',
  };

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.seedName ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _tin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('New $_noun'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Not on file yet. Fill this in and the document will use '
                'them. A code is drawn from the series automatically.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Ramli Enterprise Sdn Bhd',
                ),
                validator: (v) => (v ?? '').trim().isEmpty
                    ? 'A name. It is what the invoice is addressed to.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tin,
                decoration: const InputDecoration(
                  labelText: 'Tax identification number',
                  hintText: 'C12345678901',
                  // Said here rather than at posting, when it is too
                  // late to be useful.
                  helperText: 'Needed before an e-Invoice can be filed '
                      'for them.',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                decoration: const InputDecoration(labelText: 'Phone'),
                keyboardType: TextInputType.phone,
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

  String? _blank(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created = await repo.saveContact(
        Contact(
          id: '',
          // Blank: 0479's rule is that a contact with no code is given
          // the next one from its own type's series, which is a better
          // code than anybody types by hand.
          code: '',
          name: _name.text.trim(),
          contactType: widget.contactType,
          tin: _blank(_tin),
          email: _blank(_email),
          phone: _blank(_phone),
        ),
      );
      // The list the picker searches, so the row just created is
      // findable from the box it was created in.
      ref.invalidate(contactsProvider);
      if (mounted) Navigator.pop(context, created);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
