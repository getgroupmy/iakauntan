import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/platform_live.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'branding_admin.dart';
import 'credit_admin.dart';
import 'landing_cms.dart';
import 'modules_admin.dart';
import 'ocr_catalog_admin.dart';
import 'payment_gateways_admin.dart';
import 'reservations_admin.dart';
import 'site_pages_admin.dart';
import 'statutory_rates_admin.dart';

/// One section of the platform console.
///
/// Public, because the console has no menu of its own: these are real
/// routes, and the app's own side menu is what opens them. The shell
/// builds a destination from each of these the same way it builds one
/// from a module.
typedef ConsoleSection = ({
  /// The heading this section sits under when the menu is grouped. Used
  /// as the heading text directly — `groupByModule` falls back to the
  /// code when there is no module by that name, and there is no module
  /// by any of these names.
  String group,
  String label,
  IconData icon,
  IconData selectedIcon,
  String path,

  /// Gets a slot in the phone's bottom bar rather than living behind
  /// "More". Two of the ten, because the bar has room for a few and
  /// Material refuses to draw one with fewer than two slots.
  bool primary,
  Widget page,
});

/// The console's ten sections, in the order the menu offers them.
///
/// Grouped in runs rather than sorted into groups, so the order stays
/// the same whether or not the platform has asked for a grouped menu.
const platformConsoleSections = <ConsoleSection>[
  (
    group: 'Platform',
    label: 'Overview',
    icon: Icons.insights_outlined,
    selectedIcon: Icons.insights,
    path: '/admin',
    primary: true,
    page: _OverviewTab(),
  ),
  (
    group: 'Platform',
    label: 'Organizations',
    icon: Icons.business_outlined,
    selectedIcon: Icons.business,
    path: '/admin/organizations',
    primary: true,
    page: _OrganizationsTab(),
  ),
  (
    group: 'Document scanning',
    label: 'Scanning credit',
    icon: Icons.credit_score_outlined,
    selectedIcon: Icons.credit_score,
    path: '/admin/credit',
    primary: false,
    page: CreditAdminTab(),
  ),
  (
    group: 'Document scanning',
    label: 'Readers',
    icon: Icons.document_scanner_outlined,
    selectedIcon: Icons.document_scanner,
    path: '/admin/readers',
    primary: false,
    page: OcrCatalogAdminTab(),
  ),
  (
    group: 'Service',
    label: 'Service settings',
    icon: Icons.tune_outlined,
    selectedIcon: Icons.tune,
    path: '/admin/service',
    primary: false,
    page: _SettingsTab(),
  ),
  (
    group: 'Service',
    label: 'Statutory rates',
    icon: Icons.gavel_outlined,
    selectedIcon: Icons.gavel,
    path: '/admin/rates',
    primary: false,
    page: StatutoryRatesAdminTab(),
  ),
  (
    group: 'Website & brand',
    label: 'Names on our domain',
    icon: Icons.alternate_email_outlined,
    selectedIcon: Icons.alternate_email,
    path: '/admin/names',
    primary: false,
    page: ReservationsAdminTab(),
  ),
  (
    group: 'Website & brand',
    label: 'Landing page',
    icon: Icons.web_outlined,
    selectedIcon: Icons.web,
    path: '/admin/landing',
    primary: false,
    page: LandingCmsTab(),
  ),
  (
    group: 'Website & brand',
    label: 'Sign in page',
    icon: Icons.login_outlined,
    selectedIcon: Icons.login,
    path: '/admin/page/signin',
    primary: false,
    page: SitePageTab(slug: 'signin'),
  ),
  (
    group: 'Website & brand',
    label: 'Sign up page',
    icon: Icons.person_add_alt_outlined,
    selectedIcon: Icons.person_add_alt_1,
    path: '/admin/page/signup',
    primary: false,
    page: SitePageTab(slug: 'signup'),
  ),
  (
    group: 'Website & brand',
    label: 'Terms of Use',
    icon: Icons.gavel_outlined,
    selectedIcon: Icons.gavel,
    path: '/admin/page/terms',
    primary: false,
    page: SitePageTab(slug: 'terms'),
  ),
  (
    group: 'Website & brand',
    label: 'Privacy Policy',
    icon: Icons.privacy_tip_outlined,
    selectedIcon: Icons.privacy_tip,
    path: '/admin/page/privacy',
    primary: false,
    page: SitePageTab(slug: 'privacy'),
  ),
  (
    group: 'Website & brand',
    label: 'Contact us',
    icon: Icons.contact_support_outlined,
    selectedIcon: Icons.contact_support,
    path: '/admin/page/contact',
    primary: false,
    page: SitePageTab(slug: 'contact'),
  ),
  (
    group: 'Website & brand',
    label: 'Branding',
    icon: Icons.palette_outlined,
    selectedIcon: Icons.palette,
    path: '/admin/branding',
    primary: false,
    page: BrandingAdminTab(),
  ),
  (
    group: 'Billing',
    label: 'Modules & pricing',
    icon: Icons.widgets_outlined,
    selectedIcon: Icons.widgets,
    path: '/admin/modules',
    primary: false,
    page: ModulesAdminTab(),
  ),
  (
    group: 'Billing',
    label: 'Payment gateways',
    icon: Icons.payments_outlined,
    selectedIcon: Icons.payments,
    path: '/admin/gateways',
    primary: false,
    page: PaymentGatewaysAdminTab(),
  ),
];

