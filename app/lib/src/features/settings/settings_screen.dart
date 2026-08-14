import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/ocr_repository.dart';
import '../../data/repository.dart';
import '../auth/reset_password_screen.dart' show validatePassword;
import 'claim_approval_card.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final org = ref.watch(currentOrgProvider);
    final role = ref.watch(memberRoleProvider).value ?? 'viewer';
    final isAdmin = role == 'owner' || role == 'admin';
    final canPost = ref.watch(canPostProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AsyncView(
        value: org,
        onRetry: () => refreshOrganization(ref),
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
                  _ScanningCard(canEdit: isAdmin),
                  const SizedBox(height: 16),
                  _ModulesCard(canAdmin: isAdmin),
                  const SizedBox(height: 16),
                  _FiscalYearsCard(canAdmin: isAdmin),
                  const SizedBox(height: 16),
                  _CreditControlCard(org: organization, canAdmin: isAdmin),
                  const SizedBox(height: 16),
                  if (moduleEnabled(ref, 'hr')) ...[
                    ClaimApprovalCard(org: organization, canAdmin: isAdmin),
                    const SizedBox(height: 16),
                  ],
                  if (organization.baseCurrency.isNotEmpty)
                    _ForeignBalancesCard(org: organization, canPost: canPost),
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

class _CompanyCard extends ConsumerWidget {
  const _CompanyCard({required this.org});

  final Organization org;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Company'),
            _LogoRow(org: org),
            const SizedBox(height: Space.md),
            _StationeryRow(org: org),
            const Divider(height: Space.xl),
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
        final repo = ref.read(repoProvider)!;

        // Credentials first, deliberately. This used to run the other
        // way round, and because the table refused the write every time,
        // a failed save still left the organization flagged as
        // e-Invoice-enabled with a client id and no secret anywhere — a
        // company marked live against a submitter that cannot log in.
        // Now the part that can fail is the part that runs first.
        if (_clientId.text.trim().isNotEmpty) {
          await repo.setEinvoiceCredentials(
            environment: _environment,
            clientId: _clientId.text.trim(),
            // Blank means "leave the stored one alone", which is what
            // lets somebody correct a client id without re-typing a
            // secret they may not have to hand.
            clientSecret: _clientSecret.text.trim().isEmpty
                ? null
                : _clientSecret.text.trim(),
          );
        }

        await ref.read(supabaseProvider).from('organizations').update({
          'einvoice_enabled': _enabled,
          'einvoice_environment': _environment,
          'einvoice_client_id': _clientId.text.trim().isEmpty
              ? null
              : _clientId.text.trim(),
        }).eq('id', widget.org.id);
      },
      successMessage: 'e-Invoice settings saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok) {
      _clientSecret.clear();
      ref.invalidate(organizationsProvider);
      refreshOrganization(ref);
      ref.invalidate(einvoiceStatusProvider);
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

/// Reading receipts and bills, which is off until somebody here says
/// otherwise.
///
/// The default is off and there is no row until this card writes one,
/// because a receipt carries a supplier, an amount and sometimes a
/// person's movements, and sending that to a third party is a decision
/// rather than something to discover afterwards.
class _ScanningCard extends ConsumerStatefulWidget {
  const _ScanningCard({required this.canEdit});

  final bool canEdit;

  @override
  ConsumerState<_ScanningCard> createState() => _ScanningCardState();
}

class _ScanningCardState extends ConsumerState<_ScanningCard> {
  final _apiKey = TextEditingController();
  final _project = TextEditingController();
  final _location = TextEditingController();
  final _processor = TextEditingController();
  bool _saving = false;

  /// "My own key", chosen but not yet saved.
  ///
  /// The database refuses to store `own` until a key exists — rightly, or
  /// an organization sits switched on with nothing to call. But the key
  /// field only appeared once `own` was stored, so choosing it was
  /// refused and there was no way to reach the field that would have
  /// satisfied it. A deadlock, and the guard was not the half that was
  /// wrong.
  ///
  /// So the choice is held here until there is a key to go with it, and
  /// the two are written together.
  String? _pendingKeySource;

  @override
  void dispose() {
    _apiKey.dispose();
    _project.dispose();
    _location.dispose();
    _processor.dispose();
    super.dispose();
  }

  Future<void> _write(Future<void> Function() action, String message) async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(context,
        action: action, successMessage: message);
    if (mounted) setState(() => _saving = false);
    if (ok) ref.invalidate(ocrStatusProvider);
    return;
  }

  /// What the screen is showing, which is the stored answer unless
  /// somebody has just asked for a different one.
  String _keySource(OcrSettings ocr) => _pendingKeySource ?? ocr.keySource;

  void _chooseKeySource(OcrSettings ocr, String chosen) {
    // Going back to the platform's key, or choosing your own when a key
    // is already on file, are both storable straight away.
    if (chosen == 'platform' || ocr.keys.contains(ocr.provider)) {
      setState(() => _pendingKeySource = null);
      _write(
        () => ref.read(repoProvider)!.setOcrSettings(
              enabled: true,
              provider: ocr.provider,
              keySource: chosen,
            ),
        'Saved',
      );
      return;
    }
    // Otherwise show the field first. Nothing is written until there is
    // a key to write with it.
    setState(() => _pendingKeySource = 'own');
  }

  /// Saves the key, then the choice that needed it — in that order,
  /// which is the order the database's own guard requires.
  Future<void> _saveKey(OcrSettings ocr) => _write(
        () async {
          final repo = ref.read(repoProvider)!;
          await repo.setOcrCredentials(
            provider: ocr.provider,
            apiKey: _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim(),
            projectId:
                _project.text.trim().isEmpty ? null : _project.text.trim(),
            location:
                _location.text.trim().isEmpty ? null : _location.text.trim(),
            processorId:
                _processor.text.trim().isEmpty ? null : _processor.text.trim(),
          );
          await repo.setOcrSettings(
            enabled: ocr.enabled,
            provider: ocr.provider,
            keySource: 'own',
          );
          _apiKey.clear();
          if (mounted) setState(() => _pendingKeySource = null);
        },
        'Scanning is on your own key',
      );

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(ocrStatusProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: AsyncView(
          value: status,
          onRetry: () => ref.invalidate(ocrStatusProvider),
          loading: const LinearProgressIndicator(),
          builder: (ocr) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(
                'Read receipts and bills',
                subtitle:
                    'Photograph a receipt and have the supplier, date and '
                    'amount filled in for you',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: ocr.enabled,
                onChanged: widget.canEdit && !_saving
                    ? (v) => _write(
                          () => ref.read(repoProvider)!.setOcrSettings(
                                enabled: v,
                                provider: ocr.provider,
                                keySource: ocr.keySource,
                              ),
                          v ? 'Scanning is on' : 'Scanning is off',
                        )
                    : null,
                title: const Text('Send documents to a reader'),
                subtitle: const Text(
                  'Off unless you turn it on. A receipt carries a supplier, '
                  'an amount and sometimes a customer.',
                ),
              ),
              if (ocr.enabled) ...[
                const SizedBox(height: 8),
                // A dropdown rather than segments: the list comes off a
                // table the platform can add to, so it has no fixed
                // width and cannot be laid out as buttons.
                DropdownButtonFormField<String>(
                  value: ocr.providers.any((p) => p.code == ocr.provider)
                      ? ocr.provider
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Reader'),
                  items: [
                    for (final p in ocr.providers)
                      DropdownMenuItem(
                        value: p.code,
                        child: Text(
                          p.runsOnDevice
                              ? '${p.name} — free'
                              : '${p.name} — ${Fmt.money(p.price)} a scan',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: widget.canEdit && !_saving
                      ? (code) {
                          if (code == null) return;
                          // A half-finished choice belongs to the reader
                          // it was made for. Changing reader abandons it
                          // rather than carrying a banner about a key
                          // nobody asked to set.
                          setState(() => _pendingKeySource = null);
                          _write(
                            () => ref.read(repoProvider)!.setOcrSettings(
                                  enabled: true,
                                  provider: code,
                                  // Switching to a reader you have no key
                                  // for would be refused, so it falls
                                  // back to the platform's.
                                  keySource: ocr.keys.contains(code)
                                      ? ocr.keySource
                                      : 'platform',
                                ),
                            'Reader changed',
                          );
                        }
                      : null,
                ),
                if (ocr.current?.blurb != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    ocr.current!.blurb!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.scheme.onSurfaceVariant),
                  ),
                ],
                if (ocr.current?.takesKey ?? true) ...[
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                          value: 'platform', label: Text('Buy credit')),
                      ButtonSegment(value: 'own', label: Text('My own key')),
                    ],
                    selected: {_keySource(ocr)},
                    onSelectionChanged: widget.canEdit && !_saving
                        ? (s) => _chooseKeySource(ocr, s.first)
                        : null,
                  ),
                ],
                const SizedBox(height: 16),
                if (ocr.onDevice)
                  const _OnDeviceNotice()
                else if (_keySource(ocr) == 'platform')
                  _CreditBalance(ocr: ocr)
                else
                  _OwnKeyFields(
                    ocr: ocr,
                    canEdit: widget.canEdit,
                    saving: _saving,
                    // True while the choice is made but unsaved, which is
                    // what the field below is there to finish.
                    pending: _pendingKeySource != null,
                    apiKey: _apiKey,
                    project: _project,
                    location: _location,
                    processor: _processor,
                    onSave: () => _saveKey(ocr),
                    onClear: () => _write(
                      () => ref
                          .read(repoProvider)!
                          .clearOcrCredentials(ocr.provider),
                      'Key removed',
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The on-device reader, which is the one with nothing to configure.
///
/// Says what it costs (nothing), where the photograph goes (nowhere),
/// and — because this is a web app as much as a phone one — where it
/// does not work.
class _OnDeviceNotice extends StatelessWidget {
  const _OnDeviceNotice();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: context.colors.success.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            const Icon(Icons.phonelink_lock_outlined, size: 20),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Nothing to configure: no key to hold and no credit to buy.',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Text(
          'Works everywhere: ML Kit on the phone app, and Tesseract in a '
          'browser, both served from us. The browser fetches about 8MB '
          'the first time it reads something and caches it after that. '
          'Check what it fills in — it reads the printing rather than '
          'understanding the document, and it cannot open a PDF.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: context.scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _CreditBalance extends StatelessWidget {
  const _CreditBalance({required this.ocr});

  final OcrSettings ocr;

  @override
  Widget build(BuildContext context) {
    final empty = ocr.outOfCredit;

    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: (empty ? context.colors.warning : context.scheme.primary)
            .withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(empty ? Icons.error_outline : Icons.account_balance_wallet_outlined,
            size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${Fmt.money(ocr.balance)} of scanning credit',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                empty
                    ? 'Not enough for another scan at '
                        '${Fmt.money(ocr.price)} each. Ask us to top it up.'
                    : '${Fmt.money(ocr.price)} a scan — about '
                        '${ocr.scansLeft} more.',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

/// An organization's own provider key.
///
/// The key itself never comes back from the server — the table holding
/// it has RLS with no policies and no grants, so the only reader is the
/// edge function. What this shows is whether one is on file.
class _OwnKeyFields extends StatelessWidget {
  const _OwnKeyFields({
    required this.ocr,
    required this.canEdit,
    required this.saving,
    required this.pending,
    required this.apiKey,
    required this.project,
    required this.location,
    required this.processor,
    required this.onSave,
    required this.onClear,
  });

  final OcrSettings ocr;
  final bool canEdit;
  final bool saving;

  /// Chosen but not stored yet, because there is no key to store with it.
  final bool pending;
  final TextEditingController apiKey;
  final TextEditingController project;
  final TextEditingController location;
  final TextEditingController processor;
  final VoidCallback onSave;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final isGoogle = ocr.provider == 'google';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ocr.hasOwnKey)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              Icon(Icons.key_outlined,
                  size: 18, color: context.colors.success),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'A key is on file. Scans run on your account with the '
                  'provider and cost nothing here.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: canEdit && !saving ? onClear : null,
                child: const Text('Remove'),
              ),
            ]),
          )
        else if (pending)
          // Says which half is missing. Without this the screen looks
          // switched over when nothing has been stored, and the first
          // scan is the thing that finds out.
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(
              color: context.colors.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Not switched over yet. Paste your '
              '${isGoogle ? 'Document AI' : 'Anthropic'} key below and save '
              'it — scanning moves onto it in the same step. Until then it '
              'stays on purchased credit.',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        TextField(
          controller: apiKey,
          enabled: canEdit,
          obscureText: !isGoogle,
          maxLines: isGoogle ? 4 : 1,
          decoration: InputDecoration(
            labelText: isGoogle ? 'Service account JSON' : 'API key',
            helperText: ocr.hasOwnKey
                ? 'Leave blank to keep the one already stored'
                : 'Stored server-side only; never sent back to the app',
          ),
        ),
        if (isGoogle) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: project,
                enabled: canEdit,
                decoration:
                    const InputDecoration(labelText: 'Project id'),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 120,
              child: TextField(
                controller: location,
                enabled: canEdit,
                decoration: const InputDecoration(
                    labelText: 'Location', hintText: 'us'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: processor,
            enabled: canEdit,
            decoration: const InputDecoration(
              labelText: 'Processor id',
              helperText: 'The Expense or Invoice parser you created',
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (canEdit)
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: saving ? null : onSave,
              child: Text(pending ? 'Save key and switch' : 'Save key'),
            ),
          ),
      ],
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

/// What happens when an invoice would take a customer past their limit.
///
/// Defaults to warn rather than block. Turning blocking on for books
/// that have been running for a year, where nobody has revisited the
/// limits, would start bouncing invoices — a change to the business,
/// not a setting.
class _CreditControlCard extends ConsumerWidget {
  const _CreditControlCard({required this.org, required this.canAdmin});

  final Organization org;
  final bool canAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Credit control',
              subtitle: 'A credit limit of zero on a customer means no limit',
            ),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'off', label: Text('Ignore')),
                ButtonSegment(value: 'warn', label: Text('Warn')),
                ButtonSegment(value: 'block', label: Text('Block')),
              ],
              selected: {org.creditControl},
              onSelectionChanged: canAdmin
                  ? (s) async {
                      await runWithFeedback(
                        context,
                        action: () =>
                            ref.read(repoProvider)!.setCreditControl(s.first),
                        successMessage: 'Credit control updated',
                      );
                      refreshOrganization(ref);
                    }
                  : null,
            ),
            const SizedBox(height: 8),
            Text(
              switch (org.creditControl) {
                'off' => 'Limits are recorded and never checked.',
                'block' =>
                  'An invoice that would take a customer past their limit '
                      'cannot be posted.',
                _ => 'The invoice screen says when a customer is at or past '
                    'their limit. Posting still goes ahead.',
              },
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Restating what the open foreign balances are worth.
///
/// Sits beside the fiscal years because it is the same job: the things
/// that have to happen before a period can be called closed. An invoice
/// raised at 4.70 and still open at a closing rate of 4.20 is carried at
/// a value the company will never collect, and nothing else in the
/// system will ever notice.
class _ForeignBalancesCard extends ConsumerStatefulWidget {
  const _ForeignBalancesCard({required this.org, required this.canPost});

  final Organization org;
  final bool canPost;

  @override
  ConsumerState<_ForeignBalancesCard> createState() =>
      _ForeignBalancesCardState();
}

class _ForeignBalancesCardState extends ConsumerState<_ForeignBalancesCard> {
  /// Defaults to the end of last month, which is what a period-end
  /// revaluation is almost always dated.
  late DateTime _asAt = DateTime(DateTime.now().year, DateTime.now().month, 0);

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(fxRevaluationPreviewProvider(_asAt));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Foreign balances',
              subtitle: 'Restate what is still open at the closing rate',
              action: TextButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text('As at ${Fmt.date(_asAt)}'),
              ),
            ),
            preview.when(
              loading: () => const LinearProgressIndicator(),
              // The likely error is a currency with no rate on file at
              // this date, which the database refuses to price rather
              // than assuming par. Said plainly, because the fix is to
              // enter the rate, not to try again.
              error: (e, _) => Text('$e',
                  style: TextStyle(color: context.colors.warning)),
              data: (rows) => rows.isEmpty
                  ? Text(
                      'Nothing open in a currency other than '
                      '${widget.org.baseCurrency}.',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final row in rows)
                          _CurrencyRow(row: row, base: widget.org.baseCurrency),
                        const SizedBox(height: 12),
                        if (widget.canPost)
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              onPressed: () => _post(rows),
                              icon: const Icon(Icons.published_with_changes,
                                  size: 18),
                              label: const Text('Post revaluation'),
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

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _asAt,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _asAt = picked);
  }

  Future<void> _post(List<FxRevaluation> rows) async {
    final net = rows.fold<double>(0, (sum, r) => sum + r.difference);
    final ok = await confirm(
      context,
      title: 'Post the revaluation?',
      message: net >= 0
          ? 'This posts an unrealised gain of '
              '${Fmt.money(net, currency: widget.org.baseCurrency)} '
              'as at ${Fmt.date(_asAt)}, and reverses the previous '
              'revaluation if there is one standing.'
          : 'This posts an unrealised loss of '
              '${Fmt.money(-net, currency: widget.org.baseCurrency)} '
              'as at ${Fmt.date(_asAt)}, and reverses the previous '
              'revaluation if there is one standing.',
      confirmLabel: 'Post',
    );
    if (!ok || !mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.revalueForeignBalances(_asAt),
      successMessage: 'Foreign balances restated',
      pendingMessage: 'Posting…',
    );
    if (mounted) {
      ref.invalidate(fxRevaluationPreviewProvider);
      refreshLedgerData(ref);
    }
  }
}

