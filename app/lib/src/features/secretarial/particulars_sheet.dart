import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_models.dart';
import '../../data/corp_repository.dart';

/// The three changes a company has to tell the Registrar about.
///
/// Not fields on the editor. `corp_entities.former_names`,
/// `registered_office_changed_on` and `constitution_adopted_on` were
/// columns since `0061` that nothing wrote, because renaming a company
/// was typing over a text box — and `0377` refuses that now, because
/// s.28(4) puts the former name on the company's documents for twelve
/// months and typing over it loses both the name and the date.
///
/// Each action asks for the date the thing happened, because that is
/// what the deadline is counted from and it is rarely today: a special
/// resolution passed last Tuesday is due fourteen days from last
/// Tuesday.
Future<bool> showParticularsSheet(
  BuildContext context, {
  required CorpEntity entity,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ParticularsSheet(entity: entity),
    ) ??
    false;

class _ParticularsSheet extends ConsumerStatefulWidget {
  const _ParticularsSheet({required this.entity});

  final CorpEntity entity;

  @override
  ConsumerState<_ParticularsSheet> createState() => _ParticularsSheetState();
}

class _ParticularsSheetState extends ConsumerState<_ParticularsSheet> {
  @override
  Widget build(BuildContext context) {
    final e = widget.entity;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(
              'Change of particulars',
              subtitle: 'Each of these starts a clock with the Registrar',
            ),
            ListTile(
              key: const ValueKey('change-name'),
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Change of name'),
              subtitle: const Text(
                'CA 2016 s.28 · lodged within 14 days. The former name '
                'goes on the company\'s documents for 12 months.',
              ),
              onTap: () => _rename(e),
            ),
            ListTile(
              key: const ValueKey('change-office'),
              leading: const Icon(Icons.location_on_outlined),
              title: const Text('Change of registered office'),
              subtitle: const Text('CA 2016 s.46(3) · lodged within 14 days'),
              onTap: () => _move(e),
            ),
            if (!e.hasConstitution)
              ListTile(
                key: const ValueKey('adopt-constitution'),
                leading: const Icon(Icons.gavel_outlined),
                title: const Text('Adoption of a constitution'),
                subtitle: const Text(
                  'CA 2016 s.32 · a copy lodged within 30 days of the '
                  'special resolution',
                ),
                onTap: () => _adopt(e),
              ),
            const Divider(),
            // The quiet half. A typo is not a change of name, and the
            // file has to be able to say which of the two happened.
            ListTile(
              key: const ValueKey('correct-particulars'),
              leading: const Icon(Icons.spellcheck),
              title: const Text('Correct a typo'),
              subtitle: const Text(
                'The record catching up with what was always true. No '
                'filing, no former name, no clock.',
              ),
              onTap: () => _correct(e),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(CorpEntity e) async {
    final name = await promptForText(
      context,
      title: 'What is the company called now?',
      label: 'New registered name',
      confirmLabel: 'Continue',
    );
    if (name == null || !mounted) return;
    final on = await _askDate('When was the resolution passed?');
    if (on == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .changeCompanyName(e.id, name, resolvedOn: on),
      successMessage: 'Renamed. The s.28 filing is due '
          '${Fmt.date(on.add(const Duration(days: 14)))}',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _move(CorpEntity e) async {
    final address = await promptForText(
      context,
      title: 'Where is the registered office now?',
      label: 'New registered office',
      confirmLabel: 'Continue',
    );
    if (address == null || !mounted) return;
    final on = await _askDate('When does the change take effect?');
    if (on == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .changeRegisteredOffice(e.id, address, effectiveOn: on),
      successMessage: 'Moved. The s.46(3) filing is due '
          '${Fmt.date(on.add(const Duration(days: 14)))}',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _adopt(CorpEntity e) async {
    final on = await _askDate('When was the constitution adopted?');
    if (on == null || !mounted) return;
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.adoptConstitution(e.id, adoptedOn: on),
      successMessage: 'Recorded. The s.32(3) filing is due '
          '${Fmt.date(on.add(const Duration(days: 30)))}',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _correct(CorpEntity e) async {
    final which = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Which one was typed wrong?'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'name'),
            child: const Text('The registered name'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'office'),
            child: const Text('The registered office'),
          ),
        ],
      ),
    );
    if (which == null || !mounted) return;

    final value = await promptForText(
      context,
      title: which == 'name'
          ? 'What should the name say?'
          : 'What should the address say?',
      label: which == 'name' ? 'Registered name' : 'Registered office',
      confirmLabel: 'Correct it',
    );
    if (value == null || !mounted) return;

    final repo = ref.read(repoProvider)!;
    final ok = await runWithFeedback(
      context,
      action: () => which == 'name'
          ? repo.correctCompanyName(e.id, value)
          : repo.correctRegisteredOffice(e.id, value),
      successMessage: 'Corrected',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  /// The date the thing happened, which is what the deadline runs from.
  Future<DateTime?> _askDate(String title) => showDatePicker(
        context: context,
        initialDate: DateTime.now(),
        firstDate: DateTime(2000),
        // Not the future: a resolution that has not been passed has no
        // date to count fourteen days from.
        lastDate: DateTime.now(),
        helpText: title,
      );
}
