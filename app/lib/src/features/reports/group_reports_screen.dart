import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/pdf_kit.dart' show LetterheadMode;
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'report_pdf.dart';
import 'report_spec.dart';
import 'reports_screen.dart' show ReportView;

/// The books of several companies, added together.
///
/// A separate screen from `ReportsScreen` rather than two more tabs on
/// it, because it reports on a different thing. Every other report on
/// that screen is this company; these are the group. Sitting them in one
/// tab bar would put two rows called "Trial Balance" next to each other
/// meaning different entities, which is exactly the confusion an
/// accounting system should not introduce.
///
/// Reachable only when the person is in more than one company of a
/// group — see the button on the Reports screen.
class GroupReportsScreen extends ConsumerStatefulWidget {
  const GroupReportsScreen({super.key});

  @override
  ConsumerState<GroupReportsScreen> createState() => _GroupReportsScreenState();
}

class _GroupReportsScreenState extends ConsumerState<GroupReportsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  DateTimeRange _range = DateTimeRange(
    start: DateTime(DateTime.now().year, 1, 1),
    end: DateTime.now(),
  );

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  ({DateTime from, DateTime to}) get _key =>
      (from: _range.start, to: _range.end);

  int get _companyCount =>
      (ref.watch(groupCompaniesProvider).valueOrNull ?? const []).length;

  /// The spec for the tab on screen, or null while it is still loading.
  /// Null disables the download: a PDF of a half-loaded report is worse
  /// than no PDF.
  /// How many inter-company pairs do not agree. Nothing is eliminated
  /// for those, so the consolidation has to say how many are outstanding
  /// rather than quietly presenting a figure that ignores them.
  int get _unreconciled =>
      (ref.watch(groupEliminationCheckProvider(_key)).valueOrNull ?? const [])
          .where((r) => r['eliminated'] != true)
          .length;

  ReportSpec? get _visibleSpec {
    switch (_tabs.index) {
      case 0:
        final rows = ref.watch(groupTrialBalanceProvider(_key)).valueOrNull;
        return rows == null
            ? null
            : groupTrialBalanceSpec(rows, _range, companies: _companyCount);
      case 1:
        final rows = ref.watch(groupConsolidatedProvider(_key)).valueOrNull;
        return rows == null
            ? null
            : consolidatedSpec(
                rows,
                _range,
                companies: _companyCount,
                unreconciled: _unreconciled,
              );
      default:
        final rows = ref.watch(groupIntercompanyProvider(_key)).valueOrNull;
        return rows == null ? null : intercompanySpec(rows, _range);
    }
  }

  Future<void> _download(ReportSpec spec) async {
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgProvider).valueOrNull;
    if (org == null) return;

    final bytes = await buildReportPdf(
      // The group has no letterhead of its own — it is a relationship
      // between companies rather than a company — so the one whose
      // screen this was opened from signs it, and the report says on its
      // face how many companies it covers.
      org: org,
      spec: spec,
      generatedAt: DateTime.now(),
      logo: await ref.read(orgLogoProvider.future),
      mode: org.usesPreprintedLetterhead
          ? LetterheadMode.stationery
          : LetterheadMode.printed,
    );

    final stem = spec.title
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .toLowerCase();
    final saved = await exportBytesFile(
      ref,
      '$stem-${Fmt.iso(_range.end)}.pdf',
      'application/pdf',
      bytes,
      what: 'Group report',
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

  /// The period the whole consolidation is drawn for.
  ///
  /// Extracted because it sits on the bar at a laptop width and under
  /// the tabs on a phone, and describing it twice is how the two come
  /// to disagree.
  Widget _rangeButton() => OutlinedButton.icon(
    key: const ValueKey('group-range'),
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
      Tab(text: 'Combined'),
      Tab(text: 'Consolidated'),
      Tab(text: 'Inter-company'),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final spec = _visibleSpec;
    final narrow = MediaQuery.sizeOf(context).width < 700;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Group'),
        actions: [
          IconButton(
            key: const ValueKey('group-download'),
            tooltip: 'Download PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
            onPressed: spec == null ? null : () => _download(spec),
          ),
          if (!narrow)
            Padding(
              padding: const EdgeInsets.only(right: 12, left: 4),
              child: _rangeButton(),
            ),
        ],
        // The same arrangement as `reports_screen.dart`, and for the
        // same measured reason: the range is twenty-three characters
        // and went 48 pixels off a 412px phone. It labels every figure
        // in the consolidation, so it moves rather than shortening.
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
      body: Column(
        children: [
          // Only over the combined tab. Saying "nothing has been
          // eliminated" above a consolidation that has just eliminated
          // it would be worse than saying nothing.
          if (_tabs.index == 0) const _CombinationNotice(),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _GroupReport(
                  provider: groupTrialBalanceProvider(_key),
                  spec: (rows) => groupTrialBalanceSpec(
                    rows,
                    _range,
                    companies: _companyCount,
                  ),
                  empty: const EmptyState(
                    icon: Icons.account_tree_outlined,
                    title: 'Nothing posted in the group',
                    message:
                        'Post documents in any company in the group and '
                        'they add up here.',
                  ),
                ),
                _GroupReport(
                  provider: groupConsolidatedProvider(_key),
                  spec: (rows) => consolidatedSpec(
                    rows,
                    _range,
                    companies: _companyCount,
                    unreconciled: _unreconciled,
                  ),
                  empty: const EmptyState(
                    icon: Icons.account_balance_outlined,
                    title: 'Nothing to consolidate',
                    message:
                        'Post documents in the companies of the group '
                        'and the consolidated position appears here.',
                  ),
                ),
                _GroupReport(
                  provider: groupIntercompanyProvider(_key),
                  spec: (rows) => intercompanySpec(rows, _range),
                  empty: const EmptyState(
                    icon: Icons.swap_horiz,
                    title: 'No trading between the companies',
                    message:
                        'Mark a customer or supplier as another company '
                        'in the group, and what passes between them appears '
                        'here.',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The sentence that stops somebody filing this as a consolidation.
///
/// On screen as well as on the PDF, because the person who reads the
/// figures and the person who prints them are often not the same, and
/// the one who reads them on screen is the one who decides what they
/// mean.
class _CombinationNotice extends StatelessWidget {
  const _CombinationNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: context.colors.info.withValues(alpha: 0.10),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: context.colors.info),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              'Combined, not consolidated. Nothing between the companies has '
              'been eliminated, so inter-company trading is counted twice. '
              'These are not statutory group accounts.',
              style: TextStyle(fontSize: 11, color: context.colors.info),
            ),
          ),
        ],
      ),
    );
  }
}

