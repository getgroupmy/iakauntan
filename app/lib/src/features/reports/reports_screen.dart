import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/pdf_kit.dart' show LetterheadMode;
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'report_csv.dart';
import 'report_pdf.dart';
import 'report_spec.dart';
import 'report_xlsx.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

/// The caveat the balance sheet has always carried. Named because two
/// call sites now pass it, and two copies of a sentence drift.
const _balanceSheetNote =
    'This should be zero once the year-end profit is transferred to '
    'retained earnings.';

class _ReportsScreenState extends ConsumerState<ReportsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  DateTimeRange _range = DateTimeRange(
    start: DateTime(DateTime.now().year, 1, 1),
    end: DateTime.now(),
  );

  /// Project code the P&L is restricted to, or null for the whole
  /// company. Only the P&L takes it: a balance sheet for one job is a
  /// different report, not this one with a filter.
  String? _project;

  /// And the department, which until now had a report and no filter.
  /// `report_profit_loss_by_dimension` has always taken both; the screen
  /// only ever offered one, so the department half of it was
  /// unreachable.
  String? _department;

  /// The account the general ledger is narrowed to, or null for every
  /// account that moved. Only the ledger takes it, and only the ledger
  /// shows the chooser: a year of a busy company is tens of thousands
  /// of lines, and the question is almost always about one account.
  String? _account;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 10, vsync: this);
    // The download button belongs to whichever report is on screen, so
    // it has to rebuild when the tab changes.
    _tabs.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// The dimension choosers, built from the codes the ledger actually
  /// holds rather than from every project or department ever created. A
  /// department that has never had a penny posted against it is not a
  /// filter anybody wants; it is a row that would come back empty.
  Widget _dimensionFilter({
    required String kind,
    required String allLabel,
    required String? selected,
    required ValueChanged<String?> onChanged,
  }) {
    final dimensions = ref.watch(_dimensionsProvider).valueOrNull ?? const [];
    final codes = [
      for (final d in dimensions)
        if (d['kind'] == kind) d['code'] as String,
    ];
    if (codes.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: SizedBox(
        width: _filterWidth,
        child: DropdownButton<String?>(
          value: selected,
          isExpanded: true,
          hint: Text(allLabel, overflow: TextOverflow.ellipsis),
          underline: const SizedBox.shrink(),
          items: [
            DropdownMenuItem(value: null, child: Text(allLabel)),
            for (final code in codes)
              DropdownMenuItem(value: code, child: Text(code)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  /// Which account the ledger is showing.
  ///
  /// Every account in the chart, not only the ones that have moved:
  /// "why is there nothing in 6300" is a question somebody asks, and a
  /// chooser that hides empty accounts cannot answer it.
  Widget _accountFilter() {
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
    if (accounts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: SizedBox(
        width: _filterWidth,
        child: DropdownButton<String?>(
          value: _account,
          // Bounded, and the CLOSED control ellipsises. A
          // `DropdownButton` sizes itself to its widest item, so one
          // account called "Professional fees and subscriptions" made
          // this control 290 pixels wide and pushed the date range off
          // the right of a 1000px window -- a laptop, not a phone.
          // Measured at 116 pixels over. The open menu is unaffected
          // and still shows every name in full.
          isExpanded: true,
          hint: const Text('All accounts', overflow: TextOverflow.ellipsis),
          underline: const SizedBox.shrink(),
          items: [
            const DropdownMenuItem(value: null, child: Text('All accounts')),
            for (final a in accounts.where((a) => !a.isGroup))
              DropdownMenuItem(
                value: a.id,
                child: Text(
                  '${a.code} ${a.name}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() => _account = v),
        ),
      ),
    );
  }

  /// Whether there is a second company to add this one to. One company
  /// in a group is still a group — it just has nothing to combine, so
  /// there is nothing to offer.
  bool get _inAGroup =>
      (ref.watch(groupCompaniesProvider).valueOrNull ?? const []).length > 1;

  /// The spec for the tab currently showing, or null while its data is
  /// still loading or failed. Null is what disables the download button:
  /// a PDF of a half-loaded report is worse than no PDF.
  ReportSpec? get _visibleSpec {
    switch (_tabs.index) {
      case 0:
        final rows = ref
            .watch(
              _profitLossProvider((
                range: _range,
                project: _project,
                department: _department,
              )),
            )
            .valueOrNull;
        return rows == null
            ? null
            : layoutSpec(
                rows,
                title: 'Profit & Loss',
                subtitle:
                    '${Fmt.longDate(_range.start)} to '
                    '${Fmt.longDate(_range.end)}',
              );
      case 1:
        final rows = ref.watch(_balanceSheetProvider(_range.end)).valueOrNull;
        return rows == null
            ? null
            : layoutSpec(
                rows,
                title: 'Balance Sheet',
                subtitle: 'As at ${Fmt.longDate(_range.end)}',
                note: _balanceSheetNote,
              );
      case 2:
        final rows = ref.watch(trialBalanceProvider).valueOrNull;
        return rows == null ? null : trialBalanceSpec(rows);
      case 3:
        final rows = ref.watch(_agedProvider(_aged(true))).valueOrNull;
        return rows == null
            ? null
            : agedBalanceSpec(rows, _range.end, receivable: true);
      case 4:
        final rows = ref.watch(_agedProvider(_aged(false))).valueOrNull;
        return rows == null
            ? null
            : agedBalanceSpec(rows, _range.end, receivable: false);
      case 5:
        final rows = ref.watch(_cashFlowProvider(_range)).valueOrNull;
        return rows == null ? null : cashFlowSpec(rows, _range);
      case 6:
        final rows = ref.watch(_equityProvider(_range)).valueOrNull;
        return rows == null ? null : changesInEquitySpec(rows, _range);
      case 7:
        final rows = ref.watch(_sstProvider(_range)).valueOrNull;
        return rows == null ? null : sstSummarySpec(rows, _range);
      default:
        final rows = ref.watch(_deferredProvider(_range.end)).valueOrNull;
        return rows == null ? null : deferredRevenueSpec(rows, _range.end);
    }
  }

  /// The aged listings are as at a date, not over a period, so they take
  /// the end of the chosen range and ignore the start.
  ({bool receivable, DateTime asAt}) _aged(bool receivable) =>
      (receivable: receivable, asAt: _range.end);

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

    final saved = await exportBytesFile(
      ref,
      '${_stem(spec)}.pdf',
      'application/pdf',
      bytes,
      what: 'Report',
      detail: '${spec.title} to ${Fmt.iso(_range.end)}',
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? 'Downloaded'
              : 'PDF download is only available in the browser',
        ),
      ),
    );
  }

  /// The same report, as something a spreadsheet can add up.
  ///
  /// Needs no organization and no logo: a CSV carries no letterhead, so
  /// unlike the PDF this cannot be blocked by a slow read of the company
  /// record.
  Future<void> _downloadCsv(ReportSpec spec) async {
    final messenger = ScaffoldMessenger.of(context);
    final csv = reportCsv(spec);
    final saved = await exportTextFile(
      ref,
      '${_stem(spec)}.csv',
      'text/csv',
      csv,
      what: 'Report',
      detail: '${spec.title} to ${Fmt.iso(_range.end)}, as CSV',
    );
    if (!saved) {
      // Nothing downloads on a phone, so leave it somewhere it can be
      // pasted rather than pretending the export happened.
      await Clipboard.setData(ClipboardData(text: csv));
    }
    messenger.showSnackBar(
      SnackBar(content: Text(saved ? 'Downloaded' : 'Copied to the clipboard')),
    );
  }

  /// The same report, as a workbook.
  ///
  /// Beside the CSV rather than instead of it. A CSV is what an
  /// importer wants -- no types, no formats, nothing to parse around --
  /// and this is what a person wants: figures that are numbers, with
  /// number formats and column widths on them. `report_xlsx.dart` has
  /// the argument.
  ///
  /// No clipboard fallback, unlike the CSV. A workbook is bytes, and
  /// there is nothing useful to paste; on a phone, where nothing
  /// downloads, the honest answer is to say so.
  Future<void> _downloadXlsx(ReportSpec spec) async {
    final messenger = ScaffoldMessenger.of(context);
    final saved = await exportBytesFile(
      ref,
      '${_stem(spec)}.xlsx',
      // The full OOXML type. A workbook served as
      // `application/octet-stream` downloads as a file the browser will
      // not name properly and Excel opens with a warning.
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      reportXlsx([spec]),
      what: 'Report',
      detail: '${spec.title} to ${Fmt.iso(_range.end)}, as a workbook',
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? 'Downloaded'
              : 'Workbook download is only available in the browser',
        ),
      ),
    );
  }

  /// Named for the report and the date it covers, because a folder of
  /// files called "profit-loss.pdf" is a folder of one usable file.
  String _stem(ReportSpec spec) =>
      '${spec.title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').toLowerCase()}'
      '-${Fmt.iso(_range.end)}';

  /// How wide a filter on the bar may be.
  ///
  /// A `DropdownButton` with no bound sizes itself to its WIDEST item,
  /// so the width of this bar was decided by the longest account name
  /// in the company's chart. Enough for "All accounts" and a code with
  /// some of a name; the open menu shows every name in full.
  static const _filterWidth = 180.0;

  /// The range the whole screen is reporting on.
  ///
  /// Extracted because it sits in the app bar on a laptop and under the
  /// tabs on a phone, and describing it twice is how the two come to
  /// disagree.
  Widget _rangeButton() => OutlinedButton.icon(
    key: const ValueKey('reports-range'),
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
    label: Text('${Fmt.date(_range.start)} – ${Fmt.date(_range.end)}'),
  );

  TabBar _tabBar() => TabBar(
    controller: _tabs,
    isScrollable: true,
    tabAlignment: TabAlignment.start,
    tabs: const [
      Tab(text: 'Profit & Loss'),
      Tab(text: 'Balance Sheet'),
      Tab(text: 'Trial Balance'),
      Tab(text: 'General Ledger'),
      Tab(text: 'Aged Receivables'),
      Tab(text: 'Aged Payables'),
      Tab(text: 'Cash Flows'),
      Tab(text: 'Changes in Equity'),
      Tab(text: 'SST Summary'),
      Tab(text: 'Deferred Revenue'),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final spec = _visibleSpec;

    // The date range is the widest thing on this bar -- "01/09/2026 –
    // 30/09/2026" is twenty-three characters -- and it labels every
    // figure underneath it, so it is the one action that keeps its
    // button. Measured: the bar ran 96 pixels off a 412px phone and 36
    // off a 600px window with the group button showing, and Flutter
    // CLIPS a toolbar rather than reporting it in a release build.
    // 900, not the 700 this was first written at. Measured: the full
    // bar -- group button, two downloads, the account filter and the
    // range -- was still four pixels over at 800. The sweep in
    // `reports_screen_test.dart` is what said so and what holds this
    // number honest, because it is an estimate of how much a row of
    // buttons wants and nothing stops the next label being longer.
    final narrow = MediaQuery.sizeOf(context).width < 900;

    // Folded rather than dropped: downloading the report on screen is
    // the reason most people open it, and the group button is the only
    // way to reach the consolidated figures.
    final folded = <({String label, IconData icon, VoidCallback? onTap})>[
      if (_inAGroup)
        (
          label: 'Group reports',
          icon: Icons.account_tree_outlined,
          onTap: () => context.push('/reports/group'),
        ),
      (
        label: 'Download PDF',
        icon: Icons.picture_as_pdf_outlined,
        onTap: spec == null ? null : () => _download(spec),
      ),
      (
        label: 'Download Excel',
        icon: Icons.grid_on_outlined,
        onTap: spec == null ? null : () => _downloadXlsx(spec),
      ),
      (
        label: 'Download CSV',
        icon: Icons.table_chart_outlined,
        onTap: spec == null ? null : () => _downloadCsv(spec),
      ),
      // 0637. Only on the two reports that HAVE a layout. Offering it
      // on the trial balance would promise something that does not
      // exist, which is worse than not offering it.
      if (_tabs.index == 0 || _tabs.index == 1)
        (
          label: 'Edit layout',
          icon: Icons.tune,
          onTap: () async {
            final kind = _tabs.index == 0 ? 'profit_loss' : 'balance_sheet';
            final saved = await context.push<bool>('/reports/layout/$kind');
            if (saved == true && mounted) setState(() {});
          },
        ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          if (narrow)
            PopupMenuButton<int>(
              key: const ValueKey('reports-more'),
              tooltip: 'More',
              itemBuilder: (_) => [
                for (var i = 0; i < folded.length; i++)
                  PopupMenuItem(
                    value: i,
                    enabled: folded[i].onTap != null,
                    child: Row(
                      children: [
                        Icon(folded[i].icon, size: 18),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            folded[i].label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              onSelected: (i) => folded[i].onTap?.call(),
            ),
          // Only for somebody who is in more than one company of a
          // group. For everybody else the group reports would be this
          // company's figures under a heading claiming otherwise, which
          // is worse than not offering them.
          if (!narrow && _inAGroup)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: TextButton.icon(
                key: const ValueKey('open-group-reports'),
                onPressed: () => context.push('/reports/group'),
                icon: const Icon(Icons.account_tree_outlined, size: 18),
                label: const Text('Group'),
              ),
            ),
          if (!narrow)
            IconButton(
              tooltip: 'Download PDF',
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
              onPressed: spec == null ? null : () => _download(spec),
            ),
          if (!narrow)
            IconButton(
              key: const ValueKey('report-xlsx'),
              tooltip: 'Download Excel',
              icon: const Icon(Icons.grid_on_outlined, size: 20),
              onPressed: spec == null ? null : () => _downloadXlsx(spec),
            ),
          if (!narrow)
            IconButton(
              tooltip: 'Download CSV',
              icon: const Icon(Icons.table_chart_outlined, size: 20),
              onPressed: spec == null ? null : () => _downloadCsv(spec),
            ),
          // Only on the P&L, and only once something in the ledger
          // actually carries a project code — an empty dropdown on every
          // report is a control that teaches people to ignore it.
          if (_tabs.index == 0) ...[
            _dimensionFilter(
              kind: 'project',
              allLabel: 'All projects',
              selected: _project,
              onChanged: (v) => setState(() => _project = v),
            ),
            _dimensionFilter(
              kind: 'department',
              allLabel: 'All departments',
              selected: _department,
              onChanged: (v) => setState(() => _department = v),
            ),
          ],
          if (_tabs.index == 3) _accountFilter(),
          if (!narrow) _rangeButton(),
        ],
        // On a phone the range moves BELOW the tabs rather than being
        // shortened. It is twenty-three characters and it labels every
        // figure on the screen; "01/09 – 30/09" would drop the year
        // from a report somebody is about to file.
        bottom: !narrow
            ? _tabBar()
            : PreferredSize(
                preferredSize: const Size.fromHeight(46 + 52),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Space.lg,
                        0,
                        Space.lg,
                        Space.sm,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: _rangeButton(),
                      ),
                    ),
                    _tabBar(),
                  ],
                ),
              ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _Report(
            provider: _profitLossProvider((
              range: _range,
              project: _project,
              department: _department,
            )),
            spec: (rows) => layoutSpec(
              rows,
              title: 'Profit & Loss',
              subtitle:
                  '${Fmt.longDate(_range.start)} to '
                  '${Fmt.longDate(_range.end)}',
            ),
            empty: const EmptyState(
              icon: Icons.summarize_outlined,
              title: 'Nothing posted in this period',
              message: 'Post invoices and bills to populate the P&L.',
            ),
          ),
          _Report(
            provider: _balanceSheetProvider(_range.end),
            spec: (rows) => layoutSpec(
              rows,
              title: 'Balance Sheet',
              subtitle: 'As at ${Fmt.longDate(_range.end)}',
              note: _balanceSheetNote,
            ),
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
          // Straight after the trial balance, because it is what the
          // trial balance is made of and that is the order somebody
          // reads them in: the total first, then the lines behind it.
          _Report(
            provider: _generalLedgerProvider((
              range: _range,
              account: _account,
            )),
            spec: (rows) => generalLedgerSpec(rows, _range),
            wide: true,
            empty: const EmptyState(
              icon: Icons.menu_book_outlined,
              title: 'No ledger activity',
              message:
                  'Post a document or a journal and every account it '
                  'touched appears here, with the balance carried down.',
            ),
          ),
          _Report(
            provider: _agedProvider(_aged(true)),
            spec: (rows) => agedBalanceSpec(rows, _range.end, receivable: true),
            wide: true,
            empty: const EmptyState(
              icon: Icons.hourglass_bottom_outlined,
              title: 'Nothing owed to you',
              message: 'Post invoices to build up a receivables ledger.',
            ),
          ),
          _Report(
            provider: _agedProvider(_aged(false)),
            spec: (rows) =>
                agedBalanceSpec(rows, _range.end, receivable: false),
            wide: true,
            empty: const EmptyState(
              icon: Icons.hourglass_bottom_outlined,
              title: 'Nothing owed by you',
              message: 'Post bills to build up a payables ledger.',
            ),
          ),
          _Report(
            provider: _cashFlowProvider(_range),
            spec: (rows) => cashFlowSpec(rows, _range),
            empty: const EmptyState(
              icon: Icons.waterfall_chart,
              title: 'No cash movement in this period',
              message: 'Post receipts and payments to build up a cash flow.',
            ),
          ),
          _Report(
            provider: _equityProvider(_range),
            spec: (rows) => changesInEquitySpec(rows, _range),
            wide: true,
            empty: const EmptyState(
              icon: Icons.pie_chart_outline,
              title: 'No equity yet',
              message:
                  'Share capital and retained earnings appear here as '
                  'they are posted.',
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
          _Report(
            provider: _deferredProvider(_range.end),
            spec: (rows) => deferredRevenueSpec(rows, _range.end),
            wide: true,
            empty: const EmptyState(
              icon: Icons.event_repeat,
              title: 'Nothing deferred',
              message:
                  'Give an invoice line a service period and it is earned '
                  'across that period rather than on the day, and appears '
                  'here until it has been.',
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
        final hasContent = s.blocks.any(
          (b) => switch (b) {
            ReportSection x => x.lines.isNotEmpty,
            ReportGrid x => x.rows.isNotEmpty,
            ReportHighlight _ => false,
          },
        );
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
                child: Text(
                  spec.note!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
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
                  child: Text(
                    line.code,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
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
            child: Text(
              grid.title!,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
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
                      numeric: grid.isNumeric(i),
                    ),
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
                            TextCell t => Text(
                              t.text,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
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

/// Keyed by period, project *and* department, so switching any of the
/// three restates the report rather than showing the last one until it
/// reloads.
///
/// Always the by-dimension function, even with nothing chosen: with
/// nulls it returns exactly what the plain report does, and one code
/// path cannot drift from the other.
final _profitLossProvider = FutureProvider.autoDispose
    .family<
      List<Map<String, dynamic>>,
      ({DateTimeRange range, String? project, String? department})
    >((ref, args) {
      // `0637`. The rows come back already composed from this
      // company's layout -- section, formula and account, in order --
      // rather than as a flat list this side then groups. A company
      // that has customised nothing gets exactly what it got before.
      return requireRepo(ref).reportWithLayout(
        kind: 'profit_loss',
        from: args.range.start,
        to: args.range.end,
        projectCode: args.project,
        departmentCode: args.department,
      );
    });

final _dimensionsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).ledgerDimensions();
    });

final _balanceSheetProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTime>((ref, asAt) {
      // `0637`, as with the P&L above: composed from this company's
      // layout rather than grouped on this side.
      return requireRepo(ref).reportWithLayout(kind: 'balance_sheet', to: asAt);
    });

/// The ledger, for the chosen range and optionally one account.
///
/// A record rather than two families because both have to change
/// together: asking for last year's dates against this year's chosen
/// account would be two requests and one confusing answer.
final _generalLedgerProvider = FutureProvider.autoDispose
    .family<
      List<Map<String, dynamic>>,
      ({DateTimeRange range, String? account})
    >((ref, args) {
      return requireRepo(ref).generalLedger(
        from: args.range.start,
        to: args.range.end,
        accountId: args.account,
      );
    });

final _sstProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTimeRange>((ref, range) {
      return requireRepo(ref).sstSummary(from: range.start, to: range.end);
    });

/// The shared aged-balance provider, so the tab body and the download
/// button read one request rather than two.
final _agedProvider = agedBalancesProvider;

final _cashFlowProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTimeRange>((ref, range) {
      return requireRepo(ref).cashFlow(from: range.start, to: range.end);
    });

final _equityProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTimeRange>((ref, range) {
      return requireRepo(ref).changesInEquity(from: range.start, to: range.end);
    });

/// The deferred revenue schedule is as at a date, like the aged
/// listings: it takes the end of the chosen range and ignores the start.
final _deferredProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTime>((ref, asAt) {
      return requireRepo(ref).deferredRevenue(asAt: asAt);
    });
