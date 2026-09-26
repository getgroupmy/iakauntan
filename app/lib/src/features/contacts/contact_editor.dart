import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/address_field.dart';
import '../../core/error_text.dart';
import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/pdf_kit.dart' show LetterheadMode;
import '../../core/providers.dart';
import '../../core/quick_add_dialog.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../custom_fields/custom_fields_section.dart';
import '../onboarding/onboarding_copy.dart'
    show oldIdentificationHelp, oldIdentificationHint, oldIdentificationLabel;
import '../../data/ocr_repository.dart';
import 'scanned_address.dart';
import 'control_account.dart';
import '../../data/places_repository.dart';
// `RepoGroupContacts` is an extension, and a Dart extension is only
// in scope where its declaring library is imported.
import '../../data/repository.dart';
import '../../data/ssm_repository.dart';
import '../../data/entity_types_repository.dart';
import '../shared/entity_search.dart';
import '../shared/ssm_query_hints.dart';
import 'brought_forward.dart';
import 'brought_forward_pdf.dart';
import 'statement_pdf.dart';
import 'contact_delete.dart';
import 'contact_extras.dart';
import 'customer_portal_card.dart';
import 'tax_details_card.dart';
import 'contact_lookalikes.dart';

/// Whether the form still says what the register said.
///
/// Somebody may look a company up and then correct the name by hand,
/// and stamping `ssm_verified_at` on that would be recording a
/// verification that did not happen — which is precisely the
/// distinction the column exists to make.
///
/// The consequence of getting it wrong in each direction is not
/// symmetric, which is why this is pinned rather than left in the
/// widget:
///
///   * too EAGER and the contact carries `ssm_verified_at` against a
///     name nobody at SSM ever confirmed, and `set_contact_ssm_entity`
///     writes the registry's name over whatever was typed;
///   * too SHY and a verification that really happened is not recorded,
///     which costs a second lookup and nothing else.
///
/// So every comparison below errs shy on purpose. Case is ignored --
/// the registry SHOUTS and an operator need not -- and nothing else is.
/// A double space inside a name, or a digit changed in the number, is a
/// different answer from the one the register gave.
///
/// Public and outside the State so it can be asserted; a private getter
/// on a private `State` cannot be.
bool ssmStillMatches({
  required SsmEntity? chosen,
  required String name,
  required String registrationNo,
}) {
  if (chosen == null) return false;

  final sameName = name.trim().toUpperCase() == chosen.name.trim().toUpperCase();

  final typedReg = registrationNo.trim().isEmpty ? null : registrationNo.trim();
  final registryReg = (chosen.regNo ?? '').trim().isEmpty
      ? null
      : (chosen.regNo ?? '').trim();
  final sameReg = typedReg == registryReg;

  return sameName && sameReg;
}

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
  Map<String, dynamic> _customFields = const {};
  bool _creditHold = false;
  String? _receivableAccountId;
  String? _payableAccountId;
  String? _linkedOrgId;
  bool _statementBusy = false;
  /// Null until somebody chooses, on a NEW contact.
  ///
  /// It used to default to `sdn_bhd`, which meant the commonest kind
  /// was also the kind nobody was ever asked about: a sole proprietor
  /// typed in quickly was filed as a private limited company, and
  /// nothing on the screen had said so. The form now asks first and
  /// the name box does not appear until it has an answer.
  String? _entityType;
  String _idType = 'BRN';
  String? _stateCode;
  bool _loading = true;
  bool _saving = false;
  bool _verifying = false;
  bool? _tinValid;

  /// What the SSM register answered, if anybody asked it.
  ///
  /// Held rather than written straight away, because the fields it
  /// fills are still editable afterwards and a person who overrides
  /// the registry has not verified anything. `_stampSsm` compares
  /// before it claims.
  SsmEntity? _ssmChosen;
  bool _ssmBusy = false;
  // The codes the series has suggested for this new contact, one per
  // prefix, so that changing the type re-suggests (C- becomes S- or P-)
  // without drawing a second number from a series already drawn on, and
  // never over a code the user has typed themselves.
  final Map<String, String> _suggested = {};

  // What is already on file under the number or name being typed,
  // asked a moment after the typing pauses. Armed once the form holds
  // what the person typed rather than what was loaded into it, so an
  // existing record is not reported against itself on the way in.
  List<Lookalike> _lookalikes = const [];
  Timer? _lookalikeTimer;
  int _lookalikeAsk = 0;
  bool _lookalikesArmed = false;

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
      'oldRegistrationNo',
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
    for (final key in const ['name', 'registrationNo', 'tin', 'idValue']) {
      _c(key).addListener(_scheduleLookalikes);
    }
    _lookalikesArmed = widget.contactId == null;
    _load();
  }

  @override
  void dispose() {
    _lookalikeTimer?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Ask once the typing pauses, not on every keystroke.
  void _scheduleLookalikes() {
    if (!_lookalikesArmed) return;
    _lookalikeTimer?.cancel();
    _lookalikeTimer = Timer(const Duration(milliseconds: 400), _askLookalikes);
  }

  /// What is on file under what has been typed so far. Nothing said
  /// until there is something worth asking about, and a lookup that
  /// fails is silence rather than a snackbar in the way of the typing:
  /// the database says it again, harder, if a duplicate is made
  /// through `create_contact_as`, and links the record on Save
  /// whatever this showed.
  Future<void> _askLookalikes() async {
    final repo = ref.read(repoProvider);
    if (repo == null || !mounted) return;
    String? typed(String key) {
      final v = _c(key).text.trim();
      return v.isEmpty ? null : v;
    }

    final name = _c('name').text;
    if (!worthAskingAbout(
      name: name,
      registrationNo: typed('registrationNo'),
      tin: typed('tin'),
      idValue: typed('idValue'),
    )) {
      if (_lookalikes.isNotEmpty) setState(() => _lookalikes = const []);
      return;
    }
    final ask = ++_lookalikeAsk;
    try {
      final rows = await repo.contactLookalikes(
        contactType: _contactType,
        name: name.trim(),
        registrationNo: typed('registrationNo'),
        tin: typed('tin'),
        idType: _idType,
        idValue: typed('idValue'),
        excludeId: widget.contactId,
      );
      // A later question has been asked; its answer is the one to show.
      if (!mounted || ask != _lookalikeAsk) return;
      setState(() => _lookalikes = rows.map(Lookalike.fromJson).toList());
    } catch (_) {
      // Left as it was.
    }
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
        _c('oldRegistrationNo').text = contact.oldRegistrationNo ?? '';
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
        _customFields = contact.customFields;
        _entityType = contact.entityType;
        _idType = contact.idType ?? 'BRN';
        _stateCode = contact.stateCode;
        _tinValid = contact.isTinVerified ? true : null;
        _loading = false;
      });
      _lookalikesArmed = true;
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
        ).showSnackBar(SnackBar(content: Text('Could not load contact: ${errorText(e)}')));
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
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    } finally {
      if (mounted) setState(() => _statementBusy = false);
    }
  }

  /// The other statement: everything that happened in a period.
  ///
  /// Offered beside the open-item one rather than instead of it, because
  /// the two answer different questions and a customer holding the wrong
  /// one cannot tell. `report_statement_of_account` (0624) built this
  /// and nothing called it until now.
  ///
  /// Customer side only, because the function is — it reads
  /// `sales_documents` and `receipts`. The menu does not offer it to a
  /// supplier.
  Future<void> _downloadBroughtForward() async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(repoProvider);
    final org = ref.read(currentOrgProvider).valueOrNull;
    if (repo == null || org == null || widget.contactId == null) return;

    final today = DateTime.now();
    final suggested = statementDefaultPeriod(today);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(
        start: suggested.from,
        end: suggested.to,
      ),
      helpText: 'Statement period',
    );
    if (picked == null || !mounted) return;

    setState(() => _statementBusy = true);
    try {
      final contact = await repo.contact(widget.contactId!);
      final lines = await repo.statementOfAccount(
        contactId: widget.contactId!,
        from: picked.start,
        to: picked.end,
      );

      // Checked before the document is written, not after it is sent.
      // The running balance comes down from the database and the page
      // prints it; if it disagrees with the movements printed beside
      // it, the customer is being asked for a figure nothing on the
      // page explains, and the right response is to say so rather than
      // to produce the document anyway.
      if (!statementAddsUp(lines)) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'The running balance does not agree with the transactions '
              'under it, so the statement was not produced. Please report '
              'this.',
            ),
          ),
        );
        return;
      }

      final bytes = await buildBroughtForwardPdf(
        org: org,
        contact: contact,
        lines: lines,
        from: picked.start,
        to: picked.end,
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
        'statement-$stem-${Fmt.iso(picked.start)}-to-'
            '${Fmt.iso(picked.end)}.pdf',
        'application/pdf',
        bytes,
        what: 'Statement of account',
        detail: '${contact.name}, '
            '${statementPeriodLabel(picked.start, picked.end)}',
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
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
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
    oldRegistrationNo: _nullIfEmpty(_c('oldRegistrationNo').text),
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
    entityType: _entityType ?? 'sdn_bhd',
    // `?? 0` and not a guess: `_creditLimitProblem` has already
    // refused anything `typedNumber` will not read, so the only text
    // that reaches here and comes back null is an empty field -- which
    // is the same no-limit the helper text offers.
    creditLimit: Fmt.typedNumber(_c('creditLimit').text) ?? 0,
    creditHold: _creditHold,
    receivableAccountId: _receivableAccountId,
    payableAccountId: _payableAccountId,
    priceLevelId: _priceLevelId,
    customFields: _customFields,
  );

  static String? _nullIfEmpty(String v) => v.trim().isEmpty ? null : v.trim();

  /// What is wrong with the credit limit as typed, if anything.
  ///
  /// Empty is allowed and means the same as zero, which is what the
  /// field's helper text promises. Everything else has to be a figure,
  /// because the alternative -- the old `?? 0` -- turned a mistyped
  /// limit into no limit at all.
  static String? _creditLimitProblem(String raw) {
    if (raw.trim().isEmpty) return null;
    final value = Fmt.typedNumber(raw);
    if (value == null) return 'Enter an amount, or leave it empty for none.';
    if (value < 0) return 'A credit limit cannot be below zero.';
    return null;
  }

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
        // Last, and only when the form still says what the register
        // said. See `_ssmStillMatches`.
        await _stampSsm(saved.id);
      },
      successMessage: 'Contact saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(contactsProvider);
      Navigator.of(context).maybePop();
    }
  }

  /// `0654`. Delete this contact, having asked.
  ///
  /// Leaves the screen only when it actually went. A refusal keeps the
  /// form open with everything on it: the likeliest next thing somebody
  /// does after "3 sales documents point at this" is go and look at
  /// them, and dropping them back on a list first would be a step
  /// taken away rather than one saved.
  Future<void> _delete() async {
    final gone = await confirmAndDeleteContact(
      context,
      ref,
      id: widget.contactId!,
      name: _c('name').text,
    );
    if (!gone || !mounted) return;
    ref.invalidate(contactsProvider);
    Navigator.of(context).maybePop();
  }

  /// Asks SSM's register who this company is.
  ///
  /// Seeded with whatever is already on the form — a registration
  /// number if one is typed, because the register matches a number
  /// exactly and a name only approximately.
  ///
  /// What comes back fills the name and both registration numbers, and
  /// seeds `idValue` only when it is empty: a TIN somebody entered
  /// deliberately for e-Invoice is not this button's to replace. The
  /// same rule the database function follows, so the form and the save
  /// cannot disagree.
  Future<void> _lookUpSsm() async {
    final typed = _nullIfEmpty(_c('registrationNo').text) ?? _c('name').text;
    setState(() => _ssmBusy = true);
    // Entity Search asks WHICH register first (0606). It used to go
    // straight to SSM, which is the right register for a company and
    // the wrong one for an audit firm or a law firm — and a contact is
    // as often one of those.
    final chosen = await showEntitySearch(
      context,
      initialQuery: SsmQueryHints.bestQuery(typed),
    );
    if (!mounted) return;
    setState(() => _ssmBusy = false);
    if (chosen == null) return;

    setState(() {
      _ssmChosen = chosen;
      _c('name').text = chosen.name;
      if (chosen.regNo != null) _c('registrationNo').text = chosen.regNo!;
      // Only when the registry returned one. An older number already
      // on file is still true when a search result is silent about it
      // — the same rule `set_contact_ssm_entity` follows, so the form
      // and the save cannot disagree.
      if (chosen.regNoOld != null) {
        _c('oldRegistrationNo').text = chosen.regNoOld!;
      }
      if (_nullIfEmpty(_c('idValue').text) == null && chosen.regNo != null) {
        _c('idValue').text = chosen.regNo!;
        _idType = 'BRN';
      }
      // A name that came from the registry is the legal name by
      // definition, and the e-Invoice uses that field when it differs.
      if (_nullIfEmpty(_c('legalName').text) == null) {
        _c('legalName').text = chosen.name;
      }
      // The TIN was checked against a number that has just changed.
      _tinValid = null;
    });
    _scheduleLookalikes();
  }

  bool get _ssmStillMatches => ssmStillMatches(
    chosen: _ssmChosen,
    name: _c('name').text,
    registrationNo: _c('registrationNo').text,
  );

  /// Records the registry's answer against the saved contact.
  ///
  /// After the save and not instead of it: the function needs a contact
  /// id, and a new contact has none until `saveContact` returns.
  Future<void> _stampSsm(String contactId) async {
    if (!_ssmStillMatches) return;
    await ref.read(ssmLookupProvider).saveToContact(contactId, _ssmChosen!);
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
        ).showSnackBar(SnackBar(content: Text(errorText(e))));
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
          //
          // A customer gets a CHOICE of the two, because there are two
          // and they are not substitutes: the open-item one lists what
          // is still unpaid, the brought-forward one lists everything
          // that happened in a period with a balance carried down. A
          // supplier gets the one button, because
          // `report_statement_of_account` reads the sales side only and
          // there is no supplier form of the second document to offer.
          if (widget.contactId != null)
            if (_contactType == 'supplier')
              IconButton(
                key: const ValueKey('contact-statement'),
                tooltip: 'Statement of what we owe',
                icon: const Icon(Icons.request_quote_outlined, size: 20),
                onPressed: _statementBusy ? null : _downloadStatement,
              )
            else
              PopupMenuButton<String>(
                key: const ValueKey('contact-statement-menu'),
                tooltip: 'Statement of account',
                icon: const Icon(Icons.request_quote_outlined, size: 20),
                enabled: !_statementBusy,
                onSelected: (v) => v == 'open'
                    ? _downloadStatement()
                    : _downloadBroughtForward(),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    key: ValueKey('statement-open-item'),
                    value: 'open',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('What is still unpaid'),
                      subtitle: Text('Open-item statement, as at today'),
                    ),
                  ),
                  PopupMenuItem(
                    key: ValueKey('statement-brought-forward'),
                    value: 'brought',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('Everything in a period'),
                      subtitle: Text(
                        'Brought-forward statement, with a running balance',
                      ),
                    ),
                  ),
                ],
              ),
          // `0654`. The same delete as the one on the row in the list,
          // through the same warning and the same refusal, and only on
          // a contact that has been saved -- there is nothing to
          // delete before that, and the button would be a second
          // Cancel.
          if (widget.contactId != null && ref.watch(canWriteProvider))
            IconButton(
              key: const ValueKey('contact-delete'),
              tooltip: 'Delete this contact',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: _saving ? null : _delete,
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
          // An existing contact's boxes are drawn and empty until the
          // record arrives, which is exactly what a form skeleton is
          // for. A NEW one is not: the form opens at the entity-type
          // question and nothing is coming but a suggested code, so
          // outlining six fields would claim a shape the screen is
          // about to decide not to draw. That one keeps its circle,
          // for the reason `core/page_waiting.dart` gives.
          ? (widget.contactId == null
                ? const Center(child: CircularProgressIndicator())
                : const SingleChildScrollView(
                    child: PageBody(
                      maxWidth: 760,
                      child: Padding(
                        padding: EdgeInsets.only(top: Space.lg),
                        child: FormSkeleton(fields: 6),
                      ),
                    ),
                  ))
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
                          isExpanded: true,
                          initialValue: _contactType,
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
                            _scheduleLookalikes();
                          },
                        ),
                      ),
                      // ----------------------------------------------
                      // What kind of business, BEFORE the name
                      //
                      // The order is the point. It used to default to
                      // Sdn Bhd below the name, which made the commonest
                      // kind the one nobody was ever asked about: a sole
                      // proprietor typed in quickly was filed as a
                      // private limited company and nothing said so.
                      //
                      // Asking first also makes the registry search
                      // mean something. `Entity Search` searches by
                      // kind, and a search that knows it is looking for
                      // an enterprise is a different search from one
                      // that does not.
                      // ----------------------------------------------
                      const SizedBox(height: 14),
                      _EntityTypeField(
                        value: _entityType,
                        onChanged: (v) => setState(() => _entityType = v),
                      ),
                      if (_entityType == null)
                        Padding(
                          padding: const EdgeInsets.only(top: Space.sm),
                          child: Text(
                            'Choose what kind of business this is. The rest '
                            'of the form follows.',
                            key: const ValueKey('contact-entity-first'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: context.scheme.onSurfaceVariant,
                                ),
                          ),
                        ),

                      // Everything below waits for that answer. On an
                      // EXISTING contact it is already answered, so the
                      // form opens whole.
                      if (_entityType != null) ...[
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _c('name'),
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(labelText: 'Name *'),
                        validator: (v) =>
                            (v ?? '').trim().isEmpty ? 'Enter a name' : null,
                      ),
                      // The registry, offered where the name is typed
                      // rather than beside the registration number.
                      // Somebody who knows the number does not need
                      // this; somebody with a letterhead and a
                      // half-remembered name is who it is for.
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('contact-ssm-lookup'),
                          onPressed: _ssmBusy ? null : _lookUpSsm,
                          icon: const Icon(
                            Icons.travel_explore_outlined,
                            size: 18,
                          ),
                          label: Text(
                            _ssmChosen == null
                                ? 'Entity Search'
                                : 'Entity Search again',
                          ),
                        ),
                      ),
                      if (_ssmChosen != null && _ssmStillMatches)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Space.sm),
                          child: Row(
                            children: [
                              Icon(
                                Icons.verified_outlined,
                                size: 16,
                                color: context.colors.success,
                              ),
                              const SizedBox(width: Space.xs),
                              Expanded(
                                child: Text(
                                  'From the register: '
                                  '${_ssmChosen!.registrationDisplay}'
                                  '${_ssmChosen!.entityType == null ? '' : ' · ${_ssmChosen!.entityType}'}'
                                  '. Saving records that it was checked.',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _c('legalName'),
                        decoration: const InputDecoration(
                          labelText: 'Legal name',
                          helperText: 'Used on e-Invoices when it differs',
                        ),
                      ),
                      ContactLookalikesNotice(rows: _lookalikes),

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
                      TextFormField(
                        key: const ValueKey('contact-old-registration'),
                        controller: _c('oldRegistrationNo'),
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: oldIdentificationLabel,
                          hintText: oldIdentificationHint,
                          helperText: oldIdentificationHelp,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _Pair(
                        left: DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _idType,
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
                              setState(() {
                                _idType = v ?? 'BRN';
                                _scheduleLookalikes();
                              }),
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
                          initialValue: _stateCode,
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
                        error: (e, _) => Text(errorText(e)),
                      ),

                      const SizedBox(height: 24),
                      const SectionHeader('Commercial terms'),
                      // Validated, and that is not a nicety here.
                      //
                      // This used to be `double.tryParse(text) ?? 0`
                      // with nothing refusing anything, and zero is the
                      // OFF position on this particular field: the
                      // helper text below says so, and `0467` agrees --
                      // `if coalesce(v_limit, 0) <= 0 then return new`.
                      //
                      // So a limit typed as "10,000", which is how the
                      // figure is written, saved as nought and the
                      // customer somebody was trying to cap came out
                      // with NO limit at all. No error, no warning; the
                      // field only admitted to it on the next load, as
                      // "0.00".
                      //
                      // It reads the comma now, and refuses what it
                      // cannot read rather than substituting for it.
                      TextFormField(
                        controller: _c('creditLimit'),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        validator: (v) => _creditLimitProblem(v ?? ''),
                        autovalidateMode: AutovalidateMode.onUserInteraction,
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
                        Builder(
                          builder: (context) {
                            final levels =
                                ref.watch(priceLevelsProvider).value ??
                                const <Map<String, dynamic>>[];
                            return SearchablePicker<String>(
                              options: [
                                for (final l in levels)
                                  PickerOption<String>(
                                    value: l['id'] as String,
                                    label: l['name'] as String,
                                    keywords: [
                                      if (l['code'] != null) '${l['code']}',
                                    ],
                                  ),
                              ],
                              value: levels.any((l) => l['id'] == _priceLevelId)
                                  ? _priceLevelId
                                  : null,
                              label: 'Price level',
                              helperText: 'What this customer is quoted',
                              allowEmpty: true,
                              emptyLabel: 'Standard',
                              createLabel: 'Add price level',
                              onCreate: (typed) => quickAdd(
                                context,
                                title: 'New price level',
                                blurb: 'Not on the list yet. Prices for it '
                                    'are set on each item.',
                                nameHint: 'Wholesale',
                                codeLabel: 'Code',
                                seed: typed,
                                save: ({required name, code}) async {
                                  final id = await ref
                                      .read(repoProvider)!
                                      .createQuickRow(
                                        QuickAddList.priceLevel,
                                        name: name,
                                        code: code,
                                      );
                                  ref.invalidate(priceLevelsProvider);
                                  return id;
                                },
                              ),
                              onChanged: (v) =>
                                  setState(() => _priceLevelId = v),
                            );
                          },
                        ),
                      // The boxes this company added for itself. It
                      // renders nothing at all where none are defined,
                      // which is most companies.
                      CustomFieldsSection(
                        entity: 'contact',
                        values: _customFields,
                        onChanged: (v) =>
                            setState(() => _customFields = v),
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
                        Builder(
                          builder: (context) {
                            // `my_group_companies` includes the company
                            // you are standing in, flagged is_current.
                            // A contact of this company standing for
                            // this company is not a thing, so it is not
                            // offered.
                            final sisters =
                                (ref.watch(groupCompaniesProvider).value ??
                                        const <Map<String, dynamic>>[])
                                    .where((o) => o['is_current'] != true)
                                    .toList();
                            return SearchablePicker<String>(
                              options: [
                                for (final o in sisters)
                                  PickerOption<String>(
                                    value: '${o['org_id']}',
                                    label: '${o['name']}',
                                  ),
                              ],
                              value: sisters.any(
                                (o) => '${o['org_id']}' == _linkedOrgId,
                              )
                                  ? _linkedOrgId
                                  : null,
                              label: 'Company in this group',
                              helperText:
                                  'Links trading with a sister company so it '
                                  'can be eliminated on consolidation',
                              allowEmpty: true,
                              emptyLabel: 'Not a group company',
                              onChanged: (v) =>
                                  setState(() => _linkedOrgId = v),
                            );
                          },
                        ),
                      // Only on a saved contact: a person or an address
                      // needs a contact_id to hang off, and there isn't
                      // one until this has been saved once.
                      if (widget.contactId != null)
                        ContactExtras(contactId: widget.contactId!),
                      // 0493. Only on a saved contact, for the same
                      // reason as the extras above: a portal hangs off
                      // a contact_id, and there isn't one until this
                      // has been saved once.
                      if (widget.contactId != null)
                        CustomerPortalCard(
                          contactId: widget.contactId!,
                          contactType: _contactType,
                          email: _c('email').text.trim(),
                        ),
                      // 0626, and on every contact rather than only on
                      // customers: a SUPPLIER's TIN is needed too, for
                      // the self-billed e-Invoice, and a link that
                      // appeared for one kind of contact and not the
                      // other would be read as a bug rather than as a
                      // rule.
                      if (widget.contactId != null)
                        TaxDetailsCard(
                          contactId: widget.contactId!,
                          email: _c('email').text.trim(),
                        ),
                      const SizedBox(height: 40),
                      ],
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
      child: SearchablePicker<String>(
        options: [
          for (final a in choices)
            PickerOption<String>(
              value: a.id,
              label: '${a.code} — ${a.name}',
              // The number is what an accountant knows the account by,
              // and it is already in the label; the name is there for
              // everybody else. Both are searched either way.
              keywords: [a.code, a.name],
            ),
        ],
        value: choices.any((a) => a.id == current) ? current : null,
        label: receivable ? 'Receivable account' : 'Payable account',
        helperText: 'Leave it alone unless this one is kept apart',
        allowEmpty: true,
        emptyLabel: kDefaultControlAccount,
        // No offer to add one. A control account is not something to
        // conjure mid-contact: it has a number in a numbered chart, a
        // type, and a place in the statements, and the Chart of
        // accounts screen is where all three are decided.
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

/// What kind of business, from the console-managed list.
///
/// `0605` turned `app.entity_type` from an enum into a table so a
/// platform administrator can add a kind without a deploy. This draws
/// whatever is on it and switched on for contacts.
///
/// While the list is loading it draws a disabled box rather than an
/// empty dropdown: an empty dropdown looks like a list with nothing on
/// it, and the answer is the gate for the rest of the form.
class _EntityTypeField extends ConsumerWidget {
  const _EntityTypeField({required this.value, required this.onChanged});

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(contactEntityTypesProvider);
    final kinds = async.valueOrNull ?? const <EntityType>[];

    if (kinds.isEmpty) {
      return InputDecorator(
        decoration: InputDecoration(
          labelText: 'Kind of business *',
          helperText: async.hasError
              ? 'The list could not be read. Try again in a moment.'
              : 'Loading the list…',
        ),
        child: const SizedBox(height: 20),
      );
    }

    // A value that is no longer on the list — a kind switched off after
    // this contact was filed — is kept as its own entry rather than
    // silently becoming null, which would look like somebody had never
    // chosen one.
    final codes = kinds.map((k) => k.code).toSet();
    final retired = value != null && !codes.contains(value);

    return DropdownButtonFormField<String>(
      key: const ValueKey('contact-entity-type'),
      isExpanded: true,
      initialValue: value,
      decoration: const InputDecoration(
        labelText: 'Kind of business *',
        helperText: 'Asked first: it decides what the rest of the form '
            'is for.',
      ),
      items: [
        for (final k in kinds)
          DropdownMenuItem(value: k.code, child: Text(k.display)),
        if (retired)
          DropdownMenuItem(value: value, child: Text('$value (no longer offered)')),
      ],
      onChanged: onChanged,
      validator: (v) => v == null ? 'Choose a kind of business' : null,
    );
  }
}
