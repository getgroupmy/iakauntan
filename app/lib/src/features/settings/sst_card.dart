import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
// For the `RepoOrgLogo` extension, which is where the company-level
// writes live.
import '../../data/repository.dart';

/// Registering the company for SST, which is four facts and not a
/// switch.
///
/// It used to be a switch on the company form, and that switch did
/// almost nothing: it stored a boolean read by one line of this file and
/// by nothing in the ledger, the document editor, the invoice PDF or the
/// e-Invoice path. A company that registered went on defaulting every
/// invoice line to 0% — which is the state one company in this database
/// was actually in, its taxed invoices each corrected by hand.
///
/// So it is its own card, and it takes all four together:
///
///   * that the company is registered,
///   * the registration number, which prints on every tax invoice,
///   * the date it took effect, and
///   * the tax code new lines should default to.
///
/// The database refuses any three of them.
class SstCard extends ConsumerWidget {
  const SstCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final org = ref.watch(currentOrgProvider).valueOrNull;
    final canAdmin = ref.watch(canAdminProvider);
    if (org == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Sales and service tax',
              subtitle: 'What new invoice lines are taxed at',
            ),
            if (org.isSstRegistered)
              _Registered(org: org)
            else
              Text(
                'This company is not registered for SST, so new lines '
                'default to Not Applicable at 0%.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            if (canAdmin) ...[
              const SizedBox(height: Space.md),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  key: const ValueKey('sst-change'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => _SstDialog(org: org),
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(
                    org.isSstRegistered ? 'Change' : 'Register for SST',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Registered extends ConsumerWidget {
  const _Registered({required this.org});

  final Organization org;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final codes = ref.watch(taxCodesProvider).valueOrNull ?? const <TaxCode>[];
    final fallback = codes.where((c) => c.isDefault).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldRow(
          label: 'Registration number',
          value: org.sstRegistrationNo ?? 'Not set',
        ),
        FieldRow(
          label: 'Took effect',
          value: org.sstRegisteredFrom == null
              ? 'Not set'
              : Fmt.date(org.sstRegisteredFrom!),
        ),
        FieldRow(
          label: 'New lines default to',
          value: fallback == null
              ? 'Nothing — no tax code is marked default'
              : '${fallback.code} · ${fallback.name}',
        ),
        if (org.sstRegisteredFrom != null) ...[
          const SizedBox(height: Space.sm),
          Text(
            'A document dated before ${Fmt.date(org.sstRegisteredFrom!)} '
            'cannot carry tax, and the database refuses to save one that '
            'does.',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _SstDialog extends ConsumerStatefulWidget {
  const _SstDialog({required this.org});

  final Organization org;

  @override
  ConsumerState<_SstDialog> createState() => _SstDialogState();
}

class _SstDialogState extends ConsumerState<_SstDialog> {
  late bool _registered = widget.org.isSstRegistered;
  late DateTime? _from = widget.org.sstRegisteredFrom;
  late final _number = TextEditingController(
    text: widget.org.sstRegistrationNo ?? '',
  );
  String? _code;
  bool _saving = false;

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .setSstRegistration(
            registered: _registered,
            from: _from,
            registrationNo: _number.text.trim(),
            taxCode: _code,
          ),
      successMessage: _registered
          ? 'Registered. New lines will default to $_code.'
          : 'Taken off the register. New lines default to NA.',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      // Both, because one card reads the company and another reads the
      // tax codes, and this changed each of them.
      refreshOrganization(ref);
      ref.invalidate(taxCodesProvider);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only codes that actually charge something. Offering a zero-rated
    // one would let somebody register and change nothing, which is the
    // bug this whole card exists to stop.
    final codes = [
      for (final c
          in ref.watch(taxCodesProvider).valueOrNull ?? const <TaxCode>[])
        if (c.rate > 0) c,
    ]..sort((a, b) => a.code.compareTo(b.code));

    return AlertDialog(
      title: const Text('SST registration'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                key: const ValueKey('sst-registered'),
                contentPadding: EdgeInsets.zero,
                value: _registered,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _registered = v),
                title: const Text('Registered for SST'),
              ),
              if (_registered) ...[
                TextField(
                  key: const ValueKey('sst-number'),
                  controller: _number,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Registration number',
                    helperText: 'Printed on every tax invoice',
                  ),
                ),
                const SizedBox(height: Space.md),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Took effect',
                    helperText: 'Invoices dated before this cannot carry tax',
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _from == null ? 'Not set' : Fmt.date(_from!),
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('sst-date'),
                        onPressed: _saving
                            ? null
                            : () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: _from ?? DateTime.now(),
                                  firstDate: DateTime(2018),
                                  lastDate: DateTime(2100),
                                );
                                if (picked != null) {
                                  setState(() => _from = picked);
                                }
                              },
                        child: const Text('Pick'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.md),
                SearchablePicker<String>(
                  key: const ValueKey('sst-code'),
                  options: [
                    for (final c in codes)
                      PickerOption<String>(
                        value: c.code,
                        label: c.code,
                        sublabel: c.name,
                        keywords: [c.name, Fmt.percent(c.rate)],
                      ),
                  ],
                  value: codes.any((c) => c.code == _code) ? _code : null,
                  label: 'New lines default to',
                  // Said here because it is the decision this dialog
                  // exists for, and getting it wrong is a wrong number
                  // on every invoice from here on.
                  helperText:
                      'Service tax and sales tax are separate '
                      'registrations — pick the one you registered for',
                  enabled: !_saving,
                  onChanged: (v) => setState(() => _code = v),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(
                    'Coming off the register clears the number and points '
                    'new lines back at Not Applicable. Documents already '
                    'raised are untouched.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('sst-save'),
          // Left enabled with the fields empty on purpose: the database
          // says which one is missing and why, and that sentence is more
          // use than a greyed-out button.
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