class _CurrencyRow extends StatelessWidget {
  const _CurrencyRow({required this.row, required this.base});

  final FxRevaluation row;
  final String base;

  @override
  Widget build(BuildContext context) {
    final gain = row.difference >= 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${row.currency} at ${Fmt.rate(row.closingRate)}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  '${row.documents} open · carried at '
                  '${Fmt.money(row.booked, currency: base)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Text(
            (gain ? '+' : '') + Fmt.money(row.difference, currency: base),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: row.difference == 0
                  ? null
                  : (gain ? context.colors.success : context.colors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fiscal years, and the periods under them.
///
/// Nothing posts to a date no period covers, so a company that reaches
/// the end of its last fiscal year stops being able to invoice. This
/// card exists to make that impossible to walk into: it says how much
/// runway is left, and creating the next year is one button.
class _FiscalYearsCard extends ConsumerWidget {
  const _FiscalYearsCard({required this.canAdmin});

  final bool canAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final years = ref.watch(fiscalYearsProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Fiscal years',
              subtitle: 'Nothing can be posted to a date no period covers',
              action: canAdmin
                  ? TextButton.icon(
                      onPressed: () => _createNext(context, ref),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add next year'),
                    )
                  : null,
            ),
            AsyncView(
              value: years,
              onRetry: () => ref.invalidate(fiscalYearsProvider),
              loading: const LinearProgressIndicator(),
              builder: (list) => list.isEmpty
                  ? const Text('No fiscal year yet — nothing can be posted.')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _RunwayNotice(years: list),
                        for (final y in list)
                          _YearTile(year: y, canAdmin: canAdmin),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createNext(BuildContext context, WidgetRef ref) async {
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.createFiscalYear(),
      successMessage: 'Next fiscal year created, with its twelve periods',
    );
    ref.invalidate(fiscalYearsProvider);
  }
}

/// How long before the books stop working. Said in months, because
/// "ends 31 December 2026" does not read as urgent in November.
class _RunwayNotice extends StatelessWidget {
  const _RunwayNotice({required this.years});

  final List<FiscalYear> years;

  @override
  Widget build(BuildContext context) {
    final last = years
        .map((y) => y.endDate)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final now = DateTime.now();
    final months =
        (last.year - now.year) * 12 + (last.month - now.month);

    if (months > 3) return const SizedBox.shrink();

    final expired = last.isBefore(now);
    final colour =
        expired ? context.colors.danger : context.colors.warning;

    return Container(
      margin: const EdgeInsets.only(bottom: Space.md),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: colour.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(expired ? Icons.error_outline : Icons.warning_amber_rounded,
              size: 18, color: colour),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              expired
                  ? 'The last fiscal year ended on ${Fmt.date(last)}. Nothing '
                      'can be posted until the next one is created.'
                  : 'The last fiscal year ends on ${Fmt.date(last)}. Create '
                      'the next one before then, or posting will stop.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _YearTile extends ConsumerWidget {
  const _YearTile({required this.year, required this.canAdmin});

  final FiscalYear year;
  final bool canAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = year.periods.where((p) => p.isOpen).length;

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: Space.sm),
      initiallyExpanded: year.covers(DateTime.now()),
      title: Row(children: [
        Text(year.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: Space.sm),
        if (year.covers(DateTime.now()))
          const StatusChip('current', compact: true),
      ]),
      subtitle: Text(
        '${Fmt.date(year.startDate)} – ${Fmt.date(year.endDate)} · '
        '$open of ${year.periods.length} periods open',
        style: const TextStyle(fontSize: 12),
      ),
      children: [
        for (final p in year.periods)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Expanded(flex: 3, child: Text(p.name)),
              StatusChip(p.status, compact: true),
              const SizedBox(width: Space.sm),
              SizedBox(
                width: 96,
                child: canAdmin && !p.isLocked
                    ? Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => _toggle(context, ref, p),
                          child: Text(p.isOpen ? 'Close' : 'Reopen'),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ]),
          ),
      ],
    );
  }

