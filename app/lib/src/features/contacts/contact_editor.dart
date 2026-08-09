import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

class ContactEditor extends ConsumerStatefulWidget {
  const ContactEditor({super.key, this.contactId, this.contactType = 'customer'});

  final String? contactId;
  final String contactType;

  @override
  ConsumerState<ContactEditor> createState() => _ContactEditorState();
}

class _ContactEditorState extends ConsumerState<ContactEditor> {
  final _formKey = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};

  String _contactType = 'customer';
  String _entityType = 'sdn_bhd';
  String _idType = 'BRN';
  String? _stateCode;
  bool _loading = true;
  bool _saving = false;
  bool _verifying = false;
  bool? _tinValid;

  @override
  void initState() {
    super.initState();
    _contactType = widget.contactType;
    for (final key in const [
      'code', 'name', 'legalName', 'tin', 'registrationNo', 'idValue',
      'sstNo', 'email', 'phone', 'mobile', 'address1', 'address2',
      'city', 'postcode', 'creditLimit',
    ]) {
      _controllers[key] = TextEditingController();
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _c(String key) => _controllers[key]!;

  Future<void> _load() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    if (widget.contactId == null) {
      // Suggest the next contact code so the user does not invent one.
      try {
        _c('code').text = await repo.nextDocumentNumber('contact');
      } catch (_) {
        // Non-fatal: the user can type their own code.
      }
      if (mounted) setState(() => _loading = false);
      return;
    }

    try {
      final contact = await repo.contact(widget.contactId!);
      if (!mounted) return;
      setState(() {
        _c('code').text = contact.code;
        _c('name').text = contact.name;
        _c('legalName').text = contact.legalName ?? '';
        _c('tin').text = contact.tin ?? '';
        _c('registrationNo').text = contact.registrationNo ?? '';
        _c('idValue').text = contact.idValue ?? '';
        _c('sstNo').text = contact.sstRegistrationNo ?? '';
        _c('email').text = contact.email ?? '';
        _c('phone').text = contact.phone ?? '';
        _c('mobile').text = contact.mobile ?? '';
        _c('address1').text = contact.addressLine1 ?? '';
        _c('address2').text = contact.addressLine2 ?? '';
        _c('city').text = contact.city ?? '';
        _c('postcode').text = contact.postcode ?? '';
        _c('creditLimit').text = contact.creditLimit.toStringAsFixed(2);
        _contactType = contact.contactType;
        _entityType = contact.entityType;
        _idType = contact.idType ?? 'BRN';
        _stateCode = contact.stateCode;
        _tinValid = contact.isTinVerified ? true : null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not load contact: $e')));
      }
    }
  }

  Contact _build() => Contact(
        id: widget.contactId ?? '',
        code: _c('code').text.trim(),
        name: _c('name').text.trim(),
        contactType: _contactType,
        legalName: _nullIfEmpty(_c('legalName').text),
        tin: _nullIfEmpty(_c('tin').text.toUpperCase()),
        registrationNo: _nullIfEmpty(_c('registrationNo').text),
        idType: _idType,
        idValue: _nullIfEmpty(_c('idValue').text) ??
            _nullIfEmpty(_c('registrationNo').text),
        sstRegistrationNo: _nullIfEmpty(_c('sstNo').text),
        email: _nullIfEmpty(_c('email').text),
        phone: _nullIfEmpty(_c('phone').text),
        mobile: _nullIfEmpty(_c('mobile').text),
        addressLine1: _nullIfEmpty(_c('address1').text),
        addressLine2: _nullIfEmpty(_c('address2').text),
        city: _nullIfEmpty(_c('city').text),
        postcode: _nullIfEmpty(_c('postcode').text),
        stateCode: _stateCode,
        entityType: _entityType,
        creditLimit: double.tryParse(_c('creditLimit').text) ?? 0,
      );

  static String? _nullIfEmpty(String v) => v.trim().isEmpty ? null : v.trim();

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () async {
        await ref
            .read(repoProvider)!
            .saveContact(_build(), id: widget.contactId);
      },
      successMessage: 'Contact saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(contactsProvider);
      Navigator.of(context).maybePop();
    }
  }

  /// Checks the TIN against LHDN so an invoice is not rejected later.
  Future<void> _verifyTin() async {
    final tin = _c('tin').text.trim();
    final idValue = _nullIfEmpty(_c('idValue').text) ??
        _nullIfEmpty(_c('registrationNo').text);

    if (tin.isEmpty || idValue == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Enter both the TIN and the registration/ID number.'),
      ));
      return;
    }

    setState(() => _verifying = true);
    try {
      final result = await ref.read(repoProvider)!.validateTin(
            tin: tin,
            idType: _idType,
            idValue: idValue,
            contactId: widget.contactId,
          );
      if (!mounted) return;
      setState(() => _tinValid = result['valid'] == true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_tinValid == true
            ? 'TIN verified with LHDN.'
            : 'LHDN could not match this TIN to $idValue.'),
        backgroundColor: _tinValid == true ? AppTheme.success : AppTheme.danger,
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final statesAsync = ref.watch(_statesRefProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.contactId == null ? 'New contact' : 'Edit contact'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: PageBody(
                maxWidth: 760,
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SectionHeader('Identity'),
                      _Pair(
                        left: TextFormField(
                          controller: _c('code'),
                          decoration: const InputDecoration(labelText: 'Code *'),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'Enter a code'
                              : null,
                        ),
                        right: DropdownButtonFormField<String>(
                          value: _contactType,
                          decoration: const InputDecoration(labelText: 'Type'),
                          items: const [
                            DropdownMenuItem(
                                value: 'customer', child: Text('Customer')),
                            DropdownMenuItem(
                                value: 'supplier', child: Text('Supplier')),
                            DropdownMenuItem(
                                value: 'both', child: Text('Customer & Supplier')),
                          ],
                          onChanged: (v) =>
                              setState(() => _contactType = v ?? 'customer'),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _c('name'),
                        textCapitalization: TextCapitalization.words,
                        decoration:
                            const InputDecoration(labelText: 'Name *'),
                        validator: (v) =>
                            (v ?? '').trim().isEmpty ? 'Enter a name' : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _c('legalName'),
                        decoration: const InputDecoration(
                          labelText: 'Legal name',
                          helperText: 'Used on e-Invoices when it differs',
                        ),
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<String>(
                        value: _entityType,
                        decoration:
                            const InputDecoration(labelText: 'Entity type'),
                        items: const [
                          DropdownMenuItem(
                              value: 'sdn_bhd', child: Text('Sdn Bhd')),
                          DropdownMenuItem(value: 'bhd', child: Text('Berhad')),
                          DropdownMenuItem(
                              value: 'enterprise', child: Text('Enterprise')),
                          DropdownMenuItem(
                              value: 'sole_proprietor',
                              child: Text('Sole Proprietor')),
                          DropdownMenuItem(
                              value: 'partnership', child: Text('Partnership')),
                          DropdownMenuItem(
                              value: 'individual', child: Text('Individual')),
                          DropdownMenuItem(
                              value: 'government', child: Text('Government')),
                          DropdownMenuItem(value: 'other', child: Text('Other')),
                        ],
                        onChanged: (v) =>
                            setState(() => _entityType = v ?? 'sdn_bhd'),
                      ),

                      const SizedBox(height: 24),
                      SectionHeader(
                        'Tax identifiers',
                        subtitle: 'LHDN requires a TIN on every B2B e-Invoice',
                        action: _tinValid == null
                            ? null
                            : Icon(
                                _tinValid! ? Icons.verified : Icons.error_outline,
                                color: _tinValid!
                                    ? AppTheme.success
                                    : AppTheme.danger,
                                size: 20,
                              ),
                      ),
                      _Pair(
                        left: TextFormField(
                          controller: _c('tin'),
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            labelText: 'TIN',
                            hintText: 'C12345678900',
                          ),
                        ),
                        right: TextFormField(
                          controller: _c('registrationNo'),
                          decoration: const InputDecoration(
                            labelText: 'SSM registration no.',
                            hintText: '202301234567',
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _Pair(
                        left: DropdownButtonFormField<String>(
                          value: _idType,
                          decoration:
                              const InputDecoration(labelText: 'ID type'),
                          items: const [
                            DropdownMenuItem(
                                value: 'BRN', child: Text('BRN (business)')),
                            DropdownMenuItem(
                                value: 'NRIC', child: Text('NRIC (individual)')),
                            DropdownMenuItem(
                                value: 'PASSPORT', child: Text('Passport')),
                            DropdownMenuItem(value: 'ARMY', child: Text('Army')),
                          ],
                          onChanged: (v) => setState(() => _idType = v ?? 'BRN'),
                        ),
                        right: TextFormField(
                          controller: _c('idValue'),
                          decoration: const InputDecoration(
                            labelText: 'ID number',
                            helperText: 'Defaults to the registration number',
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _Pair(
                        left: TextFormField(
                          controller: _c('sstNo'),
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                              labelText: 'SST registration no.'),
                        ),
                        right: OutlinedButton.icon(
                          onPressed: _verifying ? null : _verifyTin,
                          icon: _verifying
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.verified_outlined, size: 18),
                          label: const Text('Verify TIN with LHDN'),
                        ),
                      ),

                      const SizedBox(height: 24),
                      const SectionHeader('Contact'),
                      _Pair(
                        left: TextFormField(
                          controller: _c('email'),
                          keyboardType: TextInputType.emailAddress,
                          decoration:
                              const InputDecoration(labelText: 'Email'),
                        ),
                        right: TextFormField(
                          controller: _c('phone'),
                          keyboardType: TextInputType.phone,
                          decoration:
                              const InputDecoration(labelText: 'Phone'),
                        ),
                      ),

                      const SizedBox(height: 24),
                      const SectionHeader('Address'),
                      TextFormField(
                        controller: _c('address1'),
                        decoration:
                            const InputDecoration(labelText: 'Address line 1'),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _c('address2'),
                        decoration:
                            const InputDecoration(labelText: 'Address line 2'),
                      ),
                      const SizedBox(height: 14),
                      _Pair(
                        left: TextFormField(
                          controller: _c('postcode'),
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Postcode'),
                        ),
                        right: TextFormField(
                          controller: _c('city'),
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(labelText: 'City'),
                        ),
                      ),
                      const SizedBox(height: 14),
                      statesAsync.when(
                        data: (states) => DropdownButtonFormField<String>(
                          value: _stateCode,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'State'),
                          items: [
                            for (final s in states)
                              DropdownMenuItem(
                                value: s['code'] as String,
                                child: Text(s['name'] as String),
                              ),
                          ],
                          onChanged: (v) => setState(() => _stateCode = v),
                        ),
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) => Text('$e'),
                      ),

                      const SizedBox(height: 24),
                      const SectionHeader('Commercial terms'),
                      TextFormField(
                        controller: _c('creditLimit'),
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Credit limit',
                          prefixText: 'RM ',
                        ),
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

final _statesRefProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final repo = ref.watch(repoProvider);
  if (repo == null) return const [];
  return repo.states();
});

class _Pair extends StatelessWidget {
  const _Pair({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 600) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [left, const SizedBox(height: 14), right],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 14),
        Expanded(child: right),
      ],
    );
  }
}
