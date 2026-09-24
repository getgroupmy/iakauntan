import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../data/attachments_repository.dart';
import '../../data/models.dart';
import '../../data/ocr_repository.dart';
import '../../data/scan_kinds_repository.dart';
import '../contacts/contact_editor.dart';
import '../documents/doc_types.dart';
import '../expenses/expenses_screen.dart' show showExpenseFromScan;
import '../shared/receipt_capture.dart';
import '../shared/scan_intake.dart';
import '../shared/supplier_from_scan.dart';
import 'scan_availability.dart';
import 'scan_blocked_dialog.dart';
import 'scan_destination.dart';
import 'scan_kind_sheet.dart';
import 'scan_supplier_picker.dart';

/// Scan, decide, verify, post — the one door.
///
/// This is the four flows the Bills list, the Expenses screen, the
/// Contacts screen and the bank reconciliation each owned, brought into
/// one place. They were not four flows because the work is different;
/// they were four flows because there were four buttons, and each knew
/// only about the destination it was standing on. The same receipt
/// became a bill or an expense depending on which screen somebody
/// happened to be looking at.
///
/// The order is the order of the work:
///
///   1. Capture and read — `showScanIntake`, unchanged.
///   2. Decide where it goes. The reader's own judgement first, then
///      the classifier's, then the person.
///   3. Get a contact where the destination needs one, because the
///      database refuses a bill without a supplier and finding that out
///      at the save is finding it out too late.
///   4. Create the record and re-point the capture at it.
///   5. Record what the paper became, so the inbox can say so. `0694`.
///
/// Step 5 is the one that did not exist. Every one of the old flows
/// created a record and left the scan row saying nothing, so a
/// photograph that quietly became nothing looked exactly like one that
/// posted a bill.
Future<void> runSmartScan(BuildContext context, WidgetRef ref) async {
  final kinds = ref.read(offeredScanKindsProvider).valueOrNull ?? const [];

  // Before the camera, not after it. A company that has never switched
  // scanning on used to find out by photographing a document and
  // getting a `FunctionException` in a snackbar — and then being asked
  // which kind of document the scan that never happened was.
  final block = scanBlock(
    ref.read(ocrStatusProvider).valueOrNull,
    canAdmin: ref.read(canAdminProvider),
  );
  if (block != null) {
    await showScanBlocked(context, block);
    return;
  }

  // Parked against expenses until the destination is known: it is the
  // table that asks least of the paper, and `refileAttachment` moves
  // the object as well as the row once there is somewhere to put it.
  final staged = await showScanIntake(
    context,
    ref,
    table: ScanDestination.unknown.table,
    title: 'Scan a document',
  );
  if (staged == null || !context.mounted) return;

  var destination = destinationFor(staged.read, kinds);

  // Nothing said what it is. Asked rather than guessed — a document
  // filed wrongly becomes a record somebody has to find and undo.
  if (destination == ScanDestination.unknown) {
    // Two different questions wearing one sheet. A reading that placed
    // nothing is "what is this?"; a capture that was never READ is "it
    // could not be read, and the file is kept — where do you want to
    // type it in?". Saying the first about the second is what put "the
    // reading could not place this document" under a scan that never
    // reached a reader.
    final chosen = await showScanKindSheet(
      context,
      read: staged.read,
      onView: _viewer(context, ref, staged.attachmentId),
      because: staged.read == null
          ? 'It could not be read, so there is nothing to fill in. The '
              'file is kept either way — choose where it goes and type '
              'the figures in.'
          : null,
    );
    if (chosen?.named != null && context.mounted) {
      await _recordNamedKind(context, ref, staged.attachmentId,
          chosen!.named!);
      return;
    }
    if (chosen?.to == null || !context.mounted) {
      // Backed out. THE FILE STAYS.
      //
      // It used to be deleted here, on the reasoning that a capture
      // nobody filed should not sit in the bucket attached to a record
      // that will never exist. That was the wrong end of the stick:
      // somebody who photographs a document and then closes a sheet has
      // not said "destroy this", and the reading was already paid for.
      // The inbox has a "Became nothing yet" filter for exactly these,
      // so it comes back with its image, its figures and "Create it
      // from what was read" still on it.
      //
      // Removing it is a deliberate act now, from the sheet that shows
      // it — and `0708` refuses once something has been built from it.
      return;
    }
    destination = chosen!.to!;
  }

  await _send(context, ref, staged, destination);
}


