import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/download.dart';
import '../../core/format.dart';
import '../../core/pdf_kit.dart' show LetterheadMode;
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'report_pdf.dart';
import 'report_spec.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  DateTimeRange _range = DateTimeRange(
    start: DateTime(DateTime.now().year, 1, 1),
    end: DateTime.now(),
  );

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    // The download button belongs to whichever report is on screen, so
    // it has to rebuild when the tab changes.
    _tabs.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// The spec for the tab currently showing, or null while its data is
  /// still loading or failed. Null is what disables the download button:
  /// a PDF of a half-loaded report is worse than no PDF.
  ReportSpec? get _visibleSpec {
    switch (_tabs.index) {
      case 0:
        final rows = ref.watch(_profitLossProvider(_range)).valueOrNull;
        return rows == null ? null : profitLossSpec(rows, _range);
      case 1:
        final rows = ref.watch(_balanceSheetProvider(_range.end)).valueOrNull;
        return rows == null ? null : balanceSheetSpec(rows, _range.end);
      case 2:
        final rows = ref.watch(trialBalanceProvider).valueOrNull;
        return rows == null ? null : trialBalanceSpec(rows);
      default:
        final rows = ref.watch(_sstProvider(_range)).valueOrNull;
        return rows == null ? null : sstSummarySpec(rows, _range);
    }
  }

  Future<void> _download(ReportSpec spec) async {
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgProvider).valueOrNull;
    if (org == null) return;

    final bytes = await buildReportPdf(
      org: org,
      spec: spec,
      generatedAt: DateTime.now(),
      logo: await ref.read(orgLogoProvider.future),
      mode: org.usesPreprintedLetterhead
          ? LetterheadMode.stationery
          : LetterheadMode.printed,
    );

    // Named for the report and the date it covers, because a folder of
    // files called "profit-loss.pdf" is a folder of one usable file.
    final stem = spec.title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').toLowerCase();
    final saved = await saveBytesFile(
        '$stem-${Fmt.iso(_range.end)}.pdf', 'application/pdf', bytes);
    messenger.showSnackBar(SnackBar(
      content: Text(
          saved ? 'Downloaded' : 'PDF download is only available in the browser'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final spec = _visibleSpec;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          IconButton(
            tooltip: 'Download PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
            onPressed: spec == null ? null : () => _download(spec),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 4),
            child: OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                  initialDateRange: _range,
                );
                if (picked != null) setState(() => _range = picked);
              },
              icon: const Icon(Icons.date_range, size: 18),
              label: Text(
                '${Fmt.date(_range.start)} – ${Fmt.date(_range.end)}',
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Profit & Loss'),
            Tab(text: 'Balance Sheet'),
            Tab(text: 'Trial Balance'),
            Tab(text: 'SST Summary'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _Report(
            provider: _profitLossProvider(_range),
            spec: (rows) => profitLossSpec(rows, _range),
            empty: const EmptyState(
              icon: Icons.summarize_outlined,
              title: 'Nothing posted in this period',
              message: 'Post invoices and bills to populate the P&L.',
            ),
          ),
          _Report(
            provider: _balanceSheetProvider(_range.end),
            spec: (rows) => balanceSheetSpec(rows, _range.end),
            empty: const EmptyState(
              icon: Icons.balance,
              title: 'Nothing on the balance sheet yet',
              message: 'Post transactions to build up your position.',
            ),
          ),
          _Report(
            provider: trialBalanceProvider,
            spec: trialBalanceSpec,
            wide: true,
            empty: const EmptyState(
              icon: Icons.table_chart_outlined,
              title: 'No ledger activity',
              message: 'The trial balance fills in as you post documents.',
            ),
          ),
          _Report(
            provider: _sstProvider(_range),
            spec: (rows) => sstSummarySpec(rows, _range),
            empty: const EmptyState(
              icon: Icons.receipt_outlined,
              title: 'No taxable transactions',
              message: 'SST figures appear once you post documents with tax.',
            ),
          ),
        ],
      ),
    );
  }
}

/// One report on screen, drawn from the same spec the PDF is drawn from.
class _Report extends ConsumerWidget {
  const _Report({
    required this.provider,
    required this.spec,
    required this.empty,
    this.wide = false,
  });

  final AutoDisposeFutureProvider<List<Map<String, dynamic>>> provider;
  final ReportSpec Function(List<Map<String, dynamic>>) spec;
  final Widget empty;

