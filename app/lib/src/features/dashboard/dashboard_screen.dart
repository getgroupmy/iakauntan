import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/platform_catalog_repository.dart';
import 'ticker.dart';
import 'todo_card.dart';

/// The dashboard a company gets is the one its modules make.
///
/// This used to be four figures — revenue, expenses, receivables, bank
/// balance — a revenue chart and an ageing table, shown to everybody. A
/// firm that bought nothing but the service desk signed in to six
/// accounting numbers, all of them zero, and had to go looking for the
/// one screen it pays for.
///
/// So the page is assembled rather than fixed, and since every module
/// has its own tab rather than a share of one column, two people at the
/// same company can open this screen and see different things. That is
/// the point: a warehouse clerk and a bookkeeper hold different modules,
/// and a dashboard that mixed both left each of them scrolling past the
/// other's figures.
///
/// A tab exists for every module `moduleEnabled` admits — the company
/// holds it, and this person's access type does not say `none`. Which
/// is the same pair `module_dashboard` applies on the server, so a tab
/// can be trusted to be theirs.
///
/// Only ticketing, point of sale and the ledger report figures today.
/// The rest get a tab and an honest sentence rather than a blank panel,
/// because a blank panel under a module's name reads as broken.
/// The panels a person has asked for, from `Settings > Landing page`.
///
/// Unset means the defaults rather than nothing: a person who has never
/// opened the settings screen must not be handed a bare dashboard.
List<String> _cardsFor(WidgetRef ref) =>
    ref.watch(userPreferencesProvider).valueOrNull?.dashboardCards ??
    UserPreferences.defaultDashboardCards;

/// The Overview is not a module and has no code of its own.
///
/// The empty string is it, so `_view` is never null and the picker
/// never has to offer a "none" that means something different from
/// every other "none" in the app.
const String dashboardOverview = '';

/// What the picker offers: the Overview, then every module dashboard
/// this person reaches.
///
/// Pure, and separate from the screen, so the rule can be asserted:
/// `app/test/dashboard_views_test.dart`. `nameOf` rather than the label
/// map so the rule can be checked without the catalogue model.
///
/// The module CODE is a keyword as well as the name, because that is
/// what somebody who knows the product types — "pos" finds Point of
/// sale without them having to remember it is filed under P.
List<PickerOption<String>> dashboardViews(
  List<String> codes,
  String Function(String code) nameOf,
) =>
    [
      const PickerOption(
        value: dashboardOverview,
        label: 'Overview',
        sublabel: 'The figures everybody sees',
        keywords: ['general', 'summary', 'home', 'everything'],
      ),
      for (final code in codes)
        PickerOption(
          value: code,
          label: nameOf(code),
          sublabel: 'Module dashboard',
          keywords: [code],
        ),
    ];

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  /// Deliberately NOT remembered between visits. The landing page is the
  /// same for everybody every time; a dashboard that reopens on
  /// whatever was last looked at is a dashboard nobody can be told how
  /// to find their way around.
  String _view = dashboardOverview;

  Future<void> _refresh() async {
    refreshLedgerData(ref);
    ref.invalidate(moduleDashboardProvider);
    await ref.read(moduleDashboardProvider.future);
    if (_view == 'accounting') {
      await ref.read(dashboardProvider.future);
    }
  }

  @override
  Widget build(BuildContext context) {
    final org = ref.watch(currentOrgProvider).value;
    final labels = ref.watch(moduleLabelsProvider).valueOrNull ?? const {};

    // Which module dashboards this person actually reaches.
    // `moduleEnabled` asks both halves — the company holds it, and their
    // access type does not say `none` — which is the same pair
    // `module_dashboard` applies on the server. Two people at the same
    // company can open this screen and be offered different modules,
    // which is the point.
    final cards = _cardsFor(ref);
    final held = ref.watch(enabledModulesProvider);
    final codes = dashboardTabs(
      labels.keys,
      held.valueOrNull,
      (c) => moduleEnabled(ref, c),
    );
    final views = dashboardViews(
      codes,
      (c) => labels[c]?.name ?? c,
    );

    // A module that was switched off, or an access type narrowed, while
    // this screen was open. Falling back to the Overview beats showing
    // a pane for something this person no longer reaches.
    final view = views.any((v) => v.value == _view) ? _view : dashboardOverview;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              refreshLedgerData(ref);
              ref.invalidate(moduleDashboardProvider);
            },
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Greeting(orgName: org?.name ?? ''),
                const SizedBox(height: 16),

                // The strip of tabs this replaced put whichever module
                // sorted first in front of everybody, so a company
                // signed in to its mail settings rather than to its
                // figures. One box, the same landing view for everyone,
                // and the modules a search away.
                //
                // Only when there is more than the Overview to choose
                // between: a picker with one entry is furniture.
                if (codes.isNotEmpty) ...[
                  SearchablePicker<String>(
                    key: const ValueKey('dashboard-view'),
                    options: views,
                    value: view,
                    label: 'Showing',
                    hint: 'Search a module by name',
                    onChanged: (v) =>
                        setState(() => _view = v ?? dashboardOverview),
                  ),
                  const SizedBox(height: 16),
                ],

                if (view == dashboardOverview) ...[
                  if (cards.contains('ticker')) const DashboardTicker(),
                  if (cards.contains('todos')) ...[
                    const TodoCard(),
                    const SizedBox(height: 16),
                  ],
                  // Somebody who has switched both panels off, and holds
                  // no module either, would otherwise get a greeting and
                  // white space.
                  //
                  // But only once the entitlements have landed. They are
                  // a round trip, and telling somebody whose modules
                  // simply have not arrived yet that there is nothing to
                  // show sends them to a settings screen to fix
                  // something that is not broken.
                  if (!cards.contains('ticker') &&
                      !cards.contains('todos') &&
                      codes.isEmpty)
                    if (held.hasValue || held.hasError)
                      const EmptyState(
                        icon: Icons.dashboard_customize_outlined,
                        title: 'Nothing to show yet',
                        message: 'Choose what belongs here under '
                            'Settings \u203a Landing page, or turn a module '
                            'on under Settings \u203a Modules.',
                      )
                    else
                      const Center(child: CircularProgressIndicator()),
                ] else
                  ModuleDashboardPane(code: view),

                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The accounting dashboard, for the companies that keep books here.
