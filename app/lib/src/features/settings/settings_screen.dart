import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'einvoice_certificate_card.dart';
import 'module_offer.dart';
import 'subscription_card.dart';
import '../../data/ocr_repository.dart';
import '../../data/platform_catalog_repository.dart';
import '../../data/repository.dart';
import '../auth/reset_password_screen.dart' show validatePassword;
import '../team/invitations.dart';
import 'addresses_card.dart';
import 'claim_approval_card.dart';
import 'branches_card.dart';
import 'chart_of_accounts_card.dart';
import 'custom_fields_card.dart';
import 'document_numbering_card.dart';
import 'chat_card.dart';
import 'company_card.dart';
import 'company_group_card.dart';
import 'sst_card.dart';
import 'sst_returns_card.dart';
import 'notifications_card.dart';
import 'passkeys_card.dart';
import 'two_factor_card.dart';
import 'ways_to_pay.dart';
import 'warehouses_card.dart';
import 'credit_ledger_dialog.dart';
import 'export_card.dart';
import '../../core/searchable_picker.dart';
import '../../data/signup_reference_repository.dart';
import '../auth/phone_number.dart';
import '../auth/reset_cooldown.dart' show looksLikeAnAddress;
import 'bank_feeds_card.dart';
import 'collect_payments_card.dart';
import 'contact_changes.dart';
import 'einvoice_credentials.dart';
import 'landing_settings.dart';
import 'tax_code_dialog.dart';

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
          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 860,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // First, and above the company card, because it is
                  // the only card here that is about YOU rather than
                  // about the company -- and it is the one somebody
                  // comes to this screen for on their first day.
                  const LandingSettingsCard(),
                  const SizedBox(height: 16),
                  if (organization == null) ...[
                    const EmptyState(
                      icon: Icons.business_outlined,
                      title: 'No organization',
                      message:
                          'Create a company and its settings appear '
                          'here. Your own account is below either way.',
                    ),
                    const SizedBox(height: 16),
                  ] else ...[
                    CompanyCard(org: organization),
                    const SizedBox(height: 16),
                    // Directly under the company it describes: it is a
                    // fact about this company, and it decides what every
                    // invoice line is taxed at.
                    const SstCard(),
                    // And under the registration, the rhythm it puts
                    // the company on. Draws nothing at all — not even a
                    // gap — for a company that is not registered, which
                    // is why it carries its own spacing.
                    const SstReturnsCard(),
                    const SizedBox(height: 16),
                    // Beside the company they describe: a branch is part
                    // of this company, a group is the companies beside it.
                    if (moduleEnabled(ref, 'chat')) ...[
                      const ChatCard(),
                      const SizedBox(height: Space.md),
                      // Beside chat, because chat is the only thing that
                      // notifies anybody — and unlike everything else on
                      // this screen it is per browser, not per company.
                      const NotificationsCard(),
                      const SizedBox(height: Space.md),
                    ],
                    if (moduleEnabled(ref, 'branches')) ...[
                      const BranchesCard(),
                      const SizedBox(height: 16),
                    ],
                    const CompanyGroupCard(),
                    const SizedBox(height: 16),
                    // Beside the company's own details, because that is
                    // what a name on our domain is: another way of
                    // saying who they are. Draws nothing for a company
                    // holding neither module.
                    const AddressesCard(),
                    _EinvoiceCard(org: organization, canEdit: isAdmin),
                    const SizedBox(height: 16),
                    // 0615. Under the credentials, because a certificate
                    // signs documents for a submitter that can log in --
                    // and the order on the screen is the order to do it
                    // in.
                    EinvoiceCertificateCard(
                      canEdit: isAdmin,
                      environment: organization.einvoiceEnvironment,
                    ),
                    const SizedBox(height: 16),
                    _ScanningCard(canEdit: isAdmin),
                    const SizedBox(height: 16),
                    _ModulesCard(canAdmin: isAdmin),
                    const SizedBox(height: 16),
                    // 0489. What the modules above actually cost, and
                    // the invoices raised for them. Directly under the
                    // card that adds them, because the price agreed to
                    // there is the figure shown here.
                    SubscriptionCard(canAdmin: isAdmin),
                    const SizedBox(height: 16),
                    _FiscalYearsCard(canAdmin: isAdmin),
                    const SizedBox(height: 16),
                    const DocumentNumberingCard(),
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
                    // No module gate and no entitlement: any company can
                    // sell something delivered over time. The card shows
                    // nothing at all until one of them has, which is why
                    // it costs the shops that never will nothing.
                    _DeferredRevenueCard(org: organization, canPost: canPost),
                    if (moduleEnabled(ref, 'inventory')) ...[
                      const WarehousesCard(),
                      const SizedBox(height: 16),
                    ],
                    // Last among the company cards, because it is the
                    // one nobody needs until the day they do — and
                    // because a platform that keeps the door open says
                    // so plainly rather than burying it.
                    ExportCard(canAdmin: isAdmin),
                    const SizedBox(height: 16),
                    const ChartOfAccountsCard(),
                    const SizedBox(height: 16),
                    const CustomFieldsCard(),
                    const SizedBox(height: 16),
                    _TaxCodesCard(),
                    const SizedBox(height: 16),
                  ],
                  // Outside the branch above, because this card is about
                  // *you* and not about a company. It used to sit below
                  // the null check with everything else, so somebody who
                  // belonged to no organization — which platform staff
                  // routinely do — got "create a company to get started"
                  // and no way to change their own password, sign out,
                  // or close their account. The one credential they
                  // most need to rotate was the one the screen would not
                  // let them reach.
                  //
                  // `role` goes in null in that case rather than the
                  // 'viewer' the provider falls back to: no company means
                  // no role in one, and printing "Viewer" would be a
                  // statement about a company that is not there.
                  _AboutCard(role: organization == null ? null : role),
                  // Directly under Change password, because it is the
                  // same decision — how you prove who you are — and
                  // somebody just told they can change their password is
                  // exactly who should be offered the thing that means
                  // they will not have to. Draws nothing when the
                  // project has passkeys off.
                  const SizedBox(height: 16),
                  const PasskeysCard(),
                  const SizedBox(height: Space.lg),
                  // `0613`. The third way to prove who you are, and
                  // deliberately the middle one in strength: weaker
                  // than a passkey, stronger than a password alone.
                  // Offered beside it because a passkey is not
                  // available everywhere — not on this app's Android
                  // and iOS builds — and somebody who cannot use the
                  // strongest thing should not be left with the
                  // weakest.
                  const TwoFactorCard(),
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

  /// Set from the status row rather than from the organization, because
  /// `my_organizations` does not return `settings` and the version
  /// lives on it. `einvoiceCredentialStatus` reads the same key and is
  /// already being fetched for this card.
  String? _version;

  @override
  void initState() {
    super.initState();
    _enabled = widget.org.einvoiceEnabled;
    _environment = widget.org.einvoiceEnvironment;
  }

  /// Saved as it is chosen, and put back if the database refuses.
  ///
  /// It refuses 1.1 without a signing certificate, and a dropdown left
  /// showing the choice that was rejected is a screen disagreeing with
  /// the row behind it — which is how somebody submits at a version
  /// they believe they are on.
  Future<void> _setVersion(String? value) async {
    if (value == null || value == _version) return;
    final previous = _version;
    setState(() {
      _version = value;
      _saving = true;
    });
    final ok = await runWithFeedback(
      context,
      successMessage: 'Filing at e-Invoice version $value',
      action: () => ref.read(repoProvider)!.setEinvoiceVersion(value),
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!ok) _version = previous;
    });
    if (ok) {
      refreshOrganization(ref);
      ref.invalidate(einvoiceStatusProvider);
    }
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

        await ref
            .read(supabaseProvider)
            .from('organizations')
            .update({
              'einvoice_enabled': _enabled,
              'einvoice_environment': _environment,
              'einvoice_client_id': _clientId.text.trim().isEmpty
                  ? null
                  : _clientId.text.trim(),
            })
            .eq('id', widget.org.id);
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

  /// Take them back out. Removing the credentials of the environment
  /// the company is actually submitting to switches submission off with
  /// them, for the reason written above `_save`: a company enabled with
  /// no credentials is marked live against a submitter that cannot log
  /// in.
  Future<void> _clear() async {
    final alsoDisables = removingLeavesItLive(
      enabled: _enabled,
      environment: _environment,
      current: widget.org.einvoiceEnvironment,
    );
    final ok = await askRemoveCredentials(
      context,
      environment: _environment,
      alsoDisables: alsoDisables,
    );
    if (!ok || !mounted) return;

    setState(() => _saving = true);
    final done = await runWithFeedback(
      context,
      action: () async {
        final repo = ref.read(repoProvider)!;
        await repo.clearEinvoiceCredentials(_environment);
        if (alsoDisables) {
          await ref
              .read(supabaseProvider)
              .from('organizations')
              .update({'einvoice_enabled': false, 'einvoice_client_id': null})
              .eq('id', widget.org.id);
        }
      },
      successMessage: 'Removed',
    );

    if (mounted) setState(() => _saving = false);
    if (done && mounted) {
      setState(() {
        if (alsoDisables) _enabled = false;
        _clientId.clear();
        _clientSecret.clear();
      });
      ref.invalidate(organizationsProvider);
      refreshOrganization(ref);
      ref.invalidate(einvoiceStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final missingTin = (widget.org.tin ?? '').isEmpty;

    // What the database says the version is, for the dropdown to start
    // at. `_version` holds what somebody has since chosen — null until
    // they do, so a refresh of the status row is reflected rather than
    // frozen at whatever it said when the card was built.
    final rows =
        ref.watch(einvoiceStatusProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
    final storedVersion = rows.isEmpty
        ? '1.0'
        : '${rows.first['einvoice_version'] ?? '1.0'}';

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
            // 0615. Which version LHDN's rules are applied at. It is on
            // `organizations.settings` and has been read by
            // `prepare_einvoice` since 0015, and until now there was
            // nowhere to set it.
            //
            // Saved on the spot rather than with the rest of the card,
            // because the database refuses 1.1 without a signing
            // certificate and that refusal has to arrive while somebody
            // is looking at the switch that caused it.
            DropdownButtonFormField<String>(
              key: const ValueKey('einvoice-version'),
              isExpanded: true,
              value: _version ?? storedVersion,
              decoration: const InputDecoration(
                labelText: 'e-Invoice version',
                helperText:
                    'A 1.1 document carries a digital signature. A document '
                    'already prepared keeps the version it was prepared '
                    'under.',
              ),
              items: const [
                DropdownMenuItem(value: '1.0', child: Text('1.0 — unsigned')),
                DropdownMenuItem(value: '1.1', child: Text('1.1 — signed')),
              ],
              onChanged: widget.canEdit && !_saving ? _setVersion : null,
            ),
            const SizedBox(height: 16),
            if (widget.canEdit)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('clear-einvoice-credentials'),
                  onPressed: _saving ? null : _clear,
                  child: Text('Remove the $_environment credentials'),
                ),
              ),
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
    final ok = await runWithFeedback(
      context,
      action: action,
      successMessage: message,
    );
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
        () => ref
            .read(repoProvider)!
            .setOcrSettings(
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
  Future<void> _saveKey(OcrSettings ocr) => _write(() async {
    final repo = ref.read(repoProvider)!;
    await repo.setOcrCredentials(
      provider: ocr.provider,
      apiKey: _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim(),
      projectId: _project.text.trim().isEmpty ? null : _project.text.trim(),
      location: _location.text.trim().isEmpty ? null : _location.text.trim(),
      processorId: _processor.text.trim().isEmpty
          ? null
          : _processor.text.trim(),
    );
    await repo.setOcrSettings(
      enabled: ocr.enabled,
      provider: ocr.provider,
      keySource: 'own',
    );
    _apiKey.clear();
    if (mounted) setState(() => _pendingKeySource = null);
  }, 'Scanning is on your own key');

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
              // Named, because `0614` widened it past receipts. The
              // subtitle names the papers rather than the technology:
              // the question somebody has is "will it read THIS", and
              // a list answers it where "AI-powered extraction" does
              // not.
              const SectionHeader(
                'AI SmartScan',
                subtitle:
                    'Photograph a bill, a receipt, a delivery order, a '
                    'name card or a bank statement and have it read — the '
                    'supplier, the date, the amounts and the lines',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: ocr.enabled,
                onChanged: widget.canEdit && !_saving
                    ? (v) => _write(
                        () => ref
                            .read(repoProvider)!
                            .setOcrSettings(
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
                            () => ref
                                .read(repoProvider)!
                                .setOcrSettings(
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
                      color: context.scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (ocr.current?.takesKey ?? true) ...[
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: 'platform',
                        label: Text('Buy credit'),
                      ),
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
                  _BillingSection(ocr: ocr)
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
          child: Row(
            children: [
              const Icon(Icons.phonelink_lock_outlined, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Nothing to configure: no key to hold and no credit to buy.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Works everywhere: ML Kit on the phone app, and Tesseract in a '
          'browser, both served from us. The browser fetches about 8MB '
          'the first time it reads something and caches it after that. '
          'Check what it fills in — it reads the printing rather than '
          'understanding the document, and it cannot open a PDF.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: context.scheme.onSurfaceVariant,
          ),
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
      child: Row(
        children: [
          Icon(
            empty ? Icons.error_outline : Icons.account_balance_wallet_outlined,
            size: 20,
          ),
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
          // The only question anybody asks of a prepaid balance. The
          // ledger has recorded every movement all along and nothing
          // read it, so the number went down and nobody could see what
          // took it.
          TextButton(
            key: const ValueKey('credit-ledger'),
            onPressed: () => showCreditLedger(context),
            child: const Text('Where it went'),
          ),
        ],
      ),
    );
  }
}

/// The scanning balance, and how the platform is paid.
///
/// `creditInvoicesProvider` has existed since 0111 and had no consumer:
/// a company could be billed for scanning credit and had nowhere to see
/// the invoice, let alone settle it. That list lived here from then
/// until 0489, when `platform_invoices` stopped being only about
/// scanning — it now carries every company's monthly module bill, and
/// this section is drawn only when the OCR key source is 'platform'.
/// The list is on the subscription card now; what is left here is the
/// balance itself and the ways the platform can be paid.
class _BillingSection extends StatelessWidget {
  const _BillingSection({required this.ocr});

  final OcrSettings ocr;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CreditBalance(ocr: ocr),
        const SizedBox(height: 12),
        // 0489. The invoice list used to be here, and only here --
        // inside the scanning card, drawn only when the key source was
        // 'platform'. It was written in 0111 for scanning credit, which
        // is what `platform_invoices` held then; now the table also
        // holds every company's monthly module bill, and a company on
        // its own OCR key could not see that bill at all. It is on the
        // subscription card, which is drawn for an owner or admin
        // whatever this company does about scanning.
        const _WaysToPay(),
        const SizedBox(height: Space.lg),
        const CollectPaymentsCard(),
        const SizedBox(height: Space.lg),
        // Beside the acquirer credentials on purpose: both are a third
        // party holding a key that reaches this company's money, both
        // are held so nothing can read the key back, and somebody
        // setting one up is usually setting up the other.
        const BankFeedsCard(),
      ],
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
            child: Row(
              children: [
                Icon(
                  Icons.key_outlined,
                  size: 18,
                  color: context.colors.success,
                ),
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
              ],
            ),
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: project,
                  enabled: canEdit,
                  decoration: const InputDecoration(labelText: 'Project id'),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: location,
                  enabled: canEdit,
                  decoration: const InputDecoration(
                    labelText: 'Location',
                    hintText: 'us',
                  ),
                ),
              ),
            ],
          ),
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
/// What this company has, and what it wants to look at.
///
/// Two different facts about a module, and 0234 keeps them apart on the
/// server for a reason:
///
///   * whether the company **holds** it, which is billing and is not
///     changed from here; and
///   * whether the company wants it **on screen**, which is a
///     preference and is.
///
/// A company that only runs a service desk can put Sales, the ledger
/// screens and the rest away and be left with what it uses. Nothing is
/// revoked by doing so: tickets still post to the same ledger, the API
/// still answers, and the switch comes back on from this same card.
/// Adding a paid module is a bill, so it is confirmed before it is
/// done — and the confirmation says the price rather than leaving
/// somebody to find it on an invoice.
Future<void> _addModule(
  BuildContext context,
  WidgetRef ref,
  ModuleSurface m,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(addModuleTitle(m)),
      content: Text(addModulePrompt(m)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Add it'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  await runWithFeedback(
    context,
    action: () => ref.read(repoProvider)!.setOwnModule(m.code, true),
    doing: 'add ${m.name}',
    successMessage: '${m.name} is on',
  );
  ref.invalidate(moduleSurfaceProvider);
  ref.invalidate(enabledModulesProvider);
  ref.invalidate(moduleDashboardProvider);
  ref.invalidate(canAddCompanyProvider);
  // 0489. The running total is the running total: a figure that still
  // says "nothing this month" beside a module somebody just added is
  // worse than no figure at all.
  ref.invalidate(moduleChargesProvider);
}

/// Take a paid add-on off again.
///
/// The counterpart to [_addModule], and the thing 0488's copy promised
/// and did not have: "you can take it off here too" was true of the
/// visibility switch, which changes nothing about the bill, and false
/// of the entitlement, which is what carries the price.
Future<void> _removeModule(
  BuildContext context,
  WidgetRef ref,
  ModuleSurface m,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(removeModuleTitle(m)),
      content: Text(removeModulePrompt(m)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Keep it'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Remove it'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  await runWithFeedback(
    context,
    action: () => ref.read(repoProvider)!.setOwnModule(m.code, false),
    doing: 'remove ${m.name}',
    successMessage: '${m.name} is off',
  );
  ref.invalidate(moduleSurfaceProvider);
  ref.invalidate(enabledModulesProvider);
  ref.invalidate(moduleDashboardProvider);
  ref.invalidate(canAddCompanyProvider);
  ref.invalidate(moduleChargesProvider);
}

class _ModulesCard extends ConsumerWidget {
  const _ModulesCard({required this.canAdmin});

  final bool canAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surface = ref.watch(moduleSurfaceProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Modules',
              subtitle:
                  'Switch off what this company does not use. '
                  'Nothing is cancelled — the screens come back from here.',
            ),
            AsyncView(
              value: surface,
              onRetry: () => ref.invalidate(moduleSurfaceProvider),
              loading: const LinearProgressIndicator(),
              builder: (modules) {
                final held = [
                  for (final m in modules)
                    if (m.entitled) m,
                ];
                final rest = [
                  for (final m in modules)
                    if (!m.entitled) m,
                ];

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final m in held)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: m.visible,
                        title: Text(m.name),
                        subtitle: m.description == null
                            ? null
                            : Text(
                                m.description!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                        // 0489. The switch beside this hides the
                        // screens; this takes the entitlement, and the
                        // monthly charge, off. Only for what is
                        // actually an add-on: the core modules are the
                        // product and cannot be removed from it.
                        secondary: (!canAdmin || m.isCore)
                            ? null
                            : IconButton(
                                key: ValueKey('remove-module-${m.code}'),
                                tooltip: 'Remove from this company',
                                icon: const Icon(
                                  Icons.remove_circle_outline,
                                  size: 20,
                                ),
                                onPressed: () => _removeModule(context, ref, m),
                              ),
                        onChanged: !canAdmin
                            ? null
                            : (on) async {
                                await runWithFeedback(
                                  context,
                                  action: () => ref
                                      .read(repoProvider)!
                                      .setModuleHidden(m.code, !on),
                                  successMessage: on
                                      ? '${m.name} is back'
                                      : '${m.name} put away',
                                );
                                ref.invalidate(moduleSurfaceProvider);
                                ref.invalidate(enabledModulesProvider);
                                ref.invalidate(moduleDashboardProvider);
                              },
                      ),
                    if (rest.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 8),
                      Text(
                        'Not on this account',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        // 0488. This used to read "Contact us to add
                        // one of these", with no address behind it and
                        // no way to act.
                        moduleOfferLine(canAdmin: canAdmin),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final m in rest)
                            ActionChip(
                              key: ValueKey('add-module-${m.code}'),
                              avatar: Icon(
                                canAdmin
                                    ? Icons.add_circle_outline
                                    : Icons.remove_circle_outline,
                                size: 16,
                                color: canAdmin
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.outline,
                              ),
                              label: Text(moduleChipLabel(m)),
                              // Absent rather than refusing: a clerk
                              // may write invoices all day and still
                              // not commit the company to a bill, and
                              // the server says the same.
                              onPressed: !canAdmin
                                  ? null
                                  : () => _addModule(context, ref, m),
                            ),
                        ],
                      ),
                      // What the promotions on offer actually are. The
                      // chip carries the price; a price nobody can see
                      // the old one beside is just a number, and one
                      // with no end date on it is a promise this
                      // product would then have to keep.
                      for (final m in rest)
                        if (modulePromoNote(m) != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            key: ValueKey('promo-note-${m.code}'),
                            modulePromoNote(m)!,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ],
                    ],
                    if (held.any((m) => m.code == 'legal')) ...[
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 8),
                      Text(
                        'Legal firm accounting',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
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
                );
              },
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
            Text(switch (org.creditControl) {
              'off' => 'Limits are recorded and never checked.',
              'block' =>
                'An invoice that would take a customer past their limit '
                    'cannot be posted.',
              _ =>
                'The invoice screen says when a customer is at or past '
                    'their limit. Posting still goes ahead.',
            }, style: Theme.of(context).textTheme.bodySmall),
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
              error: (e, _) =>
                  Text('$e', style: TextStyle(color: context.colors.warning)),
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
                              icon: const Icon(
                                Icons.published_with_changes,
                                size: 18,
                              ),
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

/// Releasing revenue that has been earned.
///
/// The other half of `0309`. A deferred line credits a liability when
/// the invoice posts and nothing moves it to revenue until somebody
/// runs the release — so without this card the money sits in 2127
/// forever and the P&L is wrong in the safe direction, which is the
/// direction nobody notices.
///
/// Sits with the foreign balances and the fiscal years for the same
/// reason they sit together: it is one of the things that has to happen
/// before a month can be called closed.
///
/// Renders nothing when there is nothing deferred. Most companies will
/// never defer a line, and a permanent empty card telling them so is a
/// tax on them for a feature they do not use.
class _DeferredRevenueCard extends ConsumerStatefulWidget {
  const _DeferredRevenueCard({required this.org, required this.canPost});

  final Organization org;
  final bool canPost;

  @override
  ConsumerState<_DeferredRevenueCard> createState() =>
      _DeferredRevenueCardState();
}

class _DeferredRevenueCardState extends ConsumerState<_DeferredRevenueCard> {
  /// End of last month, which is when a release is almost always dated
  /// — the same default the depreciation and revaluation runs take.
  late DateTime _upto = DateTime(DateTime.now().year, DateTime.now().month, 0);

  @override
  Widget build(BuildContext context) {
    final due = ref.watch(revenueDueProvider);

    // Nothing deferred, still loading, or the read failed: no card. A
    // spinner and an error box here would be noise on a settings screen
    // for a company that has never deferred anything, and the failure
    // is not one anybody can act on from here.
    final rows = due.value;
    if (rows == null || rows.isEmpty) return const SizedBox.shrink();

    final split = splitRevenueDue(rows, _upto);
    final ready = split.ready;
    final later = split.later;
    final readyTotal = ready.fold<double>(0, (s, r) => s + r.amount);
    final laterTotal = later.fold<double>(0, (s, r) => s + r.amount);

    return Column(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(
                  'Deferred revenue',
                  subtitle: 'Release what has been earned',
                  action: TextButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text('Up to ${Fmt.date(_upto)}'),
                  ),
                ),
                if (ready.isEmpty)
                  Text(
                    'Nothing earned by ${Fmt.date(_upto)}. The next '
                    'release is ${Fmt.date(later.first.periodEnd)}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else ...[
                  for (final row in ready) _DueRow(row: row, base: _base),
                  const Divider(height: 20),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'To release',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Money(readyTotal, currency: _base, bold: true),
                    ],
                  ),
                ],
                if (later.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${Fmt.money(laterTotal, currency: _base)} still to '
                    'come, through ${Fmt.date(later.last.periodEnd)}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (widget.canPost && ready.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: () => _post(ready.length, readyTotal),
                      icon: const Icon(Icons.published_with_changes, size: 18),
                      label: const Text('Recognise'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  /// The ledger's own currency. `0309` posts in `app.base_currency`,
  /// which always resolves, so an empty string here is a gap in the row
  /// this screen read rather than a real second currency — falling back
  /// to the formatter's default beats printing a bare space.
  String get _base =>
      widget.org.baseCurrency.isEmpty ? 'MYR' : widget.org.baseCurrency;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _upto,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _upto = picked);
  }

  Future<void> _post(int journals, double total) async {
    final ok = await confirm(
      context,
      title: 'Release the revenue?',
      // Says how many journals, because that is what will appear in the
      // ledger and one entry per month is the part people are surprised
      // by. Each is dated on its own period end, not on today, so a
      // closed month refuses it rather than landing in the wrong one.
      message:
          'This posts $journals journal${journals == 1 ? '' : 's'} — one '
          'per month — moving '
          '${Fmt.money(total, currency: _base)} out of deferred revenue '
          'and into income, each dated on the month it was earned.',
      confirmLabel: 'Recognise',
    );
    if (!ok || !mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.recogniseRevenue(_upto),
      successMessage: 'Revenue recognised',
      pendingMessage: 'Posting…',
    );
    if (mounted) {
      ref.invalidate(revenueDueProvider);
      refreshLedgerData(ref);
    }
  }
}

