import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/ocr_repository.dart';
import '../../data/ssm_repository.dart';
import 'ssm_entity_picker.dart';
import 'ssm_query_hints.dart';

/// Finding the supplier a scanned document came from, and offering to
/// create it when there isn't one.
///
/// A bill names its supplier on the letterhead. Making somebody search
/// for a name that is already on screen is work the machine should have
/// done — so it is looked up in the background, and the only time
/// anybody is asked anything is when the answer is genuinely in doubt:
/// no match, or more than one.
///
/// Nothing is created silently. A contact record is a lasting thing that
/// turns up in reports, on statements and in the e-Invoice submission,
/// and creating one because a reader misread a letterhead is a mess
/// somebody has to clean up later. So a missing supplier is a question,
/// with the details on screen before the press.

/// What came of trying to find the supplier.
enum SupplierOutcome {
  /// Found, or created, and the identifier is on [SupplierMatch.contactId].
  resolved,

  /// The person chose to abandon the whole capture.
  discarded,

  /// Nothing decided here — the caller should ask the usual way.
  ask,
}

class SupplierMatch {
  const SupplierMatch(this.outcome, [this.contactId]);

  final SupplierOutcome outcome;
  final String? contactId;
}

/// Looks the supplier up, and asks only when it has to.
Future<SupplierMatch> resolveSupplier(
  BuildContext context,
  WidgetRef ref,
  OcrExtraction? read,
) async {
  final name = read?.supplierName?.trim();
  if (name == null || name.isEmpty) {
    return const SupplierMatch(SupplierOutcome.ask);
  }

  final repo = ref.read(repoProvider);
  if (repo == null) return const SupplierMatch(SupplierOutcome.ask);

  final List<Contact> candidates;
  try {
    // Searched on the name as printed. The search is a substring match
    // in the database, so a letterhead carrying the registration number
    // after the name finds nothing — hence the narrowing below rather
    // than a single clever query.
    candidates = await repo.contacts(
      type: 'supplier',
      search: _searchable(name),
    );
  } catch (_) {
    // A lookup that failed is not an answer. Ask the usual way rather
    // than offering to create a duplicate of something that is probably
    // already there.
    return const SupplierMatch(SupplierOutcome.ask);
  }

  final exact = _bestMatches(candidates, name, read?.supplierRegistrationNo);
  if (exact.length == 1) {
    return SupplierMatch(SupplierOutcome.resolved, exact.first.id);
  }
  if (exact.length > 1) return const SupplierMatch(SupplierOutcome.ask);

  // Nothing that could be called a match. Two of these on screen at once
  // would be confusing, so the near-misses are shown inside the question
  // rather than as a second dialog.
  if (!context.mounted) return const SupplierMatch(SupplierOutcome.discarded);
  final answer = await showDialog<_NotFoundAnswer>(
    context: context,
    builder: (_) => _SupplierNotFound(read: read!, near: candidates),
  );

  switch (answer) {
    case _NotFoundAnswer.create:
      if (!context.mounted) {
        return const SupplierMatch(SupplierOutcome.discarded);
      }
      final id = await createSupplierFromScan(context, ref, read);
      return id == null
          ? const SupplierMatch(SupplierOutcome.discarded)
          : SupplierMatch(SupplierOutcome.resolved, id);
    case _NotFoundAnswer.choose:
      return const SupplierMatch(SupplierOutcome.ask);
    case _NotFoundAnswer.discard:
    case null:
      return const SupplierMatch(SupplierOutcome.discarded);
  }
}

