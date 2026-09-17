import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'asset_editor.dart';
import 'asset_schedule_dialog.dart';
import 'capitalise_dialog.dart';
import 'depreciation_dialog.dart';
import 'disposal_dialog.dart';

/// The fixed asset register, and the depreciation run that comes off it.
///
/// This is the schedule the auditor asks for by name: cost, accumulated
/// depreciation and net book value per asset, with the basis stated so
/// the charge can be checked rather than taken on trust.
class AssetsScreen extends ConsumerStatefulWidget {
  const AssetsScreen({super.key});

  @override
  ConsumerState<AssetsScreen> createState() => _AssetsScreenState();
}

class _AssetsScreenState extends ConsumerState<AssetsScreen> {
  bool _includeDisposed = false;

  @override
  Widget build(BuildContext context) {
    final assets = ref.watch(fixedAssetsProvider(_includeDisposed));
    final canWrite = ref.watch(canWriteProvider);
    final canPost = ref.watch(canPostProvider);
    final canReadLedger = ref.watch(canReadLedgerProvider);
    final narrow = MediaQuery.sizeOf(context).width < 640;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Fixed assets'),
        actions: [
          // The note itself, which until 0156 could not be produced from
          // the movements behind it.
          if (canReadLedger)
            IconButton(
              key: const ValueKey('asset-schedule'),
              tooltip: 'Fixed asset schedule',
              icon: const Icon(Icons.table_chart_outlined),
              onPressed: () => showAssetSchedule(context),
            ),
          if (canWrite)
            // The reconciliation from the ledger's end: what has been
            // bought and coded to a fixed asset account with nothing in
            // the register claiming it.
            IconButton(
              key: const ValueKey('asset-uncapitalised'),
              tooltip: 'Bought, not in the register',
              icon: const Icon(Icons.playlist_add_check_outlined),
              onPressed: () => showUncapitalisedPurchases(context),
            ),
          if (canPost)
            IconButton(
              tooltip: 'Run depreciation',
              icon: const Icon(Icons.calculate_outlined),
              onPressed: () => _runDepreciation(context),
            ),
          if (canWrite)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FilledButton.icon(
                onPressed: () => _edit(context, null),
                icon: const Icon(Icons.add, size: 18),
                label: Text(narrow ? 'New' : 'New asset'),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          FilterBar(
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('In use')),
                ButtonSegment(value: true, label: Text('Including disposed')),
              ],
              selected: {_includeDisposed},
              onSelectionChanged: (s) =>
                  setState(() => _includeDisposed = s.first),
            ),
          ),
          Expanded(
            child: AsyncView(
              value: assets,
              onRetry: () => ref.invalidate(fixedAssetsProvider),
              skeleton: const ListSkeleton(rows: 6, leading: false),
              builder: (list) => list.isEmpty
                  ? const EmptyState(
                      icon: Icons.inventory_2_outlined,
                      title: 'No fixed assets',
                      message: 'Add the vehicles, machines and equipment the '
                          'company owns, and depreciation follows from them.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(Space.lg),
                      itemCount: list.length + 1,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => i == list.length
                          ? _RegisterTotals(assets: list)
                          : _AssetTile(
                              asset: list[i],
                              onTap: canWrite
                                  ? () => _edit(context, list[i])
                                  : null,
                              onDispose: canPost && !list[i].isDisposed
                                  ? () => _dispose(context, list[i])
                                  : null,
                              onHistory: canReadLedger
                                  ? () => showDepreciationHistory(
                                      context,
                                      list[i],
                                    )
                                  : null,
                            ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, FixedAsset? asset) async {
    final saved = await showAssetEditor(context, ref, asset: asset);
    if (saved == true) ref.invalidate(fixedAssetsProvider);
  }

  Future<void> _dispose(BuildContext context, FixedAsset asset) async {
    final done = await showDisposalDialog(context, ref, asset: asset);
    if (done == true) {
      ref.invalidate(fixedAssetsProvider);
      refreshLedgerData(ref);
    }
  }

  Future<void> _runDepreciation(BuildContext context) async {
    final done = await showDepreciationDialog(context, ref);
    if (done == true) {
      ref.invalidate(fixedAssetsProvider);
      refreshLedgerData(ref);
    }
  }
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({
    required this.asset,
    this.onTap,
    this.onDispose,
    this.onHistory,
  });

  final FixedAsset asset;
  final VoidCallback? onTap;
  final VoidCallback? onDispose;
  final VoidCallback? onHistory;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Expanded(child: Text('${asset.assetNo} · ${asset.name}')),
          if (asset.status != 'active') StatusChip(asset.status, compact: true),
        ],
      ),
      subtitle: Text(
        '${asset.basis} · bought ${Fmt.date(asset.acquisitionDate)}'
        // Which bill the cost came from. An asset that names one can
        // be checked against the ledger; one that was typed in cannot,
        // which is what `0382` is about — so the register says which is
        // which rather than looking the same either way.
        '${asset.purchaseDocNo == null ? '' : ' · ${asset.purchaseDocNo}'}'
        '${asset.supplierName == null ? '' : ' from ${asset.supplierName}'}'
        '${asset.depreciatedTo == null ? '' : ' · depreciated to ${Fmt.date(asset.depreciatedTo)}'}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Money(asset.netBookValue, bold: true),
              Text(
                'cost ${Fmt.money(asset.cost)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          // Offered on a disposed asset too: what it was charged over
          // its life is exactly what somebody asks about afterwards.
          if (onHistory != null)
            IconButton(
              key: ValueKey('asset-history-${asset.id}'),
              tooltip: 'Depreciation history',
              icon: const Icon(Icons.history, size: 20),
              onPressed: onHistory,
            ),
          if (onDispose != null)
            IconButton(
              tooltip: 'Dispose',
              icon: const Icon(Icons.sell_outlined, size: 20),
              onPressed: onDispose,
            ),
        ],
      ),
    );
  }
}

/// The three figures that have to agree with the balance sheet.
class _RegisterTotals extends StatelessWidget {
  const _RegisterTotals({required this.assets});

  final List<FixedAsset> assets;

  @override
  Widget build(BuildContext context) {
    final live = assets.where((a) => !a.isDisposed);
    final cost = live.fold<double>(0, (s, a) => s + a.cost);
    final accum =
        live.fold<double>(0, (s, a) => s + a.accumulatedDepreciation);

    return Padding(
      padding: const EdgeInsets.only(top: Space.lg),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            children: [
              _TotalLine(label: 'Cost', value: cost),
              const SizedBox(height: 6),
              _TotalLine(label: 'Accumulated depreciation', value: -accum),
              const Divider(height: 20),
              _TotalLine(
                label: 'Net book value',
                value: cost - accum,
                emphasise: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TotalLine extends StatelessWidget {
  const _TotalLine({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;
  final double value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontWeight: emphasise ? FontWeight.w700 : FontWeight.w500)),
        ),
        Money(value, bold: emphasise),
      ],
    );
  }
}