  Future<void> _toggle(
      BuildContext context, WidgetRef ref, FiscalPeriod period) async {
    final closing = period.isOpen;
    if (closing) {
      final ok = await confirm(
        context,
        title: 'Close ${period.name}?',
        message: 'Nothing more can be posted into it. You can reopen it '
            'later — only a locked period is final.',
        confirmLabel: 'Close',
      );
      if (!ok || !context.mounted) return;
    }

    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .setPeriodStatus(period.id, closing ? 'closed' : 'open'),
      successMessage: closing ? '${period.name} closed' : '${period.name} reopened',
    );
    ref.invalidate(fiscalYearsProvider);
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
            // A demo login is shared with everybody else looking at the
            // demo, so changing its password would lock all of them out.
            // The database refuses it either way (0076); this is here so
            // the answer arrives before the attempt rather than after.
            if (ref.watch(isDemoAccountProvider))
              Container(
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: context.colors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: const Text(
                  'This is a shared demo account. Its password and email '
                  'are fixed, so nobody can lock anyone else out. Create '
                  'your own account to change them.',
                  style: TextStyle(fontSize: 13),
                ),
              )
            else
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _ChangePasswordDialog(),
                ),
                icon: const Icon(Icons.password_outlined, size: 18),
                label: const Text('Change password'),
              ),
            const SizedBox(height: 8),
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

