import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';

/// Navigation destination shared by the rail (wide) and bottom bar (narrow).
class _Dest {
  const _Dest(this.label, this.icon, this.selectedIcon, this.path,
      {this.primary = false, this.module, this.platformOnly = false});

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String path;

  /// Primary destinations get a slot in the mobile bottom bar; the rest
  /// live behind "More".
  final bool primary;

  /// Add-on this destination belongs to. Hidden when the tenant is not
  /// entitled to it. The database blocks the writes regardless — this
  /// just avoids showing doors that will not open.
  final String? module;

  /// Only visible to platform staff.
  final bool platformOnly;
}

const _destinations = <_Dest>[
  _Dest('Dashboard', Icons.dashboard_outlined, Icons.dashboard, '/',
      primary: true),
  _Dest('Sales', Icons.receipt_long_outlined, Icons.receipt_long,
      '/sales/invoice',
      primary: true),
  _Dest('Purchases', Icons.shopping_bag_outlined, Icons.shopping_bag,
      '/purchases/bill',
      module: 'purchases'),
  _Dest('Expenses', Icons.receipt_outlined, Icons.receipt, '/expenses'),
  _Dest('Matters', Icons.gavel_outlined, Icons.gavel, '/legal',
      module: 'legal'),
  _Dest('Contacts', Icons.people_outline, Icons.people, '/contacts',
      primary: true),
  _Dest('Items', Icons.inventory_2_outlined, Icons.inventory_2, '/items',
      module: 'inventory'),
  _Dest('CRM', Icons.trending_up_outlined, Icons.trending_up, '/crm',
      primary: true, module: 'crm'),
  _Dest('e-Invoice', Icons.verified_outlined, Icons.verified, '/einvoice',
      module: 'einvoice'),
  _Dest('My HR', Icons.badge_outlined, Icons.badge, '/hr/me', module: 'hr'),
  _Dest('People', Icons.groups_outlined, Icons.groups, '/hr/people',
      module: 'hr'),
  _Dest('Leave', Icons.event_available_outlined, Icons.event_available,
      '/hr/leave',
      module: 'hr'),
  _Dest('Claims', Icons.request_quote_outlined, Icons.request_quote,
      '/hr/claims',
      module: 'hr'),
  _Dest('Payroll', Icons.payments_outlined, Icons.payments, '/hr/payroll',
      module: 'payroll'),
  _Dest('Talent', Icons.work_outline, Icons.work, '/hr/talent', module: 'hr'),
  _Dest('HR setup', Icons.tune_outlined, Icons.tune, '/hr/setup', module: 'hr'),
  _Dest('Secretarial', Icons.domain_outlined, Icons.domain, '/secretarial',
      module: 'secretarial'),
  _Dest('Journals', Icons.menu_book_outlined, Icons.menu_book, '/journals'),
  _Dest('Reports', Icons.bar_chart_outlined, Icons.bar_chart, '/reports'),
  _Dest('Team', Icons.manage_accounts_outlined, Icons.manage_accounts, '/team'),
  _Dest('Settings', Icons.settings_outlined, Icons.settings, '/settings'),
  _Dest('Platform', Icons.shield_outlined, Icons.shield, '/admin',
      platformOnly: true),
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

  /// Destinations this user can actually reach: add-ons the tenant is
  /// entitled to, plus the platform console for staff.
  List<_Dest> _visible(WidgetRef ref) {
    final isPlatformAdmin =
        ref.watch(isPlatformAdminProvider).value ?? false;

    // Every destination but the console reads from an organization, so
    // with none selected they are doors onto an empty room. A platform
    // operator belongs to no company and would otherwise be handed a full
    // rail of screens that can only fail.
    final hasOrg =
        (ref.watch(organizationsProvider).value ?? const []).isNotEmpty;

    return _destinations.where((d) {
      if (d.platformOnly) return isPlatformAdmin;
      if (!hasOrg) return false;
      if (d.module == null) return true;
      return moduleEnabled(ref, d.module!);
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
    return wide
        ? _wideLayout(context, ref, dests)
        : _narrowLayout(context, ref, dests);
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
                        constraints:
                            BoxConstraints(minHeight: constraints.maxHeight),
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
    final orgs = ref.watch(organizationsProvider).value ?? const <Organization>[];

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
                            child: Text(Fmt.initials(o.name),
                                style: const TextStyle(fontSize: 12)),
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
                          fontWeight: FontWeight.w600, fontSize: 13),
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
              if (orgs.length > 1)
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
              Text(user?.email ?? '',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              if (role.isNotEmpty)
                Text(Fmt.label(role),
                    style: Theme.of(ctx).textTheme.bodySmall),
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
