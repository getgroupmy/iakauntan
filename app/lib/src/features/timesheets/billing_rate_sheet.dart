import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../secretarial/person_editor.dart' show StatutoryDateField;

/// What a rate row applies to.
///
/// `0164` puts it plainly: a null project means "this person's default
/// rate", and a row with a project is that person's rate on that
/// project only. Two partial unique indexes rather than one over a
/// nullable column, because in Postgres nulls are distinct and the
/// single index would take the same default rate twice.
String rateScope(String? projectId) =>
    projectId == null ? 'Default rate' : 'On one project';

/// Which rate is in force on a day.
///
/// The most specific row that has taken effect: a project rate beats
/// the person's default, and a later effective date beats an earlier
/// one. Rates are added and never edited -- an invoice raised in March
/// stays raised at March's rate -- so choosing between them is
/// something that has to happen at the point of use.
Map<String, dynamic>? rateInForce(
  Iterable<Map<String, dynamic>> rates,
  String userId,
  DateTime on, {
  String? projectId,
}) {
  final day = DateTime(on.year, on.month, on.day);
  Map<String, dynamic>? best;

  for (final r in rates) {
    if (r['user_id'] != userId) continue;
    final rowProject = r['project_id'] as String?;
    // A rate for a different project says nothing about this one.
    if (rowProject != null && rowProject != projectId) continue;

    final from = DateTime.parse(r['effective_from'] as String);
    if (from.isAfter(day)) continue;

    if (best == null) {
      best = r;
      continue;
    }

    final bestProject = best['project_id'] as String?;
    // A project rate always beats the default, whatever the dates.
    if (rowProject != null && bestProject == null) {
      best = r;
      continue;
    }
    if (rowProject == null && bestProject != null) continue;

    final bestFrom = DateTime.parse(best['effective_from'] as String);
    if (from.isAfter(bestFrom)) best = r;
  }
  return best;
}

double? hourlyRateOf(String text) {
  final v = double.tryParse(text.trim().replaceAll(',', ''));
  if (v == null || v < 0) return null;
  return v;
}

/// What a rate row is, given what was entered.
Map<String, dynamic> billingRateValues({
  required String userId,
  required DateTime effectiveFrom,
  required double hourlyRate,
  String? projectId,
  String? notes,
}) {
  final trimmedNotes = notes?.trim();
  return <String, dynamic>{
    'user_id': userId,
    // Null is meaningful here, not missing: it is what makes the row
    // the person's default rather than a rate on one project.
    'project_id': projectId,
    'effective_from': Fmt.iso(effectiveFrom),
    'hourly_rate': hourlyRate,
    'notes':
        (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
  };
}

/// Record a rate.
Future<bool> showBillingRateSheet(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => const _RateSheet(),
    ) ??
    false;

class _RateSheet extends ConsumerStatefulWidget {
  const _RateSheet();

  @override
  ConsumerState<_RateSheet> createState() => _RateSheetState();
}

class _RateSheetState extends ConsumerState<_RateSheet> {
  final _formKey = GlobalKey<FormState>();
  final _rate = TextEditingController();
  final _notes = TextEditingController();

  String? _userId;
  String? _projectId;
  DateTime? _from;
  bool _saving = false;

  @override
  void dispose() {
    _rate.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final rate = hourlyRateOf(_rate.text);
    if (rate == null || _userId == null || _from == null) return;

    setState(() => _saving = true);
    final values = billingRateValues(
      userId: _userId!,
      effectiveFrom: _from!,
      hourlyRate: rate,
      projectId: _projectId,
      notes: _notes.text,
    );

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.addBillingRate(values),
      successMessage: 'Recorded',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(billingRatesProvider);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final team = ref.watch(teamProvider).valueOrNull ?? const [];
    final projects = ref.watch(projectsProvider).valueOrNull ?? const [];

    return AlertDialog(
      title: const Text('Record a rate'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'A rate is added and never edited. An invoice raised in '
                  "March stays raised at March's rate however many times it "
                  'is reprinted.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Space.md),
                DropdownButtonFormField<String>(
                  key: const ValueKey('rate-person'),
                  value: _userId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Person'),
                  items: [
                    // Only somebody who has accepted has a user_id to
                    // hang a rate on.
                    for (final m in team.where((m) => m.userId != null))
                      DropdownMenuItem(
                        value: m.userId,
                        child: Text(
                          m.fullName ?? m.email ?? '—',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _saving ? null : (v) => setState(() => _userId = v),
                  validator: (v) => v == null ? 'Required' : null,
                ),
                const SizedBox(height: Space.md),
                DropdownButtonFormField<String?>(
                  key: const ValueKey('rate-project'),
                  value: _projectId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Applies to',
                    helperText: 'Leave as the default unless this person '
                        'charges differently on one project.',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Every project — the default rate'),
                    ),
                    for (final p in projects)
                      DropdownMenuItem<String?>(
                        value: p['id'] as String?,
                        child: Text(
                          '${p['code']} · ${p['name']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged:
                      _saving ? null : (v) => setState(() => _projectId = v),
                ),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: StatutoryDateField(
                      label: 'Effective from',
                      value: _from,
                      enabled: !_saving,
                      onChanged: (d) => setState(() => _from = d),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('rate-hourly'),
                      controller: _rate,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Hourly rate'),
                      validator: (v) =>
                          hourlyRateOf(v ?? '') == null ? 'An amount' : null,
                    ),
                  ),
                ]),
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _notes,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('rate-save'),
          onPressed: _saving || _from == null ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Record'),
        ),
      ],
    );
  }
}