/// Opens the captured page, so "what is this?" can be answered by
/// looking at it. `0709`.
///
/// Null where there is nothing to open — the attachment is gone, or the
/// link cannot be minted. A button that opens nothing is worse than no
/// button, so the sheet draws none.
Future<void> Function()? _viewer(
  BuildContext context,
  WidgetRef ref,
  String attachmentId,
) {
  final repo = ref.read(repoProvider);
  if (repo == null) return null;
  return () async {
    try {
      final path = await repo.attachmentPath(attachmentId);
      if (path == null) return;
      // The bucket is private, so this expires rather than being a URL
      // that keeps working after it has been forwarded.
      final url = await repo.attachmentUrl(path);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(storageProblem(e))));
      }
    }
  };
}

/// Records a kind of document this product has never heard of. `0709`.
///
/// Nothing is created from it. The file stays, the scan carries the
/// name, and `platform_named_kinds` turns a pile of them into the
/// argument for the next row in `scan_document_kinds`.
Future<void> _recordNamedKind(
  BuildContext context,
  WidgetRef ref,
  String attachmentId,
  String named,
) async {
  try {
    await ref.read(repoProvider)?.setScanDocumentKind(
          attachmentId: attachmentId,
          named: named,
        );
  } catch (_) {
    // Best effort, like every other note written beside a scan. Losing
    // the label is a smaller wrong than an error over a capture that
    // is safely filed.
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Noted as "$named". The file is kept, and nothing has '
          'been created from it.'),
    ),
  );
}

/// The same door, entered one step in.
///
/// `0698`. A scan that already happened has a reading on its row and a
/// file in the bucket, and until this there was no way to turn it into
/// the record it describes — the figures were on screen and the only
/// use for them was to type them in again.
///
/// It goes through [_send] rather than beside it, deliberately. Every
/// rule about where a reading belongs, which contact it needs and what
/// gets written on the scan afterwards lives in there, and a second
/// entry point that reimplemented any of it would be a second set of
/// answers to drift apart.
///
/// The destination is decided the same way a fresh capture's is, and
/// asked for when the reading does not say — a scan that came back
/// wrong is exactly the one whose destination is in doubt.
Future<void> sendScanOn(
  BuildContext context,
  WidgetRef ref,
  StagedReceipt staged,
) async {
  final kinds = ref.read(offeredScanKindsProvider).valueOrNull ?? const [];
  var destination = destinationFor(staged.read, kinds);

  if (destination == ScanDestination.unknown) {
    final chosen = await showScanKindSheet(
      context,
      read: staged.read,
      onView: _viewer(context, ref, staged.attachmentId),
      because: staged.read == null
          ? 'It could not be read, so there is nothing to fill in. The '
              'file is kept either way — choose where it goes and type '
              'the figures in.'
          : null,
    );
    if (chosen?.named != null && context.mounted) {
      await _recordNamedKind(context, ref, staged.attachmentId,
          chosen!.named!);
      return;
    }
    // Abandoned. The capture is NOT deleted here, unlike the fresh
    // path: this file has been in the bucket since it was scanned and
    // is somebody's evidence. Backing out of building a record from it
    // is not a decision to throw it away.
    if (chosen?.to == null || !context.mounted) return;
    destination = chosen!.to!;
  }

  await _send(context, ref, staged, destination);
}

/// Hands the capture to whichever flow owns that destination.
Future<void> _send(
  BuildContext context,
  WidgetRef ref,
  StagedReceipt staged,
  ScanDestination destination,
) async {
  switch (destination) {
    case ScanDestination.expense:
      // The expense form files the capture itself when it posts, and
      // records the posting with it.
      await showExpenseFromScan(context, staged);

    case ScanDestination.contact:
      final made = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => ContactEditor(
            contactType: 'supplier',
            scanned: staged.read,
          ),
        ),
      );
      // The editor answers with the contact it made, or null if it was
      // abandoned. Re-point the capture only where there is something
      // to point it at; a letterhead filed against a contact that was
      // never created is an orphan in the bucket.
      if (made != null) {
        await _fileAgainst(ref, staged, 'contacts', made);
      }

    case ScanDestination.bankStatement:
      // Straight to the importer, with the reading in hand. The rows
      // are the document here — a statement is forty records and not
      // one — so there is nothing to create first, and the import
      // screen is where the lines are checked before they land.
      ref.read(pendingStatementProvider.notifier).park(staged);
      if (context.mounted) context.go('/banking');

    case ScanDestination.bill:
    case ScanDestination.purchaseOrder:
    case ScanDestination.goodsReceived:
    case ScanDestination.invoice:
      await _startDocument(context, ref, staged, destination);

    case ScanDestination.unknown:
      // Unreachable: `runSmartScan` asks before it gets here and
      // `offerableDestinations` does not contain it. Left as a case
      // rather than a default so that adding a destination is a
      // compile error here.
      break;
  }
}

