import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'received_einvoice.dart';

/// The e-Invoices suppliers have sent us.
///
/// The other direction from `einvoice_screen.dart`, and the half that
/// removes the most typing: MyInvois makes every supplier send one, so
/// a bill that used to be typed off a PDF arrives as structured data
/// already carrying the lines, the tax and the classification codes.
///
/// ## Import, rather than fetch
///
/// There is no MyInvois fetcher and this screen does not pretend there
/// is. Retrieving the documents addressed to a company needs live
/// credentials and a sandbox that is not reachable from where this is
/// built, and a fetcher written against an API nobody has called is a
/// fetcher nobody has tested. So a file is imported, which is already
/// most of the value — a supplier can send the JSON directly and many
/// do.
///
/// ## Two steps, deliberately, and neither is automatic
///
/// Importing a document does not create a bill, and linking a supplier
/// is its own action. `0650` matches a supplier by TIN and by
/// registration number and NEVER by name, because "Pembekal Jaya" and
/// "Pembekal Jaya Sdn Bhd" are two rows in most contact lists and a
/// link nobody chose becomes a bill against the wrong supplier. So
/// where the identifiers do not match, this screen asks — which is the
/// one place somebody can see the choice being made.
class ReceivedEinvoicesScreen extends ConsumerStatefulWidget {
  const ReceivedEinvoicesScreen({super.key});

  @override
  ConsumerState<ReceivedEinvoicesScreen> createState() =>
      _ReceivedEinvoicesScreenState();
}

