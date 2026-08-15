import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/attachments_repository.dart';
import '../../data/ocr_repository.dart';
import 'doc_types.dart';
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
  final match = await resolveSupplier(context, ref, read);
  if (!context.mounted) return;

  String? contactId = match.contactId;
  if (match.outcome == SupplierOutcome.ask) {
    contactId = await _pickSupplier(context, ref, read?.supplierName);
  }

  if (contactId == null) {
    // Abandoned at the supplier. The capture was filed against a
    // placeholder that will never become a document, so it goes with it
    // rather than sitting in the bucket forever.
    await repo.deleteAttachmentById(staged.attachmentId);
    return;
  }

  try {
    final id = await repo.saveDocument(
      kind: meta.kind,
      docType: docType,
      header: {
        'contact_id': contactId,
        'doc_date': Fmt.iso(read?.documentDate ?? DateTime.now()),
        if (read?.documentNo != null) 'supplier_doc_no': read!.documentNo,
      },
      lines: const [],
    );
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

/// Which supplier this is from — the one thing no scan can decide.
Future<String?> _pickSupplier(
  BuildContext context,
  WidgetRef ref,
  String? readName,
) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SupplierPicker(readName: readName),
  );
}

class _SupplierPicker extends ConsumerStatefulWidget {
  const _SupplierPicker({this.readName});

  /// What the document said, used to seed the search and shown as a
  /// reminder — never selected automatically.
  final String? readName;

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
      contactsProvider((type: 'supplier', search: _query)),
    );

    return AlertDialog(
      title: const Text('Which supplier?'),
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
              decoration: const InputDecoration(
                labelText: 'Search suppliers',
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: Space.sm),
            Expanded(
              child: AsyncView(
                value: contacts,
                onRetry: () => ref.invalidate(
                  contactsProvider((type: 'supplier', search: _query)),
                ),
                loading: const LinearProgressIndicator(),
                builder: (list) => list.isEmpty
                    ? const EmptyState(
                        icon: Icons.person_search_outlined,
                        title: 'No supplier matches',
                        message:
                            'Clear the search to see them all, or add '
                            'the supplier under Contacts first.',
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
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
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
          // Only on bills, and only when a group company has actually
          // addressed something here. A permanent menu item for a
          // company with no group is a door onto an empty room.
          if (widget.docType == 'bill')
            Consumer(
              builder: (context, ref, _) {
                final waiting =
                    (ref.watch(intercompanyInboxProvider).valueOrNull ??
                            const [])
                        .where((r) => r['already_billed'] != true)
                        .length;
                if (waiting == 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: TextButton.icon(
                    key: const ValueKey('open-intercompany'),
                    onPressed: () => context.go('/intercompany'),
                    icon: const Icon(Icons.swap_horiz, size: 18),
                    label: Text('From the group ($waiting)'),
                  ),
                );
              },
            ),
          if (canPost && meta.settles)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: TextButton.icon(
                onPressed: () => showSettlementDialog(context, ref, kind: kind),
                icon: const Icon(Icons.payments_outlined, size: 18),
                label: Text(kind.isSales ? 'Receive payment' : 'Pay supplier'),
              ),
            ),
          // Only on the purchase side. A sales invoice is raised from
          // what we are owed, not read off a piece of paper somebody
          // handed us — there is nothing to scan.
          if (canWrite && !kind.isSales)
            TextButton.icon(
              onPressed: () =>
                  _scanInto(context, ref, docType: widget.docType, meta: meta),
              icon: const Icon(Icons.document_scanner_outlined, size: 18),
              label: Text('Scan ${meta.singular.toLowerCase()}'),
            ),
          if (canWrite)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.icon(
                onPressed: () =>
                    context.go('${kind.routePrefix}/${widget.docType}/new'),
                icon: const Icon(Icons.add, size: 18),
                label: Text('New ${meta.singular.toLowerCase()}'),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _search = v),
                    decoration: InputDecoration(
                      hintText: kind.isSales
                          ? 'Search document number'
                          : 'Search our number or the supplier’s',
                      prefixIcon: const Icon(Icons.search, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'all', label: Text('All')),
                    ButtonSegment(value: 'draft', label: Text('Draft')),
                    ButtonSegment(
                      value: 'outstanding',
                      label: Text('Outstanding'),
                    ),
                  ],
                  selected: {_status},
                  onSelectionChanged: (s) => setState(() => _status = s.first),
                ),
              ],
            ),
          ),
        ),
      ),
      body: AsyncView(
        value: docs,
        onRetry: () => ref.invalidate(documentsProvider),
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
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.doc,
    required this.docType,
    required this.kind,
  });

  final BusinessDocument doc;
  final String docType;
  final DocKind kind;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;

    return ListTile(
      onTap: () => context.go('${kind.routePrefix}/$docType/${doc.id}'),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.xs,
      ),
      title: Row(
        children: [
          Text(doc.docNo, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          StatusChip(doc.isOverdue ? 'overdue' : doc.status, compact: true),
          if (doc.einvoiceStatus != 'not_applicable') ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'e-Invoice: ${Fmt.label(doc.einvoiceStatus)}',
              child: Icon(
                _einvoiceIcon(doc.einvoiceStatus),
                size: 16,
                color: _einvoiceColor(context, doc.einvoiceStatus),
              ),
            ),
          ],
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
