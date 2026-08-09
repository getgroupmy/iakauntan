import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'doc_types.dart';
import 'settlement_dialog.dart';

/// One list screen for every document type in both cycles. The doc type
/// in the route decides which table, contact kind and actions apply.
class DocumentListScreen extends ConsumerStatefulWidget {
  const DocumentListScreen({super.key, required this.docType});

  final String docType;

  @override
  ConsumerState<DocumentListScreen> createState() =>
      _DocumentListScreenState();
}

class _DocumentListScreenState extends ConsumerState<DocumentListScreen> {
  String _status = 'all';
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final meta = metaFor(widget.docType);
    final kind = meta.kind;
    final docs = ref.watch(documentsProvider((
      kind: kind,
      docType: widget.docType,
      status: _status,
      search: _search,
    )));
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
                  child: Row(children: [
                    Icon(e.value.icon, size: 18),
                    const SizedBox(width: 10),
                    Text(e.value.plural),
                  ]),
                ),
            ],
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
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
                      value: 'outstanding', label: Text('Outstanding')),
                ],
                selected: {_status},
                onSelectionChanged: (s) => setState(() => _status = s.first),
              ),
            ]),
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
                      onPressed: () => context
                          .go('${kind.routePrefix}/${widget.docType}/new'),
                      icon: const Icon(Icons.add),
                      label: Text('New ${meta.singular.toLowerCase()}'),
                    )
                  : null,
            );
          }

          final outstanding =
              list.fold<double>(0, (sum, d) => sum + d.balanceAmount);

          return Column(
            children: [
              if (outstanding > 0)
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  color: Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withValues(alpha: 0.35),
                  child: Text(
                    '${list.length} documents · ${Fmt.money(outstanding)} '
                    '${kind.isSales ? 'receivable' : 'payable'}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      title: Row(
        children: [
          Text(doc.docNo,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          StatusChip(doc.isOverdue ? 'overdue' : doc.status, compact: true),
          if (doc.einvoiceStatus != 'not_applicable') ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'e-Invoice: ${Fmt.label(doc.einvoiceStatus)}',
              child: Icon(
                _einvoiceIcon(doc.einvoiceStatus),
                size: 16,
                color: _einvoiceColor(doc.einvoiceStatus),
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
              style: const TextStyle(fontSize: 11, color: AppTheme.amber),
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

  static Color _einvoiceColor(String status) => switch (status) {
        'valid' => AppTheme.success,
        'invalid' || 'rejected' => AppTheme.danger,
        'submitted' || 'pending' => AppTheme.amber,
        _ => const Color(0xFF94A3B8),
      };
}
