import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_live.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/scan_kinds_repository.dart';
import '../../data/scan_targets_repository.dart';

/// What a scanned paper can be recognised as, from the operator's side.
///
/// `0614`. The list is a table rather than an enum so that this page
/// can exist — the same reason `0605` gave the kinds of business one
/// and `0606` gave the registers one.
///
/// ## What this page does NOT control
///
/// It does not classify. Nothing typed here teaches the reader to
/// recognise anything: the rules that CHOOSE between these rows are
/// string matching against letterheads, they live in
/// `features/shared/document_classifier.dart`, and they change every
/// time a bank rewords its statement. What this page holds is the list
/// and what each kind is FOR.
///
/// So a kind added here is a kind a person can pick by hand. It will
/// not be suggested until somebody writes the words to look for, and
/// the note on the page says so — an administrator who adds "Payslip"
/// and waits for payslips to start recognising themselves has been
/// misled by a screen, which is worse than not having the screen.
class ScanKindsAdminTab extends ConsumerWidget {
  const ScanKindsAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kinds = ref.watch(allScanKindsProvider);

    return AsyncView(
      value: kinds,
      onRetry: () => ref.invalidate(allScanKindsProvider),
      skeleton: const ListSkeleton(rows: 6, trailing: false),
      builder: (rows) => SingleChildScrollView(
        child: PageBody(
          maxWidth: 900,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(
                        'What AI SmartScan can recognise',
                        subtitle:
                            'Offered when a scan comes back. Lower order '
                            'comes first.',
                        action: FilledButton.tonalIcon(
                          key: const ValueKey('scan-kind-add'),
                          onPressed: () => _edit(context, ref, null),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add a kind'),
                        ),
                      ),
                      if (rows.isEmpty)
                        const Text('Nothing on the list yet.')
                      else
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _KindRow(
                            kind: rows[i],
                            onTap: () => _edit(context, ref, rows[i]),
                          ),
                        ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.lg),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        'Adding a kind does not teach the reader',
                        subtitle: 'What this list is and what it is not',
                      ),
                      Text(
                        'A kind added here is a kind a person can pick by '
                        'hand when a scan comes back. It will not be '
                        'suggested on its own: the words that recognise a '
                        'bank statement or a delivery order are in the app, '
                        'because they change with every letterhead, and '
                        'they are written for the kinds this shipped with.\n\n'
                        'So add a kind when somebody is sorting that paper '
                        'and wants somewhere to file it. Ask for the '
                        'recognition separately.',
                        key: const ValueKey('scan-kind-note'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.xxl),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    ScanKind? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ScanKindDialog(existing: existing),
    );
    if (saved == true) {
      ref.invalidate(allScanKindsProvider);
      invalidatePlatformTable(ref, 'scan_document_kinds');
    }
  }
}

class _KindRow extends StatelessWidget {
  const _KindRow({required this.kind, required this.onTap});

  final ScanKind kind;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: SizedBox(
        width: 44,
        child: Text('${kind.sortOrder}', style: muted),
      ),
      // A Wrap, for the reason `entity_types_admin.dart` uses one: a
      // long name beside two chips is wider than a 360px phone, and a
      // Row would put the last of them off the right edge.
      title: Wrap(
        spacing: Space.sm,
        runSpacing: Space.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(kind.label),
          if (!kind.isActive) const StatusChip('off', compact: true),
        ],
      ),
      // Where it goes, in the words the dialog offers rather than the
      // value stored. `bank_import` is what the row says; "the bank
      // reconciliation screen" is what it means.
      subtitle: Text(
        '${kind.code} · ${scanKindDestinationLabel(kind.destination)}'
        '${kind.isBuiltin ? ' · built in' : ''}',
        style: muted,
      ),
    );
  }
}

/// Why a kind cannot be saved, in the words to show — or null.
///
/// Public and pure. The code is written onto every scan filed as this
/// kind, so it is checked here as well as in the function: a refusal
/// that arrives as a constraint name is a refusal nobody can act on.
String? scanKindProblem({
  required String code,
  required String label,
  required bool isNew,
}) {
  if (label.trim().isEmpty) return 'A kind of document needs a name.';
  if (!isNew) return null;
  final c = code.trim();
  if (c.isEmpty) return 'A kind of document needs a code.';
  if (!RegExp(r'^[a-z][a-z0-9_]{1,40}$').hasMatch(c)) {
    return 'A code is lower-case letters, digits and underscores, '
        'starting with a letter — for example credit_note.';
  }
  return null;
}

