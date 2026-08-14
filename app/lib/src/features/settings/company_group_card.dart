import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Companies that belong to the same people.
///
/// Where two shops share an SSM number they are one company with two
/// branches, which is the card above. Where they have their own
/// registrations they are separate legal entities — each with its own
/// TIN, its own books and its own return to file — and the software must
/// not pretend otherwise. A group names the relationship without merging
/// anything.
///
/// It is a name, not a key to the books. Grouping two companies does not
/// let a member of one read a row of the other: every policy in the
/// schema still asks whether you are a member of *that* company.
/// Switching between the ones you do belong to already works from the
/// company switcher in the sidebar.
class CompanyGroupCard extends ConsumerStatefulWidget {
  const CompanyGroupCard({super.key});

  @override
  ConsumerState<CompanyGroupCard> createState() => _CompanyGroupCardState();
}

class _CompanyGroupCardState extends ConsumerState<CompanyGroupCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final companies = ref.watch(groupCompaniesProvider);
    final canAdmin = ref.watch(canAdminProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Company group',
              subtitle: 'Separate registrations, same owner',
            ),
            AsyncView(
              value: companies,
              onRetry: () => ref.invalidate(groupCompaniesProvider),
              loading: const LinearProgressIndicator(),
              builder: (list) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (list.isEmpty)
                    const Text(
                      'This company is on its own. Group it with another '
                      'when they share an owner but have different '
                      'registrations.',
                      style: TextStyle(fontSize: 13),
                    )
                  else
                    for (final c in list)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c['name']?.toString() ?? '',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w500),
                                  ),
                                  Text(
                                    (c['registration_no'] ?? 'No registration')
                                        .toString(),
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            if (c['is_current'] == true)
                              const StatusChip('this one', compact: true),
                          ],
                        ),
                      ),
                  if (canAdmin) ...[
                    const SizedBox(height: Space.md),
                    Row(
                      children: [
                        if (list.isEmpty)
                          FilledButton.tonal(
                            key: const ValueKey('start-group'),
                            onPressed: _busy ? null : _startGroup,
                            child: const Text('Start a group'),
                          )
                        else
                          TextButton(
                            onPressed: _busy ? null : _leaveGroup,
                            child: Text('Leave the group',
                                style:
                                    TextStyle(color: context.colors.danger)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // What it does and does not do, where somebody is
                    // about to press the button rather than in a manual.
                    const Text(
                      'A group keeps each company\'s books separate — each '
                      'still files its own return. It records that they '
                      'belong together, which is what consolidated '
                      'reporting and inter-company billing will be built '
                      'on.',
                      style: TextStyle(fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startGroup() async {
    final name = await _askName(context);
    if (name == null || !mounted) return;

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.createCompanyGroup(name),
      successMessage: 'Group created',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(groupCompaniesProvider);
      refreshOrganization(ref);
    }
  }

  Future<void> _leaveGroup() async {
    final sure = await confirm(
      context,
      title: 'Leave the group?',
      message: 'This company stops being listed with the others. Nothing in '
          'its books changes — they were never shared.',
      confirmLabel: 'Leave',
      destructive: true,
    );
    if (!sure || !mounted) return;

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.joinCompanyGroup(null),
      successMessage: 'Left the group',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(groupCompaniesProvider);
      refreshOrganization(ref);
    }
  }

  Future<String?> _askName(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name the group'),
        content: TextField(
          key: const ValueKey('group-name'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Group name',
            hintText: 'Kumpulan Kabeer',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isNotEmpty) Navigator.of(ctx).pop(v);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}