/// Changing a password you already know.
///
/// Deliberately different from the reset-link screen, which asks for no
/// current password because the holder cannot remember one. Here they
/// can, and being asked matters: Supabase's updateUser accepts a new
/// password on the strength of the session alone, so without this step a
/// borrowed laptop or a stolen session is enough to lock the owner out of
/// their own books. The current password is checked by signing in with
/// it, which is the only way to verify it from a client.
class _ChangePasswordDialog extends ConsumerStatefulWidget {
  const _ChangePasswordDialog();

  @override
  ConsumerState<_ChangePasswordDialog> createState() =>
      _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<_ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = ref.read(supabaseProvider).auth;
    final email = auth.currentUser?.email;
    if (email == null) {
      setState(() => _error = 'No signed-in account.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await auth.signInWithPassword(email: email, password: _current.text);
      await auth.updateUser(UserAttributes(password: _next.text));
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password changed.')),
        );
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _current,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Current password',
                ),
                validator: (v) =>
                    (v ?? '').isEmpty ? 'Enter your current password' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _next,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New password'),
                validator: validatePassword,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration:
                    const InputDecoration(labelText: 'Confirm new password'),
                validator: (v) => v == _next.text
                    ? null
                    : 'The two passwords do not match',
                onFieldSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_error!,
                      style: TextStyle(color: context.colors.danger)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Change password'),
        ),
      ],
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