/// Create a supplier, reviewing what was read first.
///
/// Public because there are two ways to arrive here and they must not
/// have two ideas of how it is done. One is the "supplier not found"
/// question, which happens when a name WAS read and matched nothing.
/// The other is the plain picker, which is where somebody lands when
/// nothing was read at all — and until this existed that dialog had no
/// create button and told people to "add the supplier under Contacts
/// first", which means leaving the scan, going somewhere else, and
/// starting again.
///
/// [read] may be null or empty. A scan that failed still leaves
/// somebody holding a bill from a supplier who is not on file, and that
/// is the moment they most need to add one.
Future<String?> createSupplierFromScan(
  BuildContext context,
  WidgetRef ref,
  OcrExtraction? read,
) async {
  // Reviewed and CORRECTED before it is written, not after. See
  // `_SupplierDraft`.
  final draft = await showDialog<_Draft>(
    context: context,
    builder: (_) => _SupplierDraft(read: read),
  );
  if (draft == null || !context.mounted) return null;
  return _create(context, ref, draft.read, draft.ssm);
}

/// What the review dialog hands back.
///
/// The extraction is what gets written; [ssm] is only there so a
/// supplier confirmed against the register can be STAMPED as confirmed
/// after it exists. Two values rather than one because a reading and a
/// registry match are different kinds of fact, and merging them here
/// would lose which was which.
class _Draft {
  const _Draft(this.read, this.ssm);

  final OcrExtraction read;
  final SsmEntity? ssm;
}