class _Books extends ConsumerWidget {
  const _Books();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(dashboardProvider);

    return AsyncView(
      value: summary,
      onRetry: () => ref.invalidate(dashboardProvider),
      builder: (data) {
        // What this person asked to see. The e-Invoice banner is not on
        // the list on purpose: it is a REFUSAL waiting to be dealt with
        // rather than a panel, and a rejected submission somebody has
        // switched off is one LHDN is still waiting for.
        final cards = _cardsFor(ref);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (cards.contains('metrics')) ...[
              _MetricGrid(data: data),
              const SizedBox(height: 24),
            ],
            if (moduleEnabled(ref, 'einvoice') &&
                (data.einvoiceInvalid > 0 || data.einvoicePending > 0))
              _EinvoiceBanner(data: data),
            if (cards.contains('trend')) ...[
              const _TrendCard(),
              const SizedBox(height: 20),
            ],
            if (cards.contains('receivables'))
              if (moduleEnabled(ref, 'crm'))
                const _TwoColumn(
                  left: _ReceivablesCard(),
                  right: _ActivitiesCard(),
                )
              else
                const _ReceivablesCard(),
          ],
        );
      },
    );
  }
}

/// Which modules get a tab, and in what order.
///
/// Pure, and separate from the screen, so the rule can be asserted:
/// `app/test/dashboard_tabs_test.dart`. What it must not do is reorder
/// or duplicate — the tabs are read against the side menu, which is
/// built from the same `sort_order`, and a dashboard whose tabs disagree
/// with the menu is one somebody has to stop and think about.
///
/// Two lists, because they answer different questions and fail
/// differently. [platformOrder] is the catalogue — every module the
/// platform sells, in `sort_order`; it decides the order and nothing
/// else. [held] is what this company actually bought, and it decides
/// membership. An earlier version took the catalogue for both, which
/// meant a company whose entitlements had arrived but whose catalogue
/// had not was told every module was switched off — a lockout produced
/// by a slow read, on the one screen that opens first.
///
/// [held] is null when the entitlements are not known yet — still
/// loading, or the read failed. Then the catalogue stands in, which
/// keeps this as permissive as [moduleEnabled]: showing a tab to
/// somebody who turns out not to hold the module costs an empty panel,
/// hiding one from somebody who does costs them the product.
///
/// A held module the catalogue has never heard of still gets a tab,
/// after the ordered ones and in code order so the result is stable.
/// The alternative is a company that bought something and cannot see
/// it because a catalogue row is missing.
///
/// [reaches] is asked once per module and answers the pair that matters:
/// the company holds it and this person's access type does not say
/// `none`.
List<String> dashboardTabs(
  Iterable<String> platformOrder,
  Set<String>? held,
  bool Function(String code) reaches,
) {
  final ordered = platformOrder.toList();
  if (held == null) {
    return [
      for (final code in ordered)
        if (reaches(code)) code,
    ];
  }
  final known = ordered.toSet();
  return [
    for (final code in ordered)
      if (held.contains(code) && reaches(code)) code,
    for (final code in held.where((c) => !known.contains(c)).toList()..sort())
      if (reaches(code)) code,
  ];
}