/// Re-point the capture at the record it became, and say so.
///
/// The two halves together, always. `refileAttachment` moves the
/// storage object and the row; `recordScanPosting` copies the
/// destination off that row onto the scan. Doing the first without the
/// second is what left every old flow's inbox saying a photograph had
/// become nothing.
Future<void> _fileAgainst(
  WidgetRef ref,
  StagedReceipt staged,
  String table,
  String recordId,
) async {
  final repo = ref.read(repoProvider);
  if (repo == null) return;
  await repo.refileAttachment(
    attachmentId: staged.attachmentId,
    table: table,
    recordId: recordId,
  );
  await repo.recordScanPosting(attachmentId: staged.attachmentId);
}

/// A bill, an order, a goods received note or an invoice.
Future<void> _startDocument(
  BuildContext context,
  WidgetRef ref,
  StagedReceipt staged,
  ScanDestination destination,
) async {
  final repo = ref.read(repoProvider);
  if (repo == null) return;
  final docType = destination.docType!;
  final meta = metaFor(docType);
  final read = staged.read;

  // Before the draft, not after. `purchase_documents.contact_id` is NOT
  // NULL, so a document created first and left to the editor to name a
  // supplier is one the database refuses — the first version of this
  // did exactly that.
  final kind = meta.kind.isSales
      ? ScanContactKind.customer
      : ScanContactKind.supplier;
  final match = await resolveSupplier(context, ref, read, kind: kind);
  if (!context.mounted) return;

  switch (match.outcome) {
    case SupplierOutcome.discarded:
      return;
    case SupplierOutcome.noSupplier:
      // Read, and nothing on it named one. `0686`. The person is told
      // what the paper is rather than handed a picker it cannot answer.
      final again = await showScanKindSheet(
        context,
        read: read,
        onView: _viewer(context, ref, staged.attachmentId),
        because: 'Nothing on this names a ${kind.one}, so it is probably '
            'not a ${meta.singular.toLowerCase()}.',
      );
      if (again?.named != null && context.mounted) {
        await _recordNamedKind(context, ref, staged.attachmentId,
            again!.named!);
        return;
      }
      if (again?.to == null || !context.mounted) {
        // The file stays, for the reason above. A document nothing on
        // it names a supplier for is exactly the one somebody wants to
        // come back to.
        return;
      }
      if (again!.to == destination) {
        // They insisted. Fall through to the ordinary picker.
        break;
      }
      await _send(context, ref, staged, again.to!);
      return;
    case SupplierOutcome.ask:
    case SupplierOutcome.resolved:
      break;
  }

  // `ask` means "nothing was decided" — two contacts matched, or the
  // lookup failed — so the question goes to the person. Without this
  // the flow reaches a null id and returns, which loses the capture
  // and says nothing about why.
  String? contactId = match.contactId;
  if (contactId == null) {
    if (!context.mounted) return;
    contactId = await pickSupplier(context, ref, read, kind);
  }
  if (contactId == null || !context.mounted) return;

  // `0628`. The same supplier's same number, already on the books: a
  // warning rather than a refusal, because a corrected re-issue and a
  // genuine second delivery on one day are both ordinary, and a check
  // that is wrong a tenth of the time teaches people to type the
  // number differently — which destroys the only field it runs on.
  if (!meta.kind.isSales) {
    final carryOn = await clearOfDuplicates(
      context,
      ref,
      contactId: contactId,
      docType: docType,
      read: read,
    );
    if (!carryOn || !context.mounted) return;
  }

  try {
    final saved = await repo.saveDocument(
      kind: meta.kind,
      docType: docType,
      header: {
        'contact_id': contactId,
        'doc_date': Fmt.iso(read?.documentDate ?? DateTime.now()),
        // Only on the purchase side. `supplier_doc_no` is THEIR number
        // for the document, and a sales document's number is this
        // company's own sequence — writing the read one there would
        // file a customer's reference as our invoice number.
        if (!meta.kind.isSales && read?.documentNo != null)
          'supplier_doc_no': read!.documentNo,
      },
      lines: const [],
    );

    await _fileAgainst(ref, staged, meta.kind.table, saved.id);

    if (read != null) {
      ref.read(pendingScanProvider.notifier).park(saved.id, read);
    }
    if (context.mounted) {
      context.go('${meta.kind.routePrefix}/$docType/${saved.id}');
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not start it: $e')));
    }
  }
}