  /// The trial balance is five columns wide and wants the whole page.
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(provider);

    return AsyncView(
      value: data,
      onRetry: () => ref.invalidate(provider),
      builder: (rows) {
        if (rows.isEmpty) return empty;
        final s = spec(rows);

        // Every block empty means the rows came back but nothing in them
        // was worth printing — an account list that nets to zero.
        final hasContent = s.blocks.any((b) => switch (b) {
              ReportSection x => x.lines.isNotEmpty,
              ReportGrid x => x.rows.isNotEmpty,
              ReportHighlight _ => false,
            });
        if (!hasContent) return empty;

        return SingleChildScrollView(
          child: PageBody(
            maxWidth: wide ? 1280 : 860,
            child: ReportView(spec: s, wide: wide),
          ),
        );
      },
    );
  }
}

/// A report drawn on screen from its spec.
///
/// Separated from the loading so a test can hand it a spec and look at
/// what comes out — the four reports have four different block shapes,
/// and a widget that throws on one of them renders as a blank page in
/// release rather than as an error.
class ReportView extends StatelessWidget {
  const ReportView({super.key, required this.spec, this.wide = false});

  final ReportSpec spec;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(wide ? Space.lg : Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(spec.title, subtitle: spec.subtitle),
            for (final block in spec.blocks) _Block(block: block),
            if (spec.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(spec.note!,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.block});

  final ReportBlock block;

  @override
  Widget build(BuildContext context) => switch (block) {
        ReportSection s when s.lines.isEmpty => const SizedBox.shrink(),
        ReportSection s => _Section(section: s),
        ReportGrid g => _Grid(grid: g),
        ReportHighlight h => _Highlight(highlight: h),
      };
}

/// A named list of accounts with its subtotal.
class _Section extends StatelessWidget {
  const _Section({required this.section});

  final ReportSection section;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
          child: Text(
            section.title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
          ),
        ),
        for (final line in section.lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 72,
                  child: Text(line.code,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                Expanded(child: Text(line.name)),
                Money(line.amount),
              ],
            ),
          ),
        const Divider(height: 20),
        Row(
          children: [
            const SizedBox(width: 72),
            Expanded(
              child: Text(
                'Total ${section.title}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Money(section.total, bold: true),
          ],
        ),
      ],
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.grid});

  final ReportGrid grid;

  Widget _cell(Cell c) => switch (c) {
        TextCell t => Text(t.text),
        MoneyCell m when !m.signed && m.value == 0 => const Text(''),
        MoneyCell m => Money(m.value, colorNegative: m.signed),
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (grid.title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
            child: Text(grid.title!,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        if (grid.rows.isEmpty)
          Text('None', style: Theme.of(context).textTheme.bodySmall)
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: MediaQuery.sizeOf(context).width - 120,
              ),
              child: DataTable(
                columnSpacing: 24,
                columns: [
                  for (var i = 0; i < grid.headers.length; i++)
                    DataColumn(
                        label: Text(grid.headers[i]),
                        numeric: grid.isNumeric(i)),
                ],
                rows: [
                  for (final row in grid.rows)
                    DataRow(cells: [for (final c in row) DataCell(_cell(c))]),
                  if (grid.total != null)
                    DataRow(
                      color: WidgetStatePropertyAll(
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                      cells: [
                        for (final c in grid.total!)
                          DataCell(switch (c) {
                            TextCell t => Text(t.text,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            MoneyCell m => Money(m.value, bold: true),
                          }),
                      ],
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Highlight extends StatelessWidget {
  const _Highlight({required this.highlight});

  final ReportHighlight highlight;

  @override
  Widget build(BuildContext context) {
    final value = highlight.value;
    final emphasise = highlight.emphasise;

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: (value >= 0 ? context.colors.success : context.colors.danger)
            .withValues(alpha: emphasise ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              highlight.label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: emphasise ? 16 : 14,
              ),
            ),
          ),
          Money(
            value,
            bold: true,
            colorNegative: true,
            style: emphasise
                ? Theme.of(context).textTheme.titleLarge
                : Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

final _profitLossProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTimeRange>((ref, range) {
  return requireRepo(ref).profitLoss(from: range.start, to: range.end);
});

final _balanceSheetProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTime>((ref, asAt) {
  return requireRepo(ref).balanceSheet(asAt: asAt);
});

final _sstProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTimeRange>((ref, range) {
  return requireRepo(ref).sstSummary(from: range.start, to: range.end);
});