/// The tiles one module contributes, or an empty list.
///
/// Split out per module so a tab can ask for its own. The keys come
/// from `module_dashboard`, which returns only what this company holds,
/// has not put away, and this person may read — so an absent key means
/// "not yours" or "nothing measured", and either way there is nothing
/// to draw.
List<Widget> moduleTiles(BuildContext context, String code,
    Map<String, dynamic> all) {
  Map<String, dynamic> block(String key) {
    final v = all[key];
    return v is Map ? Map<String, dynamic>.from(v) : const {};
  }

  num n(Map<String, dynamic> m, String key) => Fmt.toDouble(m[key]);

  final tiles = <Widget>[];

  if (code == 'ticketing' && all.containsKey('ticketing')) {
    final t = block('ticketing');
    final breaching = n(t, 'breaching');
    final breached = n(t, 'breached');
    tiles.addAll([
      StatTile(
        label: 'Open tickets',
        value: n(t, 'open').toStringAsFixed(0),
        caption: n(t, 'unassigned') > 0
            ? '${n(t, 'unassigned').toStringAsFixed(0)} unassigned'
            : 'All assigned',
        icon: Icons.confirmation_number_outlined,
        accent: context.colors.info,
        onTap: () => context.go('/tickets'),
      ),
      StatTile(
        label: 'Against the clock',
        value: breaching.toStringAsFixed(0),
        caption: breached > 0
            ? '${breached.toStringAsFixed(0)} already past due'
            : 'Due within four hours',
        icon: Icons.timer_outlined,
        accent: breaching > 0 ? context.colors.danger : null,
        onTap: () => context.go('/tickets'),
      ),
      StatTile(
        label: 'Resolved today',
        value: n(t, 'resolved_today').toStringAsFixed(0),
        caption: 'Closed off since midnight',
        icon: Icons.task_alt,
        accent: context.colors.success,
        onTap: () => context.go('/tickets'),
      ),
    ]);
  }

  if (code == 'crm' && all.containsKey('crm')) {
    final c = block('crm');
    final other = n(c, 'other_currency');
    final overdue = n(c, 'overdue_activities');
    tiles.addAll([
      StatTile(
        label: 'Open deals',
        value: n(c, 'open_deals').toStringAsFixed(0),
        // The value is the company's own currency only — 0303 does not
        // convert, because a rate lookup that raises would take the
        // whole dashboard with it. So when there are deals it could not
        // add up, the caption says so rather than showing a total that
        // is quietly short.
        caption: other > 0
            ? '${Fmt.money(n(c, 'open_value'))} plus '
                  '${other.toStringAsFixed(0)} in other currencies'
            : Fmt.money(n(c, 'open_value')),
        icon: Icons.handshake_outlined,
        accent: context.colors.info,
        onTap: () => context.go('/crm'),
      ),
      StatTile(
        label: 'Closing this month',
        value: n(c, 'closing_this_month').toStringAsFixed(0),
        caption: 'Expected to land by month end',
        icon: Icons.event_available_outlined,
        onTap: () => context.go('/crm'),
      ),
      StatTile(
        label: 'Won this month',
        value: n(c, 'won_this_month').toStringAsFixed(0),
        caption: 'By the date they closed',
        icon: Icons.emoji_events_outlined,
        accent: context.colors.success,
        onTap: () => context.go('/crm'),
      ),
      StatTile(
        label: 'Follow-ups overdue',
        value: overdue.toStringAsFixed(0),
        caption: overdue > 0 ? 'Somebody is waiting' : 'Nothing owed',
        icon: Icons.phone_missed_outlined,
        accent: overdue > 0 ? context.colors.danger : null,
        onTap: () => context.go('/crm'),
      ),
    ]);
  }

  if (code == 'secretarial' && all.containsKey('secretarial')) {
    final f = block('secretarial');
    final overdue = n(f, 'overdue');
    final soon = n(f, 'due_soon');
    // `next_due` is a date column, so it arrives as a string or not at
    // all — the server returns null when nothing is coming.
    final nextRaw = f['next_due'];
    final next = nextRaw == null ? null : DateTime.tryParse('$nextRaw');
    tiles.addAll([
      StatTile(
        label: 'Past their deadline',
        value: overdue.toStringAsFixed(0),
        // A late Annual Return is a compounding penalty and a charge
        // registered late is void against the liquidator, so this is
        // the one tile on the dashboard that should look alarming when
        // it is not zero.
        caption: overdue > 0 ? 'Lodge these first' : 'Nothing is late',
        icon: Icons.gavel_outlined,
        accent: overdue > 0 ? context.colors.danger : context.colors.success,
        onTap: () => context.go('/secretarial'),
      ),
      StatTile(
        label: 'Due within a month',
        value: soon.toStringAsFixed(0),
        // The date rather than a count of days: a secretary works to a
        // calendar, and "14 Sep" is what goes in the diary.
        caption: next != null
            ? 'Next on ${Fmt.date(next)}'
            : 'Nothing in the next month',
        icon: Icons.event_note_outlined,
        onTap: () => context.go('/secretarial'),
      ),
      StatTile(
        label: 'Companies on the register',
        value: n(f, 'entities').toStringAsFixed(0),
        caption: 'Live clients, struck-off ones aside',
        icon: Icons.apartment_outlined,
        onTap: () => context.go('/secretarial'),
      ),
    ]);
  }

  if (code == 'pos' && all.containsKey('pos')) {
    final p = block('pos');
    tiles.addAll([
      StatTile(
        label: 'Takings today',
        value: Fmt.money(n(p, 'takings_today')),
        caption: '${n(p, 'sales_today').toStringAsFixed(0)} sales rung up',
        icon: Icons.point_of_sale_outlined,
        accent: context.colors.success,
        onTap: () => context.go('/till'),
      ),
      StatTile(
        label: 'Bills still open',
        value: n(p, 'open_bills').toStringAsFixed(0),
        caption: n(p, 'open_shifts') > 0
            ? '${n(p, 'open_shifts').toStringAsFixed(0)} shifts open'
            : 'No shift open',
        icon: Icons.receipt_long_outlined,
        accent: n(p, 'open_bills') > 0 ? context.colors.warning : null,
        onTap: () => context.go('/till'),
      ),
    ]);
  }

  if (code == 'inventory' && all.containsKey('inventory')) {
    final i = block('inventory');
    final reorder = n(i, 'to_reorder');
    final out = n(i, 'out_of_stock');
    tiles.addAll([
      StatTile(
        label: 'Stock value',
        value: Fmt.money(n(i, 'stock_value')),
        caption: '${n(i, 'items_held').toStringAsFixed(0)} items held',
        icon: Icons.inventory_2_outlined,
        onTap: () => context.go('/items'),
      ),
      StatTile(
        label: 'To reorder',
        value: reorder.toStringAsFixed(0),
        // Pooled across warehouses by 0300, so this is a count of
        // purchase orders somebody has to raise rather than of shelves
        // that happen to be low.
        caption: reorder > 0 ? 'At or under their level' : 'Nothing running low',
        icon: Icons.add_shopping_cart_outlined,
        accent: reorder > 0 ? context.colors.warning : null,
        onTap: () => context.go('/items'),
      ),
      StatTile(
        label: 'Out of stock',
        value: out.toStringAsFixed(0),
        caption: out > 0 ? 'None anywhere' : 'Everything in stock',
        icon: Icons.remove_shopping_cart_outlined,
        accent: out > 0 ? context.colors.danger : context.colors.success,
        // The stock take rather than the item list: an item the system
        // thinks is empty is a shelf somebody has to go and look at.
        onTap: () => context.go('/stock-take'),
      ),
    ]);
  }

  if (code == 'hr' && all.containsKey('hr')) {
    final h = block('hr');
    final leave = n(h, 'leave_to_approve');
    final claims = n(h, 'claims_to_approve');
    tiles.addAll([
      StatTile(
        label: 'Headcount',
        value: n(h, 'headcount').toStringAsFixed(0),
        // Probation and notice are employment and both get paid, so
        // both are in the figure. 0301 says why at length.
        caption: '${n(h, 'on_leave_today').toStringAsFixed(0)} away today',
        icon: Icons.badge_outlined,
        onTap: () => context.go('/hr/people'),
      ),
      StatTile(
        label: 'Leave to approve',
        value: leave.toStringAsFixed(0),
        caption: leave > 0 ? 'Waiting on somebody' : 'Nothing waiting',
        icon: Icons.beach_access_outlined,
        accent: leave > 0 ? context.colors.warning : null,
        onTap: () => context.go('/hr/leave'),
      ),
      StatTile(
        label: 'Claims to approve',
        value: claims.toStringAsFixed(0),
        caption: claims > 0 ? 'Waiting on somebody' : 'Nothing waiting',
        icon: Icons.receipt_outlined,
        accent: claims > 0 ? context.colors.warning : null,
        onTap: () => context.go('/hr/claims'),
      ),
    ]);
  }

  if (code == 'payroll' && all.containsKey('payroll')) {
    final r = block('payroll');
    final approve = n(r, 'to_approve');
    final pay = n(r, 'to_pay');
    tiles.addAll([
      StatTile(
        label: 'Runs open',
        value: n(r, 'open_runs').toStringAsFixed(0),
        caption: 'Not yet paid',
        icon: Icons.payments_outlined,
        onTap: () => context.go('/hr/payroll'),
      ),
      StatTile(
        label: 'To approve',
        value: approve.toStringAsFixed(0),
        caption: approve > 0 ? 'Calculated, awaiting sign-off' : 'None waiting',
        icon: Icons.fact_check_outlined,
        accent: approve > 0 ? context.colors.warning : null,
        onTap: () => context.go('/hr/payroll'),
      ),
      StatTile(
        label: 'To pay',
        value: pay.toStringAsFixed(0),
        caption: pay > 0 ? 'Signed off, not paid' : 'Nothing outstanding',
        icon: Icons.account_balance_outlined,
        accent: pay > 0 ? context.colors.info : null,
        onTap: () => context.go('/hr/payroll'),
      ),
    ]);
  }

  return tiles;
}