/// The part of a printed name worth searching on.
///
/// A letterhead reads `TM Technology Services Sdn Bhd 200201003726
/// (571389-H)`, and searching for all of that matches nothing. The
/// registration numbers and anything bracketed come off; what is left is
/// the trading name, which is what somebody typed when they set the
/// supplier up.
String _searchable(String name) {
  var out = name
      .replaceAll(RegExp(r'\((?:[^()]*)\)'), ' ')
      .replaceAll(RegExp(r'(?<![\d-])(?:19|20)\d{10}(?![\d-])'), ' ')
      .replaceAll(RegExp(r'(?<![\w-])\d{5,8}\s*-\s*[A-Za-z](?![\w-])'), ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
  // Still too long to be a name? Search on the leading words, which is
  // where a trading name sits.
  final words = out.split(' ');
  if (words.length > 6) out = words.take(6).join(' ');
  return out;
}

/// A name reduced to what two spellings of the same company share.
String _key(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\((?:[^()]*)\)'), ' ')
    .replaceAll(RegExp(r'\bsdn\.?\s*bhd\.?\b'), 'sdn bhd')
    .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
    .replaceAll(RegExp(r'\s{2,}'), ' ')
    .trim();

/// Which of the candidates is actually this supplier.
///
/// A registration number is an identity and a name is a label, so a
/// matching SSM number settles it outright even where the names differ —
/// which they will, because one was typed by a person and the other read
/// off a letterhead.
List<Contact> _bestMatches(List<Contact> candidates, String name, String? reg) {
  if (reg != null && reg.trim().isNotEmpty) {
    final wanted = _digits(reg);
    final byReg = candidates
        .where(
          (c) =>
              c.registrationNo != null && _digits(c.registrationNo!) == wanted,
        )
        .toList();
    if (byReg.isNotEmpty) return byReg;
  }

  final wanted = _key(name);
  final byName = candidates.where((c) => _key(c.name) == wanted).toList();
  if (byName.isNotEmpty) return byName;

  // One contains the other: `TM Technology Services Sdn Bhd` against a
  // record saved as `TM Technology Services`.
  return candidates.where((c) {
    final k = _key(c.name);
    if (k.length < 4) return false;
    return wanted.contains(k) || k.contains(wanted);
  }).toList();
}

String _digits(String s) =>
    s.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();

enum _NotFoundAnswer { create, choose, discard }

class _SupplierNotFound extends StatelessWidget {
  const _SupplierNotFound({required this.read, required this.near});

  final OcrExtraction read;

  /// Anything the search turned up that was not good enough to call a
  /// match. Shown because "supplier not found" is hard to believe when
  /// something very like it is on file, and creating a second record for
  /// the same company is the expensive mistake here.
  final List<Contact> near;

  @override
  Widget build(BuildContext context) {
    final detail = <(String, String?)>[
      ('SSM no', read.supplierRegistrationNo),
      ('Tax number', read.supplierTaxId),
      ('Email', read.supplierEmail),
      ('Phone', read.supplierPhone),
      ('Address', read.supplierAddress),
    ].where((row) => row.$2 != null).toList();

    return AlertDialog(
      title: const Text('Supplier not found'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Nothing on file matches this document. It can be created '
                'from what was read:',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: Space.md),
              Text(
                read.supplierName ?? '—',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: Space.sm),
              for (final (label, value) in detail)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 92,
                        child: Text(
                          label,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          value!,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              if (near.isNotEmpty) ...[
                const SizedBox(height: Space.md),
                Container(
                  padding: const EdgeInsets.all(Space.md),
                  decoration: BoxDecoration(
                    color: context.colors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        near.length == 1
                            ? 'There is a supplier with a similar name:'
                            : 'There are suppliers with similar names:',
                        style: const TextStyle(fontSize: 13),
                      ),
                      const SizedBox(height: 4),
                      for (final c in near.take(4))
                        Text(
                          '• ${c.name}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      const SizedBox(height: 4),
                      const Text(
                        'Choose an existing one instead if this is the same '
                        'company under another spelling.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _NotFoundAnswer.discard),
          child: const Text('Discard'),
        ),
        if (near.isNotEmpty)
          TextButton(
            onPressed: () => Navigator.pop(context, _NotFoundAnswer.choose),
            child: const Text('Choose existing'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _NotFoundAnswer.create),
          child: const Text('Create and continue'),
        ),
      ],
    );
  }
}

/// Creates the supplier from what the document said.
///
/// The address goes in whole rather than split across street, city and
/// postcode. A Malaysian address on a letterhead runs to four lines in
/// no fixed order, and a wrongly split one is worse than an unsplit one
/// because it looks deliberate — the contact editor is where somebody
/// tidies it, with the paper in front of them.
Future<String?> _create(
  BuildContext context,
  WidgetRef ref,
  OcrExtraction read,
  SsmEntity? ssm,
) async {
  final repo = ref.read(repoProvider)!;
  final messenger = ScaffoldMessenger.of(context);

  try {
    // '' is a field somebody cleared in `_SupplierDraft`; see `_text`
    // there. Everywhere else it is simply an absent field, and both
    // should reach the contact as null rather than as an empty string
    // that reads on a statement as a blank line somebody typed.
    String? clean(String? v) {
      final t = v?.trim() ?? '';
      return t.isEmpty ? null : t;
    }

    final address = clean(
      read.supplierAddress,
    )?.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

    // The code is generated rather than typed, so a collision with one
    // that reached the table another way is this code's problem to
    // solve and not something to show somebody holding a receipt.
    final saved = await repo.createContactWithGeneratedCode(
      Contact(
        id: '',
        code: '',
        name: clean(read.supplierName) ?? '',
        contactType: 'supplier',
        registrationNo: clean(read.supplierRegistrationNo),
        // The SSM number is also what identifies the party on an
        // e-Invoice, so it seeds the identity field rather than leaving it
        // for somebody to copy across by hand.
        idValue: clean(read.supplierRegistrationNo),
        sstRegistrationNo: clean(read.supplierTaxId),
        email: clean(read.supplierEmail),
        phone: clean(read.supplierPhone),
        addressLine1: address == null || address.isEmpty ? null : address.first,
        addressLine2: address == null || address.length < 2
            ? null
            : address.skip(1).join(', '),
        currency: read.currency ?? 'MYR',
      ),
    );
    // Confirmed against the register while the draft was being
    // reviewed, so the contact records that it was checked rather than
    // only carrying a number somebody agreed with. After the create,
    // because the function needs an id.
    //
    // Its own failure, deliberately. The supplier exists by this point
    // and the bill can be captured against it; a stamp that did not
    // land leaves `ssm_verified_at` null and nothing else. Letting it
    // fall into the catch below would report "could not create the
    // supplier" about a supplier that had just been created, and the
    // person would create a second one.
    if (ssm != null) {
      try {
        await ref.read(ssmLookupProvider).saveToContact(saved.id, ssm);
      } on SsmLookupException catch (e) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Supplier created, but the register check was not '
              'recorded: ${e.userMessage}',
            ),
          ),
        );
      }
    }
    return saved.id;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not create the supplier: $e')),
    );
    return null;
  }
}

