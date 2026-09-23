import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/skeletons.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/attachments_repository.dart';
import '../../data/ocr_repository.dart';
import '../../data/repository.dart';
import 'bulk_plan.dart';
import 'doc_types.dart';
import 'duplicate_bill.dart';
import 'late_orders_dialog.dart';
import '../expenses/expenses_screen.dart';
import '../shared/scan_intake.dart';
import '../shared/supplier_from_scan.dart';
import 'settlement_dialog.dart';

/// One list screen for every document type in both cycles. The doc type
/// in the route decides which table, contact kind and actions apply.
/// Scan a supplier's paperwork, then start the bill it describes.
///
/// The supplier is asked for *before* anything is created, and that is
/// the database's rule rather than a preference: `purchase_documents`
/// has `contact_id not null`, because a payable that is owed to nobody
/// is not a payable. The first version of this created the draft first
/// and left the supplier to the editor, which the constraint refused —
/// correctly.
///
/// It is asked rather than matched. The reading's supplier name seeds
/// the search, so the right contact is usually one tap away, but two
/// contacts called "Syarikat Maju" are ordinary and picking the wrong
/// one surfaces months later in an aged payables listing.
Future<void> _scanInto(
  BuildContext context,
  WidgetRef ref, {
  required String docType,
  required DocTypeMeta meta,
}) async {
  final staged = await showScanIntake(
    context,
    ref,
    table: meta.kind.table,
    title: 'Scan a ${meta.singular.toLowerCase()}',
  );
  if (staged == null || !context.mounted) return;

  final repo = ref.read(repoProvider)!;
  final read = staged.read;

  // Looked up before anybody is asked. The document names its supplier
  // on the letterhead, and searching for a name that is already on
  // screen is work the machine should have done.
  final kind = meta.kind.isSales
      ? ScanContactKind.customer
      : ScanContactKind.supplier;
  final match = await resolveSupplier(context, ref, read, kind: kind);
  if (!context.mounted) return;

  // Read, and nothing on it named a supplier. `0686`. Said plainly
  // rather than dropped into the ordinary picker, which is a question
  // this document cannot answer asked in a dialog indistinguishable
  // from the one somebody gets when they press New.
  if (match.outcome == SupplierOutcome.noSupplier) {
    final choice = await showDialog<_NotABill>(
      context: context,
      builder: (_) => _NotABillDialog(read: read!, kind: kind),
    );
    if (!context.mounted) return;
    switch (choice) {
      case _NotABill.expense:
        // Straight into the expense form on the capture already made.
        // The attachment is re-pointed when the expense posts, so
        // nothing here has to be undone and nothing is photographed
        // twice.
        await showExpenseFromScan(context, staged);
        return;
      case _NotABill.chooseAnyway:
        break;
      case _NotABill.discard:
      case null:
        await repo.deleteAttachmentById(staged.attachmentId);
        return;
    }
  }

  String? contactId = match.contactId;
  if (match.outcome == SupplierOutcome.ask ||
      match.outcome == SupplierOutcome.noSupplier) {
    // Re-checked: `noSupplier` reaches here only through the dialog
    // above, which is an await the analyzer cannot see past.
    if (!context.mounted) return;
    contactId = await _pickSupplier(context, ref, read, kind);
  }

  if (contactId == null) {
    // Abandoned at the supplier. The capture was filed against a
    // placeholder that will never become a document, so it goes with it
    // rather than sitting in the bucket forever.
    await repo.deleteAttachmentById(staged.attachmentId);
    return;
  }

  // 0628. Before anything is created, not after: a duplicate caught
  // here is a decision, and one caught after the draft exists is a
  // second draft to go and delete. The same receipt photographed twice
  // is the ordinary way this happens, and the second photograph is
  // taken by somebody who does not remember the first.
  //
  // Only on the purchase side. A sales document's number is this
  // company's own sequence and cannot collide.
  if (!meta.kind.isSales) {
    if (!context.mounted) return;
    final go = await _clearOfDuplicates(
      context,
      ref,
      contactId: contactId,
      docType: docType,
      read: read,
    );
    if (!go) {
      await repo.deleteAttachmentById(staged.attachmentId);
      return;
    }
    if (!context.mounted) return;
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
    final id = saved.id;
    await repo.refileAttachment(
      attachmentId: staged.attachmentId,
      table: meta.kind.table,
      recordId: id,
    );
    if (read != null) ref.read(pendingScanProvider.notifier).park(id, read);
    if (context.mounted) {
      context.go('${meta.kind.routePrefix}/$docType/$id');
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not start it: $e')));
    }
  }
}


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
Future<bool> _clearOfDuplicates(
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

/// Which supplier this is from — the one thing no scan can decide.
/// What to do with a page that has no supplier on it. `0686`.
enum _NotABill { expense, chooseAnyway, discard }

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
class _NotABillDialog extends StatelessWidget {
  const _NotABillDialog({required this.read, required this.kind});

  final OcrExtraction read;
  final ScanContactKind kind;

  /// The voucher case, named. The classifier settles the kind from what
  /// the paper calls itself, so when it says voucher the dialog can say
  /// something true and specific instead of the general sentence.
  bool get _isVoucher => read.documentKind == 'payment_voucher';

  @override
  Widget build(BuildContext context) {
    final noun = kind.one;
    final muted = Theme.of(context).textTheme.bodySmall;

    final facts = <String>[
      if (read.documentNo != null) 'No. ${read.documentNo}',
      if (read.documentDate != null) Fmt.date(read.documentDate!),
      if (read.totalAmount != null) Fmt.money(read.totalAmount!),
    ];

    return AlertDialog(
      key: const ValueKey('not-a-bill'),
      title: Text(
        _isVoucher
            ? 'This is a payment voucher'
            : "This doesn't look like a $noun bill",
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isVoucher
                ? 'A voucher is your own record of money going out, so '
                    'there is no $noun to owe — the only company named '
                    'on it is usually your own.'
                : 'The page was read, and nothing on it named a $noun.',
          ),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            // What WAS read, so somebody can tell a page with no
            // supplier from a page the reader made nothing of.
            Text(facts.join('  ·  '), style: muted),
          ],
          if (read.rawText != null && facts.isEmpty) ...[
            const SizedBox(height: Space.sm),
            Text(
              'Nothing else was read from it either.',
              style: muted,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('not-a-bill-discard'),
          onPressed: () => Navigator.pop(context, _NotABill.discard),
          child: const Text('Discard'),
        ),
        // Kept, and not buried. A bill whose letterhead was unreadable
        // is an ordinary thing, and a dialog that only offered the
        // expense would be a wall in front of it.
        TextButton(
          key: const ValueKey('not-a-bill-choose'),
          onPressed: () => Navigator.pop(context, _NotABill.chooseAnyway),
          child: Text('Choose a $noun anyway'),
        ),
        FilledButton(
          key: const ValueKey('not-a-bill-expense'),
          onPressed: () => Navigator.pop(context, _NotABill.expense),
          child: const Text('Record as an expense'),
        ),
      ],
    );
  }
}

