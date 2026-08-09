import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

const salesDocTypes = <String, ({String plural, String singular, IconData icon})>{
  'quotation': (plural: 'Quotations', singular: 'Quotation', icon: Icons.request_quote_outlined),
  'sales_order': (plural: 'Sales Orders', singular: 'Sales Order', icon: Icons.shopping_cart_outlined),
  'delivery_order': (plural: 'Delivery Orders', singular: 'Delivery Order', icon: Icons.local_shipping_outlined),
  'invoice': (plural: 'Invoices', singular: 'Invoice', icon: Icons.receipt_long_outlined),
  'credit_note': (plural: 'Credit Notes', singular: 'Credit Note', icon: Icons.undo_outlined),
  'debit_note': (plural: 'Debit Notes', singular: 'Debit Note', icon: Icons.redo_outlined),
};

class SalesListScreen extends ConsumerStatefulWidget {
  const SalesListScreen({super.key, required this.docType});

  final String docType;

  @override
  ConsumerState<SalesListScreen> createState() => _SalesListScreenState();
}

class _SalesListScreenState extends ConsumerState<SalesListScreen> {
  String _status = 'all';
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final meta = salesDocTypes[widget.docType] ?? salesDocTypes['invoice']!;
    final docs = ref.watch(salesDocumentsProvider(
      (docType: widget.docType, status: _status, search: _search),
    ));
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(meta.plural),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Switch document type',
            icon: const Icon(Icons.swap_horiz),
            onSelected: (type) => context.go('/sales/$type'),
            itemBuilder: (_) => [
              for (final e in salesDocTypes.entries)
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
          if (canWrite)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.icon(
                onPressed: () => context.go('/sales/${widget.docType}/new'),
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
                  decoration: const InputDecoration(
                    hintText: 'Search document number',
                    prefixIcon: Icon(Icons.search, size: 20),
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
        onRetry: () => ref.invalidate(salesDocumentsProvider),
        builder: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: meta.icon,
              title: 'No ${meta.plural.toLowerCase()} yet',
              message: 'Create your first ${meta.singular.toLowerCase()}.',
              action: canWrite
                  ? FilledButton.icon(
                      onPressed: () =>
                          context.go('/sales/${widget.docType}/new'),
                      icon: const Icon(Icons.add),
                      label: Text('New ${meta.singular.toLowerCase()}'),
                    )
                  : null,
            );
          }

          final totalOutstanding =
              list.fold<double>(0, (sum, d) => sum + d.balanceAmount);

          return Column(
            children: [
              if (totalOutstanding > 0)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                  color: Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withValues(alpha: 0.35),
                  child: Text(
                    '${list.length} documents · ${Fmt.money(totalOutstanding)} outstanding',
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
  const _DocumentTile({required this.doc, required this.docType});

  final SalesDocument doc;
  final String docType;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;

    return ListTile(
      onTap: () => context.go('/sales/$docType/${doc.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      title: Row(
        children: [
          Text(
            doc.docNo,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
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
        '${doc.contactName ?? '—'} · ${Fmt.date(doc.docDate)}'
        '${doc.dueDate != null ? ' · due ${Fmt.date(doc.dueDate)}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Money(doc.totalAmount, currency: doc.currency, bold: true),
          if (!narrow && doc.balanceAmount > 0 && doc.balanceAmount != doc.totalAmount)
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
