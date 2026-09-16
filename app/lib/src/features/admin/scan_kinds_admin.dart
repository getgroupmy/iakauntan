import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_live.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/scan_kinds_repository.dart';

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
              DropdownButtonFormField<String?>(
                key: const ValueKey('scan-kind-destination'),
                isExpanded: true,
                value: _destination,
                decoration: const InputDecoration(
                  labelText: 'Where it goes',
                  helperText:
                      'Filed only means the paper is kept and the form is '
                      'typed in.',
                ),
                items: [
                  for (final d in scanKindDestinations)
                    DropdownMenuItem(value: d.$1, child: Text(d.$2)),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _destination = v),
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
