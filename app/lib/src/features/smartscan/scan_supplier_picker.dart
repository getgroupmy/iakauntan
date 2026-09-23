/// Choosing the supplier, and checking the bill is not already on the
/// books.
///
/// Both lived on the Bills list screen, because that is where the scan
/// button was. Neither is about a list of documents: they are steps in
/// turning a photograph into a record, which is what this module does
/// now. Moved rather than rewritten — `0628`'s duplicate check in
/// particular is a piece of judgement it took a report to arrive at,
/// and retyping it would be a chance to lose that.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/ocr_repository.dart';
import '../../data/repository.dart';
import '../documents/duplicate_bill.dart';
import '../shared/supplier_from_scan.dart';



/// Warns about a bill already on the books, and lets it go on anyway.
///
/// `0628`. Returns true to carry on. A check that REFUSED would refuse
/// a supplier's corrected re-issue and a genuine second delivery on one
/// day, and what people do with a check that is wrong a tenth of the
/// time is type the number differently — which destroys the only field
/// it runs on.
///
/// A lookup that fails is not a duplicate. It carries on: a network
/// error must not stop somebody entering a bill.
Future<bool> clearOfDuplicates(
  BuildContext context,
  WidgetRef ref, {
  required String contactId,
  required String docType,
  required OcrExtraction? read,
}) async {
  final number = read?.documentNo?.trim();
  final date = read?.documentDate;
  final total = read?.totalAmount;
  if ((number == null || number.isEmpty) && (date == null || total == null)) {
    return true;
  }

  final List<DuplicateBill> found;
  try {
    final rows = await ref.read(repoProvider)!.duplicatePurchaseDocuments(
      contactId: contactId,
      docType: docType,
      supplierDocNo: number,
      docDate: date,
      totalAmount: total,
    );
    found = [for (final r in rows) DuplicateBill.fromMap(r)];
  } catch (_) {
    return true;
  }
  if (found.isEmpty || !context.mounted) return found.isEmpty;

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.copy_all_outlined),
      title: Text(
        duplicateHeadline(found),
        key: const ValueKey('duplicate-headline'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            duplicateAdvice(found),
            key: const ValueKey('duplicate-advice'),
          ),
          const SizedBox(height: Space.md),
          for (final d in found)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                duplicateLine(d),
                key: ValueKey('duplicate-line-${d.id}'),
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('duplicate-stop'),
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Stop'),
        ),
        // Deliberately not styled as the primary action. Going on is
        // allowed and is sometimes right; it should not be the button
        // somebody presses without reading.
        TextButton(
          key: const ValueKey('duplicate-go-on'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Enter it anyway'),
        ),
      ],
    ),
  );
  return go ?? false;
}


/// Says so, rather than asking a question the paper cannot answer.
///
/// `0686`. A payment voucher was photographed into Bills and the screen
/// asked "which supplier?" with an empty search box. Every part of that
/// page was a company recording money LEAVING: its own letterhead, its
/// own voucher book, the EPF as payee. There is no supplier, and had
/// the reader guessed one, the letterhead would have become a contact
/// record of the firm itself and a payable it owed to itself.
///
/// So the reading is shown — a person can see at a glance whether the
/// machine read the right page — and the way out is the one the
/// document actually wants. Recording it as an expense is offered
/// first because for a voucher it is simply correct; choosing a
/// supplier anyway stays, because a bill whose letterhead was
/// unreadable is a real thing and this dialog must not become a wall.

Future<String?> pickSupplier(
  BuildContext context,
  WidgetRef ref,
  OcrExtraction? read, [
  ScanContactKind kind = ScanContactKind.supplier,
]) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SupplierPicker(read: read, kind: kind),
  );
}

class _SupplierPicker extends ConsumerStatefulWidget {
  const _SupplierPicker({this.read, this.kind = ScanContactKind.supplier});

  final ScanContactKind kind;

  /// What the document said. The name seeds the search and is shown as
  /// a reminder — never selected automatically. The rest of it is what
  /// pre-fills a supplier created from here, so the SSM number and the
  /// address the scan found are not thrown away just because the name
  /// matched nothing.
  final OcrExtraction? read;

  String? get readName => read?.supplierName;

  @override
  ConsumerState<_SupplierPicker> createState() => _SupplierPickerState();
}

class _SupplierPickerState extends ConsumerState<_SupplierPicker> {
  late final TextEditingController _search = TextEditingController(
    text: widget.readName ?? '',
  );
  late String _query = widget.readName ?? '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contacts = ref.watch(
      contactsProvider((type: widget.kind.type, search: _query)),
    );

    return AlertDialog(
      title: Text('Which ${widget.kind.one}?'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            if (widget.readName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Row(
                  children: [
                    const Icon(Icons.description_outlined, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'The document says “${widget.readName}”',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            TextField(
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Search ${widget.kind.one}s',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: Space.sm),
            Expanded(
              child: AsyncView(
                value: contacts,
                onRetry: () => ref.invalidate(
                  contactsProvider((type: widget.kind.type, search: _query)),
                ),
                loading: const LinearProgressIndicator(),
                skeleton: const ListSkeleton(rows: 6, leading: false),
                builder: (list) => list.isEmpty
                    ? const EmptyState(
                        icon: Icons.person_search_outlined,
                        title: 'No supplier matches',
                        // No longer "add the supplier under Contacts
                        // first". That meant leaving the scan, going
                        // somewhere else, and starting again — for the
                        // commonest case there is, a bill from somebody
                        // new.
                        message:
                            'Clear the search to see them all, or create '
                            'this one without leaving the scan.',
                      )
                    : ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) => ListTile(
                          dense: true,
                          title: Text(list[i].name),
                          subtitle: Text(
                            list[i].code,
                            style: const TextStyle(fontSize: 12),
                          ),
                          onTap: () => Navigator.pop(context, list[i].id),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        // The way out that did not exist. Somebody scanning a bill
        // from a supplier who is not on file used to be told to go to
        // Contacts and start again, which is the commonest case there
        // is — a new supplier is exactly when a bill needs scanning.
        TextButton.icon(
          key: const ValueKey('picker-new-supplier'),
          onPressed: () async {
            final id = await createSupplierFromScan(
              context,
              ref,
              widget.read,
              kind: widget.kind,
            );
            if (id != null && context.mounted) Navigator.pop(context, id);
          },
          icon: const Icon(Icons.add, size: 18),
          label: Text('New ${widget.kind.one}'),
        ),
        // No `Spacer()` between these two, however much this wants to
        // push Cancel to the other end. `AlertDialog.actions` are laid
        // out by an `OverflowBar`, which is not a Flex, and a `Spacer`
        // is an `Expanded` — which throws at layout in a parent that
        // cannot give it a flex. In a release web build that throw is
        // an `ErrorWidget`, and `ErrorWidget` renders as a plain grey
        // rectangle filling whatever space it is given. Which is to say
        // the whole dialog goes grey, with no message anywhere.
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// One thing the app bar offers, as a button or as a menu item.
///
/// [id] is only for the two that a test names; the rest are found by
/// their label.