/// A module's figures, laid out, or an honest word about there being
/// none yet.
///
/// The empty state is the point of saying it out loud. Only ticketing,
/// point of sale and the ledger produce figures today; every other
/// module reaches this screen with nothing, and a blank panel under a
/// tab with the module's name on it reads as something broken rather
/// than as something not built.
class ModuleDashboardPane extends ConsumerWidget {
  const ModuleDashboardPane({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (code == 'accounting') return const _Books();

    final all = ref.watch(moduleDashboardProvider).valueOrNull ?? const {};
    final tiles = moduleTiles(context, code, all);

    if (tiles.isEmpty) {
      return const EmptyState(
        icon: Icons.insights_outlined,
        title: 'Nothing measured here yet',
        message: 'This module does not report figures to the dashboard. '
            'Its own screens have everything it records.',
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1100 ? 4 : (width >= 700 ? 2 : 1);

    return GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: columns == 1 ? 3.2 : 1.75,
      children: tiles,
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.orgName});

  final String orgName;

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Selamat pagi'
        : hour < 19
            ? 'Selamat petang'
            : 'Selamat malam';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          greeting,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        ),
        const SizedBox(height: 2),
        Text(
          '$orgName · ${Fmt.longDate(DateTime.now())}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

class _MetricGrid extends ConsumerWidget {
  const _MetricGrid({required this.data});

  final DashboardSummary data;

  /// Month-on-month change, or null when there is not enough history to
  /// claim one. A first month in business is not a 100% rise.
  static double? _delta(List<double> series) {
    if (series.length < 2) return null;
    final previous = series[series.length - 2];
    if (previous == 0) return null;
    return (series.last - previous) / previous;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1100 ? 4 : (width >= 700 ? 2 : 1);

    // The same series the chart below uses; the tiles show its shape so the
    // top row answers "which way is this going" without scrolling.
    final rows = ref.watch(revenueTrendProvider).valueOrNull ?? const [];
    final revenueSeries = [
      for (final r in rows) Fmt.toDouble(r['revenue']),
    ];
    final expenseSeries = [
      for (final r in rows) Fmt.toDouble(r['expenses']),
    ];

    final tiles = <Widget>[
      StatTile(
        label: 'Revenue this month',
        value: Fmt.money(data.revenue),
        caption: 'Invoiced, excluding drafts',
        icon: Icons.trending_up,
        accent: context.colors.success,
        trend: revenueSeries,
        delta: _delta(revenueSeries),
      ),
      StatTile(
        label: 'Expenses this month',
        value: Fmt.money(data.expenses),
        caption: 'Supplier bills',
        icon: Icons.trending_down,
        accent: context.colors.warning,
        trend: expenseSeries,
        delta: _delta(expenseSeries),
        // Spending more than last month is not an achievement.
        deltaIsGood: false,
      ),
      StatTile(
        label: 'Receivables',
        value: Fmt.money(data.receivables),
        caption: data.overdueReceivables > 0
            ? '${Fmt.money(data.overdueReceivables)} overdue'
            : 'Nothing overdue',
        icon: Icons.account_balance_wallet_outlined,
        accent: data.overdueReceivables > 0 ? context.colors.danger : null,
      ),
      StatTile(
        label: 'Bank balance',
        value: Fmt.money(data.bankBalance),
        caption: 'Across active accounts',
        icon: Icons.account_balance,
        accent: context.colors.info,
      ),
    ];

    return GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: columns == 1 ? 3.2 : 1.75,
      children: tiles,
    );
  }
}

class _EinvoiceBanner extends ConsumerWidget {
  const _EinvoiceBanner({required this.data});

  final DashboardSummary data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needsAttention = data.einvoiceInvalid > 0;
    final color = needsAttention ? context.colors.danger : context.colors.warning;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => context.go('/einvoice'),
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Row(
              children: [
                Icon(
                  needsAttention ? Icons.error_outline : Icons.schedule,
                  color: color,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        needsAttention
                            ? '${data.einvoiceInvalid} e-Invoice(s) rejected by LHDN'
                            : '${data.einvoicePending} e-Invoice(s) awaiting validation',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        needsAttention
                            ? 'Fix the validation errors and resubmit.'
                            : 'MyInvois usually validates within a few minutes.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrendCard extends ConsumerWidget {
  const _TrendCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trend = ref.watch(revenueTrendProvider);
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Revenue vs expenses',
              subtitle: 'Last 12 months',
            ),
            SizedBox(
              height: 240,
              child: AsyncView(
                value: trend,
                onRetry: () => ref.invalidate(revenueTrendProvider),
                builder: (rows) {
                  if (rows.isEmpty) {
                    return const EmptyState(
                      icon: Icons.show_chart,
                      title: 'No data yet',
                      message: 'Post your first invoice to see the trend.',
                    );
                  }

                  final revenue = <FlSpot>[];
                  final expenses = <FlSpot>[];
                  var maxY = 0.0;

                  for (var i = 0; i < rows.length; i++) {
                    final r = Fmt.toDouble(rows[i]['revenue']);
                    final e = Fmt.toDouble(rows[i]['expenses']);
                    revenue.add(FlSpot(i.toDouble(), r));
                    expenses.add(FlSpot(i.toDouble(), e));
                    maxY = [maxY, r, e].reduce((a, b) => a > b ? a : b);
                  }

                  return LineChart(
                    LineChartData(
                      minY: 0,
                      maxY: maxY == 0 ? 1000 : maxY * 1.2,
                      gridData: FlGridData(
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (_) => FlLine(
                          color: scheme.outlineVariant.withValues(alpha: 0.5),
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(),
                        rightTitles: const AxisTitles(),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 48,
                            getTitlesWidget: (value, meta) => Text(
                              Fmt.compact(value),
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: rows.length > 6 ? 2 : 1,
                            getTitlesWidget: (value, meta) {
                              final i = value.toInt();
                              if (i < 0 || i >= rows.length) {
                                return const SizedBox.shrink();
                              }
                              final period = Fmt.parseDate(rows[i]['period']);
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  period == null
                                      ? ''
                                      : Fmt.monthYear(period).split(' ').first,
                                  style: const TextStyle(fontSize: 10),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      lineBarsData: [
                        _line(revenue, context.colors.success),
                        _line(expenses, context.colors.warning),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _Legend(color: context.colors.success, label: 'Revenue'),
                SizedBox(width: 20),
                _Legend(color: context.colors.warning, label: 'Expenses'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static LineChartBarData _line(List<FlSpot> spots, Color color) =>
      LineChartBarData(
        spots: spots,
        isCurved: true,
        curveSmoothness: 0.25,
        color: color,
        barWidth: 2.5,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(
          show: true,
          color: color.withValues(alpha: 0.10),
        ),
      );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _ReceivablesCard extends ConsumerWidget {
  const _ReceivablesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final aging = ref.watch(arAgingProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Outstanding invoices',
              action: TextButton(
                onPressed: () => context.go('/sales/invoice'),
                child: const Text('View all'),
              ),
            ),
            AsyncView(
              value: aging,
              onRetry: () => ref.invalidate(arAgingProvider),
              loading: const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              ),
              builder: (all) {
                // The aged listing carries the credits too — unapplied
                // receipts and unused credit notes — because that is
                // what makes it foot to the control account. This card
                // is about who owes money, so they are left out here.
                final rows = all
                    .where((r) => Fmt.toDouble(r['outstanding']) > 0)
                    .toList()
                  ..sort((a, b) => Fmt.toInt(b['days_overdue'])
                      .compareTo(Fmt.toInt(a['days_overdue'])));

                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.check_circle_outline,
                    title: 'All settled',
                    message: 'No outstanding customer invoices.',
                  );
                }
                return Column(
                  children: [
                    for (final row in rows.take(6))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          row['contact_name']?.toString() ?? '—',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        subtitle: Text(
                          '${row['doc_no']} · due ${Fmt.date(Fmt.parseDate(row['due_date']))}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Money(
                              Fmt.toDouble(row['outstanding']),
                              currency: row['currency']?.toString() ?? 'MYR',
                              bold: true,
                            ),
                            if (Fmt.toInt(row['days_overdue']) > 0)
                              Text(
                                '${row['days_overdue']} days late',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: context.colors.danger,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivitiesCard extends ConsumerWidget {
  const _ActivitiesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activities = ref.watch(activitiesProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Upcoming activities',
              action: TextButton(
                onPressed: () => context.go('/crm'),
                child: const Text('Pipeline'),
              ),
            ),
            AsyncView(
              value: activities,
              onRetry: () => ref.invalidate(activitiesProvider),
              loading: const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              ),
              builder: (rows) {
                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.event_available,
                    title: 'Nothing scheduled',
                    message: 'Follow-ups you plan will show up here.',
                  );
                }
                return Column(
                  children: [
                    for (final row in rows.take(6))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .primaryContainer,
                          child: Icon(
                            _activityIcon(row['activity_type']?.toString()),
                            size: 15,
                          ),
                        ),
                        title: Text(
                          row['subject']?.toString() ?? '—',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          Fmt.dateTime(Fmt.parseDate(row['due_date'])),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static IconData _activityIcon(String? type) => switch (type) {
        'call' => Icons.phone,
        'email' => Icons.mail_outline,
        'meeting' => Icons.groups_outlined,
        'whatsapp' => Icons.chat_bubble_outline,
        'site_visit' => Icons.place_outlined,
        'demo' => Icons.slideshow_outlined,
        _ => Icons.task_alt,
      };
}

/// Side-by-side on desktop, stacked on narrow screens.
class _TwoColumn extends StatelessWidget {
  const _TwoColumn({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 900) {
      return Column(children: [left, const SizedBox(height: 20), right]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 20),
        Expanded(child: right),
      ],
    );
  }
}
