import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/live_updates.dart';
import '../../core/maintenance.dart';
import '../../core/platform_live.dart';
import '../../core/page_waiting.dart';
import '../../core/providers.dart';
import '../../data/platform_catalog_repository.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../landing/landing_content.dart';
import '../chat/call_incoming.dart';
import '../chat/chat_live.dart';
import '../admin/platform_console_screen.dart';
import 'notification_bell.dart';

/// Navigation destination shared by the rail (wide) and bottom bar (narrow).
/// One heading and the destinations beneath it.
///
/// A null heading is the ungrouped case: one flat list, which is what
/// the menu did before 0293 and what it still does when a platform has
/// not asked for grouping.
typedef MenuSection<T> = ({String? heading, List<T> items});

/// Gather menu entries under the headings their modules sit in.
///
/// Generic rather than typed to the destination, so the arrangement can
/// be asserted without a widget — this decides what fifteen modules'
/// worth of doors look like to somebody trying to find one, and
/// getting it wrong is a menu nobody can read.
///
/// The order of the headings follows the order the entries arrive in,
/// so the destination list stays the thing that decides what comes
/// first. Entries belonging to no module — the workspace ones, Settings
/// and Team and Import — gather at the end under no heading, because
/// they are not part of any module and inventing a heading for them
/// would be inventing a module.
List<MenuSection<T>> groupByModule<T>(
  List<T> items,
  String? Function(T) moduleOf,
  Map<String, String> groupNames,
  bool grouped,
) {
  if (!grouped) return [(heading: null, items: items)];

  final order = <String>[];
  final byHeading = <String, List<T>>{};
  final loose = <T>[];

  for (final item in items) {
    final code = moduleOf(item);
    if (code == null) {
      loose.add(item);
      continue;
    }
    final heading = groupNames[code] ?? code;
    if (!byHeading.containsKey(heading)) {
      byHeading[heading] = <T>[];
      order.add(heading);
    }
    byHeading[heading]!.add(item);
  }

  return [
    for (final heading in order) (heading: heading, items: byHeading[heading]!),
    if (loose.isNotEmpty) (heading: null, items: loose),
  ];
}

/// What a waiting count reads as on a badge.
///
/// Capped, because the badge is a nudge rather than a figure: past a
/// point the exact number changes nothing about what you do next, and
/// a four-digit badge stops being a badge and starts being a shape.
String badgeLabel(int count) => count > 99 ? '99+' : '$count';

/// Whether a destination is the one the unread count belongs to.
bool destCarriesUnread(String path) => path == '/chat';

/// What the "More" slot carries on a phone.
///
/// `chatUnreadProvider` says it is "for the badge on the rail" and
/// there was no badge anywhere -- the count was derived, summed and
/// thrown away. On a phone the problem is worse than a missing badge:
/// Chat is not a primary destination, so its badge would sit inside a
/// sheet nobody opens unless they already knew there was something in
/// it. The count moves to "More", which is the only thing on that bar
/// able to say it.
///
/// Nought where this company does not hold Chat at all, and nought
/// where Chat has a slot of its own -- the badge would then be shown
/// twice, once against the thing and once against the drawer it is
/// not in.
/// An icon with a count on it, or the icon as it was.
Widget _badged(Widget icon, int count) =>
    count > 0 ? Badge(label: Text(badgeLabel(count)), child: icon) : icon;

int unreadOnMore({
  required Iterable<String> reachable,
  required Iterable<String> primary,
  required int unread,
}) {
  if (!reachable.any(destCarriesUnread)) return 0;
  if (primary.any(destCarriesUnread)) return 0;
  return unread;
}

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
    this.firmOnly = false,
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

  /// Shown only to somebody who belongs to an accounting practice.
  ///
  /// Not a module: a practice is not something a company buys, and it is
  /// not attached to the company in the rail at all — the same person
  /// sees it whichever of their clients they are looking at. Almost
  /// nobody has one, so an always-visible "Practice" would be a door
  /// onto an explanation for every company that keeps its own books.
  final bool firmOnly;
}