Future<String?> _pickSupplier(
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
class _ListAction {
  const _ListAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.id,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final String? id;
}

class DocumentListScreen extends ConsumerStatefulWidget {
  const DocumentListScreen({super.key, required this.docType});

  final String docType;

  @override
  ConsumerState<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends ConsumerState<DocumentListScreen> {
  String _status = 'all';
  String _search = '';

  /// Ticked, for a batch. Empty means the list behaves exactly as it
  /// did before 0500: tapping a row opens it.
  final _picked = <String>{};
  bool _running = false;

  void _toggle(String id) => setState(() {
    if (!_picked.remove(id)) _picked.add(id);
  });

  Future<void> _runBatch(
    List<BusinessDocument> docs,
    String verb,
    Future<List<Map<String, dynamic>>> Function(List<String>) action,
    String field,
  ) async {
    if (docs.isEmpty || _running) return;
    setState(() => _running = true);
    List<Map<String, dynamic>> rows = const [];
    try {
      rows = await action([for (final d in docs) d.id]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$verb failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
    if (!mounted || rows.isEmpty) return;

    setState(_picked.clear);
    ref.invalidate(documentsProvider);
    refreshLedgerData(ref);

    final failed = [
      for (final r in rows)
        if (r[field] != true) r,
    ];
    if (failed.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(BulkPlan.outcome(rows, field))));
      return;
    }
    // Named, not counted. "2 failed" is not something anybody can act
    // on; "INV-19 is dated into a closed period" is.
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(BulkPlan.outcome(rows, field)),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in failed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r['doc_no']?.toString() ?? 'A document',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          r['problem']?.toString() ?? 'Refused.',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Roughly what one of the secondary actions occupies: a
  /// `TextButton.icon` whose label is two or three words. Taken from
  /// the widest of them, "From the group (2)", with room to spare --
  /// under-estimating it puts the bar back over the edge, and the
  /// sweep in `document_list_screen_test.dart` is what would say so.
  static const _actionWidth = 190.0;

  /// The title, the type switcher and the New button, which are on the
  /// bar whatever the document type is. Sized for the longest pair of
  /// them -- "Purchase Orders" over "New purchase order" -- because it
  /// is a single number for every list and the widest one is the one
  /// that has to fit. At 420 the purchase order list still went 22
  /// pixels over at exactly 700, which is what the sweep found.
  static const _chromeWidth = 520.0;

  /// Everything on the bar that is not the type switcher or "New".
  ///
  /// Gathered into a list rather than written inline so the same
  /// entries can be buttons on a wide screen and menu items on a narrow
  /// one, instead of being described twice and drifting apart.
  List<_ListAction> _secondaryActions(
    BuildContext context, {
    required DocTypeMeta meta,
    required DocKind kind,
    required bool canWrite,
    required bool canPost,
  }) {
    // Only on bills, and only when a group company has actually
    // addressed something here. A permanent entry for a company with no
    // group is a door onto an empty room.
    final waiting = widget.docType != 'bill'
        ? 0
        : (ref.watch(intercompanyInboxProvider).valueOrNull ?? const [])
              .where((r) => r['already_billed'] != true)
              .length;

    // Only on the sales order list, and only when something is actually
    // late. A permanent button reading "nothing is late" is the same
    // empty room; a count is a reason to look.
    final late = widget.docType != 'sales_order'
        ? const <Map<String, dynamic>>[]
        : (ref.watch(lateOrdersProvider).valueOrNull ?? const []);

    return [
      if (waiting > 0)
        _ListAction(
          id: 'open-intercompany',
          label: 'From the group ($waiting)',
          icon: Icons.swap_horiz,
          onTap: () => context.go('/intercompany'),
        ),
      if (late.isNotEmpty)
        _ListAction(
          id: 'late-orders',
          label: 'Late (${late.length})',
          icon: Icons.schedule,
          onTap: () => showLateOrders(context),
        ),
      if (canPost && meta.settles)
        _ListAction(
          label: kind.isSales ? 'Receive payment' : 'Pay supplier',
          icon: Icons.payments_outlined,
          onTap: () => showSettlementDialog(context, ref, kind: kind),
        ),
      // Only on the purchase side. A sales invoice is raised from what
      // we are owed, not read off a piece of paper somebody handed us --
      // there is nothing to scan.
      // `0682`. Hidden on the sales side until now, and the reason was
      // the wording rather than the machinery: everything under it
      // asked "which supplier?", which is the wrong question about your
      // own customer. `ScanContactKind` carries the noun now.
      if (canWrite)
        _ListAction(
          label: 'Scan ${meta.singular.toLowerCase()}',
          icon: Icons.document_scanner_outlined,
          onTap: () =>
              _scanInto(context, ref, docType: widget.docType, meta: meta),
        ),
    ];
  }

  Widget _searchField(DocKind kind) => TextField(
    onChanged: (v) => setState(() => _search = v),
    decoration: InputDecoration(
      hintText: kind.isSales
          ? 'Search document number'
          : 'Search our number or the supplier’s',
      prefixIcon: const Icon(Icons.search, size: 20),
    ),
  );

  Widget _statusFilter() => SegmentedButton<String>(
    showSelectedIcon: false,
    segments: const [
      ButtonSegment(value: 'all', label: Text('All')),
      ButtonSegment(value: 'draft', label: Text('Draft')),
      ButtonSegment(value: 'outstanding', label: Text('Outstanding')),
    ],
    selected: {_status},
    onSelectionChanged: (s) => setState(() => _status = s.first),
  );

  @override
  Widget build(BuildContext context) {
    final meta = metaFor(widget.docType);
    final kind = meta.kind;
    final docs = ref.watch(
      documentsProvider((
        kind: kind,
        docType: widget.docType,
        status: _status,
        search: _search,
      )),
    );
    final canWrite = ref.watch(canWriteProvider);
    final canPost = ref.watch(canPostProvider);

    // What a batch of these could do fits on a laptop and ran off
    // everything narrower. Measured: a bill list for a company in a
    // group carries the type switcher, "From the group (2)",
    // "Pay supplier", "Scan bill" and "New bill", which together need
    // about 970 logical pixels -- so a browser window at 800 lost the
    // right-hand end of the bar, and a phone lost most of it. Flutter
    // CLIPS an overflowing toolbar rather than reporting it in a
    // release build, so nobody would have been told.
    final secondary = _secondaryActions(
      context,
      meta: meta,
      kind: kind,
      canWrite: canWrite,
      canPost: canPost,
    );
    // Asked of how many there actually are rather than of a single
    // breakpoint, because the number changes with the document type,
    // the role and whether a group company has sent anything: an
    // invoice list for a viewer has none of them and a bill list for an
    // owner in a group has three, and one threshold cannot be right for
    // both.
    final room = MediaQuery.sizeOf(context).width;
    final folded = room < _chromeWidth + secondary.length * _actionWidth;
    final narrow = room < 700;

    return Scaffold(
      appBar: AppBar(
        title: Text(meta.plural),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Switch document type',
            icon: const Icon(Icons.swap_horiz),
            onSelected: (type) =>
                context.go('${metaFor(type).kind.routePrefix}/$type'),
            itemBuilder: (_) => [
              for (final e in docTypesFor(kind))
                PopupMenuItem(
                  value: e.key,
                  child: Row(
                    children: [
                      Icon(e.value.icon, size: 18),
                      const SizedBox(width: 10),
                      Text(e.value.plural),
                    ],
                  ),
                ),
            ],
          ),
          if (!folded)
            for (final a in secondary)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: TextButton.icon(
                  key: a.id == null ? null : ValueKey(a.id!),
                  onPressed: a.onTap,
                  icon: Icon(a.icon, size: 18),
                  label: Text(a.label),
                ),
              ),
          if (canWrite)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.icon(
                onPressed: () =>
                    context.go('${kind.routePrefix}/${widget.docType}/new'),
                icon: const Icon(Icons.add, size: 18),
                label: Text(
                  narrow ? 'New' : 'New ${meta.singular.toLowerCase()}',
                ),
              ),
            ),
          // Folded rather than dropped. Every one of these is the only
          // way to reach what is behind it from this screen, so hiding
          // one on a phone would be removing the feature there.
          if (folded && secondary.isNotEmpty)
            PopupMenuButton<int>(
              key: const ValueKey('more-actions'),
              tooltip: 'More',
              itemBuilder: (_) => [
                for (var i = 0; i < secondary.length; i++)
                  PopupMenuItem(
                    value: i,
                    child: Row(
                      children: [
                        Icon(secondary[i].icon, size: 18),
                        const SizedBox(width: 12),
                        // A menu on a phone is 256 wide and
                        // "From the group (1)" beside its icon does not
                        // fit -- so the label yields rather than
                        // overflowing the item it is in.
                        Flexible(
                          child: Text(
                            secondary[i].label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              onSelected: (i) => secondary[i].onTap(),
            ),
        ],
        bottom: PreferredSize(
          // The segmented control alone is 504 wide, which is more than
          // a phone has, so on a narrow screen the two go one above the
          // other and the control scrolls sideways -- the arrangement
          // `narrow_layout_test.dart` established when the e-Invoice
          // filters lost "Needs fixing" off the right edge.
          preferredSize: Size.fromHeight(narrow ? 116 : 64),
          child: narrow
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Space.lg,
                        0,
                        Space.lg,
                        Space.sm,
                      ),
                      child: _searchField(kind),
                    ),
                    FilterBar(child: _statusFilter()),
                  ],
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    0,
                    Space.lg,
                    Space.md,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: _searchField(kind)),
                      const SizedBox(width: 12),
                      _statusFilter(),
                    ],
                  ),
                ),
        ),
      ),
      body: AsyncView(
        value: docs,
        onRetry: () => ref.invalidate(documentsProvider),
        // Rows in a list, and the shape is decided by the screen
        // rather than by the payload -- a name and a value, on
        // every one of them. No avatar: these rows do not carry
        // one, and a bone where nothing goes reflows the moment
        // the data lands, which is the flicker a skeleton is for.
        skeleton: const ListSkeleton(leading: false),
        builder: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: meta.icon,
              title: 'No ${meta.plural.toLowerCase()} yet',
              message: 'Create your first ${meta.singular.toLowerCase()}.',
              action: canWrite
                  ? FilledButton.icon(
                      onPressed: () => context.go(
                        '${kind.routePrefix}/${widget.docType}/new',
                      ),
                      icon: const Icon(Icons.add),
                      label: Text('New ${meta.singular.toLowerCase()}'),
                    )
                  : null,
            );
          }

          final outstanding = list.fold<double>(
            0,
            (sum, d) => sum + d.balanceAmount,
          );

          return Column(
            children: [
              if (outstanding > 0)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.lg,
                    vertical: Space.sm,
                  ),
                  color: Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.35),
                  child: Text(
                    '${list.length} documents · ${Fmt.money(outstanding)} '
                    '${kind.isSales ? 'receivable' : 'payable'}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              Expanded(
                child: ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _DocumentTile(
                    doc: list[i],
                    docType: widget.docType,
                    kind: kind,
                    // Only where a batch could do something: the two
                    // bulk functions are the sales side's, and somebody
                    // who cannot post or send has nothing to tick for.
                    picked: _picked.contains(list[i].id),
                    onPick: kind.isSales && (canPost || canWrite)
                        ? () => _toggle(list[i].id)
                        : null,
                  ),
                ),
              ),
              if (_picked.isNotEmpty)
                _BatchBar(
                  plan: BulkPlan.of(list, _picked, widget.docType),
                  running: _running,
                  onClear: () => setState(_picked.clear),
                  onPost: canPost
                      ? (docs) => _runBatch(
                          docs,
                          'Post',
                          ref.read(repoProvider)!.bulkPostDocuments,
                          'posted',
                        )
                      : null,
                  onEmail: canWrite
                      ? (docs) => _runBatch(
                          docs,
                          'Email',
                          ref.read(repoProvider)!.bulkEmailDocuments,
                          'sent',
                        )
                      : null,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The bar that appears once something is ticked.
///
/// What each button says comes from [BulkPlan], which knows that a
/// quotation writes no journal and a posted invoice does not post
/// twice — so "Post 12 of 40" is said before the batch rather than
/// discovered after it.
class _BatchBar extends StatelessWidget {
  const _BatchBar({
    required this.plan,
    required this.running,
    required this.onClear,
    required this.onPost,
    required this.onEmail,
  });

  final BulkPlan plan;
  final bool running;
  final VoidCallback onClear;
  final void Function(List<BusinessDocument>)? onPost;
  final void Function(List<BusinessDocument>)? onEmail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            Text(
              '${plan.selected.length} selected',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            if (running)
              const Padding(
                padding: EdgeInsets.only(right: Space.md),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            TextButton(
              onPressed: running ? null : onClear,
              child: const Text('Clear'),
            ),
            const SizedBox(width: Space.sm),
            if (onEmail != null)
              OutlinedButton(
                onPressed: running || plan.emailable.isEmpty
                    ? null
                    : () => onEmail!(plan.emailable),
                child: Text(plan.emailLabel()),
              ),
            if (onPost != null) ...[
              const SizedBox(width: Space.sm),
              FilledButton(
                onPressed: running || plan.postable.isEmpty
                    ? null
                    : () => onPost!(plan.postable),
                child: Text(plan.postLabel()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.doc,
    required this.docType,
    required this.kind,
    this.picked = false,
    this.onPick,
  });

  final BusinessDocument doc;
  final String docType;
  final DocKind kind;
  final bool picked;
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;

    return ListTile(
      onTap: () => context.go('${kind.routePrefix}/$docType/${doc.id}'),
      leading: onPick == null
          ? null
          : Checkbox(value: picked, onChanged: (_) => onPick!()),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.xs,
      ),
      // A `Wrap`, not a `Row`. The trailing column takes what it needs
      // first, which on a phone leaves this about 120 wide -- and a Row
      // pushed the chip and the e-Invoice mark off the right edge of
      // every line in the list. Truncating the document NUMBER instead
      // is not the trade to make: it is the thing somebody came to the
      // list to read.
      title: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 2,
        children: [
          Text(doc.docNo, style: const TextStyle(fontWeight: FontWeight.w600)),
          StatusChip(doc.isOverdue ? 'overdue' : doc.status, compact: true),
          if (doc.einvoiceStatus != 'not_applicable')
            Tooltip(
              message: 'e-Invoice: ${Fmt.label(doc.einvoiceStatus)}',
              child: Icon(
                _einvoiceIcon(doc.einvoiceStatus),
                size: 16,
                color: _einvoiceColor(context, doc.einvoiceStatus),
              ),
            ),
        ],
      ),
      subtitle: Text(
        [
          doc.contactName ?? '—',
          Fmt.date(doc.docDate),
          if (doc.dueDate != null) 'due ${Fmt.date(doc.dueDate)}',
          if ((doc.supplierDocNo ?? '').isNotEmpty) 'ref ${doc.supplierDocNo}',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Money(doc.totalAmount, currency: doc.currency, bold: true),
          if (!narrow &&
              doc.balanceAmount > 0 &&
              doc.balanceAmount != doc.totalAmount)
            Text(
              '${Fmt.money(doc.balanceAmount, currency: doc.currency)} due',
              style: TextStyle(fontSize: 11, color: context.colors.warning),
            ),
        ],
      ),
    );
  }

  static IconData _einvoiceIcon(String status) => switch (status) {
    'valid' => Icons.verified,
    'invalid' || 'rejected' => Icons.error_outline,
    'cancelled' => Icons.cancel_outlined,
    'submitted' || 'pending' => Icons.schedule,
    _ => Icons.help_outline,
  };

  static Color _einvoiceColor(BuildContext context, String status) =>
      switch (status) {
        'valid' => context.colors.success,
        'invalid' || 'rejected' => context.colors.danger,
        'submitted' || 'pending' => context.colors.warning,
        _ => const Color(0xFF94A3B8),
      };
}