class _DueRow extends StatelessWidget {
  const _DueRow({required this.row, required this.base});

  final RevenueDue row;
  final String base;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Fmt.date(row.periodEnd)),
                Text(
                  '${row.lines} line${row.lines == 1 ? '' : 's'} on '
                  '${row.documents} invoice${row.documents == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Money(row.amount, currency: base),
        ],
      ),
    );
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
                Text(
                  '${row.currency} at ${Fmt.rate(row.closingRate)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
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
    final months = (last.year - now.year) * 12 + (last.month - now.month);

    if (months > 3) return const SizedBox.shrink();

    final expired = last.isBefore(now);
    final colour = expired ? context.colors.danger : context.colors.warning;

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
          Icon(
            expired ? Icons.error_outline : Icons.warning_amber_rounded,
            size: 18,
            color: colour,
          ),
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
      title: Row(
        children: [
          Text(year.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: Space.sm),
          if (year.covers(DateTime.now()))
            const StatusChip('current', compact: true),
        ],
      ),
      subtitle: Text(
        '${Fmt.date(year.startDate)} – ${Fmt.date(year.endDate)} · '
        '$open of ${year.periods.length} periods open',
        style: const TextStyle(fontSize: 12),
      ),
      children: [
        for (final p in year.periods)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
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
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    FiscalPeriod period,
  ) async {
    final closing = period.isOpen;
    if (closing) {
      final ok = await confirm(
        context,
        title: 'Close ${period.name}?',
        message:
            'Nothing more can be posted into it. You can reopen it '
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
      successMessage: closing
          ? '${period.name} closed'
          : '${period.name} reopened',
    );
    ref.invalidate(fiscalYearsProvider);
  }
}

/// The rates this company charges.
///
/// The seeded codes cover SST as it stands, which is not the same thing
/// as covering every company: a rate moves in a budget, a business is
/// exempt on one service line and not another, and until this card the
/// only way to record either was a migration. The database has allowed
/// the write since 0010 — `tax_codes` has had insert, update and delete
/// policies for anyone who can post all along — so this is a screen
/// catching up with a permission, not a permission being widened.
class _TaxCodesCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final taxCodes = ref.watch(taxCodesProvider);
    final canEdit = ref.watch(canPostProvider);

    Future<void> edit([TaxCode? existing]) async {
      final saved = await showDialog<String>(
        context: context,
        builder: (_) => TaxCodeDialog(existing: existing),
      );
      if (saved != null) ref.invalidate(taxCodesProvider);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Tax codes',
              subtitle: 'Sales and service tax rates used on documents',
              action: canEdit
                  ? TextButton.icon(
                      onPressed: () => edit(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add'),
                    )
                  : null,
            ),
            AsyncView(
              value: taxCodes,
              onRetry: () => ref.invalidate(taxCodesProvider),
              loading: const LinearProgressIndicator(),
              builder: (list) => Column(
                children: [
                  for (final t in list)
                    InkWell(
                      key: ValueKey('tax-code-${t.code}'),
                      onTap: canEdit ? () => edit(t) : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 64,
                              child: Text(
                                t.code,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
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
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (canEdit) ...[
                              const SizedBox(width: 4),
                              const Icon(Icons.chevron_right, size: 18),
                            ],
                          ],
                        ),
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

  /// The caller's role in the current company, or null when they belong
  /// to no company at all.
  final String? role;

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
            FieldRow(label: 'Signed in as', value: user?.email ?? '—'),
            if (role != null) FieldRow(label: 'Role', value: Fmt.label(role!)),
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
            // Both behind the same password. These two are how an
            // account is recovered -- the address a reset link goes to
            // and the number somebody is rung on -- so somebody who
            // walks past an unattended screen and changes either owns
            // the account a minute later.
            if (!ref.watch(isDemoAccountProvider)) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('change-email'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _ChangeEmailDialog(),
                ),
                icon: const Icon(Icons.alternate_email, size: 18),
                label: const Text(changeEmailLabel),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('change-mobile'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _ChangeMobileDialog(),
                ),
                icon: const Icon(Icons.phone_outlined, size: 18),
                label: const Text(changeMobileLabel),
              ),
            ],
            const SizedBox(height: 8),
            // Somebody who already had an account when they were
            // invited has no other way in. `app.handle_new_user` claims
            // a pending invitation at *signup*, so the accidental path
            // only ever worked for people who did not have an account
            // yet — an accountant taking on a second company's books
            // was invited, never told, and the row expired in a
            // fortnight.
            OutlinedButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _JoinCompanyDialog(),
              ),
              icon: const Icon(Icons.group_add_outlined, size: 18),
              label: const Text('Join another company'),
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
            // Not offered on the shared demo logins: closing one would
            // take the panel away from everybody.
            // Needs a company: the blockers it lists — unapproved
            // claims, unposted journals, an unfiled return — are all
            // facts about one, and the provider behind them is
            // org-bound. Closing an account that belongs to no company
            // is a real thing to want and not what this widget does, so
            // it is left off rather than shown broken.
            if (role != null && !ref.watch(isDemoAccountProvider)) ...[
              const SizedBox(height: Space.lg),
              const Divider(),
              const SizedBox(height: Space.sm),
              const _CloseAccount(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Closing your own account.
///
/// What this does is anonymise rather than delete, and the dialog says
/// so in those words. Roughly a hundred columns record who posted a
/// journal, approved a payroll or signed a resolution, and a set of
/// books that cannot answer that is not one anybody can rely on — so the
/// identity goes and the trail stays. Saying "deleted" here and meaning
/// something else would be the kind of promise that gets found out.
class _CloseAccount extends ConsumerWidget {
  const _CloseAccount();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blockers = ref.watch(accountDeletionBlockersProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Close this account',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: Space.xs),
        Text(
          'Your name, email address, phone number and picture are removed '
          'from this system, every device stops receiving notifications, '
          'and you are signed out of everywhere. Entries you posted keep '
          'a record that somebody posted them, without saying who — the '
          'law requires those books to be kept for seven years.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: Space.sm),
        blockers.when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
          data: (rows) => rows.isEmpty
              ? OutlinedButton.icon(
                  key: const ValueKey('close-account'),
                  onPressed: () => _close(context, ref),
                  icon: const Icon(Icons.person_remove_outlined, size: 18),
                  label: const Text('Close my account'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.colors.danger,
                  ),
                )
              // Said before the button rather than after pressing it:
              // the database refuses this, and an action that always
              // fails is worse than one that is not offered.
              : Container(
                  key: const ValueKey('close-account-blocked'),
                  padding: const EdgeInsets.all(Space.md),
                  decoration: BoxDecoration(
                    color: context.colors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Text(
                    'You are the only owner of '
                    '${rows.map((r) => r['organization']).join(', ')}. '
                    'Make somebody else an owner first, or the company is '
                    'left with nobody who can administer it.',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _close(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Close this account?',
      message:
          'This cannot be undone. Your name and contact details are '
          'removed, you lose access to every company you belong to, and '
          'you cannot sign in again with this address.',
      confirmLabel: 'Close my account',
    );
    if (!ok || !context.mounted) return;

    final done = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.deleteMyAccount(),
      successMessage: 'Your account has been closed',
    );
    if (!done || !context.mounted) return;

    await ref.read(supabaseProvider).auth.signOut();
    ref.read(currentOrgIdProvider.notifier).clear();
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

/// Changing the address a password reset goes to, behind the password.
///
/// The address does not move when this returns: GoTrue sends a
/// confirmation to the NEW address and waits for the link to be
/// followed. That is the protection that matters — somebody who
/// changes an address they cannot read has changed nothing — and the
/// password re-entry is the one that stops the change being made at
/// all by whoever found the screen unlocked.
class _ChangeEmailDialog extends ConsumerStatefulWidget {
  const _ChangeEmailDialog();

  @override
  ConsumerState<_ChangeEmailDialog> createState() => _ChangeEmailDialogState();
}

class _ChangeEmailDialogState extends ConsumerState<_ChangeEmailDialog> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = ref.read(supabaseProvider).auth;
    final current = auth.currentUser?.email;
    if (current == null) {
      setState(() => _error = 'No signed-in account.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // GoTrue verifies the password, by being asked to sign in with
      // it. A check written here would be a check the client could
      // skip.
      await auth.signInWithPassword(email: current, password: _password.text);
      await auth.updateUser(UserAttributes(email: _email.text.trim()));
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(emailChangeSent(_email.text.trim()))),
      );
    } on AuthException catch (e) {
      if (mounted) {
        setState(
          () => _error = looksWrongPassword(code: e.code, message: e.message)
              ? wrongPassword
              : e.message,
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(changeEmailTitle),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const ValueKey('new-email'),
                controller: _email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'New email address',
                ),
                validator: (v) => looksLikeAnAddress((v ?? '').trim())
                    ? null
                    : 'Enter a valid email address',
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('email-password'),
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: currentPasswordLabel,
                  helperText: whyPasswordAgain,
                  helperMaxLines: 3,
                ),
                validator: currentPasswordError,
                onFieldSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: context.colors.danger)),
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
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Send the confirmation'),
        ),
      ],
    );
  }
}

/// Changing the number somebody is rung on, behind the same password.
///
/// The number goes through `update_my_phone`, which applies the same
/// E.164 rule registration uses: the trunk-prefix zero comes off in the
/// database rather than here, so it comes off whichever door a number
/// arrives through.
class _ChangeMobileDialog extends ConsumerStatefulWidget {
  const _ChangeMobileDialog();

  @override
  ConsumerState<_ChangeMobileDialog> createState() =>
      _ChangeMobileDialogState();
}

class _ChangeMobileDialogState extends ConsumerState<_ChangeMobileDialog> {
  final _formKey = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  String _dialCode = homeDialCode;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final client = ref.read(supabaseProvider);
    final current = client.auth.currentUser?.email;
    if (current == null) {
      setState(() => _error = 'No signed-in account.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await client.auth.signInWithPassword(
        email: current,
        password: _password.text,
      );
      final saved = await client.rpc(
        'update_my_phone',
        params: {'p_dial': _dialCode, 'p_national': _phone.text.trim()},
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(saved is String ? mobileChanged(saved) : mobileRemoved),
        ),
      );
    } on AuthException catch (e) {
      if (mounted) {
        setState(
          () => _error = looksWrongPassword(code: e.code, message: e.message)
              ? wrongPassword
              : e.message,
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final codes = withDialCodes(
      ref.watch(signupReferenceProvider).valueOrNull?.dialCodes ??
          const <Map<String, dynamic>>[],
    );

    return AlertDialog(
      title: const Text(changeMobileTitle),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SearchablePicker<String>(
                key: const ValueKey('mobile-country'),
                label: countryFieldLabel,
                value: codes.any((c) => dialOf(c) == _dialCode)
                    ? codes.firstWhere((c) => dialOf(c) == _dialCode)['code']
                          as String?
                    : null,
                options: [
                  for (final c in codes)
                    PickerOption(
                      value: '${c['code']}',
                      label: countryPickerLabel(c),
                      sublabel: countryPickerSublabel(c),
                      keywords: ['${c['alpha2']}', '+${dialOf(c)}'],
                    ),
                ],
                onChanged: (v) => setState(() => _dialCode = dialFor(codes, v)),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('new-mobile'),
                controller: _phone,
                keyboardType: TextInputType.phone,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: phoneFieldLabel,
                  prefixText: '+$_dialCode ',
                  helperText: phoneNote(
                    dialCode: _dialCode,
                    number: _phone.text,
                  ),
                  helperMaxLines: 2,
                ),
                // Not required: an empty box takes the number off,
                // which is a thing somebody is allowed to want.
                validator: (v) => phoneError(
                  dialCode: _dialCode,
                  number: v ?? '',
                  required: false,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mobile-password'),
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: currentPasswordLabel,
                  helperText: whyPasswordAgainMobile,
                  helperMaxLines: 3,
                ),
                validator: currentPasswordError,
                onFieldSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: context.colors.danger)),
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
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Password changed.')));
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
                decoration: const InputDecoration(
                  labelText: 'Confirm new password',
                ),
                validator: (v) =>
                    v == _next.text ? null : 'The two passwords do not match',
                onFieldSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: TextStyle(color: context.colors.danger),
                  ),
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
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Change password'),
        ),
      ],
    );
  }
}

