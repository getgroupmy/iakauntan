import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// How much leave a length of service earns.
///
/// `leave_entitlement_bands` has been in the schema since the HR module
/// landed, empty and unreachable, so every leave type fell back to its
/// flat `default_days` regardless of how long somebody had worked
/// here — which is below the statutory minimum for anyone past two
/// years of service.
Future<void> showLeaveBands(
    BuildContext context, Map<String, dynamic> leaveType) {
  return showDialog<void>(
    context: context,
    builder: (_) => _LeaveBandsDialog(leaveType: leaveType),
  );
}

class _LeaveBandsDialog extends ConsumerStatefulWidget {
  const _LeaveBandsDialog({required this.leaveType});

  final Map<String, dynamic> leaveType;

  @override
  ConsumerState<_LeaveBandsDialog> createState() => _LeaveBandsDialogState();
}

class _LeaveBandsDialogState extends ConsumerState<_LeaveBandsDialog> {
  bool _busy = false;

  String get _typeId => widget.leaveType['id'] as String;

  @override
  Widget build(BuildContext context) {
    final bands = ref.watch(leaveBandsProvider(_typeId));
    final scales = widget.leaveType['scales_with_service'] == true;

    return AlertDialog(
      title: Text('${widget.leaveType['name']} · entitlement'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Bands replace the flat "days a year" figure for anyone '
                'whose service reaches them. With none entered, everybody '
                'gets '
                '${Fmt.days(Fmt.toDouble(widget.leaveType['default_days']))} '
                'days no matter how long they have been here.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (!scales)
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(
                    'This leave type does not scale with service yet. '
                    'Applying a preset turns that on; adding a band by hand '
                    'does not.',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colors.warning,
                    ),
                  ),
                ),
              const SizedBox(height: Space.md),
              AsyncView(
                value: bands,
                onRetry: () => ref.invalidate(leaveBandsProvider(_typeId)),
                skeleton: const ListSkeleton(rows: 3, leading: false),
                builder: (list) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (list.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: Space.lg),
                        child: Text('No bands — the flat figure applies.'),
                      )
                    else
                      for (final b in list) _BandRow(
                        band: b,
                        onEdit: () => _edit(b),
                        onDelete: () => _delete(b),
                      ),
                  ],
                ),
              ),
              const Divider(height: Space.xl),
              // The presets are the Employment Act floors. Naming the
              // section rather than the numbers means somebody can check
              // them against the Act instead of against this screen.
              Text('Employment Act 1955 minimums',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Space.xs),
              const Text(
                'Applying one replaces every band below. A company may '
                'grant more than the Act requires and many do.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: Space.sm),
              Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _applyPreset('annual'),
                  child: const Text('Annual — 8 / 12 / 16 days (s.60E)'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _applyPreset('sick'),
                  child: const Text('Sick — 14 / 18 / 22 days (s.60F)'),
                ),
              ]),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _edit(null),
          child: const Text('Add band'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _applyPreset(String preset) async {
    final ok = await confirm(
      context,
      title: 'Apply the Act minimums?',
      message: 'Every band on this leave type is replaced, and the type is '
          'set to scale with service.',
      confirmLabel: 'Apply',
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.applyStatutoryLeaveBands(_typeId, preset),
      successMessage: 'Bands applied',
    );
    if (mounted) setState(() => _busy = false);
    ref.invalidate(leaveBandsProvider(_typeId));
    ref.invalidate(setupRowsProvider((table: 'leave_types', orderBy: 'name')));
  }

  Future<void> _edit(Map<String, dynamic>? band) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _BandDialog(leaveTypeId: _typeId, band: band),
    );
    if (saved == true) ref.invalidate(leaveBandsProvider(_typeId));
  }

  Future<void> _delete(Map<String, dynamic> band) async {
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .deleteSetupRow('leave_entitlement_bands', band['id'] as String),
      successMessage: 'Band removed',
    );
    ref.invalidate(leaveBandsProvider(_typeId));
  }
}

class _BandRow extends StatelessWidget {
  const _BandRow({
    required this.band,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, dynamic> band;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final from = Fmt.toInt(band['service_years_from']);
    final to = band['service_years_to'];

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: onEdit,
      title: Text(to == null
          ? '$from years and over'
          : '$from to ${Fmt.toInt(to)} years'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('${Fmt.days(Fmt.toDouble(band['days']))} days',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          onPressed: onDelete,
        ),
      ]),
    );
  }
}

class _BandDialog extends ConsumerStatefulWidget {
  const _BandDialog({required this.leaveTypeId, this.band});

  final String leaveTypeId;
  final Map<String, dynamic>? band;

  @override
  ConsumerState<_BandDialog> createState() => _BandDialogState();
}

class _BandDialogState extends ConsumerState<_BandDialog> {
  late final _from = TextEditingController(
      text: widget.band?['service_years_from']?.toString() ?? '0');
  late final _to =
      TextEditingController(text: widget.band?['service_years_to']?.toString() ?? '');
  late final _days =
      TextEditingController(text: widget.band?['days']?.toString() ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    _days.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.band == null ? 'Add band' : 'Edit band'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _from,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'From, years of service *',
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _to,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'To, years of service',
                helperText: 'Leave empty for the top band',
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _days,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Days a year *'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final from = int.tryParse(_from.text.trim());
    final to = _to.text.trim().isEmpty ? null : int.tryParse(_to.text.trim());
    final days = double.tryParse(_days.text.trim());

    final problem = from == null
        ? 'Enter the year the band starts from.'
        : days == null || days < 0
            ? 'Enter the number of days.'
            : (to != null && to < from)
                ? 'A band cannot end before it starts.'
                : null;
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
      return;
    }

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveLeaveBand(
            {
              'leave_type_id': widget.leaveTypeId,
              'service_years_from': from,
              'service_years_to': to,
              'days': days,
            },
            id: widget.band?['id'] as String?,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}