/// One place inside the product that an address can be pointed at.
///
/// `0342` lets an operator confine a subdomain to a module, or to one
/// screen inside it. The console needs a list of what those are, and
/// this is it — derived from the same table the navigation is built
/// from, so a screen that exists is offerable and one that does not
/// cannot be chosen.
typedef ModuleDestination = ({String module, String label, String path});

/// Every destination a name can be pointed at, module first.
///
/// Platform-only destinations are left out: the console's own sections
/// are not something a company's address opens. So are the five that
/// belong to no module — Dashboard, Import, Team, Email and Settings
/// are the workspace rather than the product, and confining an address
/// to "Settings" is not a thing anybody means.
List<ModuleDestination> assignableDestinations() {
  final out = <ModuleDestination>[
    for (final d in _destinations)
      if (d.module != null && !d.platformOnly && !d.adminOnly)
        (module: d.module!, label: d.label, path: d.path),
  ];
  out.sort((a, b) {
    final byModule = a.module.compareTo(b.module);
    return byModule != 0 ? byModule : a.label.compareTo(b.label);
  });
  return out;
}

/// The paths a name confined to [module] may reach.
///
/// Every destination of that module, plus its alternate — property is
/// sold as strata and non-strata and either opens the portfolio, so an
/// address confined to one of them must not stop at the other's door.
Set<String> pathsForModule(String module) => {
  for (final d in _destinations)
    if (d.module == module || d.altModule == module) d.path,
};