/// One section of the platform operator console.
///
/// Everything here goes through SECURITY DEFINER functions that
/// re-check platform admin rights, so a tenant user who guesses the
/// route sees errors rather than data. The check below is what stops
/// them seeing the furniture.
///
/// ## Why there is no menu in this file
///
/// There was one, twice: first a strip of tabs across the top, then a
/// column down the side. Both were a second menu, drawn beside the
/// app's own, in a window that then had two of them — a thin strip of
/// icons on the far left and a list of sections next to it.
///
/// The sections are routes now. The shell's side menu opens them, the
/// same menu that opens Sales and Payroll, with the same header above
/// it and the same account button under it. One menu, and this screen
/// is what sits to the right of it.
class PlatformConsoleScreen extends ConsumerWidget {
  const PlatformConsoleScreen({super.key, required this.path});

  /// Which of `platformConsoleSections` to show.
  final String path;

  ConsoleSection get _section => platformConsoleSections.firstWhere(
    (s) => s.path == path,
    orElse: () => platformConsoleSections.first,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(isPlatformAdminProvider);
    final section = _section;

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Icon(Icons.shield_outlined, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(section.label)),
        ]),
      ),
      body: AsyncView(
        value: isAdmin,
        builder: (allowed) {
          if (!allowed) {
            return const EmptyState(
              icon: Icons.lock_outline,
              title: 'Not a platform administrator',
              message: 'This console is for platform staff only.',
            );
          }
          return section.page;
        },
      ),
    );
  }
}

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(platformStatsProvider);

    return AsyncView(
      value: stats,
      onRetry: () => ref.invalidate(platformStatsProvider),
      builder: (s) {
        final width = MediaQuery.sizeOf(context).width;
        final columns = width >= 1100 ? 4 : (width >= 700 ? 2 : 1);

        return SingleChildScrollView(
          child: PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  'Platform health',
                  subtitle: 'Across every tenant on this deployment',
                ),
                GridView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    // One column runs the full width of a phone, so an
                    // aspect ratio ties the card's height to the width
                    // of the screen — which has nothing to do with how
                    // tall the three lines inside it are. At 412 pixels
                    // that came out four short and clipped the caption
                    // off "10 joined in 30 days"; narrower still, and
                    // the caption wraps and it clips more. A height in
                    // pixels is what a stack of text actually needs.
                    childAspectRatio: columns == 1 ? 1 : 1.75,
                    mainAxisExtent: columns == 1 ? 132 : null,
                  ),
                  children: [
                    StatTile(
                      label: 'Organizations',
                      value: '${Fmt.toInt(s['organizations'])}',
                      caption: '${Fmt.toInt(s['organizations_active'])} active',
                      icon: Icons.business_outlined,
                    ),
                    StatTile(
                      label: 'Users',
                      value: '${Fmt.toInt(s['users'])}',
                      caption: '${Fmt.toInt(s['signups_30d'])} joined in 30 days',
                      icon: Icons.people_outline,
                      accent: context.colors.info,
                    ),
                    StatTile(
                      label: 'Invoiced value',
                      value: Fmt.money(Fmt.toDouble(s['invoiced_value'])),
                      caption: '${Fmt.toInt(s['invoices'])} invoices',
                      icon: Icons.receipt_long_outlined,
                      accent: context.colors.success,
                    ),
                    StatTile(
                      label: 'e-Invoices validated',
                      value: '${Fmt.toInt(s['einvoices_valid'])}',
                      caption: Fmt.toInt(s['einvoices_failed']) > 0
                          ? '${Fmt.toInt(s['einvoices_failed'])} need attention'
                          : 'None failing',
                      icon: Icons.verified_outlined,
                      accent: Fmt.toInt(s['einvoices_failed']) > 0
                          ? context.colors.danger
                          : context.colors.success,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionHeader('e-Invoice adoption'),
                        Row(children: [
                          const Expanded(
                              child: Text('Organizations with e-Invoice on')),
                          Text(
                            '${Fmt.toInt(s['einvoice_enabled_orgs'])}'
                            ' of ${Fmt.toInt(s['organizations'])}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _OrganizationsTab extends ConsumerWidget {
  const _OrganizationsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orgs = ref.watch(platformOrgsProvider);
    final modules = ref.watch(platformModulesProvider).value ?? const [];

    return AsyncView(
      value: orgs,
      onRetry: () => ref.invalidate(platformOrgsProvider),
      builder: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.business_outlined,
            title: 'No organizations yet',
            message: 'Tenants appear here as they register.',
          );
        }

        return ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) =>
              _OrgTile(org: list[i], modules: modules),
        );
      },
    );
  }
}

