/// Everything about how this company reads its paperwork, on the screen
/// where the paperwork is.
///
/// Asked for in those words: "turn off and on also selection of AI
/// model, add api key and all, move it from settings leave nothing
/// there and move everything here".
///
/// It is the right place, and the argument is not only tidiness.
/// Settings is a page somebody visits when something is wrong; AI
/// SmartScan is the page they are already on when they find out. Every
/// refusal this module produces — the module is off, scanning is off,
/// this reader will not open a PDF, there is no credit left — now names
/// a control that is on the same screen as the sentence, rather than
/// sending somebody somewhere else to look for it.
///
/// MOVED, NOT REWRITTEN. This is `settings_screen.dart`'s scanning card
/// and its five helpers, carried across with their comments intact.
/// Several of them record a report it took to arrive at — the on-device
/// notice, the key pool, what happens when a provider is retired
/// underneath a company that chose it — and retyping any of that would
/// be a chance to lose it.
///
/// `scan_availability.dart` sends an administrator here now rather than
/// to `/settings`, which is the half of this change that would
/// otherwise be a door onto an empty room.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/ocr_repository.dart';
import '../settings/credit_ledger_dialog.dart';
import '../shared/ocr_key_pool_editor.dart';

/// Reading receipts and bills, which is off until somebody here says
/// otherwise.
///
/// The default is off and there is no row until this card writes one,
/// because a receipt carries a supplier, an amount and sometimes a
/// person's movements, and sending that to a third party is a decision
/// rather than something to discover afterwards.
class SmartScanSettingsCard extends ConsumerStatefulWidget {
  const SmartScanSettingsCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  ConsumerState<SmartScanSettingsCard> createState() => SmartScanSettingsCardState();
}

class SmartScanSettingsCardState extends ConsumerState<SmartScanSettingsCard> {
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