/// One group report, drawn from the same spec the PDF is drawn from.
///
/// The same shape as `_Report` on the Reports screen. Not shared with it
/// because the two differ in what they do with a refusal: a group whose
/// companies keep different currencies is refused by the database with a
/// sentence worth reading, and `AsyncView` shows it.
class _GroupReport extends ConsumerWidget {
  const _GroupReport({
    required this.provider,
    required this.spec,
    required this.empty,
  });

  final AutoDisposeFutureProvider<List<Map<String, dynamic>>> provider;
  final ReportSpec Function(List<Map<String, dynamic>> rows) spec;
  final Widget empty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(
      value: ref.watch(provider),
      onRetry: () => ref.invalidate(provider),
      // A report is lines of a label and a figure, and the person
      // has already said which report. What the rows decide is how
      // MANY lines and what they say -- not that the page is a column
      // of them.
      skeleton: const Padding(
        padding: EdgeInsets.all(Space.lg),
        child: CardRowsSkeleton(
          rows: 10,
          leading: false,
          lines: 1,
          trailing: 1,
          trailingWidth: 90,
          rowGap: Space.sm,
        ),
      ),
      builder: (rows) {
        if (rows.isEmpty) return empty;
        final s = spec(rows);

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
            maxWidth: 1280,
            child: ReportView(spec: s, wide: true),
          ),
        );
      },
    );
  }
}
