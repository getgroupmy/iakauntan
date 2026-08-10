import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final org = ref.watch(currentOrgProvider);
    final role = ref.watch(memberRoleProvider).value ?? 'viewer';
    final isAdmin = role == 'owner' || role == 'admin';

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AsyncView(
        value: org,
        onRetry: () => ref.invalidate(currentOrgProvider),
        builder: (organization) {
          if (organization == null) {
            return const EmptyState(
              icon: Icons.business_outlined,
              title: 'No organization',
              message: 'Create a company to get started.',
            );
          }

          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 860,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CompanyCard(org: organization),
                  const SizedBox(height: 16),
                  _EinvoiceCard(org: organization, canEdit: isAdmin),
                  const SizedBox(height: 16),
                  _ModulesCard(canAdmin: isAdmin),
                  const SizedBox(height: 16),
                  const _ChartOfAccountsCard(),
                  const SizedBox(height: 16),
                  _TaxCodesCard(),
                  const SizedBox(height: 16),
                  _AboutCard(role: role),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CompanyCard extends StatelessWidget {
  const _CompanyCard({required this.org});

  final Organization org;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Company'),
            _Field(label: 'Name', value: org.name),
            _Field(label: 'Entity type', value: Fmt.label(org.entityType)),
            _Field(
                label: 'SSM registration',
                value: org.registrationNo ?? 'Not set'),
            _Field(label: 'LHDN TIN', value: org.tin ?? 'Not set'),
            _Field(
              label: 'SST',
              value: org.isSstRegistered
                  ? (org.sstRegistrationNo ?? 'Registered')
                  : 'Not registered',
            ),
            _Field(label: 'MSIC code', value: org.msicCode ?? 'Not set'),
            _Field(label: 'Base currency', value: org.baseCurrency),
            _Field(
              label: 'Rounding',
              value: Fmt.label(org.roundingMethod),
            ),
          ],
        ),
      ),
    );
  }
}

/// MyInvois credentials live in a service-role-only table, so this card
/// writes them through an RPC-free upsert that RLS blocks for reads.
class _EinvoiceCard extends ConsumerStatefulWidget {
  const _EinvoiceCard({required this.org, required this.canEdit});

  final Organization org;
  final bool canEdit;

  @override
  ConsumerState<_EinvoiceCard> createState() => _EinvoiceCardState();
}

class _EinvoiceCardState extends ConsumerState<_EinvoiceCard> {
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  late bool _enabled;
  late String _environment;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _enabled = widget.org.einvoiceEnabled;
    _environment = widget.org.einvoiceEnvironment;
  }

  @override
  void dispose() {
    _clientId.dispose();
    _clientSecret.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () async {
        final client = ref.read(supabaseProvider);

        await client.from('organizations').update({
          'einvoice_enabled': _enabled,
          'einvoice_environment': _environment,
          'einvoice_client_id': _clientId.text.trim().isEmpty
              ? null
              : _clientId.text.trim(),
        }).eq('id', widget.org.id);

        // Only write credentials when a secret was actually entered, so
        // saving other settings does not wipe them.
        if (_clientId.text.trim().isNotEmpty &&
            _clientSecret.text.trim().isNotEmpty) {
          await client.from('einvoice_credentials').upsert({
            'org_id': widget.org.id,
            'client_id': _clientId.text.trim(),
            'client_secret': _clientSecret.text.trim(),
            'environment': _environment,
          });
        }
      },
      successMessage: 'e-Invoice settings saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok) {
      _clientSecret.clear();
      ref.invalidate(organizationsProvider);
      ref.invalidate(currentOrgProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final missingTin = (widget.org.tin ?? '').isEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'LHDN e-Invoice',
              subtitle: 'MyInvois API credentials from the MyTax portal',
            ),
            if (missingTin)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: context.colors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'Set the company TIN before enabling e-Invoice — LHDN '
                  'rejects submissions without it.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: widget.canEdit && !missingTin
                  ? (v) => setState(() => _enabled = v)
                  : null,
              title: const Text('Enable e-Invoice submission'),
              subtitle: const Text('Allow invoices to be sent to MyInvois'),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'sandbox', label: Text('Sandbox')),
                ButtonSegment(value: 'production', label: Text('Production')),
              ],
              selected: {_environment},
              onSelectionChanged: widget.canEdit
                  ? (s) => setState(() => _environment = s.first)
                  : null,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _clientId,
              enabled: widget.canEdit,
              decoration: const InputDecoration(
                labelText: 'Client ID',
                hintText: 'From MyTax > e-Invoice > API',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _clientSecret,
              enabled: widget.canEdit,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Client secret',
                helperText:
                    'Stored server-side only; never sent back to the app',
              ),
            ),
            const SizedBox(height: 16),
            if (widget.canEdit)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What the tenant is entitled to. Add-ons are switched on by platform
