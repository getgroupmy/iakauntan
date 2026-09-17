import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
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
                      _GroupRow(
                        company: c,
                        // Every company in the group, so the dialog can
                        // offer the others as the parent.
                        group: list,
                        busy: _busy,
                      ),
                  // Ownership is a fact about a pair, so it only means
                  // anything once there are two. A group of one is a
                  // group somebody has just started.
                  if (list.length > 1) ...[
                    const SizedBox(height: Space.sm),
                    Text(
                      'A consolidated report has to know who owns whom, and '
                      'refuses to produce a figure until every company here '
                      'says so. Anything short of wholly owned needs minority '
                      'interest, which is not built — record it anyway and '
                      'the report will say so by name rather than quietly '
                      'understating it.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
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
                            child: Text(
                              'Leave the group',
                              style: TextStyle(color: context.colors.danger),
                            ),
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
      message:
          'This company stops being listed with the others. Nothing in '
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

/// How much of one company belongs to another, as a sentence.
///
/// `100.0000` comes back from a `numeric(9,4)` and reads like a
/// measurement rather than a share, so trailing zeros go.
String formatOwnedPercent(double percent) {
  final whole = percent.roundToDouble() == percent;
  return whole ? percent.toStringAsFixed(0) : percent.toString();
}

/// One company in the group, with who owns it.
///
/// The button is per row rather than per card because
/// `set_group_ownership` asks for administrator rights on the company
/// being *owned*, not on its parent — a company's share capital is a
/// fact about that company, and the person who runs it is the one who
/// knows it. So somebody standing in the holding company can be shown
/// that a subsidiary has no ownership recorded while not being able to
/// record it, and the honest thing is to show the row without the
/// button rather than offer one that would be refused.
class _GroupRow extends ConsumerWidget {
  const _GroupRow({
    required this.company,
    required this.group,
    required this.busy,
  });

  final Map<String, dynamic> company;
  final List<Map<String, dynamic>> group;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final parent = company['parent_name']?.toString();
    final percent = company['owned_percent'] == null
        ? null
        : double.tryParse(company['owned_percent'].toString());
    final orgId = company['org_id']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  company['name']?.toString() ?? '',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                Text(
                  (company['registration_no'] ?? 'No registration').toString(),
                  style: const TextStyle(fontSize: 11),
                ),
                if (group.length > 1)
                  Text(
                    parent == null || percent == null
                        ? 'Ownership not recorded'
                        : 'Owned ${formatOwnedPercent(percent)}% by $parent',
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
              ],
            ),
          ),
          if (company['is_current'] == true)
            const StatusChip('this one', compact: true),
          if (group.length > 1 && company['can_admin'] == true)
            TextButton(
              key: ValueKey('ownership-$orgId'),
              onPressed: busy
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          _OwnershipDialog(company: company, group: group),
                    ),
              child: const Text('Ownership'),
            ),
        ],
      ),
    );
  }
}

class _OwnershipDialog extends ConsumerStatefulWidget {
  const _OwnershipDialog({required this.company, required this.group});

  final Map<String, dynamic> company;
  final List<Map<String, dynamic>> group;

  @override
  ConsumerState<_OwnershipDialog> createState() => _OwnershipDialogState();
}

class _OwnershipDialogState extends ConsumerState<_OwnershipDialog> {
  late String? _parent = widget.company['parent_org_id']?.toString();
  late final _percent = TextEditingController(
    text: widget.company['owned_percent'] == null
        ? '100'
        : formatOwnedPercent(
            double.tryParse(widget.company['owned_percent'].toString()) ?? 100,
          ),
  );
  bool _saving = false;

  @override
  void dispose() {
    _percent.dispose();
    super.dispose();
  }

  /// The companies that may be offered as the parent.
  ///
  /// Not this one — a company cannot own itself — and not one that is
  /// itself owned: 0148 refuses a chain of holdings outright rather than
  /// consolidating two levels correctly and three wrongly, so a chooser
  /// that offered one would only be collecting a refusal.
  List<Map<String, dynamic>> get _candidates => [
    for (final c in widget.group)
      if (c['org_id'] != widget.company['org_id'] && c['parent_org_id'] == null)
        c,
  ];

  Future<void> _save() async {
    final percent = _parent == null
        ? null
        : double.tryParse(_percent.text.trim().replaceAll('%', ''));

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .setGroupOwnership(
            orgId: widget.company['org_id'].toString(),
            parentOrgId: _parent,
            percent: percent,
          ),
      successMessage: _parent == null
          ? 'Ownership cleared'
          : 'Ownership recorded',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.invalidate(groupCompaniesProvider);
      // The company's own row carries the columns too, and the reports
      // screen reads it.
      refreshOrganization(ref);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final name = widget.company['name']?.toString() ?? 'this company';
    final candidates = _candidates;

    return AlertDialog(
      title: Text('Who owns $name?'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SearchablePicker<String>(
                key: const ValueKey('ownership-parent'),
                options: [
                  // A group can have more than one administrator, so the
                  // recorded parent may be a company this person is not
                  // a member of and which is therefore not on the list.
                  // Carried as its own option so that opening the dialog
                  // and pressing Save does not silently clear ownership
                  // somebody else recorded.
                  if (_parent != null &&
                      !candidates.any(
                        (c) => c['org_id']?.toString() == _parent,
                      ))
                    PickerOption<String>(
                      value: _parent!,
                      label:
                          widget.company['parent_name']?.toString() ??
                          'The company recorded as owning this one',
                    ),
                  for (final c in candidates)
                    PickerOption<String>(
                      value: '${c['org_id']}',
                      label: c['name']?.toString() ?? '',
                    ),
                ],
                value: _parent,
                label: 'Owned by',
                helperText: 'A company in this group that you belong to',
                enabled: !_saving,
                allowEmpty: true,
                emptyLabel: 'Nobody — this is the top of the group',
                onChanged: (v) => setState(() => _parent = v),
              ),
              if (_parent != null) ...[
                const SizedBox(height: Space.md),
                TextField(
                  key: const ValueKey('ownership-percent'),
                  controller: _percent,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Share held',
                    suffixText: '%',
                    helperText: 'More than 0 and at most 100',
                  ),
                ),
                const SizedBox(height: Space.sm),
                Text(
                  'Record the real figure. Anything under 100% means the '
                  'group does not own the whole of it, and the consolidated '
                  'report will refuse and name the company rather than treat '
                  'somebody else\'s share as the group\'s.',
                  style: TextStyle(fontSize: 11, color: muted),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(
                    'One company in the group is the top of it and has no '
                    'parent to record. Every other one needs an owner before '
                    'a consolidated report can be produced.',
                    style: TextStyle(fontSize: 11, color: muted),
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
          key: const ValueKey('ownership-save'),
          // Enabled with a nonsense percentage on purpose, as elsewhere:
          // the database's sentence about what is wrong is more use than
          // a button that will not press.
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