/// The last look before a contact record exists.
///
/// The header of this file already says why: a contact is a lasting
/// thing that turns up in reports, on statements and in the e-Invoice
/// submission, and creating one because a reader misread a letterhead
/// is a mess somebody has to clean up later. That argument was written
/// down and then not acted on — the details were SHOWN and the button
/// wrote them unchanged, so a misread name became a permanent record
/// with no moment at which anybody could correct it.
///
/// The SSM number makes it more than cosmetic. It seeds `id_value`,
/// which is what identifies the party on an e-Invoice, so one wrong
/// digit is a submission LHDN rejects or, worse, attributes to another
/// company. A letterhead is exactly where a reader loses a digit.
///
/// Everything is pre-filled and everything is editable. Only the name
/// is required, because a contact with no name is not a contact and
/// everything else can be filled in later from the supplier's own
/// paperwork.
class _SupplierDraft extends StatefulWidget {
  const _SupplierDraft({required this.read});

  /// What the document said, or null when nothing was read. An empty
  /// form is still the right place to be: somebody is holding a bill
  /// from a supplier who is not on file.
  final OcrExtraction? read;

  @override
  State<_SupplierDraft> createState() => _SupplierDraftState();
}

class _SupplierDraftState extends State<_SupplierDraft> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.read?.supplierName?.trim() ?? '',
  );
  late final _reg = TextEditingController(
    text: widget.read?.supplierRegistrationNo ?? '',
  );
  late final _tax = TextEditingController(
    text: widget.read?.supplierTaxId ?? '',
  );
  late final _email = TextEditingController(
    text: widget.read?.supplierEmail ?? '',
  );
  late final _phone = TextEditingController(
    text: widget.read?.supplierPhone ?? '',
  );
  late final _address = TextEditingController(
    text: widget.read?.supplierAddress ?? '',
  );

  /// What the register answered, when somebody asked it. Carried out
  /// of the dialog so the contact can be stamped as confirmed; see
  /// `_Draft`.
  SsmEntity? _ssm;

  @override
  void dispose() {
    _name.dispose();
    _reg.dispose();
    _tax.dispose();
    _email.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  /// Empty string, not null, for a field somebody cleared.
  ///
  /// `OcrExtraction.copyWith` is written `supplierTaxId ?? this.supplierTaxId`,
  /// so passing null means "leave it alone" and there is no way through
  /// it to say "make this empty". Handing back '' says it, and `_create`
  /// turns '' back into null on the way into the contact — which keeps
  /// the one place that decides how a reading becomes a contact still
  /// the only place.
  ///
  /// Without this, clearing a misread SSM number in this dialog would
  /// silently keep the misread one, which is the exact failure the
  /// dialog exists to prevent.
  String _text(TextEditingController c) => c.text.trim();

  /// Asks the register, seeded with the best of what is on screen.
  ///
  /// A registration number first if there is one, because the register
  /// matches a number exactly; failing that the name; failing that
  /// whatever the reader saw, which on a bill whose supplier block was
  /// missed is the only place the company is named at all. That last
  /// case is the one somebody hits when a scan produced no supplier
  /// details and the dialog opened empty.
  Future<void> _lookUpSsm() async {
    final seed = SsmQueryHints.bestQuery(
      [
        if (_reg.text.trim().isNotEmpty) _reg.text.trim(),
        if (_name.text.trim().isNotEmpty) _name.text.trim(),
        widget.read?.rawText ?? '',
      ].firstWhere((s) => s.trim().isNotEmpty, orElse: () => ''),
    );

    final chosen = await showSsmEntityPicker(context, initialQuery: seed);
    if (chosen == null || !mounted) return;
    setState(() {
      _ssm = chosen;
      _name.text = chosen.name;
      if (chosen.regNo != null) _reg.text = chosen.regNo!;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create this supplier'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.read?.supplierName == null
                      // Nothing was read, so there is nothing to
                      // correct — but the SSM warning still applies,
                      // and it is the field people leave until later
                      // and then never fill in.
                      ? 'Nothing was read from the document, so this is '
                            'blank. The SSM number goes on every '
                            'e-Invoice raised against this supplier.'
                      : 'Read from the document. Correct anything wrong '
                            'before it is saved — this becomes a '
                            'permanent contact, and the SSM number goes '
                            'on every e-Invoice raised against it.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  key: const ValueKey('scan-supplier-name'),
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'A supplier needs a name.'
                      : null,
                ),
                const SizedBox(height: Space.sm),
                TextFormField(
                  key: const ValueKey('scan-supplier-reg'),
                  controller: _reg,
                  decoration: const InputDecoration(
                    labelText: 'SSM registration no.',
                    helperText: 'Identifies the supplier on an e-Invoice',
                  ),
                ),
                // The moment this is most worth doing. A number about
                // to seed `id_value` has come off a letterhead through
                // a reader, which is two chances to lose a digit, and
                // the register will say in one search whether it is a
                // real company's number.
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('scan-supplier-ssm'),
                    onPressed: _lookUpSsm,
                    icon: const Icon(Icons.travel_explore_outlined, size: 18),
                    label: const Text('Check the SSM register'),
                  ),
                ),
                if (_ssm != null)
                  Row(
                    children: [
                      Icon(
                        Icons.verified_outlined,
                        size: 16,
                        color: context.colors.success,
                      ),
                      const SizedBox(width: Space.xs),
                      Expanded(
                        child: Text(
                          'From the register: ${_ssm!.registrationDisplay}'
                          '${_ssm!.entityType == null ? '' : ' \u00b7 ${_ssm!.entityType}'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: Space.sm),
                TextFormField(
                  controller: _tax,
                  decoration: const InputDecoration(
                    labelText: 'SST or tax number',
                  ),
                ),
                const SizedBox(height: Space.sm),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    // Only a shape check, and only when something was
                    // typed. A remittance advice goes here, so a
                    // plainly broken address is worth catching; being
                    // strict about what an address may contain is not
                    // this dialog's business.
                    if (t.isEmpty) return null;
                    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$').hasMatch(t)
                        ? null
                        : 'That does not look like an email address.';
                  },
                ),
                const SizedBox(height: Space.sm),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone'),
                ),
                const SizedBox(height: Space.sm),
                TextFormField(
                  controller: _address,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Address'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('scan-supplier-save'),
          onPressed: () {
            if (!(_formKey.currentState?.validate() ?? false)) return;
            // Handed back as an extraction rather than a Contact so
            // `_create` stays the one place that decides how a reading
            // becomes a contact — the address splitting, the currency
            // default, the SSM number seeding `id_value`. Two places
            // deciding that is two places to fix it.
            Navigator.pop(
              context,
              _Draft(
                (widget.read ?? const OcrExtraction()).copyWith(
                  supplierName: _name.text.trim(),
                  supplierRegistrationNo: _text(_reg),
                  supplierTaxId: _text(_tax),
                  supplierEmail: _text(_email),
                  supplierPhone: _text(_phone),
                  supplierAddress: _text(_address),
                ),
                _ssm,
              ),
            );
          },
          child: const Text('Create supplier'),
        ),
      ],
    );
  }
}