class _ScanKindDialog extends ConsumerStatefulWidget {
  const _ScanKindDialog({required this.existing});

  final ScanKind? existing;

  @override
  ConsumerState<_ScanKindDialog> createState() => _ScanKindDialogState();
}

class _ScanKindDialogState extends ConsumerState<_ScanKindDialog> {
  late final _code = TextEditingController(text: widget.existing?.code ?? '');
  late final _label = TextEditingController(text: widget.existing?.label ?? '');
  late final _labelMy = TextEditingController(
    text: widget.existing?.labelMy ?? '',
  );
  late final _hint = TextEditingController(text: widget.existing?.hint ?? '');
  late final _order = TextEditingController(
    text: '${widget.existing?.sortOrder ?? 100}',
  );
  late String? _destination = widget.existing?.destination;
  // The target, as `module.action`. Null for a kind that is filed and
  // nothing else, which is three of the ones this shipped with.
  late String? _target = widget.existing?.targetKey;
  late bool _active = widget.existing?.isActive ?? true;
  bool _busy = false;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    _code.dispose();
    _label.dispose();
    _labelMy.dispose();
    _hint.dispose();
    _order.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final problem = scanKindProblem(
      code: _code.text,
      label: _label.text,
      isNew: _isNew,
    );
    if (problem != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    // An unreadable order is a typo, not "leave it". Saying "Saved"
    // while keeping the old number is how a list stops matching what
    // somebody is looking at.
    final order = int.tryParse(_order.text.trim());
    if (_order.text.trim().isNotEmpty && order == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The order has to be a whole number.')),
      );
      return;
    }

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => ref
          .read(scanKindsRepoProvider)
          .save(
            code: _isNew ? _code.text.trim() : widget.existing!.code,
            label: _label.text.trim(),
            labelMy: _labelMy.text.trim(),
            destination: _destination ?? '',
            hint: _hint.text.trim(),
            sortOrder: order,
            isActive: _active,
          ),
    );
    if (!mounted) return;

    // The target is a second call, and it goes SECOND. `0681` put it
    // in its own function rather than widening the seven-argument
    // `platform_save_scan_kind`, and the kind has to exist before it
    // can be pointed anywhere — which for a new kind means after the
    // save above.
    if (ok) {
      final parts = _target?.split('.');
      await runWithFeedback(
        context,
        successMessage: null,
        action: () => ref
            .read(scanTargetsRepoProvider)
            .setKindTarget(
              _isNew ? _code.text.trim() : widget.existing!.code,
              parts?.first,
              parts?.last,
            ),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: 'Remove ${widget.existing!.label}?',
      message:
          'Only a kind nothing is filed as can be removed. If any scan '
          'is, switch it off instead — a scan filed under a kind stays '
          'filed under it.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    final done = await runWithFeedback(
      context,
      successMessage: 'Removed',
      action: () =>
          ref.read(scanKindsRepoProvider).remove(widget.existing!.code),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (done) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant);

    return AlertDialog(
      title: Text(_isNew ? 'Add a kind of document' : 'Edit the kind'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('scan-kind-code'),
                controller: _code,
                // The code is written onto every scan filed as this
                // kind, so it is fixed once set.
                enabled: _isNew && !_busy,
                decoration: InputDecoration(
                  labelText: 'Code',
                  helperText: _isNew
                      ? 'Lower case, no spaces. Cannot be changed later.'
                      : 'Set when the kind was added and fixed since.',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('scan-kind-label'),
                controller: _label,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'What it is called on the scan result.',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _labelMy,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Name in Malay',
                  helperText:
                      'Optional. The English name is used when there is '
                      'none.',
                ),
              ),
              const SizedBox(height: Space.md),
              // Module, then action, then the fields that record has.
              // `0681`. The old free-text "Where it goes" named a
              // SCREEN and nothing more, so the reader was asked the
              // same eleven questions about every document ever
              // scanned; these name the RECORD, which is what lets the
              // list below exist at all.
              ScanKindTargetPicker(
                value: _target,
                enabled: !_busy,
                onChanged: (v) => setState(() {
                  _target = v;
                  // `destination` follows the target by trigger in the
                  // database. Cleared here so the dialog does not go on
                  // showing the screen the old target opened while the
                  // new one is selected — the save is what makes it
                  // true, and showing a stale answer in between is how
                  // somebody saves the wrong thing twice.
                  if (v != null) _destination = null;
                }),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('scan-kind-hint'),
                controller: _hint,
                enabled: !_busy,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'What happens if it is accepted',
                  helperText:
                      'One line, under the name. Somebody is about to '
                      'press a button and this says what it does.',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('scan-kind-order'),
                controller: _order,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Order',
                  helperText: 'Lower comes first.',
                ),
              ),
              const Divider(height: Space.xl),
              SwitchListTile(
                key: const ValueKey('scan-kind-active'),
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: _busy ? null : (v) => setState(() => _active = v),
                title: const Text('On'),
                subtitle: Text(
                  'Off takes it out of the scan result. Anything already '
                  'filed as it stays filed as it.',
                  style: muted,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (!_isNew && !widget.existing!.isBuiltin)
          TextButton(
            key: const ValueKey('scan-kind-delete'),
            onPressed: _busy ? null : _delete,
            child: Text(
              'Remove',
              style: TextStyle(color: context.colors.danger),
            ),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('scan-kind-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Which module a scanned paper goes into, which action it becomes,
/// and what that record has room for.
///
/// `0681`. Three controls, and the third is the one that was missing:
/// until now a kind named a SCREEN in free text, so every document ever
/// scanned was asked the same eleven questions out of one hard-coded
/// schema in the edge function — whether it was a bill, a bank
/// statement or a name card.
///
/// ## The fields are discovered, not typed
///
/// They are the real columns of the table the action writes, read out
/// of `information_schema` at the moment this opens. A list somebody
/// typed goes stale the first time a column is renamed, goes stale
/// silently, and the symptom is a reader being asked for a field that
/// no longer exists and a bookkeeper wondering why one box never fills
/// in. What is stored is the TICK.
///
/// ## They belong to the target, not to the kind
///
/// A delivery order and a supplier's bill both land in purchasing.
/// Configuring the same columns twice is two lists that disagree by
/// Thursday, so the checklist says whose it is — an edit here reaches
/// every kind pointing at the same place.
class ScanKindTargetPicker extends ConsumerWidget {
  const ScanKindTargetPicker({
    super.key,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  /// `module.action`, or null for filed-and-nothing-else.
  final String? value;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targets = ref.watch(scanTargetsProvider);

    return AsyncView<List<ScanTarget>>(
      value: targets,
      onRetry: () => ref.invalidate(scanTargetsProvider),
      skeleton: const CardRowsSkeleton(rows: 2, leading: false),
      builder: (all) {
        final modules = <String, String>{};
        for (final t in all) {
          modules[t.module] = t.moduleName ?? t.module;
        }
        final chosen = all.where((t) => t.key == value).firstOrNull;
        // The module comes off the chosen target rather than being held
        // separately: one source of truth, and re-opening the dialog
        // shows what is stored without a second field to keep in step.
        final module = chosen?.module;
        final forModule =
            all.where((t) => t.module == module).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String?>(
              key: const ValueKey('scan-kind-module'),
              isExpanded: true,
              initialValue: module,
              decoration: const InputDecoration(
                labelText: 'Which module it goes into',
                helperText:
                    'Nothing means the paper is filed and the form is '
                    'typed in by hand.',
              ),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('Filed only — nothing is created'),
                ),
                for (final e in modules.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: enabled
                  ? (m) {
                      if (m == null) {
                        onChanged(null);
                        return;
                      }
                      // Straight to the module's first action rather
                      // than leaving the second dropdown empty: every
                      // module here has at least one, and an empty
                      // required field somebody has to notice is a
                      // save that fails for no visible reason.
                      final first =
                          all.where((t) => t.module == m).firstOrNull;
                      onChanged(first?.key);
                    }
                  : null,
            ),
            if (module != null && forModule.length > 1) ...[
              const SizedBox(height: Space.md),
              DropdownButtonFormField<String>(
                key: const ValueKey('scan-kind-action'),
                isExpanded: true,
                initialValue: value,
                decoration: const InputDecoration(
                  labelText: 'What it becomes',
                ),
                items: [
                  for (final t in forModule)
                    DropdownMenuItem(value: t.key, child: Text(t.label)),
                ],
                onChanged: enabled ? onChanged : null,
              ),
            ],
            if (chosen != null) ...[
              if (chosen.hint != null) ...[
                const SizedBox(height: Space.sm),
                Text(
                  chosen.hint!,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: Space.lg),
              _TargetFields(target: chosen),
            ],
          ],
        );
      },
    );
  }
}

/// The columns that record has, and which of them the reader is asked
/// to fill.
class _TargetFields extends ConsumerStatefulWidget {
  const _TargetFields({required this.target});

  final ScanTarget target;

  @override
  ConsumerState<_TargetFields> createState() => _TargetFieldsState();
}

class _TargetFieldsState extends ConsumerState<_TargetFields> {
  /// The edits made since this opened, by column name. Held here rather
  /// than written on every tick: a checklist that saved on each tap
  /// would be a round trip per box and a half-configured target the
  /// moment somebody closed the dialog mid-thought.
  final _edited = <String, ScanTargetColumn>{};
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final args = (module: widget.target.module, action: widget.target.action);
    final columns = ref.watch(scanTargetColumnsProvider(args));

    return AsyncView<List<ScanTargetColumn>>(
      value: columns,
      onRetry: () => ref.invalidate(scanTargetColumnsProvider(args)),
      skeleton: const ListSkeleton(rows: 5, trailing: false),
      builder: (discovered) {
        final rows = [
          for (final c in discovered) _edited[c.name] ?? c,
        ];
        final asked = rows.where((c) => c.isAsked).toList();
        final gone = rows.where((c) => !c.stillThere).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'What the reader is asked to fill in',
              subtitle:
                  'The real columns of ${widget.target.tableName}, read '
                  'from the database just now. Ticked ones go to the AI '
                  'with the document. Shared by every kind that lands '
                  'here.',
            ),
            if (asked.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  'Nothing is ticked, so this destination is not offered '
                  'to the reader at all — a choice it could make and then '
                  'have nothing to fill is worse than not offering it.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.colors.warning,
                  ),
                ),
              ),
            // Said before the list rather than after: a column that was
            // ticked and has since been dropped is shown rather than
            // quietly removed, so somebody sees what happened instead
            // of wondering where the configuration went.
            if (gone.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  '${gone.map((c) => c.name).join(', ')} '
                  '${gone.length == 1 ? 'is' : 'are'} ticked and no longer '
                  'in the table. Untick to stop asking for '
                  '${gone.length == 1 ? 'it' : 'them'}.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.colors.danger,
                  ),
                ),
              ),
            const SizedBox(height: Space.sm),
            for (final c in rows) _FieldRow(
              column: c,
              enabled: !_busy,
              onChanged: (next) => setState(() => _edited[c.name] = next),
            ),
            const SizedBox(height: Space.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                key: const ValueKey('scan-kind-save-fields'),
                onPressed: _busy || _edited.isEmpty
                    ? null
                    : () => _save(rows.where((c) => c.isAsked).toList()),
                child: const Text('Save the fields'),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _save(List<ScanTargetColumn> asked) async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      doing: 'saving what the reader is asked for',
      successMessage: 'The reader will be asked for these',
      action: () => ref
          .read(scanTargetsRepoProvider)
          .saveFields(widget.target.module, widget.target.action, asked),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _edited.clear();
    });
    if (ok) {
      ref.invalidate(
        scanTargetColumnsProvider(
          (module: widget.target.module, action: widget.target.action),
        ),
      );
    }
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.column,
    required this.enabled,
    required this.onChanged,
  });

  final ScanTargetColumn column;
  final bool enabled;
  final ValueChanged<ScanTargetColumn> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          key: ValueKey('scan-field-${column.name}'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          value: column.isAsked,
          onChanged: enabled
              ? (v) => onChanged(column.copyWith(isAsked: v ?? false))
              : null,
          title: Wrap(
            spacing: Space.sm,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(column.name),
              Text(
                column.dataType,
                style: TextStyle(
                  fontSize: 11,
                  color: context.scheme.onSurfaceVariant,
                ),
              ),
              if (column.isRequired)
                const StatusChip('required', compact: true),
              // Marked rather than hidden. A foreign key cannot be read
              // off a page — what is printed is a name, not a uuid —
              // and it is still the honest place to hang "the supplier
              // as printed, which will be matched to a contact".
              if (column.isForeign)
                const StatusChip('matched by name', compact: true),
              if (!column.stillThere)
                const StatusChip('no longer a column', compact: true),
            ],
          ),
        ),
        // The sentence the field is asked with. Only for the ticked
        // ones: a box under every column of a wide table is a form
        // nobody reads, and the question only matters once somebody
        // has decided to ask it.
        if (column.isAsked)
          Padding(
            padding: const EdgeInsets.only(left: 40, bottom: Space.sm),
            child: TextFormField(
              key: ValueKey('scan-field-why-${column.name}'),
              initialValue: column.description ?? '',
              enabled: enabled,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'How to ask for it',
                helperText:
                    'Without this the reader is handed a column name and '
                    'answers from the name alone.',
              ),
              onChanged: (v) => onChanged(
                column.copyWith(description: v.trim()),
              ),
            ),
          ),
      ],
    );
  }
}
