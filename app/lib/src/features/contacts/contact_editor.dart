import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/address_field.dart';
import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/pdf_kit.dart' show LetterheadMode;
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/ocr_repository.dart';
import 'scanned_address.dart';
import 'control_account.dart';
import '../../data/places_repository.dart';
// `RepoGroupContacts` is an extension, and a Dart extension is only
// in scope where its declaring library is imported.
import '../../data/repository.dart';
import 'statement_pdf.dart';
import 'contact_extras.dart';

class ContactEditor extends ConsumerStatefulWidget {
  const ContactEditor({
    super.key,
    this.contactId,
    this.contactType = 'customer',
    this.scanned,
  });

  final String? contactId;
  final String contactType;

  /// A letterhead, invoice or name card that has just been read.
  ///
  /// Fills what the paper carries — the name, the numbers, the address
  /// as printed — and leaves the rest. What it deliberately does not
  /// fill is the city: see `splitScannedAddress`.
  final OcrExtraction? scanned;

  @override
  ConsumerState<ContactEditor> createState() => _ContactEditorState();
}

class _ContactEditorState extends ConsumerState<ContactEditor> {
  final _formKey = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};

  String _contactType = 'customer';
  String? _priceLevelId;
  bool _creditHold = false;
  String? _receivableAccountId;
  String? _payableAccountId;
  String? _linkedOrgId;
  bool _statementBusy = false;
  String _entityType = 'sdn_bhd';
  String _idType = 'BRN';
  String? _stateCode;
  bool _loading = true;
  bool _saving = false;
  bool _verifying = false;
  bool? _tinValid;
  // The codes the series has suggested for this new contact, one per
  // prefix, so that changing the type re-suggests (C- becomes S- or P-)
  // without drawing a second number from a series already drawn on, and
  // never over a code the user has typed themselves.
  final Map<String, String> _suggested = {};

  @override
  void initState() {
    super.initState();
    _contactType = widget.contactType;
    for (final key in const [
      'code',
      'name',
      'legalName',
      'tin',
      'registrationNo',
      'idValue',
      'sstNo',
      'email',
      'phone',
      'mobile',
      'address1',
      'address2',
      'city',
      'postcode',
      'creditLimit',
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

  /// Whether the code field still holds a suggestion rather than a code
  /// the user typed.
  bool _codeIsSuggested() {
    final current = _c('code').text.trim();
    return current.isEmpty || _suggested.containsValue(current);
  }

  /// Fills the code field from the series for the current type, unless the
  /// user has already typed a code of their own. Non-fatal when the series
  /// cannot be reached: the user can type a code.
  Future<void> _suggestCode() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    if (!_codeIsSuggested()) return;
    final type = _contactType;
    final prefix = Repo.contactCodePrefix(type);
    final drawn = _suggested[prefix];
    if (drawn != null) {
      setState(() => _c('code').text = drawn);
      return;
    }
    try {
      final code = await repo.nextContactCode(type);
      if (!mounted) return;
      _suggested[prefix] = code;
      // The type may have moved on while the series was being asked.
      if (_contactType != type || !_codeIsSuggested()) return;
      setState(() => _c('code').text = code);
    } catch (_) {
      // Non-fatal: the user can type their own code.
    }
  }

  Future<void> _load() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    if (widget.contactId == null) {
      // Suggest the next code of the series for this type (C-, S- or P-)
      // so the user does not invent one.
      await _suggestCode();
      final read = widget.scanned;
      if (read != null) {
        _c('name').text = read.supplierName ?? '';
        _c('tin').text = read.supplierTaxId ?? '';
        _c('registrationNo').text = read.supplierRegistrationNo ?? '';
        _c('email').text = read.supplierEmail ?? '';
        _c('phone').text = read.supplierPhone ?? '';
        final address = splitScannedAddress(read.supplierAddress);
        _c('address1').text = address.line1;
        _c('address2').text = address.line2;
        if (address.postcode != null) _c('postcode').text = address.postcode!;
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
        _creditHold = contact.creditHold;
        _receivableAccountId = contact.receivableAccountId;
        _payableAccountId = contact.payableAccountId;
        _contactType = contact.contactType;
        _priceLevelId = contact.priceLevelId;
        _entityType = contact.entityType;
        _idType = contact.idType ?? 'BRN';
        _stateCode = contact.stateCode;
        _tinValid = contact.isTinVerified ? true : null;
        _loading = false;
      });
      // Read separately, because it is not on the model: see
      // `RepoGroupContacts`. Its own try, so that a company without the
      // group feature — or a transient failure on one extra column —
      // reports nothing rather than "could not load contact" about a
      // contact that has plainly just loaded.
      try {
        final linked = await ref
            .read(repoProvider)!
            .contactLinkedOrg(widget.contactId!);
        if (mounted) setState(() => _linkedOrgId = linked);
      } catch (_) {
        // The field simply stays unset, which is what it means.
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not load contact: $e')));
      }
    }
  }

  /// A statement of what this customer still owes.
  ///
  /// Reloaded from the database rather than taken from the form, for the
  /// same reason the invoice PDF is: an unsaved edit in a text field is
  /// not yet part of the record, and a statement is a document that goes
  /// out to somebody else.
  Future<void> _downloadStatement() async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(repoProvider);
    final org = ref.read(currentOrgProvider).valueOrNull;
    if (repo == null || org == null || widget.contactId == null) return;

    setState(() => _statementBusy = true);
    try {
      final contact = await repo.contact(widget.contactId!);
      // A contact can be both, and then the statement follows what is
      // on screen rather than guessing. `contact_type` is the only thing
      // that says which of the two ledgers this person is being looked
      // at through.
      final supplier = _contactType == 'supplier';
      final documents = await repo.outstandingFor(
        kind: supplier ? DocKind.purchase : DocKind.sales,
        contactId: widget.contactId!,
      );
      final asAt = DateTime.now();

      final bytes = await buildStatementPdf(
        org: org,
        contact: contact,
        documents: documents,
        asAt: asAt,
        side: supplier ? StatementSide.supplier : StatementSide.customer,
        logo: await ref.read(orgLogoProvider.future),
        mode: org.usesPreprintedLetterhead
            ? LetterheadMode.stationery
            : LetterheadMode.printed,
      );

      final stem = contact.code
          .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
          .toLowerCase();
      final saved = await exportBytesFile(
        ref,
        '${supplier ? 'supplier-statement' : 'statement'}'
            '-$stem-${Fmt.iso(asAt)}.pdf',
        'application/pdf',
        bytes,
        what: supplier ? 'Supplier statement' : 'Customer statement',
        detail: '${contact.name} to ${Fmt.iso(asAt)}',
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            saved
                ? 'Downloaded'
                : 'PDF download is only available in the browser',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _statementBusy = false);
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
    idValue:
        _nullIfEmpty(_c('idValue').text) ??
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
    creditHold: _creditHold,
    receivableAccountId: _receivableAccountId,
    payableAccountId: _payableAccountId,
    priceLevelId: _priceLevelId,
  );

  static String? _nullIfEmpty(String v) => v.trim().isEmpty ? null : v.trim();

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () async {
        final saved = await ref
            .read(repoProvider)!
            .saveContact(_build(), id: widget.contactId);
        // After the contact, and through its own function rather than
        // as a column on the update: the link asserts that two
        // companies are related, and 0142 checks both ends before
        // believing it.
        await ref.read(repoProvider)!.linkGroupContact(saved.id, _linkedOrgId);
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
    final idValue =
        _nullIfEmpty(_c('idValue').text) ??
        _nullIfEmpty(_c('registrationNo').text);

    if (tin.isEmpty || idValue == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter both the TIN and the registration/ID number.'),
        ),
      );
      return;
    }

    setState(() => _verifying = true);
    try {
      final result = await ref
          .read(repoProvider)!
          .validateTin(
            tin: tin,
            idType: _idType,
            idValue: idValue,
            contactId: widget.contactId,
          );
      if (!mounted) return;
      setState(() => _tinValid = result['valid'] == true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tinValid == true
                ? 'TIN verified with LHDN.'
                : 'LHDN could not match this TIN to $idValue.',
          ),
          backgroundColor: _tinValid == true
              ? context.colors.success
              : context.colors.danger,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
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
          // Only for a saved contact: a statement is a list of open
          // documents, and a contact that does not exist yet has none.
          // Suppliers get one too — theirs lists what we owe them, for
          // checking against the statement they send us, which is the
          // half of the reconciliation that used to have no document.
          if (widget.contactId != null)
            IconButton(
              tooltip: _contactType == 'supplier'
                  ? 'Statement of what we owe'
                  : 'Statement of account',
              icon: const Icon(Icons.request_quote_outlined, size: 20),
              onPressed: _statementBusy ? null : _downloadStatement,
            ),
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
                          decoration: const InputDecoration(
                            labelText: 'Code *',
                          ),
                          validator: (v) =>
                              (v ?? '').trim().isEmpty ? 'Enter a code' : null,
                        ),
                        right: DropdownButtonFormField<String>(
                          value: _contactType,
                          decoration: const InputDecoration(labelText: 'Type'),
                          items: const [
                            DropdownMenuItem(
                              value: 'customer',
                              child: Text('Customer'),
                            ),
                            DropdownMenuItem(
                              value: 'supplier',
                              child: Text('Supplier'),
                            ),
                            DropdownMenuItem(
                              value: 'both',
                              child: Text('Customer & Supplier'),
                            ),
                            DropdownMenuItem(
                              value: 'prospect',
                              child: Text('Prospect'),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() => _contactType = v ?? 'customer');
                            if (widget.contactId == null) _suggestCode();
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _c('name'),
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(labelText: 'Name *'),
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
                        decoration: const InputDecoration(
                          labelText: 'Entity type',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'sdn_bhd',
                            child: Text('Sdn Bhd'),
                          ),
                          DropdownMenuItem(value: 'bhd', child: Text('Berhad')),
                          DropdownMenuItem(
                            value: 'enterprise',
                            child: Text('Enterprise'),
                          ),
                          DropdownMenuItem(
                            value: 'sole_proprietor',
                            child: Text('Sole Proprietor'),
                          ),
                          DropdownMenuItem(
                            value: 'partnership',
                            child: Text('Partnership'),
                          ),
                          DropdownMenuItem(
                            value: 'individual',
                            child: Text('Individual'),
                          ),
                          DropdownMenuItem(
                            value: 'government',
                            child: Text('Government'),
                          ),
                          DropdownMenuItem(
                            value: 'other',
                            child: Text('Other'),
                          ),
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
                                _tinValid!
                                    ? Icons.verified
                                    : Icons.error_outline,
                                color: _tinValid!
                                    ? context.colors.success
                                    : context.colors.danger,
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
                          decoration: const InputDecoration(
                            labelText: 'ID type',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'BRN',
                              child: Text('BRN (business)'),
                            ),
                            DropdownMenuItem(
                              value: 'NRIC',
                              child: Text('NRIC (individual)'),
                            ),
                            DropdownMenuItem(
                              value: 'PASSPORT',
                              child: Text('Passport'),
                            ),
                            DropdownMenuItem(
                              value: 'ARMY',
                              child: Text('Army'),
                            ),
                          ],
                          onChanged: (v) =>
                              setState(() => _idType = v ?? 'BRN'),
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
                            labelText: 'SST registration no.',
                          ),
                        ),
                        right: OutlinedButton.icon(
                          onPressed: _verifying ? null : _verifyTin,
                          icon: _verifying
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
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
                          decoration: const InputDecoration(labelText: 'Email'),
                        ),
                        right: TextFormField(
                          controller: _c('phone'),
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Phone'),
                        ),
                      ),

                      const SizedBox(height: 24),
                      const SectionHeader('Address'),
                      AddressField(
                        controller: _c('address1'),
                        label: 'Address line 1',
                        country: ref.watch(orgCountryAlpha2Provider),
                        // The state is a dropdown here rather than a
                        // box, so it is set rather than typed into.
                        onChosen: (a) {
                          fillAddressBoxes(
                            a,
                            statesAsync.valueOrNull ?? const [],
                            postcode: _c('postcode'),
                            city: _c('city'),
                          );
                          final code = stateCodeFor(
                            statesAsync.valueOrNull ?? const [],
                            a.state,
                          );
                          if (code != null) setState(() => _stateCode = code);
                        },
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _c('address2'),
                        decoration: const InputDecoration(
                          labelText: 'Address line 2',
                        ),
                      ),
                      const SizedBox(height: 14),
                      _Pair(
                        left: TextFormField(
                          controller: _c('postcode'),
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Postcode',
                          ),
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
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Credit limit',
                          prefixText: 'RM ',
                          helperText: 'Zero means no limit',
                        ),
                      ),
                      // Only for customers, and only ever set by hand.
                      // 0362 makes it refuse an invoice whatever the
                      // organization's credit control mode says, because
                      // a hold is somebody's instruction rather than
                      // arithmetic — so it must not be possible to end
                      // up on stop by accident.
                      if (_contactType != 'supplier')
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _creditHold,
                          onChanged: (v) => setState(() => _creditHold = v),
                          title: const Text('On credit hold'),
                          subtitle: const Text(
                            'Refuses a new invoice until it is taken off. '
                            'Credit notes and receipts still go through.',
                          ),
                        ),
                      const SizedBox(height: 14),
                      // Read by 0013 in four places and settable
                      // nowhere until now, so every company's
                      // receivables sat in one account whether or not
                      // its accounts needed them apart. A balance owed
                      // by a related party is disclosed separately
                      // under MPERS, and a control account of its own
                      // is how that comes out of a ledger.
                      if (_contactType != 'supplier')
                        _controlAccountField(receivable: true),
                      if (_contactType != 'customer')
                        _controlAccountField(receivable: false),
                      const SizedBox(height: 14),
                      // Only for customers: a price level is what we
                      // charge, not what a supplier charges us.
                      if (_contactType != 'supplier')
                        DropdownButtonFormField<String?>(
                          value: _priceLevelId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Price level',
                            helperText: 'What this customer is quoted',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: null,
                              child: Text('Standard'),
                            ),
                            for (final l
                                in ref.watch(priceLevelsProvider).value ??
                                    const [])
                              DropdownMenuItem(
                                value: l['id'] as String,
                                child: Text(
                                  l['name'] as String,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() => _priceLevelId = v),
                        ),
                      // Only where there is a group to point at. A
                      // company that stands alone has no sister to link
                      // to, and an empty dropdown would be an invitation
                      // to wonder what it was for.
                      //
                      // The list is `my_group_companies`, which is
                      // already narrowed to companies this person is a
                      // member of — the same narrowing
                      // `link_group_contact` enforces, so the options
                      // offered are the options that will be accepted.
                      if ((ref.watch(groupCompaniesProvider).value ?? const [])
                          .where((o) => o['is_current'] != true)
                          .isNotEmpty)
                        DropdownButtonFormField<String?>(
                          value: _linkedOrgId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Company in this group',
                            helperText:
                                'Links trading with a sister company so it '
                                'can be eliminated on consolidation',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: null,
                              child: Text('Not a group company'),
                            ),
                            // `my_group_companies` includes the company
                            // you are standing in, flagged is_current.
                            // A contact of this company standing for
                            // this company is not a thing, so it is not
                            // offered.
                            for (final o
                                in (ref.watch(groupCompaniesProvider).value ??
                                        const [])
                                    .where((o) => o['is_current'] != true))
                              DropdownMenuItem(
                                value: o['org_id'] as String?,
                                child: Text(
                                  '${o['name']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() => _linkedOrgId = v),
                        ),
                      // Only on a saved contact: a person or an address
                      // needs a contact_id to hang off, and there isn't
                      // one until this has been saved once.
                      if (widget.contactId != null)
                        ContactExtras(contactId: widget.contactId!),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  /// Where this contact's balance sits, when it is not the usual one.
  ///
  /// The list is `controlAccountChoices`, which is the whole of the
  /// decision and is asserted separately: only a control account of the
  /// matching subtype, no group headings, nothing retired. Pointed at
  /// the bank instead, a customer's balance would post into cash and
  /// the aged listing — which reconciles against the control account —
  /// would stop agreeing with the ledger without saying why.
  Widget _controlAccountField({required bool receivable}) {
    final choices = controlAccountChoices(
      ref.watch(accountsProvider).valueOrNull ?? const <Account>[],
      receivable: receivable,
    );
    final current = receivable ? _receivableAccountId : _payableAccountId;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: DropdownButtonFormField<String?>(
        value: choices.any((a) => a.id == current) ? current : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: receivable ? 'Receivable account' : 'Payable account',
          helperText: 'Leave it alone unless this one is kept apart',
        ),
        items: [
          const DropdownMenuItem(
            value: null,
            child: Text(kDefaultControlAccount),
          ),
          for (final a in choices)
            DropdownMenuItem(value: a.id, child: Text('${a.code} — ${a.name}')),
        ],
        onChanged: (v) => setState(
          () => receivable ? _receivableAccountId = v : _payableAccountId = v,
        ),
      ),
    );
  }
}

final _statesRefProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
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
