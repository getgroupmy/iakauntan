import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error_text.dart';
import '../../core/skeletons.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'bulk_plan.dart';
import 'doc_types.dart';
import 'late_orders_dialog.dart';
import 'settlement_dialog.dart';


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
        ).showSnackBar(SnackBar(content: Text('$verb failed: ${errorText(e)}')));
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
          // Beside the status, because that is where somebody's eye
          // already is when they scan the list. `0707`.
          EntrySourceChip(doc.entrySource, compact: true),
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