/// Every way this company may settle a platform invoice.
///
/// The list comes from `payment_gateways_for`, which answers for the
/// country the company is registered in. `0292`'s table comment said
/// the catalogue was readable by a tenant "so that a company can be
/// shown the ways it may pay", `0295` filled it with forty providers
/// and where each one sells, and until `0352` gave the reader a caller
/// none of it reached anybody.
///
/// Drawn only when there is something to say. A company whose platform
/// has switched on the one gateway this app can start a payment with
/// already has a Pay button above, and repeating "you may pay by card"
/// under it is noise.
class _WaysToPay extends ConsumerWidget {
  const _WaysToPay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final country = ref.watch(currentOrgProvider).valueOrNull?.countryCode;
    final gateways = ref.watch(gatewaysForCountryProvider(country)).valueOrNull;
    // Still loading, or the read failed. Either way this block is an
    // aside on a settings screen and must not become the reason it
    // shows an error.
    if (gateways == null) return const SizedBox.shrink();

    final byHand = payByHandBecause(gateways);
    if (byHand == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'How to pay',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          byHand,
          style: TextStyle(
            fontSize: 12,
            color: context.scheme.onSurfaceVariant,
          ),
        ),
        for (final g in gateways)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${g['name']}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (methodsLine(g).isNotEmpty)
                  Text(
                    methodsLine(g),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.scheme.onSurfaceVariant,
                    ),
                  ),
                if (instructionsOf(g) != null)
                  Text(
                    instructionsOf(g)!,
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Taking up an invitation with the code somebody was given.
///
/// The check before the round trip is a courtesy, not a control. What
/// decides is `accept_invitation`, and the rule that matters is one
/// this side cannot evaluate: the caller has to be signed in as the
/// address the invitation names. That is `0353`'s answer to a token
/// that every member of the inviting company can read.
class _JoinCompanyDialog extends ConsumerStatefulWidget {
  const _JoinCompanyDialog();

  @override
  ConsumerState<_JoinCompanyDialog> createState() => _JoinCompanyState();
}

class _JoinCompanyState extends ConsumerState<_JoinCompanyDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _said;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final blocked = joinBlockedBecause(_code.text);
    if (blocked != null) {
      setState(() => _said = blocked);
      return;
    }
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() {
      _busy = true;
      _said = null;
    });
    try {
      final orgId = await repo.acceptInvitation(cleanCode(_code.text));
      if (!mounted) return;
      // Open the company they have just joined, rather than leaving
      // them on the settings screen of the one they were already in
      // wondering whether it worked.
      ref.invalidate(organizationsProvider);
      ref.read(currentOrgIdProvider.notifier).select(orgId);
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _said = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join another company'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste the invitation code you were sent. It only works for '
              'the address you are signed in as.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _code,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Invitation code'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            if (_said != null) ...[
              const SizedBox(height: Space.sm),
              Text(
                _said!,
                style: TextStyle(fontSize: 12, color: context.colors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _join,
          child: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Join'),
        ),
      ],
    );
  }
}