/// The mark that goes at the top of every invoice, payslip and letter.
///
/// Admin only, matching the storage policy — the bucket refuses a write
/// whose first path segment is not an organization the caller administers,
/// so showing the button to anyone else would only produce a refusal.
class _LogoRow extends ConsumerStatefulWidget {
  const _LogoRow({required this.org});

  final Organization org;

  @override
  ConsumerState<_LogoRow> createState() => _LogoRowState();
}

class _LogoRowState extends ConsumerState<_LogoRow> {
  bool _busy = false;

  Future<void> _pick() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Image', extensions: ['png', 'jpg', 'jpeg', 'webp']),
    ]);
    if (file == null) return;

    final bytes = await file.readAsBytes();
    // The bucket caps at 5 MB; refusing here says why, rather than
    // letting storage return a bare 413.
    if (bytes.length > 5 * 1024 * 1024) {
      if (mounted) _say('That image is over 5 MB. Try a smaller one.');
      return;
    }

    setState(() => _busy = true);
    try {
      await repo.uploadOrgLogo(bytes, file.mimeType ?? 'image/png');
      refreshOrganization(ref);
      ref.invalidate(orgLogoProvider);
      if (mounted) _say('Logo updated');
    } catch (e) {
      if (mounted) _say('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _busy = true);
    try {
      await repo.removeOrgLogo();
      refreshOrganization(ref);
      ref.invalidate(orgLogoProvider);
      if (mounted) _say('Logo removed');
    } catch (e) {
      if (mounted) _say('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final canAdmin = ref.watch(canAdminProvider);
    final url = widget.org.logoUrl;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 180,
          child: Text('Logo',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 64,
                width: 128,
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  border: Border.all(color: context.scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                padding: const EdgeInsets.all(6),
                child: url == null
                    ? Center(
                        child: Text('None',
                            style: Theme.of(context).textTheme.bodySmall),
                      )
                    : Image.network(url,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Center(
                              child: Text('Could not load',
                                  style:
                                      Theme.of(context).textTheme.bodySmall),
                            )),
              ),
              const SizedBox(height: Space.sm),
              if (canAdmin)
                Row(children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pick,
                    icon: _busy
                        ? const SizedBox(
                            height: 14,
                            width: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.upload_outlined, size: 18),
                    label: Text(url == null ? 'Upload' : 'Replace'),
                  ),
                  if (url != null) ...[
                    const SizedBox(width: Space.sm),
                    TextButton(
                      onPressed: _busy ? null : _remove,
                      child: const Text('Remove'),
                    ),
                  ],
                ])
              else
                Text('Ask an administrator to change this.',
                    style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: Space.xs),
              Text(
                'PNG or JPEG, up to 5 MB. Printed at the top left of every '
                'invoice, payslip and generated document.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Companies that print onto their own letterhead paper.
///
/// Whether a business owns pre-printed stationery is a fact about the
/// business rather than about one invoice, so it lives here instead of in
/// a menu on every download. Off means the PDF is complete on its own,
/// which is the only safe default for a file that gets e-mailed.
class _StationeryRow extends ConsumerStatefulWidget {
  const _StationeryRow({required this.org});

  final Organization org;

  @override
  ConsumerState<_StationeryRow> createState() => _StationeryRowState();
}

class _StationeryRowState extends ConsumerState<_StationeryRow> {
  bool _busy = false;

  Future<void> _set(bool value) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _busy = true);
    try {
      await repo.setPreprintedLetterhead(value);
      refreshOrganization(ref);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(value
              ? 'Invoices and payslips will leave room for your letterhead'
              : 'Invoices and payslips will print their own letterhead'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canAdmin = ref.watch(canAdminProvider);
    final on = widget.org.usesPreprintedLetterhead;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 180,
          child: Text('Printed stationery',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Switch(
                  value: on,
                  onChanged: canAdmin && !_busy ? _set : null,
                ),
                const SizedBox(width: Space.sm),
                Flexible(
                  child: Text(
                    on
                        ? 'Leaving room for your letterhead'
                        : 'Printing our own letterhead',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ]),
              const SizedBox(height: Space.xs),
              Text(
                on
                    ? 'Invoices and payslips start 42 mm down the first page, '
                        'so nothing lands on top of your printed header. Your '
                        'registration and SST numbers are still printed, '
                        'smaller, because a tax invoice has to carry them and '
                        'stationery usually does not.'
                    : 'Turn this on only if you print onto paper that already '
                        'carries your header. A PDF you e-mail should keep its '
                        'own letterhead — nothing outside the file supplies '
                        'your address.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