class _OrgTile extends ConsumerWidget {
  const _OrgTile({required this.org, required this.modules});

  final PlatformOrg org;
  final List<ModuleInfo> modules;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final addOns = modules.where((m) => !m.isCore).toList();

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: Space.lg),
      title: Row(children: [
        Flexible(
          child: Text(org.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 10),
        StatusChip(org.status, compact: true),
      ]),
      subtitle: Text(
        [
          if ((org.registrationNo ?? '').isNotEmpty) org.registrationNo,
          '${org.memberCount} users',
          '${org.invoiceCount} invoices',
          Fmt.money(org.invoicedValue),
        ].where((e) => e != null).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(
                'Add-on modules',
                subtitle: 'Switching one off blocks new records but keeps history',
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in addOns)
                    FilterChip(
                      label: Text(
                        m.monthlyPrice > 0
                            ? '${m.name} · ${Fmt.money(m.monthlyPrice)}/mo'
                            : m.name,
                      ),
                      selected: org.modules.contains(m.code),
                      onSelected: (on) => _toggleModule(context, ref, m, on),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const SectionHeader('Account status'),
              Wrap(
                spacing: 8,
                children: [
                  for (final status in const ['active', 'trial', 'suspended'])
                    ChoiceChip(
                      label: Text(Fmt.label(status)),
                      selected: org.status == status,
                      onSelected: (_) => _setStatus(context, ref, status),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _toggleModule(
      BuildContext context, WidgetRef ref, ModuleInfo m, bool on) async {
    await runWithFeedback(
      context,
      action: () =>
          ref.read(platformRepoProvider).setModule(org.id, m.code, on),
      successMessage: on
          ? '${m.name} enabled for ${org.name}'
          : '${m.name} disabled for ${org.name}',
    );
    ref.invalidate(platformOrgsProvider);
    ref.invalidate(enabledModulesProvider);
  }

  Future<void> _setStatus(
      BuildContext context, WidgetRef ref, String status) async {
    if (status == 'suspended') {
      final ok = await confirm(
        context,
        title: 'Suspend ${org.name}?',
        message: 'Members keep their sign-in but the account is flagged '
            'suspended. Use this for non-payment or abuse.',
        confirmLabel: 'Suspend',
        destructive: true,
      );
      if (!ok || !context.mounted) return;
    }

    await runWithFeedback(
      context,
      action: () => ref.read(platformRepoProvider).setOrgStatus(org.id, status),
      successMessage: '${org.name} is now ${Fmt.label(status).toLowerCase()}',
    );
    ref.invalidate(platformOrgsProvider);
  }
}

class _SettingsTab extends ConsumerWidget {
  const _SettingsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(platformSettingsProvider);

    return AsyncView(
      value: settings,
      onRetry: () => ref.invalidate(platformSettingsProvider),
      builder: (list) => SingleChildScrollView(
        child: PageBody(
          maxWidth: 860,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(
                'Backend service settings',
                subtitle: 'Applied across every tenant',
              ),
              for (final s in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _SettingCard(setting: s),
                ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingCard extends ConsumerStatefulWidget {
  const _SettingCard({required this.setting});

  final Map<String, dynamic> setting;

  @override
  ConsumerState<_SettingCard> createState() => _SettingCardState();
}

class _SettingCardState extends ConsumerState<_SettingCard> {
  late final TextEditingController _controller;
  bool _dirty = false;

  Map<String, dynamic> get _value =>
      Map<String, dynamic>.from(widget.setting['value'] as Map? ?? {});

  /// Settings that are a single on/off get a switch; the rest are edited
  /// as raw JSON, which keeps the console honest about what is stored.
  bool get _isToggle =>
      _value.length <= 2 && _value.containsKey('enabled');

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _encode(_value));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static String _encode(Map<String, dynamic> v) =>
      v.entries.map((e) => '${e.key}: ${e.value}').join(', ');

  Future<void> _save(Map<String, dynamic> value) async {
    await runWithFeedback(
      context,
      action: () => ref
          .read(platformRepoProvider)
          .updateSetting(widget.setting['key'] as String, value),
      successMessage: 'Saved',
    );
    if (mounted) setState(() => _dirty = false);
    invalidatePlatformTable(ref, 'platform_settings');
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.setting['key'] as String;
    final description = widget.setting['description'] as String?;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(Fmt.label(key),
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (description != null)
                        Text(description,
                            style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                if (_isToggle)
                  Switch(
                    value: _value['enabled'] == true,
                    onChanged: (v) => _save({..._value, 'enabled': v}),
                  ),
              ],
            ),
            if (!_isToggle) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      onChanged: (_) => setState(() => _dirty = true),
                      decoration: const InputDecoration(
                        labelText: 'Value',
                        helperText: 'key: value, comma separated',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _dirty ? () => _save(_parse(_controller.text)) : null,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Parses "key: value, key: value" back into JSON, keeping numbers and
  /// booleans typed so the stored jsonb stays useful.
  static Map<String, dynamic> _parse(String raw) {
    final out = <String, dynamic>{};
    for (final pair in raw.split(',')) {
      final idx = pair.indexOf(':');
      if (idx < 0) continue;
      final k = pair.substring(0, idx).trim();
      final v = pair.substring(idx + 1).trim();
      if (k.isEmpty) continue;
      if (v == 'true' || v == 'false') {
        out[k] = v == 'true';
      } else {
        final n = num.tryParse(v);
        out[k] = n ?? v;
      }
    }
    return out;
  }
}