// Not `const`: the console's ten sections are appended from their own
// table at the end, and a constant list cannot be built with a loop.
final _destinations = <_Dest>[
  _Dest(
    'Dashboard',
    Icons.dashboard_outlined,
    Icons.dashboard,
    '/dashboard',
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
  // Client money, in and out. 0549 built both movements and the only
  // door onto either was the matter screen -- one matter at a time,
  // which is where you go when you already know which matter you want.
  // Somebody banking the morning's cheques does not: they have a
  // cheque and a client, and the matter is what they are looking up.
  _Dest(
    'Receive payment',
    Icons.south_west_outlined,
    Icons.south_west,
    '/legal/receipts',
    module: 'legal',
  ),
  _Dest(
    'Payout',
    Icons.north_east_outlined,
    Icons.north_east,
    '/legal/payouts',
    module: 'legal',
  ),
  // Four doors onto one screen, under the CONTACTS heading the module
  // already gives them. All Contacts stays what it was — the same page,
  // opening on the same tab — and the three below it open it on theirs.
  _Dest(
    'All Contacts',
    Icons.people_outline,
    Icons.people,
    '/contacts',
    primary: true,
    module: 'contacts',
  ),
  _Dest(
    'Customer',
    Icons.person_outline,
    Icons.person,
    '/customers',
    module: 'contacts',
  ),
  _Dest(
    'Supplier',
    Icons.local_shipping_outlined,
    Icons.local_shipping,
    '/suppliers',
    module: 'contacts',
  ),
  _Dest(
    'Prospect',
    Icons.person_search_outlined,
    Icons.person_search,
    '/prospects',
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
  _Dest('Queue', Icons.people_outline, Icons.people, '/queue', module: 'pos'),
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
  // Before the journals rather than after them: the chart is what a
  // journal posts INTO, and somebody looking for an account code is
  // looking for it before they write the entry, not after.
  //
  // It had no entry at all until it was reported missing. The chart sat
  // on a card most of the way down Settings — a company's setup, which
  // is not what a chart of accounts is.
  _Dest(
    'Chart of accounts',
    Icons.account_tree_outlined,
    Icons.account_tree,
    '/accounts',
    module: 'accounting',
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
    'Practice',
    Icons.apartment_outlined,
    Icons.apartment,
    '/practice',
    firmOnly: true,
  ),
  _Dest(
    'Security',
    Icons.shield_outlined,
    Icons.shield,
    '/security',
    adminOnly: true,
  ),
  _Dest('Email', Icons.mail_outline, Icons.mail, '/email'),
  // Mail that arrived, as opposed to `/email` which is mail this
  // company sent. Two different questions, and putting them on one
  // screen would make the outbox's own list harder to read.
  _Dest(
    'Inbox',
    Icons.inbox_outlined,
    Icons.inbox,
    '/inbox',
    module: 'mailbox',
  ),
  _Dest('Settings', Icons.settings_outlined, Icons.settings, '/settings'),
  // The assistant. One entry, because it is one screen — the module's
  // whole surface is a question box.
  _Dest(
    'Ask about your books',
    Icons.auto_awesome_outlined,
    Icons.auto_awesome,
    '/ask',
    primary: true,
    module: 'ai',
  ),
  // No module, and last: reporting a fault is not a feature a company
  // buys, and a company that has stopped paying for one is exactly the
  // company most likely to want to say why.
  _Dest(
    'Report a problem',
    Icons.bug_report_outlined,
    Icons.bug_report,
    '/feedback',
  ),
  // The platform console, one destination per section. Everything a
  // platform operator does lives in this menu rather than in a second
  // one drawn inside the console — there is one side menu in this app
  // and this is it.
  //
  // `module` carries the heading rather than a module code: no module
  // is named "Billing", so `groupByModule` falls through to the code
  // itself, which is the heading. And `platformOnly` is answered before
  // `module` is ever read, so nothing here is hidden for want of an
  // entitlement nobody sells.
  for (final s in platformConsoleSections)
    _Dest(
      s.label,
      s.icon,
      s.selectedIcon,
      s.path,
      primary: s.primary,
      module: s.group,
      platformOnly: true,
    ),
];

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child, required this.location});

  final Widget child;
  final String location;

  /// Where the bottom bar gives way to the side menu, and where that
  /// menu grows from a column of icons to icons with their names.
  ///
  /// Public because the platform console has a menu of its own beside
  /// this one, and a second menu that changed shape at its own widths
  /// would be a different menu rather than the same one twice.
  static const railBreakpoint = 900.0;
  static const extendedBreakpoint = 1200.0;

  /// Material's own defaults for the rail, named here because the header
  /// sits beside the rail rather than inside it and has to match.
  // Named without the underscore because `_GroupedRail` measures
  // itself against the rail it stands in for, and a private static is
  // not visible from another class even in the same file.
  static const extendedWidth = 256.0;
  static const collapsedWidth = 80.0;

  /// Destinations this user can actually reach: modules the company
  /// holds and has not put away, plus the platform console for staff.
  List<_Dest> _visible(WidgetRef ref) {
    // `valueOrNull` at all five sites in this method, and the reason is
    // the shell rather than taste. `AsyncError.value` THROWS, so the
    // `??` beside it never runs -- and a throw HERE is not one screen
    // failing to load. It is the navigation rail failing to build, so
    // there is no rail to navigate away with and nothing on screen but
    // grey. The fallbacks below are all "show less", which is the safe
    // direction: a door that is missing for a moment beats every door
    // missing until a reload.
    final isPlatformAdmin =
        ref.watch(isPlatformAdminProvider).valueOrNull ?? false;

    // Every destination but the console reads from an organization, so
    // with none selected they are doors onto an empty room. A platform
    // operator belongs to no company and would otherwise be handed a full
    // rail of screens that can only fail.
    final hasOrg =
        (ref.watch(organizationsProvider).valueOrNull ?? const []).isNotEmpty;

    final isAdmin = ref.watch(canAdminProvider);

    // Read once for the rail rather than by the screen, so the door
    // appears the moment somebody is taken on at a practice.
    final atAPractice =
        (ref.watch(myFirmsProvider).valueOrNull ?? const []).isNotEmpty;

    return _destinations.where((d) {
      if (d.platformOnly) return isPlatformAdmin;
      if (!hasOrg) return false;
      if (d.adminOnly && !isAdmin) return false;
      if (d.firmOnly && !atAPractice) return false;
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
      // `/dashboard` is a prefix of nothing else, so the exact-match
      // special case the old `/` needed is gone with it.
      final match = location.startsWith(path);
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

    // And the platform's own tables, which belong to no company and so
    // need no organization to follow. A module renamed in the console,
    // the menu grouped or ungrouped, a logo replaced: all of it lands
    // here rather than waiting for the next sign-in.
    ref.watch(platformLiveProvider);

    final dests = _visible(ref);

    // Both Material navigation widgets require at least two destinations,
    // and there are two ordinary ways to have fewer: a platform operator
    // belongs to no company and so sees only the console, and on the very
    // first frame the platform-admin answer has not arrived yet and the
    // list is empty. Either one puts selectedIndex out of range, which
    // throws while building — and a release build renders a thrown build
    // as a blank page, with no clue as to why.
    if (dests.length < 2) {
      return _underTheNotice(ref, _bareLayout(context, dests));
    }

    final wide = MediaQuery.sizeOf(context).width >= railBreakpoint;
    return _underTheNotice(
      ref,
      _reachableByCall(
        ref,
        wide
            ? _wideLayout(context, ref, dests)
            : _narrowLayout(context, ref, dests),
      ),
    );
  }

  /// The maintenance banner, above whatever the layout drew.
  ///
  /// `0018` seeded `maintenance_mode` as "Show a maintenance banner and
  /// block writes" and it did neither for five hundred migrations.
  /// `0564` makes `can_write` and `can_admin` refuse; this is the other
  /// half, and it is the half that stops somebody concluding the
  /// product is broken. A save that fails with no explanation is a bug
  /// report.
  ///
  /// Above the whole shell rather than on one screen, because the
  /// screen somebody is on when the shutter comes down is not
  /// predictable.
  Widget _underTheNotice(WidgetRef ref, Widget shell) {
    final notice = ref.watch(maintenanceNoticeProvider).valueOrNull;
    if (notice == null) return shell;
    return Column(
      children: [
        MaintenanceBanner(message: notice),
        Expanded(child: shell),
      ],
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
    // The null check below already says what this means to do when the
    // answer has not arrived; a failed load is the same situation and
    // must not throw out of the shell.
    final modules = ref.watch(enabledModulesProvider).valueOrNull;
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
                // No bell here: this layout is what somebody sees when
                // there is no company to have notifications for.
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
    final extended = MediaQuery.sizeOf(context).width >= extendedBreakpoint;

    // Watched, not read: the setting and the module names arrive after
    // the first frame, and a menu that only regroups when something
    // else happens to rebuild it is a menu that looks like the switch
    // did nothing.
    //
    // Headings need room for words, so grouping applies to the extended
    // rail only. Collapsed, the rail is a column of icons with no space
    // to say what they have in common — 0293's switch is about a menu
    // somebody can read, and a heading over a 72-pixel column is not
    // one.
    // The count `chatUnreadProvider` has always derived, finally put
    // where its own doc comment said it was for.
    final unread = ref.watch(chatUnreadProvider);
    final grouped =
        extended && (ref.watch(navGroupingProvider).valueOrNull ?? false);
    final groupNames =
        ref
            .watch(moduleLabelsProvider)
            .valueOrNull
            ?.map((code, m) => MapEntry(code, m.group)) ??
        const <String, String>{};

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
            width: extended ? extendedWidth : collapsedWidth,
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
                          // `NavigationRail` takes a flat list of
                          // destinations and has nowhere to put a
                          // heading, which is why 0293's switch changed
                          // nothing here however it was set: the
                          // grouping reached the More sheet on a phone
                          // and never reached the side menu at all.
                          child: grouped
                              ? _GroupedRail(
                                  dests: dests,
                                  selected: _selectedIndexIn(dests),
                                  groupNames: groupNames,
                                  unread: unread,
                                  onSelected: (i) => context.go(dests[i].path),
                                )
                              : NavigationRail(
                                  extended: extended,
                                  minExtendedWidth: extendedWidth,
                                  selectedIndex: _selectedIndexIn(dests),
                                  onDestinationSelected: (i) =>
                                      context.go(dests[i].path),
                                  trailing: Expanded(
                                    child: Align(
                                      alignment: Alignment.bottomCenter,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const NotificationBell(),
                                            _AccountButton(),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  destinations: [
                                    for (final d in dests)
                                      NavigationRailDestination(
                                        icon: _badged(
                                          Icon(d.icon),
                                          destCarriesUnread(d.path)
                                              ? unread
                                              : 0,
                                        ),
                                        selectedIcon: _badged(
                                          Icon(d.selectedIcon),
                                          destCarriesUnread(d.path)
                                              ? unread
                                              : 0,
                                        ),
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
    // Material's bottom bar refuses to draw fewer than two slots, and
    // "More" is only one of them — so a set of destinations with none
    // marked primary threw rather than rendered. The first destination
    // stands in: whatever this person can reach, they can reach one of
    // it without opening the sheet.
    if (primary.isEmpty) primary.add(dests.first);
    final selected = dests[_selectedIndexIn(dests)];
    final primaryIndex = primary.indexOf(selected);
    final unread = ref.watch(chatUnreadProvider);
    final onMore = unreadOnMore(
      reachable: [for (final d in dests) d.path],
      primary: [for (final d in primary) d.path],
      unread: unread,
    );

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: primaryIndex >= 0 ? primaryIndex : primary.length,
        onDestinationSelected: (i) {
          if (i < primary.length) {
            context.go(primary[i].path);
          } else {
            _showMoreSheet(
              context,
              dests,
              unread: unread,
              groupNames:
                  ref
                      .read(moduleLabelsProvider)
                      .valueOrNull
                      ?.map((code, m) => MapEntry(code, m.group)) ??
                  const {},
              grouped: ref.read(navGroupingProvider).valueOrNull ?? false,
            );
          }
        },
        destinations: [
          for (final d in primary)
            NavigationDestination(
              icon: _badged(
                Icon(d.icon),
                destCarriesUnread(d.path) ? unread : 0,
              ),
              selectedIcon: _badged(
                Icon(d.selectedIcon),
                destCarriesUnread(d.path) ? unread : 0,
              ),
              label: d.label,
            ),
          NavigationDestination(
            icon: _badged(const Icon(Icons.more_horiz), onMore),
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
  void _showMoreSheet(
    BuildContext context,
    List<_Dest> dests, {
    required Map<String, String> groupNames,
    required bool grouped,
    int unread = 0,
  }) {
    final rest = dests.where((d) => !d.primary).toList();
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
              for (final entry in groupByModule<_Dest>(
                rest,
                (d) => d.module,
                groupNames,
                grouped,
              )) ...[
                if (entry.heading != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      entry.heading!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final d in entry.items)
                  ListTile(
                    leading: Icon(d.icon),
                    title: Text(d.label),
                    trailing: destCarriesUnread(d.path) && unread > 0
                        ? Badge(label: Text(badgeLabel(unread)))
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      context.go(d.path);
                    },
                  ),
              ],
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

/// The side menu with headings in it.
///
/// Stands in for `NavigationRail` when a platform operator has asked for
/// the menu to be grouped by module. The rail cannot do this itself —
/// its `destinations` is a flat list of `NavigationRailDestination` and
/// there is nowhere to put a heading between two of them — so the
/// grouped form is drawn here instead of bending the rail into a shape
/// it does not have.
///
/// Deliberately the same measurements as the extended rail it replaces,
/// so switching the setting moves the headings in and out without the
/// menu changing width or the destinations moving sideways.
class _GroupedRail extends StatelessWidget {
  const _GroupedRail({
    required this.dests,
    required this.selected,
    required this.groupNames,
    required this.onSelected,
    this.unread = 0,
  });

  final List<_Dest> dests;
  final int selected;
  final Map<String, String> groupNames;
  final void Function(int index) onSelected;
  final int unread;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // The same width as the extended rail this replaces, so turning
      // the setting on moves headings in without the menu resizing.
      width: AppShell.extendedWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          for (final section in groupByModule<_Dest>(
            dests,
            (d) => d.module,
            groupNames,
            true,
          )) ...[
            if (section.heading != null) RailHeading(section.heading!),
            for (final d in section.items)
              RailTile(
                icon: d.icon,
                selectedIcon: d.selectedIcon,
                label: d.label,
                // The index the caller knows this destination by. The
                // sections reorder them, so the position within a
                // section says nothing about which route it is — reading
                // the index off the section would navigate somewhere
                // else entirely.
                selected: dests.indexOf(d) == selected,
                unread: destCarriesUnread(d.path) ? unread : 0,
                onTap: () => onSelected(dests.indexOf(d)),
              ),
          ],
          const Spacer(),
          const NotificationBell(),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _AccountButton(),
          ),
        ],
      ),
    );
  }
}

/// The words over a run of related destinations.
///
/// Public, and used by the platform console's menu as well as this one:
/// a heading that was drawn one way here and another way there would be
/// two menus rather than one menu in two places.
class RailHeading extends StatelessWidget {
  const RailHeading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One row of a grouped side menu: an icon, a name, and a pill behind
/// it when it is the one you are looking at.
///
/// Takes the icons and the label rather than a destination, so the
/// platform console — whose sections are not routes — draws its menu
/// out of the same rows this one is made of.
class RailTile extends StatelessWidget {
  const RailTile({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.unread = 0,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// How many are waiting behind this one. Nought draws nothing.
  final int unread;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(100),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(100),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  selected ? selectedIcon : icon,
                  size: 22,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
                if (unread > 0) Badge(label: Text(badgeLabel(unread))),
              ],
            ),
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
    final org = ref.watch(currentOrgProvider).valueOrNull;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.fromLTRB(extended ? 16 : 8, 16, extended ? 16 : 8, 8),
      child: extended
          ? _OrgSwitcher(org: org)
          : Tooltip(
              // The company wins when there is one — this is their
              // workspace, not the platform's. The fallback is the only
              // place the platform's own name belongs here.
              // Empty rather than the shipped name while the brand is
              // in flight: a tooltip nobody is hovering over costs
              // nothing to withhold, and Flutter draws none for an
              // empty message.
              message: org?.name ?? platformWordmark(ref) ?? '',
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
        ref.watch(organizationsProvider).valueOrNull ?? const <Organization>[];

    // Multi-Company is a module (0486). The sheet opens for somebody
    // who has one company and may add another, as well as for somebody
    // who has several -- otherwise the only door to a second company
    // would be one you need a second company to reach.
    final canAdd = ref.watch(canAddCompanyProvider).valueOrNull ?? false;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: orgs.length < 2 && !canAdd
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
                    // Absent rather than present and refusing: the
                    // server answers `can_add_company`, so a company
                    // without the module is not offered a door that
                    // opens onto an error.
                    if (canAdd) ...[
                      const Divider(height: 1),
                      ListTile(
                        key: const ValueKey('add-company'),
                        leading: const Icon(Icons.add_business_outlined),
                        title: const Text('Add a company'),
                        subtitle: const Text('Another set of books on '
                            'this sign-in'),
                        onTap: () {
                          Navigator.pop(ctx);
                          context.go('/companies/new');
                        },
                      ),
                    ],
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
                      org?.name ?? platformWordmark(ref) ?? '',
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
              if (orgs.length > 1 || canAdd)
                const Icon(Icons.unfold_more, size: 16),
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
    final role = ref.watch(memberRoleProvider).valueOrNull ?? '';

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

/// What this platform calls itself, for the handful of places that have
/// no company to name yet.
///
/// Not a replacement for the organization's name anywhere: an accountant
/// working inside "Sinar Teknologi" should see Sinar Teknologi, and the
/// operator's brand belongs on the way in and on the front page rather
/// than over the top of their customer's own identity.
///
/// Null while the payload is still in flight, and only then. Every
/// public page draws [PageWaiting] rather than the name we ship with
/// (see `core/page_waiting.dart`); the shell cannot do that, because
/// holding somebody's books behind a spinner waiting on the landing
/// payload would be a worse trade than the flicker it fixes. So the
/// word waits on its own: the space where it goes stays empty for the
/// length of one round trip, and the name arrives once instead of
/// arriving wrong and being corrected.
///
/// A failure still gives 'iAkauntan'. A payload that is never coming is
/// a real answer, and this is what a platform that has not renamed
/// itself is called.
String? platformWordmark(WidgetRef ref) {
  final fetched = ref.watch(landingContentProvider);
  if (!settled(fetched)) return null;
  return fetched.valueOrNull?.wordmark ?? 'iAkauntan';
}