class _ReceivedEinvoicesScreenState
    extends ConsumerState<ReceivedEinvoicesScreen> {
  String _filter = 'all';
  bool _importing = false;

  void _reload() => ref.invalidate(receivedEinvoicesProvider);

  Future<void> _import() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'e-Invoice', extensions: ['json']),
      ],
    );
    if (file == null || !mounted) return;

    setState(() => _importing = true);
    final text = await file.readAsString();
    if (!mounted) return;

    Map<String, dynamic>? result;
    await runWithFeedback(
      context,
      action: () async {
        // Sent as TEXT rather than decoded here. The edge function
        // parses it with the same module the round-trip assertions use,
        // and a decode in between would be a second place for the file
        // to be misread.
        result = await ref.read(repoProvider)!.receiveEinvoice(text);
      },
      // The outcome is announced below instead, because "imported" and
      // "you already had this one" are different news and this one
      // sentence cannot be both.
      successMessage: null,
      pendingMessage: 'Reading the document…',
    );

    if (!mounted) return;
    setState(() => _importing = false);
    final r = result;
    if (r == null) return;

    _reload();
    await _showOutcome(r);
  }

  Future<void> _showOutcome(Map<String, dynamic> result) async {
    final warnings = importWarnings(result);
    if (warnings.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(importOutcome(result))));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('received-import-outcome'),
        title: Text(importOutcome(result)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final w in warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2, right: 8),
                        child: Icon(Icons.warning_amber_outlined, size: 18),
                      ),
                      Expanded(child: Text(w)),
                    ],
                  ),
                ),
              // The document is kept whatever is wrong with it, and
              // saying so is the point: somebody who has just been
              // shown four problems needs to know nothing was lost.
              const Text(
                'The document has been kept as it arrived, so you can '
                'look at it and decide.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _linkSupplier(ReceivedEinvoice doc) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final created = await confirm(
      context,
      title: 'Create this supplier?',
      message:
          '${doc.supplierName ?? 'The supplier'} is not on file. Create a '
          'contact from what the document says about them, and link it to '
          'this document?',
      confirmLabel: 'Create supplier',
    );
    if (!created || !mounted) return;

    await runWithFeedback(
      context,
      action: () => repo.createSupplierFromReceivedEinvoice(doc.id),
      successMessage: 'Supplier linked',
    );
    _reload();
  }

  Future<void> _draftBill(ReceivedEinvoice doc) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    await runWithFeedback(
      context,
      action: () => repo.draftBillFromReceivedEinvoice(doc.id),
      successMessage:
          'Draft ${draftBillKindLabel(doc.typeCode)} created from '
          '${doc.docNo ?? 'the document'}',
    );
    _reload();
  }

  Future<void> _setAside(ReceivedEinvoice doc) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ignoring = doc.status != 'ignored';
    await runWithFeedback(
      context,
      action: () => repo.setReceivedEinvoiceStatus(
        doc.id,
        ignoring ? 'ignored' : 'received',
      ),
      successMessage: ignoring ? 'Set aside' : 'Moved back to Received',
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(receivedEinvoicesProvider(_filter));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Received e-Invoices'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              key: const ValueKey('received-import'),
              onPressed: _importing ? null : _import,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('Import a document'),
            ),
          ),
        ],
      ),
      body: PageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FilterBar(
              child: Wrap(
                spacing: Space.sm,
                children: [
                  for (final f in const [
                    ('all', 'All'),
                    ('received', 'Received'),
                    ('billed', 'Billed'),
                    ('ignored', 'Set aside'),
                  ])
                    ChoiceChip(
                      key: ValueKey('received-filter-${f.$1}'),
                      label: Text(f.$2),
                      selected: _filter == f.$1,
                      onSelected: (_) => setState(() => _filter = f.$1),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: AsyncView<List<ReceivedEinvoice>>(
                value: docs,
                // The layout is already decided here and only the values
                // are missing, which is where `skeletons.dart` says a
                // skeleton is honest.
                skeleton: const ListSkeleton(rows: 6),
                onRetry: _reload,
                builder: (rows) => rows.isEmpty
                    ? const EmptyState(
                        icon: Icons.mark_email_read_outlined,
                        title: 'Nothing has arrived yet',
                        message:
                            'When a supplier sends you a MyInvois document, '
                            'import the file here and it becomes a draft '
                            'bill with the lines already filled in.',
                      )
                    : ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) => _DocumentTile(
                          doc: rows[i],
                          onLink: () => _linkSupplier(rows[i]),
                          onDraft: () => _draftBill(rows[i]),
                          onSetAside: () => _setAside(rows[i]),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.doc,
    required this.onLink,
    required this.onDraft,
    required this.onSetAside,
  });

  final ReceivedEinvoice doc;
  final VoidCallback onLink;
  final VoidCallback onDraft;
  final VoidCallback onSetAside;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Null rather than a set, deliberately: this screen does not load
    // the currency list, and `draftBillProblem` treats null as "not
    // known" so it cannot accuse an ordinary document of naming an
    // unknown currency. The database still refuses one.
    final problem = draftBillProblem(doc);

    return ListTile(
      key: ValueKey('received-${doc.id}'),
      isThreeLine: true,
      title: Row(
        children: [
          Expanded(
            child: Text(
              receivedSummaryLine(doc),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Money(doc.payableAmount, currency: doc.currency ?? 'MYR'),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusChip(doc.status),
              Text(receivedTypeLabel(doc.typeCode), style: theme.textTheme.bodySmall),
              if (doc.issueDate != null)
                Text(Fmt.date(doc.issueDate!), style: theme.textTheme.bodySmall),
              if (doc.lineCount > 0)
                Text(
                  '${doc.lineCount} line${doc.lineCount == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
          if (receivedNeedsAttention(doc)) ...[
            const SizedBox(height: 6),
            Text(
              doc.contactId == null
                  ? supplierPrompt(doc)
                  : doc.problems.first,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
      trailing: PopupMenuButton<String>(
        key: ValueKey('received-menu-${doc.id}'),
        onSelected: (v) => switch (v) {
          'link' => onLink(),
          'draft' => onDraft(),
          _ => onSetAside(),
        },
        itemBuilder: (context) => [
          if (doc.contactId == null && doc.supplierName != null)
            const PopupMenuItem(
              value: 'link',
              child: Text('Create and link supplier'),
            ),
          PopupMenuItem(
            value: 'draft',
            enabled: problem == null,
            // The reason IS the label when there is one. A disabled
            // item saying "Draft a bill" tells somebody nothing about
            // why it will not.
            child: Text(problem ?? 'Draft a ${draftBillKindLabel(doc.typeCode)}'),
          ),
          PopupMenuItem(
            value: 'aside',
            child: Text(
              doc.status == 'ignored' ? 'Move back to Received' : 'Set aside',
            ),
          ),
        ],
      ),
    );
  }
}