/// staff, not here, so this is informational with one exception: the
/// legal module needs a one-time setup the company admin runs.
class _ModulesCard extends ConsumerWidget {
  const _ModulesCard({required this.canAdmin});

  final bool canAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(enabledModulesProvider);
    final catalog = ref.watch(platformModulesProvider).value ?? const [];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Modules',
              subtitle: 'Contact us to add or remove an add-on',
            ),
            AsyncView(
              value: enabled,
              onRetry: () => ref.invalidate(enabledModulesProvider),
              loading: const LinearProgressIndicator(),
              builder: (active) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final m in catalog)
                        Chip(
                          avatar: Icon(
                            active.contains(m.code)
                                ? Icons.check_circle
                                : Icons.remove_circle_outline,
                            size: 16,
                            color: active.contains(m.code)
                                ? context.colors.success
                                : Theme.of(context).colorScheme.outline,
                          ),
                          label: Text(m.name),
                        ),
                    ],
                  ),
                  if (active.contains('legal')) ...[
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 8),
                    Text(
                      'Legal firm accounting',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Creates the client account, client monies liability '
                      'and disbursement accounts required to keep client '
                      'money separate from office money. Safe to run twice.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    if (canAdmin)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await runWithFeedback(
                              context,
                              action: () =>
                                  ref.read(repoProvider)!.setupLegalModule(),
                              successMessage: 'Client account ready',
                            );
                            ref.invalidate(accountsProvider);
                            ref.invalidate(bankAccountsProvider);
                          },
                          icon: const Icon(Icons.gavel_outlined, size: 18),
                          label: const Text('Set up client account'),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartOfAccountsCard extends ConsumerWidget {
  const _ChartOfAccountsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Chart of accounts',
              subtitle: 'Malaysian SME template, MPERS aligned',
            ),
            AsyncView(
              value: accounts,
              onRetry: () => ref.invalidate(accountsProvider),
              loading: const LinearProgressIndicator(),
              builder: (list) {
                final byType = <String, int>{};
                for (final a in list.where((a) => !a.isGroup)) {
                  byType[a.accountType] = (byType[a.accountType] ?? 0) + 1;
                }
                return Column(
                  children: [
                    for (final e in byType.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(child: Text(Fmt.label(e.key))),
                            Text('${e.value} accounts',
                                style:
                                    Theme.of(context).textTheme.bodySmall),
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

class _TaxCodesCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final taxCodes = ref.watch(taxCodesProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Tax codes',
              subtitle: 'Sales and service tax rates used on documents',
            ),
            AsyncView(
              value: taxCodes,
              onRetry: () => ref.invalidate(taxCodesProvider),
              loading: const LinearProgressIndicator(),
              builder: (list) => Column(
                children: [
                  for (final t in list)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 64,
                            child: Text(
                              t.code,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Expanded(child: Text(t.name)),
                          if (t.isDefault)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: StatusChip('default', compact: true),
                            ),
                          Text(
                            Fmt.percent(t.rate),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutCard extends ConsumerWidget {
  const _AboutCard({required this.role});

  final String role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Your account'),
            _Field(label: 'Signed in as', value: user?.email ?? '—'),
            _Field(label: 'Role', value: Fmt.label(role)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await ref.read(supabaseProvider).auth.signOut();
                ref.read(currentOrgIdProvider.notifier).clear();
              },
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
