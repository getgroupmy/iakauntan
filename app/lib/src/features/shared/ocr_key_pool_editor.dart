import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/row_actions.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// `OcrPoolKey` and `OcrKeyPool` live here.
import '../../data/ocr_repository.dart';

/// A reader's pool of keys, and everything anybody does to one.
///
/// ONE editor, used twice: the platform console draws it for the
/// platform's pool (`orgId` null) and the tenant's Settings card draws
/// it for that company's own. The database is what tells the two
/// apart — `app.is_platform_admin()` for a null org id and
/// `app.can_admin(org_id)` for a uuid — so there is nothing here that
/// needs to know which side it is on, and two copies of this would be
/// two copies that drift.
///
/// ## The key goes in and does not come back
///
/// This can add a key, change what it may spend, stand it down and
/// remove it. It cannot show you one. `ocr_keys_for` has no column
/// that could carry a key, and the table behind it has its grants
/// revoked from everybody but the service role. The last four
/// characters are here only so two keys off the same account can be
/// told apart against the provider's own console. A key you have lost
/// is one you replace.
///
/// ## Two gates, and they fail differently
///
/// A key runs when its CLOCK allows it and its BUDGET has room, and
/// this says which one stopped it, because the answers are different:
/// switched off is a decision to reverse, outside its hours is a wait
/// with a known end, and spent is a wait that needs nobody.

/// What a key has spent, over what it may spend.
///
/// Only the caps that exist. "0 of no cap" is not a sentence, and a
/// paid key has three of them — so a key with no caps at all says so
/// in one word rather than printing three lines of nothing.
String keyBudgetLine(OcrPoolKey k) {
  final parts = <String>[
    if (k.perMinute != null) '${k.spentMinute}/${k.perMinute} a minute',
    if (k.perDay != null) '${k.spentDay}/${k.perDay} a day',
    if (k.perMonth != null) '${k.spentMonth}/${k.perMonth} a month',
  ];
  return parts.isEmpty ? 'No cap' : parts.join(' · ');
}

const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// When a key may run, in the words somebody set it in.
///
/// Empty is ALWAYS and says so. A blank line here would read as a
/// setting that failed to load, and the difference between "any time"
/// and "nothing loaded" is the difference between leaving it alone and
/// going to look for a bug.
///
/// Sorted, because the database stores an array in whatever order the
/// chips were pressed and "22:00, 09:00" reads as a mistake.
String keyClockLine(OcrPoolKey k) {
  if (k.hours.isEmpty && k.weekdays.isEmpty && k.months.isEmpty) {
    return 'Any time';
  }
  return [
    if (k.hours.isNotEmpty)
      (k.hours.toList()..sort())
          .map((h) => '${h.toString().padLeft(2, '0')}:00')
          .join(', '),
    if (k.weekdays.isNotEmpty)
      (k.weekdays.toList()..sort()).map((d) => _dayNames[d - 1]).join(', '),
    if (k.months.isNotEmpty)
      (k.months.toList()..sort()).map((m) => _monthNames[m - 1]).join(', '),
  ].join(' · ');
}

/// Why a key cannot be saved as the form stands, or null when it can.
///
/// The key itself is required on a NEW one and optional on an existing
/// one, and that asymmetry is the whole point: a cap has to be
/// raiseable without retyping a secret nobody still has, because this
/// app cannot show anybody the secret it holds.
///
/// Pure and apart from the dialog so the rule can be read and asserted.
/// `save_ocr_key` refuses the same things and refuses them last; this
/// is the same refusal said where somebody is typing.
String? readerKeyProblem({
  required String label,
  required String apiKey,
  required bool isNew,
  String perMinute = '',
  String perDay = '',
  String perMonth = '',
}) {
  if (label.trim().isEmpty) return 'Give the key a name.';
  if (isNew && apiKey.trim().isEmpty) {
    return 'Paste the key. It cannot be read back afterwards.';
  }
  for (final (what, raw) in [
    ('a minute', perMinute),
    ('a day', perDay),
    ('a month', perMonth),
  ]) {
    final t = raw.trim();
    if (t.isEmpty) continue;
    final n = int.tryParse(t);
    if (n == null || n <= 0) {
      return 'A cap per $what is a whole number above nought, or blank '
          'for no cap.';
    }
  }
  return null;
}