  /// The reader list.
  ///
  /// A dropdown rather than segments: the list comes off a table the
  /// platform can add to, so it has no fixed width and cannot be laid
  /// out as buttons.
  ///
  /// A method rather than inline, because it is drawn from two places
  /// — under a switch that is on, and under one that is off because
  /// the reader behind it has been retired. It was inline, in the
  /// second place it was not drawn at all, and that is the whole of
  /// `0678`: the control that fixes a retired reader was reachable
  /// only by first doing the thing the retired reader made impossible.
  Widget _readerPicker(OcrSettings ocr) => DropdownButtonFormField<String>(
    key: const ValueKey('smartscan-reader'),
    initialValue: ocr.providers.any((p) => p.code == ocr.provider)
        ? ocr.provider
        : null,
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'Reader'),
    items: [
      for (final p in ocr.providers)
        DropdownMenuItem(
          value: p.code,
          child: Text(
            p.runsOnDevice || p.price <= 0
                ? '${p.name} — free'
                      '${p.isActive ? '' : ' — no longer offered'}'
                : '${p.name} — ${Fmt.money(p.price)} a scan'
                      '${p.isActive ? '' : ' — no longer offered'}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
    onChanged: widget.canEdit && !_saving
        ? (code) {
            if (code == null) return;
            // A half-finished choice belongs to the reader it was made
            // for. Changing reader abandons it rather than carrying a
            // banner about a key nobody asked to set.
            setState(() => _pendingKeySource = null);
            _write(
              () => ref
                  .read(repoProvider)!
                  .setOcrSettings(
                    // Changing the reader is not switching scanning
                    // on. It used to send `true`, which was harmless
                    // while this was only drawn with scanning already
                    // on, and is not now that a company with a retired
                    // reader picks a new one while it is off.
                    enabled: ocr.enabled,
                    provider: code,
                    // Switching to a reader you have no key for would
                    // be refused, so it falls back to the platform's.
                    keySource: ocr.keys.contains(code)
                        ? ocr.keySource
                        : 'platform',
                  ),
              'Reader changed',
            );
          }
        : null,
  );

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
          skeleton: const CardRowsSkeleton(rows: 3, leading: false),
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
              // A module before it is a setting. `0682`. Drawing the
              // switch and letting the save refuse would be a screen
              // that could have predicted its own refusal and did not;
              // and "AI SmartScan is not switched on for this company"
              // arriving as a red banner AFTER the tap reads as a bug
              // rather than as a subscription.
              if (!ocr.hasModule)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.lock_outline,
                        size: 16,
                        color: context.colors.warning,
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          'AI SmartScan is a module and it is not switched '
                          'on for this company. An owner turns it on under '
                          'Subscription; everything below is what it does '
                          'once it is.',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.colors.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: ocr.enabled,
                // The switch moves the switch and says nothing about
                // the reader. It used to echo back `ocr.provider`, and
                // for a company that had never chosen one that was the
                // platform's default rather than anything this company
                // had asked for -- so retiring that reader in the
                // console turned this toggle into `Claude is not
                // available`. Null now means "leave the reader alone",
                // and a company with no reader yet gets whatever the
                // platform currently hands out. 0678.
                // Off is always allowed. A company whose module has
                // lapsed still has a switch reading "on", and refusing
                // to let them turn it off would be refusing to let them
                // tidy up after us — which is what `set_ocr_settings`
                // does too.
                onChanged: widget.canEdit && !_saving &&
                        (ocr.hasModule || ocr.enabled)
                    ? (v) => _write(
                        () => ref
                            .read(repoProvider)!
                            .setOcrSettings(enabled: v),
                        v ? 'Scanning is on' : 'Scanning is off',
                      )
                    : null,
                title: const Text('Send documents to a reader'),
                subtitle: const Text(
                  'Off unless you turn it on. A receipt carries a supplier, '
                  'an amount and sometimes a customer.',
                ),
              ),
              // Drawn while scanning is OFF, and only in this one
              // case. A company on a reader the platform has retired
              // cannot switch scanning on -- the save is refused, and
              // rightly, since nothing would scan -- and every control
              // that could change the reader lived inside
              // `if (ocr.enabled)`. So the only way out of the state
              // was through the door that was locked. 0678.
              if (ocr.mustChooseAnother) ...[
                const SizedBox(height: 8),
                Text(
                  '${ocr.current?.name ?? ocr.provider} is no longer '
                  'offered, so scanning cannot be switched on with it. '
                  'Choose another reader and the switch above will work.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.colors.warning,
                  ),
                ),
                const SizedBox(height: 8),
                _readerPicker(ocr),
              ],
              if (ocr.enabled) ...[
                const SizedBox(height: 8),
                _readerPicker(ocr),
                // Which vendor reads the document when the chosen one
                // will not, said BEFORE it happens. A company whose
                // paperwork is being read by somebody it did not pick
                // is entitled to know that is the arrangement, and
                // finding out afterwards is not the same thing. 0679.
                if (ocr.fallbackName != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.alt_route,
                        size: 14,
                        color: context.scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'If ${ocr.current?.name ?? 'this reader'} cannot '
                          'be reached, the document is read by '
                          '${ocr.fallbackName} instead — once, and at no '
                          'charge. Your own key is never used for it.',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
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
                // The balance, and only the balance. Until this move
                // the four payments cards were drawn here too --
                // Payment Methods, Collect Payments, Bank Feeds and
                // Bank Rules, each with exactly one construction site
                // and that site inside a card about reading receipts,
                // behind a condition about who pays for SCANNING. A
                // company on its own OCR key could reach none of them.
                // They are a section of their own in Settings now.
                else if (_keySource(ocr) == 'platform')
                  _CreditBalance(ocr: ocr)
                else ...[
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
                  // 0675. More than one key, each with what it may
                  // spend and when it may run.
                  //
                  // BELOW the single key rather than instead of it, and
                  // that is not tidiness. The scan asks the pool first
                  // and falls back on the single key, so a company that
                  // never opens this carries on exactly as it did; and
                  // Document AI needs a project, a location and a
                  // processor, which a pool row has nowhere to put --
                  // the field above is the only way to configure that
                  // reader at all.
                  const SizedBox(height: Space.lg),
                  _OwnKeyPool(
                    provider: ocr.provider,
                    canEdit: widget.canEdit && !_saving,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// This company's own pool of keys for the reader it has chosen.
///
/// The same editor the platform console draws, handed this company's
/// id instead of null — `app.can_admin(org_id)` is what decides
/// whether the person looking may change anything, and it decides in
/// the database rather than here.
///
/// Drawn only once a company is resolved. It always is by the time
/// this card is on screen, but `currentOrgIdProvider` is nullable and
/// a pool asked for with a null id is the PLATFORM's pool — which this
/// screen must never show and the database would refuse anyway.
class _OwnKeyPool extends ConsumerWidget {
  const _OwnKeyPool({required this.provider, required this.canEdit});

  final String provider;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orgId = ref.watch(currentOrgIdProvider);
    if (orgId == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          'More than one key',
          subtitle: 'Each with what it may spend and when it may run. '
              'Scans move between them, so a key that has reached its '
              'limit stands down until the limit resets.',
        ),
        const SizedBox(height: Space.sm),
        OcrKeyPoolEditor(
          provider: provider,
          orgId: orgId,
          canEdit: canEdit,
        ),
      ],
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
                  // A reader the platform has marked free costs this
                  // company nothing and never touches the balance, so
                  // the sentence about how many scans are left is not
                  // about it. Said plainly rather than by printing
                  // `RM0.00 a scan — about 0 more`, which is three
                  // true numbers arranged to read as bad news.
                  ocr.price <= 0
                      ? 'This reader is free. Nothing is taken from this '
                            'balance for scanning.'
                      : empty
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
