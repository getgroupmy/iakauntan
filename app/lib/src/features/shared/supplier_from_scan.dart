import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/ocr_repository.dart';

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
  if (name == null || name.isEmpty) return const SupplierMatch(SupplierOutcome.ask);

  final repo = ref.read(repoProvider);
  if (repo == null) return const SupplierMatch(SupplierOutcome.ask);

  final List<Contact> candidates;
  try {
    // Searched on the name as printed. The search is a substring match
    // in the database, so a letterhead carrying the registration number
    // after the name finds nothing — hence the narrowing below rather
    // than a single clever query.
    candidates = await repo.contacts(type: 'supplier', search: _searchable(name));
  } catch (_) {
    // A lookup that failed is not an answer. Ask the usual way rather
    // than offering to create a duplicate of something that is probably
    // already there.
    return const SupplierMatch(SupplierOutcome.ask);
  }

  final exact = _bestMatches(candidates, name, read?.supplierRegistrationNo);
  if (exact.length == 1) return SupplierMatch(SupplierOutcome.resolved, exact.first.id);
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
      if (!context.mounted) return const SupplierMatch(SupplierOutcome.discarded);
      final id = await _create(context, ref, read!);
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
        .where((c) =>
            c.registrationNo != null && _digits(c.registrationNo!) == wanted)
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

String _digits(String s) => s.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();

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
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: Space.sm),
              for (final (label, value) in detail)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    SizedBox(
                      width: 92,
                      child: Text(label,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    Expanded(
                      child: Text(value!,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ]),
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
                        Text('• ${c.name}',
                            style: const TextStyle(fontSize: 13)),
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
          onPressed: () =>
              Navigator.pop(context, _NotFoundAnswer.discard),
          child: const Text('Discard'),
        ),
        if (near.isNotEmpty)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _NotFoundAnswer.choose),
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
) async {
  final repo = ref.read(repoProvider)!;
  final messenger = ScaffoldMessenger.of(context);

  try {
    final address = read.supplierAddress?.split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    // The code is generated rather than typed, so a collision with one
    // that reached the table another way is this code's problem to
    // solve and not something to show somebody holding a receipt.
    final saved = await repo.createContactWithGeneratedCode(Contact(
      id: '',
      code: '',
      name: read.supplierName!.trim(),
      contactType: 'supplier',
      registrationNo: read.supplierRegistrationNo,
      // The SSM number is also what identifies the party on an
      // e-Invoice, so it seeds the identity field rather than leaving it
      // for somebody to copy across by hand.
      idValue: read.supplierRegistrationNo,
      sstRegistrationNo: read.supplierTaxId,
      email: read.supplierEmail,
      phone: read.supplierPhone,
      addressLine1: address == null || address.isEmpty ? null : address.first,
      addressLine2: address == null || address.length < 2
          ? null
          : address.skip(1).join(', '),
      currency: read.currency ?? 'MYR',
    ));
    return saved.id;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not create the supplier: $e')),
    );
    return null;
  }
}