/// The pool, with the buttons that change it.
///
/// No `Scaffold` and no floating button: this is drawn inside a card
/// on the Settings screen as well as on a console page of its own, and
/// a widget that needs a Scaffold around it can only be used in one of
/// those.
class OcrKeyPoolEditor extends ConsumerWidget {
  const OcrKeyPoolEditor({
    super.key,
    required this.provider,
    this.orgId,
    this.canEdit = true,
  });

  final String provider;

  /// Null is the platform's pool. A uuid is that company's own.
  final String? orgId;

  /// False draws the pool and offers nothing that changes it. A reader
  /// who may see what is configured is not always one who may change
  /// it, and the database refuses either way.
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (provider: provider, orgId: orgId);
    final pool = ref.watch(ocrKeyPoolProvider(args));

    return AsyncView<List<OcrPoolKey>>(
      value: pool,
      onRetry: () => ref.invalidate(ocrKeyPoolProvider(args)),
      skeleton: const CardRowsSkeleton(rows: 3, leading: false, lines: 2),
      builder: (keys) {
        final usable = keys.where((k) => k.isUsableNow).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (keys.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.md),
                child: Text(
                  orgId == null
                      ? 'No keys yet. A reader with an empty pool falls '
                          'back on the key in the function\u2019s '
                          'environment, and fails when there is none.'
                      : 'No keys yet. Scans run on the single key above, '
                          'or on the platform\u2019s if there is none.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.scheme.onSurfaceVariant,
                      ),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Text(
                  // The count that matters is how many could run RIGHT
                  // NOW, not how many exist. A pool of six with none
                  // usable is a stopped scanner.
                  usable == keys.length
                      ? '${keys.length} '
                          '${keys.length == 1 ? 'key' : 'keys'}, all usable'
                      : '$usable of ${keys.length} usable right now',
                  style: TextStyle(
                    fontSize: 12,
                    color: usable == 0
                        ? context.colors.danger
                        : context.scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final k in keys)
                _KeyRow(
                  provider: provider,
                  orgId: orgId,
                  poolKey: k,
                  canEdit: canEdit,
                ),
            ],
            if (canEdit) ...[
              const SizedBox(height: Space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const ValueKey('add-reader-key'),
                  onPressed: () => editKey(context, ref, provider, orgId, null),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add a key'),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Opens the editor for one key, and refreshes the pool it belongs to.
///
/// Free rather than a method, because three places open it and one of
/// them is the "Add" button above.
Future<void> editKey(
  BuildContext context,
  WidgetRef ref,
  String provider,
  String? orgId,
  OcrPoolKey? existing,
) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) =>
        _KeyDialog(provider: provider, orgId: orgId, existing: existing),
  );
  if (saved == true) {
    ref.invalidate(ocrKeyPoolProvider((provider: provider, orgId: orgId)));
  }
}

class _KeyRow extends ConsumerWidget {
  const _KeyRow({
    required this.provider,
    required this.orgId,
    required this.poolKey,
    required this.canEdit,
  });

  final String provider;
  final String? orgId;
  final OcrPoolKey poolKey;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stood = poolKey.standDownReason;

    return ListTile(
      key: ValueKey('reader-key-${poolKey.id}'),
      title: Row(
        children: [
          Flexible(
            child: Text(poolKey.label, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: Space.sm),
          // The only thing about the key itself that this screen has,
          // and all it needs: enough to match a row against Google's
          // own list, and no use to anybody who reads it over a
          // shoulder.
          Text(
            '…${poolKey.keyTail}',
            style: TextStyle(
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: context.scheme.onSurfaceVariant,
            ),
          ),
          if (stood != null) ...[
            const SizedBox(width: Space.sm),
            StatusChip(
              // A status the chip has no colour of its own for reads
              // neutral, which is right: none of the three is an error.
              stood == 'Switched off' ? 'draft' : 'pending',
              compact: true,
            ),
          ],
        ],
      ),
      subtitle: Text(
        [
          if (stood != null) stood,
          keyBudgetLine(poolKey),
          keyClockLine(poolKey),
          if (poolKey.lastUsedAt != null)
            'last used ${Fmt.dateTime(poolKey.lastUsedAt)}',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      isThreeLine: poolKey.lastError != null,
      trailing: !canEdit ? null : RowActions(
        menuKey: 'reader-key-menu-${poolKey.id}',
        actions: [
          RowAction(
            label: poolKey.isActive ? 'Switch it off' : 'Switch it on',
            actionKey: 'toggle-${poolKey.id}',
            onTap: () => _toggle(context, ref),
          ),
          RowAction(
            label: 'Change it',
            actionKey: 'edit-${poolKey.id}',
            onTap: () => _edit(context, ref),
          ),
          RowAction(
            label: 'Remove it',
            actionKey: 'remove-${poolKey.id}',
            onTap: () => _remove(context, ref),
          ),
        ],
      ),
      onTap: canEdit ? () => _edit(context, ref) : null,
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    await runWithFeedback(
      context,
      // Nothing but the switch. Every other argument is sent as it
      // stands, because `save_ocr_key` takes what it is given for the
      // caps and the clock -- omitting them would clear them.
      action: () => ref.read(ocrKeyPoolApiProvider).save(
            provider,
            orgId: orgId,
            id: poolKey.id,
            label: poolKey.label,
            perMinute: poolKey.perMinute,
            perDay: poolKey.perDay,
            perMonth: poolKey.perMonth,
            hours: poolKey.hours,
            weekdays: poolKey.weekdays,
            months: poolKey.months,
            isActive: !poolKey.isActive,
          ),
      successMessage: poolKey.isActive ? 'Switched off' : 'Switched on',
    );
    ref.invalidate(ocrKeyPoolProvider((provider: provider, orgId: orgId)));
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) =>
      editKey(context, ref, provider, orgId, poolKey);

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final go = await confirm(
      context,
      title: 'Remove ${poolKey.label}?',
      message: 'It is taken out of the pool for good. The key itself is '
          'not cancelled at the provider — do that in their console as '
          'well, or it stays live.',
      confirmLabel: 'Remove it',
      destructive: true,
    );
    if (!go || !context.mounted) return;
    await runWithFeedback(
      context,
      action: () =>
          ref.read(ocrKeyPoolApiProvider)
              .remove(provider, poolKey.id, orgId: orgId),
      successMessage: 'Removed',
    );
    ref.invalidate(ocrKeyPoolProvider((provider: provider, orgId: orgId)));
  }
}

/// Adding a key, or changing what one may spend.
class _KeyDialog extends ConsumerStatefulWidget {
  const _KeyDialog({
    required this.provider,
    required this.orgId,
    required this.existing,
  });

  final String provider;
  final String? orgId;
  final OcrPoolKey? existing;

  @override
  ConsumerState<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends ConsumerState<_KeyDialog> {
  late final _label =
      TextEditingController(text: widget.existing?.label ?? '');
  final _key = TextEditingController();
  late final _perMinute =
      TextEditingController(text: widget.existing?.perMinute?.toString() ?? '');
  late final _perDay =
      TextEditingController(text: widget.existing?.perDay?.toString() ?? '');
  late final _perMonth =
      TextEditingController(text: widget.existing?.perMonth?.toString() ?? '');

  late final Set<int> _hours = {...?widget.existing?.hours};
  late final Set<int> _weekdays = {...?widget.existing?.weekdays};
  late final Set<int> _months = {...?widget.existing?.months};
  late bool _active = widget.existing?.isActive ?? true;
  bool _saving = false;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    for (final c in [_label, _key, _perMinute, _perDay, _perMonth]) {
      c.dispose();
    }
    super.dispose();
  }

  String? get _problem => readerKeyProblem(
        label: _label.text,
        apiKey: _key.text,
        isNew: _isNew,
        perMinute: _perMinute.text,
        perDay: _perDay.text,
        perMonth: _perMonth.text,
      );

  Future<void> _save() async {
    if (_problem != null) return;
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(ocrKeyPoolApiProvider).save(
            widget.provider,
            orgId: widget.orgId,
            id: widget.existing?.id,
            label: _label.text.trim(),
            // Blank means "leave it alone" on an existing key, and the
            // function refuses a blank on a new one -- so nothing here
            // has to decide what an empty box means.
            apiKey: _key.text.trim().isEmpty ? null : _key.text.trim(),
            perMinute: int.tryParse(_perMinute.text.trim()),
            perDay: int.tryParse(_perDay.text.trim()),
            perMonth: int.tryParse(_perMonth.text.trim()),
            hours: _hours.toList()..sort(),
            weekdays: _weekdays.toList()..sort(),
            months: _months.toList()..sort(),
            isActive: _active,
          ),
      successMessage: _isNew ? 'Key added' : 'Saved',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;

    return AlertDialog(
      title: Text(_isNew ? 'Add a key' : widget.existing!.label),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('key-label'),
                controller: _label,
                enabled: !_saving,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Name it',
                  helperText: 'What this key is for. Two keys off one '
                      'account differ by that and nothing else.',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('key-secret'),
                controller: _key,
                enabled: !_saving,
                onChanged: (_) => setState(() {}),
                obscureText: true,
                decoration: InputDecoration(
                  labelText: _isNew ? 'The key' : 'Replace the key',
                  helperText: _isNew
                      ? 'It cannot be read back, here or anywhere else in '
                          'this app.'
                      : 'Leave blank to keep the key that is on file. '
                          'Ends …${widget.existing!.keyTail}.',
                ),
              ),

              const Divider(height: Space.xl),
              const SectionHeader(
                'What it may spend',
                subtitle: 'Blank is no cap. A free Google AI Studio key is '
                    'capped per minute and per day.',
              ),
              Row(children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('cap-minute'),
                    controller: _perMinute,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'A minute'),
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: TextField(
                    key: const ValueKey('cap-day'),
                    controller: _perDay,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'A day'),
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: TextField(
                    key: const ValueKey('cap-month'),
                    controller: _perMonth,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'A month'),
                  ),
                ),
              ]),
              const SizedBox(height: Space.xs),
              Text(
                // Said plainly, because the alternative belief is that
                // this reads Google's counter. It does not, and cannot.
                'Counted here, not at the provider. Google’s own day '
                'rolls over on Pacific time, so set these under what your '
                'account actually allows rather than equal to it.',
                style: TextStyle(
                  fontSize: 12,
                  color: context.scheme.onSurfaceVariant,
                ),
              ),

              const Divider(height: Space.xl),
              const SectionHeader(
                'When it may run',
                subtitle: 'Nothing chosen means any time, which is what '
                    'most keys want. Malaysian time.',
              ),
              _Chips(
                label: 'Hours',
                selected: _hours,
                enabled: !_saving,
                values: [for (var h = 0; h < 24; h++) h],
                nameOf: (h) => h.toString().padLeft(2, '0'),
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: Space.sm),
              _Chips(
                label: 'Days',
                selected: _weekdays,
                enabled: !_saving,
                values: const [1, 2, 3, 4, 5, 6, 7],
                nameOf: (d) => const [
                  'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
                ][d - 1],
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: Space.sm),
              _Chips(
                label: 'Months',
                selected: _months,
                enabled: !_saving,
                values: const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
                nameOf: (m) => const [
                  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
                ][m - 1],
                onChanged: () => setState(() {}),
              ),

              const Divider(height: Space.xl),
              SwitchListTile(
                key: const ValueKey('key-active'),
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: _saving ? null : (v) => setState(() => _active = v),
                title: const Text('In the pool'),
                subtitle: const Text(
                  'Off keeps the key and stops it being handed out.',
                ),
              ),

              if (widget.existing?.lastError != null) ...[
                const SizedBox(height: Space.sm),
                Text(
                  'Last refused: ${widget.existing!.lastError}',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.colors.danger,
                  ),
                ),
              ],
              if (problem != null) ...[
                const SizedBox(height: Space.md),
                Text(
                  problem,
                  style: TextStyle(color: context.colors.danger),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('key-save'),
          onPressed: _saving || problem != null ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isNew ? 'Add it' : 'Save'),
        ),
      ],
    );
  }
}

/// A row of chips that is a SET, not a choice.
///
/// Nothing selected means always rather than never, so there is no
/// "all" chip to press: pressing every hour and pressing none would
/// then be two ways of saying one thing, and the second is the one the
/// database stores.
class _Chips extends StatelessWidget {
  const _Chips({
    required this.label,
    required this.selected,
    required this.values,
    required this.nameOf,
    required this.onChanged,
    required this.enabled,
  });

  final String label;
  final Set<int> selected;
  final List<int> values;
  final String Function(int) nameOf;
  final VoidCallback onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          selected.isEmpty ? '$label — any' : label,
          style: TextStyle(
            fontSize: 12,
            color: context.scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Space.xs),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final v in values)
              FilterChip(
                key: ValueKey('${label.toLowerCase()}-$v'),
                label: Text(nameOf(v)),
                visualDensity: VisualDensity.compact,
                selected: selected.contains(v),
                onSelected: !enabled
                    ? null
                    : (on) {
                        on ? selected.add(v) : selected.remove(v);
                        onChanged();
                      },
              ),
          ],
        ),
      ],
    );
  }
}
