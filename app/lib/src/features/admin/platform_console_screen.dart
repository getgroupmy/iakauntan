import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'statutory_rates_admin.dart';

/// Platform operator console. Everything here goes through SECURITY
/// DEFINER functions that re-check platform admin rights, so a tenant
/// user who guesses the route sees errors rather than data.
class PlatformConsoleScreen extends ConsumerStatefulWidget {
  const PlatformConsoleScreen({super.key});

  @override
  ConsumerState<PlatformConsoleScreen> createState() =>
      _PlatformConsoleScreenState();
}

class _PlatformConsoleScreenState extends ConsumerState<PlatformConsoleScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isPlatformAdminProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.shield_outlined, size: 20),
          SizedBox(width: 10),
          Text('Platform console'),
        ]),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Organizations'),
            Tab(text: 'Service settings'),
            Tab(text: 'Statutory rates'),
          ],
        ),
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
          return TabBarView(
            controller: _tabs,
            children: const [
              _OverviewTab(),
              _OrganizationsTab(),
              _SettingsTab(),
              StatutoryRatesAdminTab(),
            ],
          );
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
                GridView.count(
                  crossAxisCount: columns,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: columns == 1 ? 3.2 : 1.75,
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
    ref.invalidate(platformSettingsProvider);
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
