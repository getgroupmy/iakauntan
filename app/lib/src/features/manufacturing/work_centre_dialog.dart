import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Where a step happens, and what an hour of it costs.
///
/// One rate rather than a labour rate and an overhead rate, because a
/// company that cannot split them still has to cost its output, and one
/// honest number beats two invented ones. Splitting it later is an
/// addition, not a correction.
class WorkCentreDialog extends ConsumerStatefulWidget {
  const WorkCentreDialog({super.key, this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<WorkCentreDialog> createState() => _WorkCentreDialogState();
}

class _WorkCentreDialogState extends ConsumerState<WorkCentreDialog> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _rate = TextEditingController(text: '0');
  final _hours = TextEditingController(text: '8');
  bool _saving = false;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final w = widget.existing;
    if (w != null) {
      _code.text = w['code']?.toString() ?? '';
      _name.text = w['name']?.toString() ?? '';
      _rate.text = Fmt.toDouble(w['cost_per_hour']).toString();
      _hours.text = Fmt.toDouble(w['capacity_hours_per_day']).toString();
    }
  }

  @override
  void dispose() {
    for (final c in [_code, _name, _rate, _hours]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid =>
      _code.text.trim().isNotEmpty &&
      _name.text.trim().isNotEmpty &&
      (double.tryParse(_hours.text.trim()) ?? 0) > 0;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isNew ? 'New work centre' : 'Edit ${_code.text}'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 120,
                  child: TextField(
                    key: const ValueKey('wc-code'),
                    controller: _code,
                    enabled: !_saving,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Code'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('wc-name'),
                    controller: _name,
                    enabled: !_saving,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('wc-rate'),
                    controller: _rate,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Cost an hour',
                      prefixText: 'RM ',
                      helperText: 'Labour and overhead together',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _hours,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Hours a day',
                      helperText: 'What it can do',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            // Said plainly rather than discovered later: the capacity is
            // recorded but nothing schedules against it yet, so a work
            // centre can be promised to two orders at once.
            const Text(
              'The rate is what an order absorbs for each hour booked '
              'here. The capacity is recorded but nothing plans against '
              'it yet — two orders can be given the same day and nothing '
              'will say so.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        if (!_isNew)
          TextButton(
            onPressed: _saving ? null : _retire,
            child: Text(
              'Close it',
              style: TextStyle(color: context.colors.danger),
            ),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid && !_saving ? _save : null,
          child: Text(_isNew ? 'Add' : 'Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveWorkCentre(
            id: widget.existing?['id'] as String?,
            code: _code.text.trim().toUpperCase(),
            name: _name.text.trim(),
            costPerHour: double.tryParse(_rate.text.trim()) ?? 0,
            capacityHoursPerDay: double.tryParse(_hours.text.trim()) ?? 8,
          ),
      successMessage: _isNew ? 'Work centre added' : 'Work centre saved',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _retire() async {
    final sure = await confirm(
      context,
      title: 'Close ${_code.text}?',
      message:
          'It stops being offered on new recipes. Orders already '
          'costed against it keep their figures, so last quarter still '
          'explains itself.',
      confirmLabel: 'Close',
      destructive: true,
    );
    if (!sure || !mounted) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .retireWorkCentre(widget.existing!['id'] as String),
      successMessage: 'Work centre closed',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }
}
