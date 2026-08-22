import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/live_updates.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../chat/call_incoming.dart';
import '../chat/chat_live.dart';

/// Navigation destination shared by the rail (wide) and bottom bar (narrow).
class _Dest {
  const _Dest(
    this.label,
    this.icon,
    this.selectedIcon,
    this.path, {
    this.primary = false,
    this.module,
    this.altModule,
    this.platformOnly = false,
    this.adminOnly = false,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String path;

  /// Primary destinations get a slot in the mobile bottom bar; the rest
  /// live behind "More".
  final bool primary;

  /// Module this destination belongs to. Hidden when the company does
  /// not hold it, and hidden when the company holds it but has put it
  /// away — `moduleEnabled` asks both questions, and 0234 keeps them
  /// apart on the server.
  ///
  /// Every destination but Dashboard, Import, Team, Email and Settings
  /// carries one. Those five are the workspace rather than the product:
  /// a company that uses nothing but the service desk still has people
  /// to invite and a company name to change, and Settings is where a
  /// module that has been put away is taken out again — hiding it would
  /// be a door that locks behind you.
  ///
  /// The database blocks the writes regardless. This just avoids showing
  /// doors that will not open, and doors nobody asked for.
  final String? module;

  /// A second add-on that also opens this destination. Property is sold
  /// as strata and non-strata, and either one is a reason to show the
  /// portfolio — a company managing only shoplots still has a portfolio.
  final String? altModule;

  /// Only visible to platform staff.
  final bool platformOnly;

  /// Only visible to an owner or an admin of this company.
  ///
  /// Not a module: the security log is not sold, it is part of keeping
  /// books. It is hidden from everybody else because it says where each
  /// colleague works from, and `security_log` refuses them anyway -- so
  /// showing it would be a door that opens onto an error message.
  final bool adminOnly;
}

const _destinations = <_Dest>[
  _Dest(
    'Dashboard',
    Icons.dashboard_outlined,
    Icons.dashboard,
    '/',
    primary: true,
  ),
  _Dest(
    'Sales',
    Icons.receipt_long_outlined,
    Icons.receipt_long,
    '/sales/invoice',
    primary: true,
    module: 'sales',
  ),
  _Dest(
    'Purchases',
    Icons.shopping_bag_outlined,
    Icons.shopping_bag,
    '/purchases/bill',
    module: 'purchases',
  ),
  _Dest(
    'Expenses',
    Icons.receipt_outlined,
    Icons.receipt,
    '/expenses',
    module: 'accounting',
  ),
  _Dest(
    'Matters',
    Icons.gavel_outlined,
    Icons.gavel,
    '/legal',
    module: 'legal',
  ),
  _Dest(
    'Contacts',
    Icons.people_outline,
    Icons.people,
    '/contacts',
    primary: true,
    module: 'contacts',
  ),
  _Dest(
    'Items',
    Icons.inventory_2_outlined,
    Icons.inventory_2,
    '/items',
    module: 'inventory',
  ),
  _Dest(
    'CRM',
    Icons.trending_up_outlined,
    Icons.trending_up,
    '/crm',
    primary: true,
    module: 'crm',
  ),
  _Dest(
    'Leads',
    Icons.filter_alt_outlined,
    Icons.filter_alt,
    '/crm/leads',
    module: 'crm',
  ),
  _Dest(
    'e-Invoice',
    Icons.verified_outlined,
    Icons.verified,
    '/einvoice',
    module: 'einvoice',
  ),
  _Dest('My HR', Icons.badge_outlined, Icons.badge, '/hr/me', module: 'hr'),
  _Dest(
    'People',
    Icons.groups_outlined,
    Icons.groups,
    '/hr/people',
    module: 'hr',
  ),
  _Dest(
    'Leave',
    Icons.event_available_outlined,
    Icons.event_available,
    '/hr/leave',
    module: 'hr',
  ),
  _Dest(
    'Claims',
    Icons.request_quote_outlined,
    Icons.request_quote,
    '/hr/claims',
    module: 'hr',
  ),
  _Dest(
    'Payroll',
    Icons.payments_outlined,
    Icons.payments,
    '/hr/payroll',
    module: 'payroll',
  ),
  _Dest('Talent', Icons.work_outline, Icons.work, '/hr/talent', module: 'hr'),
  _Dest(
    'Onboarding',
    Icons.checklist_rtl_outlined,
    Icons.checklist_rtl,
    '/hr/onboarding',
    module: 'hr',
  ),
  _Dest('HR setup', Icons.tune_outlined, Icons.tune, '/hr/setup', module: 'hr'),
  _Dest(
    'Secretarial',
    Icons.domain_outlined,
    Icons.domain,
    '/secretarial',
    module: 'secretarial',
  ),
  _Dest(
    'Stock take',
    Icons.checklist_outlined,
    Icons.checklist,
    '/stock-take',
    module: 'inventory',
  ),
  _Dest(
    'Batches',
    Icons.qr_code_2_outlined,
    Icons.qr_code_2,
    '/lots',
    module: 'inventory',
  ),
  // Stock leaving one store for another, and stock becoming something
  // else on the way. Beside the other stock screens because both
  // questions are asked while looking at a shelf.
  _Dest(
    'Transfers',
    Icons.local_shipping_outlined,
    Icons.local_shipping,
    '/transfers',
    module: 'inventory',
  ),
  // Next to transfers, because both are about stock that has moved and
  // money that has to follow it.
  _Dest(
    'Landed cost',
    Icons.anchor_outlined,
    Icons.anchor,
    '/landed-cost',
    module: 'inventory',
  ),
  // With the stock screens: what a bundle is made of is a question
  // asked while looking at a shelf, and the answer is what leaves it.
  _Dest(
    'Bundles',
    Icons.widgets_outlined,
    Icons.widgets,
    '/bundles',
    module: 'inventory',
  ),
  // With the ledger screens rather than the stock ones: a contra is
  // about two control accounts, and the person who strikes one is
  // looking at an aged listing, not at a shelf.
  _Dest(
    'Contra',
    Icons.swap_horiz_outlined,
    Icons.swap_horiz,
    '/contra',
    module: 'sales',
  ),
  // Beside contra, because both are money that settles a document
  // without a receipt being written for it.
  _Dest(
    'Deposits',
    Icons.savings_outlined,
    Icons.savings,
    '/deposits',
    module: 'sales',
  ),
  // With the ledger rather than the reports, because a budget is a
  // thing somebody maintains all year and looks at monthly, not a
  // report they run once.
  _Dest(
    'Budgets',
    Icons.flag_outlined,
    Icons.flag,
    '/budgets',
    module: 'accounting',
  ),
  // With deposits and contra: all three are money that settles a
  // document without a receipt, and all three are read while looking at
  // an aged listing.
  _Dest(
    'Cheques',
    Icons.event_note_outlined,
    Icons.event_note,
    '/cheques',
    module: 'sales',
  ),
  // Next to the budget: both are forward-looking, and both are read by
  // the person who has to decide something rather than record it.
  _Dest(
    'Cash flow',
    Icons.show_chart_outlined,
    Icons.show_chart,
    '/cash-flow',
    module: 'accounting',
  ),
  // With the stock screens, because the question it answers — what is
  // running out — is asked while looking at what is on the shelf.
  _Dest(
    'Replenishment',
    Icons.inventory_outlined,
    Icons.inventory,
    '/forecasting',
    module: 'forecasting',
  ),
  // Above the ledger screens rather than among them. Somebody standing
  // at a till is not doing accounting, and the thing they need is the
  // one thing they need all day.
  _Dest(
    'Till',
    Icons.point_of_sale_outlined,
    Icons.point_of_sale,
    '/till',
    module: 'pos',
  ),
  // Beside the till rather than inside it. A waiter working the room
  // and a cashier working the counter are two people on two devices,
  // and making one of them a tab of the other's screen would put a
  // dining room behind a drawer they never open.
  _Dest(
    'Floor',
    Icons.table_restaurant_outlined,
    Icons.table_restaurant,
    '/floor',
    module: 'pos',
  ),
  _Dest(
    'Kitchen',
    Icons.soup_kitchen_outlined,
    Icons.soup_kitchen,
    '/kitchen',
    module: 'pos',
  ),
  _Dest(
    'Diary',
    Icons.event_note_outlined,
    Icons.event_note,
    '/diary',
    module: 'pos',
  ),
  // A control rather than a screen anybody works in, which is why it
  // sits with the till and not in Reports: the person who needs it is
  // the person who runs the shop, and Reports is gated on accounting
  // that a food stall may not have bought.
  // The line at the door, beside the floor plan it feeds.
  _Dest(
    'Queue',
    Icons.people_outline,
    Icons.people,
    '/queue',
    module: 'pos',
  ),
  // Everything out on a motorbike, beside the queue for the same
  // reason: both are somebody standing at the pass being asked how much
  // longer.
  _Dest(
    'Deliveries',
    Icons.moped_outlined,
    Icons.moped,
    '/deliveries',
    module: 'pos',
  ),
  // When each part of the menu is offered. Beside promotions, because
  // both are a shop deciding in advance what the till may do.
  _Dest(
    'Menu times',
    Icons.schedule_outlined,
    Icons.schedule,
    '/menu-times',
    module: 'pos',
  ),
  // Beside the till rather than in Reports: writing a happy hour down
  // is running a shop, not analysing one.
  _Dest(
    'Promotions',
    Icons.local_offer_outlined,
    Icons.local_offer,
    '/promotions',
    module: 'pos',
  ),
  _Dest(
    // Not "Voids" since 0255: the screen carries the discount report
    // too, and a manager looking for where the price went would not
    // have thought to open a page named after voiding.
    'Off the bills',
    Icons.remove_shopping_cart_outlined,
    Icons.remove_shopping_cart,
    '/voids',
    module: 'pos',
  ),
  // Its own module since 0231, and gated on that rather than on the
  // till: a gym that runs memberships and a minimart that does not are
  // the reason the two were separated in the first place.
  _Dest(
    'Memberships',
    Icons.card_membership_outlined,
    Icons.card_membership,
    '/memberships',
    module: 'memberships',
  ),
  // Its own module too, and the pair a shop chooses between: a gym
  // runs memberships, a minimart runs a points card.
  _Dest(
    'Loyalty',
    Icons.card_giftcard_outlined,
    Icons.card_giftcard,
    '/loyalty',
    module: 'loyalty',
  ),
  // The customer's own screen, and the screen they watch afterwards.
  // Both are on the staff menu because somebody has to be able to set
  // the machine up and check on it; neither is a place a cashier
  // works.
  _Dest(
    'Kiosk',
    Icons.storefront_outlined,
    Icons.storefront,
    '/kiosk',
    module: 'pos',
  ),
  // Where a bar is created, "drinks go to it" is said, and a shop
  // decides it does deliveries. Setup rather than daily work, but it
  // sits with the POS screens because the person who does it is the
  // person who runs the shop, not the person who administers the
  // company.
  _Dest(
    'Outlet setup',
    Icons.rule_outlined,
    Icons.rule,
    '/counters',
    module: 'pos',
  ),
  // What a plate is made of, and how many more of it the store can
  // make. Beside the outlet setup because it is the kitchen's own
  // configuration rather than a report about it.
  _Dest(
    'Recipes',
    Icons.restaurant_menu_outlined,
    Icons.restaurant_menu,
    '/recipes',
    module: 'pos',
  ),
  // A court is one room and a dozen businesses. Beside the recipes
  // because both answer "whose food is this" — one for the store, one
  // for the till.
  _Dest(
    'Stalls',
    Icons.storefront_outlined,
    Icons.storefront,
    '/stalls',
    module: 'pos',
  ),
  // The other half of Takings: the questions we did not think of. Built
  // by whoever runs the shop, out of the same sales.
  _Dest(
    'Report builder',
    Icons.query_stats_outlined,
    Icons.query_stats,
    '/pos-reports',
    module: 'pos',
  ),
  // The owner's view rather than the shop's: every outlet's day on one
  // board. Beside the till screens because it is about the shops, not
  // beside the ledger reports it is not made of.
  _Dest(
    'Takings',
    Icons.query_stats_outlined,
    Icons.query_stats,
    '/takings',
    module: 'pos',
  ),
  _Dest(
    'Order board',
    Icons.tv_outlined,
    Icons.tv,
    '/order-board',
    module: 'pos',
  ),
  _Dest('Chat', Icons.forum_outlined, Icons.forum, '/chat', module: 'chat'),
  // No module gate. Chasing an unpaid invoice is what the sales ledger
  // is for when a customer does not pay, and sales is core.
  _Dest(
    'Collections',
    Icons.phone_forwarded_outlined,
    Icons.phone_forwarded,
    '/collections',
    module: 'sales',
  ),
  _Dest(
    'Approvals',
    Icons.how_to_reg_outlined,
    Icons.how_to_reg,
    '/approvals',
    module: 'approvals',
  ),
  // Beside the reports it is assembled from rather than beside the
  // corporate secretarial work it is lodged for: preparing a set of
  // accounts is an accounting job, and the person doing it is already
  // looking at the trial balance.
  _Dest(
    'Financial statements',
    Icons.description_outlined,
    Icons.description,
    '/financial-statements',
    module: 'mbrs',
  ),
  // Legal firms already record time; everyone else who sells hours now
  // can too, which is why this answers to either module.
  _Dest(
    'Timesheets',
    Icons.schedule_outlined,
    Icons.schedule,
    '/timesheets',
    module: 'timesheets',
    altModule: 'legal',
  ),
  // Next to the modules whose work it interrupts. A service desk is
  // read between other jobs rather than sat in all day, so it sits with
  // them rather than at the bottom of the list.
  _Dest(
    'Service desk',
    Icons.support_agent_outlined,
    Icons.support_agent,
    '/tickets',
    module: 'ticketing',
  ),
  // Two modules, one destination. Which half of it a site belongs to is
  // a fact about the site, not a choice in the navigation, and an agent
  // holding both has one portfolio rather than two lists.
  _Dest(
    'Property',
    Icons.apartment_outlined,
    Icons.apartment,
    '/property',
    module: 'property_strata',
    altModule: 'property_nonstrata',
  ),
  _Dest(
    'Manufacturing',
    Icons.precision_manufacturing_outlined,
    Icons.precision_manufacturing,
    '/manufacturing',
    module: 'manufacturing',
  ),
  // Directly after the documents it settles, because "has this been
  // paid?" is asked in the same breath as "did we invoice them?".
  _Dest(
    'Receipts & payments',
    Icons.payments_outlined,
    Icons.payments,
    '/receipts',
    module: 'accounting',
  ),
  _Dest(
    'Reconcile',
    Icons.account_balance_outlined,
    Icons.account_balance,
    '/reconcile',
    module: 'accounting',
  ),
  _Dest(
    'Fixed assets',
    Icons.inventory_2_outlined,
    Icons.inventory_2,
    '/assets',
    module: 'fixed_assets',
  ),
  _Dest(
    'Journals',
    Icons.menu_book_outlined,
    Icons.menu_book,
    '/journals',
    module: 'accounting',
  ),
  _Dest(
    'Recurring journals',
    Icons.repeat,
    Icons.repeat_on,
    '/recurring',
    module: 'accounting',
  ),
  _Dest(
    'Recurring invoices',
    Icons.event_repeat_outlined,
    Icons.event_repeat,
    '/recurring-documents',
    module: 'sales',
  ),
  _Dest(
    'Withholding tax',
    Icons.account_balance_outlined,
    Icons.account_balance,
    '/withholding',
    module: 'accounting',
  ),
  _Dest(
    'Salespeople',
    Icons.badge_outlined,
    Icons.badge,
    '/salespeople',
    module: 'sales',
  ),
  _Dest(
    'Exchange rates',
    Icons.currency_exchange_outlined,
    Icons.currency_exchange,
    '/exchange-rates',
    module: 'accounting',
  ),
  _Dest('Import', Icons.upload_file_outlined, Icons.upload_file, '/import'),
  _Dest(
    'Reports',
    Icons.bar_chart_outlined,
    Icons.bar_chart,
    '/reports',
    module: 'accounting',
  ),
  _Dest('Team', Icons.manage_accounts_outlined, Icons.manage_accounts, '/team'),
  _Dest(
    'Security',
    Icons.shield_outlined,
    Icons.shield,
    '/security',
    adminOnly: true,
  ),
  _Dest('Email', Icons.mail_outline, Icons.mail, '/email'),
  _Dest('Settings', Icons.settings_outlined, Icons.settings, '/settings'),
  _Dest(
    'Platform',
    Icons.shield_outlined,
    Icons.shield,
    '/admin',
    platformOnly: true,
  ),
];

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child, required this.location});

  final Widget child;
  final String location;

  static const _railBreakpoint = 900.0;

  /// Material's own defaults for the rail, named here because the header
  /// sits beside the rail rather than inside it and has to match.
  static const _extendedWidth = 256.0;
  static const _collapsedWidth = 80.0;

  /// Destinations this user can actually reach: modules the company
  /// holds and has not put away, plus the platform console for staff.
  List<_Dest> _visible(WidgetRef ref) {
    final isPlatformAdmin = ref.watch(isPlatformAdminProvider).value ?? false;

    // Every destination but the console reads from an organization, so
    // with none selected they are doors onto an empty room. A platform
    // operator belongs to no company and would otherwise be handed a full
    // rail of screens that can only fail.
    final hasOrg =
        (ref.watch(organizationsProvider).value ?? const []).isNotEmpty;

    final isAdmin = ref.watch(canAdminProvider);

    return _destinations.where((d) {
      if (d.platformOnly) return isPlatformAdmin;
      if (!hasOrg) return false;
      if (d.adminOnly && !isAdmin) return false;
      if (d.module == null) return true;
      if (moduleEnabled(ref, d.module!)) return true;
      return d.altModule != null && moduleEnabled(ref, d.altModule!);
    }).toList();
  }

  int _selectedIndexIn(List<_Dest> dests) {
    // Longest matching prefix wins so /sales/invoice/123 still lights up Sales.
    var best = 0;
    var bestLength = 0;
    for (var i = 0; i < dests.length; i++) {
      final path = dests[i].path;
      final match = path == '/' ? location == '/' : location.startsWith(path);
      if (match && path.length >= bestLength) {
        best = i;
        bestLength = path.length;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Kept alive for as long as there is a shell around a signed-in
    // user, which is the whole time anybody can see anything worth
    // updating. It follows the organization by itself — switching
    // company tears the subscription down and opens the right one.
    ref.watch(liveUpdatesProvider);

    final dests = _visible(ref);

    // Both Material navigation widgets require at least two destinations,
    // and there are two ordinary ways to have fewer: a platform operator
    // belongs to no company and so sees only the console, and on the very
    // first frame the platform-admin answer has not arrived yet and the
    // list is empty. Either one puts selectedIndex out of range, which
    // throws while building — and a release build renders a thrown build
    // as a blank page, with no clue as to why.
    if (dests.length < 2) return _bareLayout(context, dests);

    final wide = MediaQuery.sizeOf(context).width >= _railBreakpoint;
    return _reachableByCall(
      ref,
      wide
          ? _wideLayout(context, ref, dests)
          : _narrowLayout(context, ref, dests),
    );
  }

  /// A ringing phone, wherever in the app somebody happens to be.
  ///
  /// This started on the chat screen, which meant a call reached only
  /// people who already had chat open — which is nobody, because the
  /// reason to ring somebody is that they are doing something else. The
  /// socket that carries it belongs here for the same reason.
  ///
  /// Still gated, and on an answer rather than a guess: `moduleEnabled`
  /// reads "still loading" as yes so navigation does not flicker, which
  /// is right for a menu item and wrong for opening a socket and
  /// starting a heartbeat in a company that never bought chat. So this
  /// waits for the real answer.
  Widget _reachableByCall(WidgetRef ref, Widget child) {
    final modules = ref.watch(enabledModulesProvider).value;
    if (modules == null || !modules.contains('chat')) return child;
    if (!moduleEnabled(ref, 'chat')) return child;

    ref.watch(chatLiveProvider);
    // Catches an endpoint the browser has rotated since last time. Never
    // prompts: a browser that has not been asked stays unasked until
    // somebody presses the button in Settings.
    ref.watch(pushRegistrarProvider);
    return IncomingCallWatcher(child: child);
  }

  /// No navigation, because there is nowhere else to go — but still the
  /// account button, so whoever is here can sign out.
  Widget _bareLayout(BuildContext context, List<_Dest> dests) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 72,
            child: Column(
              children: [
                const _RailHeader(extended: false),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _AccountButton(),
                ),
              ],
            ),
          ),
          VerticalDivider(
            width: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _wideLayout(BuildContext context, WidgetRef ref, List<_Dest> dests) {
    final scheme = Theme.of(context).colorScheme;
    final extended = MediaQuery.sizeOf(context).width >= 1200;

    return Scaffold(
      body: Row(
        children: [
          // NavigationRail does not scroll. With every module switched on
          // there are twenty-one destinations, which is taller than a
          // laptop screen — everything below HR setup simply could not be
          // reached, with no scrollbar to suggest there was more.
          //
          // The scroll view needs a minimum height of the viewport so the
          // rail still fills the screen when the list is short, and
          // IntrinsicHeight so that the Expanded in `trailing` — which is
          // what pins the account button to the bottom — has a bounded
          // height to expand into.
          SizedBox(
            // A definite width, because IntrinsicHeight below measures
            // this subtree and an intrinsic pass offers unbounded width.
            // The company switcher is a Row that fills its line, and a
            // Row cannot size itself against unbounded width at all.
            width: extended ? _extendedWidth : _collapsedWidth,
            child: Column(
              children: [
                // Outside the scroll view: the company you are looking at
                // should not scroll away from you, and keeping it out of
                // the rail keeps it out of the intrinsic measurement too.
                _RailHeader(extended: extended),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: IntrinsicHeight(
                          child: NavigationRail(
                            extended: extended,
                            minExtendedWidth: _extendedWidth,
                            selectedIndex: _selectedIndexIn(dests),
                            onDestinationSelected: (i) =>
                                context.go(dests[i].path),
                            trailing: Expanded(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: _AccountButton(),
                                ),
                              ),
                            ),
                            destinations: [
                              for (final d in dests)
                                NavigationRailDestination(
                                  icon: Icon(d.icon),
                                  selectedIcon: Icon(d.selectedIcon),
                                  label: Text(d.label),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          VerticalDivider(
            width: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _narrowLayout(BuildContext context, WidgetRef ref, List<_Dest> dests) {
    final primary = dests.where((d) => d.primary).toList();
    final selected = dests[_selectedIndexIn(dests)];
    final primaryIndex = primary.indexOf(selected);

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: primaryIndex >= 0 ? primaryIndex : primary.length,
        onDestinationSelected: (i) {
          if (i < primary.length) {
            context.go(primary[i].path);
          } else {
            _showMoreSheet(context, dests);
          }
        },
        destinations: [
          for (final d in primary)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
          const NavigationDestination(
            icon: Icon(Icons.more_horiz),
            label: 'More',
          ),
        ],
      ),
    );
  }

  /// Everything the bottom bar has no room for.
  ///
  /// Scrollable, and deliberately so. A default modal sheet is capped at
  /// a little over half the screen; with the modules switched on this
  /// list runs to seventeen entries plus Sign out, so the plain Column
  /// that used to be here overflowed by about four hundred pixels and
  /// simply clipped — no scrollbar, no bounce, nothing to suggest the
  /// list continued. Sign out was the entry off the bottom.
  void _showMoreSheet(BuildContext context, List<_Dest> dests) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Needed for the sheet to grow past the 9/16 default at all.
      isScrollControlled: true,
      // But not to the top of the screen: a navigation sheet that covers
      // everything reads as a page you have navigated to, and you should
      // still be able to see what you are leaving behind.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final d in dests.where((d) => !d.primary))
                ListTile(
                  leading: Icon(d.icon),
                  title: Text(d.label),
                  onTap: () {
                    Navigator.pop(ctx);
                    context.go(d.path);
                  },
                ),
              const Divider(),
              Consumer(
                builder: (context, ref, _) => ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Sign out'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await ref.read(supabaseProvider).auth.signOut();
                    ref.read(currentOrgIdProvider.notifier).clear();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailHeader extends ConsumerWidget {
  const _RailHeader({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final org = ref.watch(currentOrgProvider).value;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.fromLTRB(extended ? 16 : 8, 16, extended ? 16 : 8, 8),
      child: extended
          ? _OrgSwitcher(org: org)
          : Tooltip(
              message: org?.name ?? 'iAkauntan',
              child: CircleAvatar(
                backgroundColor: scheme.primary,
                child: Text(
                  Fmt.initials(org?.name ?? 'iA'),
                  style: TextStyle(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
    );
  }
}

class _OrgSwitcher extends ConsumerWidget {
  const _OrgSwitcher({this.org});

  final Organization? org;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final orgs =
        ref.watch(organizationsProvider).value ?? const <Organization>[];

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: orgs.length < 2
            ? null
            : () => showDialog<void>(
                context: context,
                builder: (ctx) => SimpleDialog(
                  title: const Text('Switch organization'),
                  children: [
                    for (final o in orgs)
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: scheme.primaryContainer,
                          child: Text(
                            Fmt.initials(o.name),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        title: Text(o.name),
                        subtitle: Text(o.registrationNo ?? o.slug),
                        selected: o.id == org?.id,
                        onTap: () {
                          ref.read(currentOrgIdProvider.notifier).select(o.id);
                          Navigator.pop(ctx);
                        },
                      ),
                  ],
                ),
              ),
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: scheme.primary,
                child: Text(
                  Fmt.initials(org?.name ?? 'iA'),
                  style: TextStyle(
                    color: scheme.onPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Flexible rather than Expanded: this sits inside the
              // navigation rail, which is measured intrinsically, and an
              // intrinsic pass hands a Row unbounded width. A child with
              // non-zero flex cannot answer "how wide would you like to
              // be?" under those conditions and throws. A loose fit can.
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      org?.name ?? 'iAkauntan',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      org?.einvoiceEnabled == true
                          ? 'e-Invoice ${org?.einvoiceEnvironment}'
                          : 'e-Invoice off',
                      style: TextStyle(
                        fontSize: 11,
                        color: org?.einvoiceEnabled == true
                            ? context.colors.success
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (orgs.length > 1) const Icon(Icons.unfold_more, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final role = ref.watch(memberRoleProvider).value ?? '';

    return PopupMenuButton<String>(
      tooltip: user?.email ?? 'Account',
      onSelected: (value) async {
        if (value == 'signout') {
          await ref.read(supabaseProvider).auth.signOut();
          ref.read(currentOrgIdProvider.notifier).clear();
        } else if (value == 'settings' && context.mounted) {
          context.go('/settings');
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                user?.email ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (role.isNotEmpty)
                Text(Fmt.label(role), style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'settings', child: Text('Settings')),
        const PopupMenuItem(value: 'signout', child: Text('Sign out')),
      ],
      child: CircleAvatar(
        radius: 18,
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        child: Text(
          Fmt.initials(user?.email ?? '?'),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
