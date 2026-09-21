import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../contacts/new_contact_dialog.dart';

/// What a bank line means.
///
/// `0625`. The import has read CSV and MT940 for a long time and the
/// reconciliation has always been there; what has never existed is the
/// step between, so a bookkeeper codes two hundred lines a month
/// against the same twenty descriptions.
///
/// ## The number at the top is the point of the card
///
/// Not the list of rules — the count of lines the rules explain
/// nothing about. A screen that shows only what matched cannot tell
/// somebody that a hundred and forty lines still need typing, and a
/// rule set is worth having exactly insofar as that number falls.
///
/// ## It suggests and never posts
///
/// Said on the card in those words, because a person writing a pattern
/// that will run over their bank statement deserves to know whether it
/// is going to touch the ledger. It is not: `0625` is `stable`
/// throughout and `bank_rules.sql` asserts that against `pg_proc`.
class BankRulesCard extends ConsumerWidget {
  const BankRulesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(bankRulesProvider);
    final coverage = ref.watch(bankRuleCoverageProvider(null)).valueOrNull;
    final unexplained = ref.watch(bankLinesUnexplainedProvider(null));
    final canPost = ref.watch(canPostProvider);

    // By rule id, so a rule with no coverage row reads as nought rather
    // than as blank — "this rule catches nothing" is the answer
    // somebody is looking for.
    final matches = {
      for (final row in coverage ?? const <Map<String, dynamic>>[])
        '${row['rule_id']}': (row['matches'] as num?)?.toInt() ?? 0,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              'What your bank lines mean',
              subtitle:
                  'A rule reads the words on a statement line and says '
                  'what to code it as. It suggests; it never posts.',
              action: canPost
                  ? FilledButton.tonalIcon(
                      key: const ValueKey('bank-rule-add'),
                      onPressed: () => _edit(context, ref, null),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add a rule'),
                    )
                  : null,
            ),

            unexplained.when(
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
              data: (n) => Container(
                key: const ValueKey('bank-rules-unexplained'),
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: n == 0
                      ? context.colors.success.withValues(alpha: 0.12)
                      : context.colors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Text(
                  n == 0
                      ? 'Every unreconciled line has a rule that describes '
                            'it.'
                      : '$n unreconciled ${n == 1 ? 'line has' : 'lines have'} '
                            'no rule. ${n == 1 ? 'It' : 'They'} still need '
                            'coding by hand.',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),

            const SizedBox(height: Space.md),

            AsyncView<List<Map<String, dynamic>>>(
              value: rules,
              onRetry: () => ref.invalidate(bankRulesProvider),
              skeleton: const ListSkeleton(rows: 4, leading: false),
              builder: (rows) => rows.isEmpty
                  ? const EmptyState(
                      icon: Icons.rule_outlined,
                      title: 'No rules yet',
                      message:
                          'Add one for a payment you see every month — the '
                          'electricity bill, the rent, the bank charge.',
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _RuleRow(
                            rule: rows[i],
                            matches: matches['${rows[i]['id']}'],
                            onTap: canPost
                                ? () => _edit(context, ref, rows[i])
                                : null,
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

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => BankRuleDialog(existing: existing),
    );
    if (saved == true) {
      ref.invalidate(bankRulesProvider);
      ref.invalidate(bankRuleCoverageProvider);
      ref.invalidate(bankLinesUnexplainedProvider);
    }
  }
}

/// One rule, and what it would catch.
class _RuleRow extends StatelessWidget {
  const _RuleRow({required this.rule, this.matches, this.onTap});

  final Map<String, dynamic> rule;
  final int? matches;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final account = (rule['accounts'] as Map?)?.cast<String, dynamic>();
    final active = rule['is_active'] != false;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: onTap != null,
      onTap: onTap,
      title: Row(
        children: [
          Flexible(
            child: Text(
              '${rule['name']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: active ? null : context.scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (!active) ...[
            const SizedBox(width: 8),
            const StatusChip('off', compact: true),
          ],
        ],
      ),
      subtitle: Text(
        bankRuleSummary(rule, account),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: matches == null
          ? null
          : Text(
              matches == 0 ? 'catches nothing' : '$matches',
              key: ValueKey('bank-rule-matches-${rule['id']}'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: matches == 0 ? FontWeight.normal : FontWeight.w600,
                color: matches == 0 ? context.scheme.onSurfaceVariant : null,
              ),
            ),
    );
  }
}

/// A rule in one line: what it looks for, then what it says.
///
/// Pulled out of the widget because it is the part that can be wrong in
/// a way nobody notices. A rule whose summary omits one of its
/// conditions reads as broader than it is, and somebody deletes it for
/// catching too little when it was never asked to catch that.
String bankRuleSummary(Map<String, dynamic> rule, Map<String, dynamic>? account) {
  final looks = <String>[
    if (rule['direction'] == 'in') 'money in',
    if (rule['direction'] == 'out') 'money out',
    if (rule['description_contains'] != null)
      'says “${rule['description_contains']}”',
    if (rule['reference_contains'] != null)
      'reference “${rule['reference_contains']}”',
    if (rule['amount_min'] != null && rule['amount_max'] != null)
      'between ${rule['amount_min']} and ${rule['amount_max']}',
    if (rule['amount_min'] != null && rule['amount_max'] == null)
      'at least ${rule['amount_min']}',
    if (rule['amount_min'] == null && rule['amount_max'] != null)
      'at most ${rule['amount_max']}',
  ];

  final says = <String>[
    if (account != null) '${account['code']} ${account['name']}',
    if ((rule['contacts'] as Map?)?['name'] != null)
      '${(rule['contacts'] as Map)['name']}',
  ];

  final left = looks.isEmpty ? 'every line' : looks.join(', ');
  return says.isEmpty ? left : '$left  →  ${says.join('  ·  ')}';
}

/// Writing one.
class BankRuleDialog extends ConsumerStatefulWidget {
  const BankRuleDialog({super.key, this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<BankRuleDialog> createState() => BankRuleDialogState();
}

class BankRuleDialogState extends ConsumerState<BankRuleDialog> {
  late final TextEditingController _name;
  late final TextEditingController _says;
  late final TextEditingController _reference;
  late final TextEditingController _min;
  late final TextEditingController _max;
  String? _direction;
  String? _accountId;
  String? _contactId;
  bool _active = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: '${e?['name'] ?? ''}');
    _says = TextEditingController(text: '${e?['description_contains'] ?? ''}');
    _reference =
        TextEditingController(text: '${e?['reference_contains'] ?? ''}');
    _min = TextEditingController(text: '${e?['amount_min'] ?? ''}');
    _max = TextEditingController(text: '${e?['amount_max'] ?? ''}');
    _direction = e?['direction'] as String?;
    _accountId = e?['account_id'] as String?;
    _contactId = e?['contact_id'] as String?;
    _active = e?['is_active'] != false;
  }

  @override
  void dispose() {
    _name.dispose();
    _says.dispose();
    _reference.dispose();
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  /// Why this rule cannot be saved yet, or null.
  ///
  /// The database refuses both of these with a check constraint, and
  /// saying so here is not duplication — a constraint violation reaches
  /// the screen as `bank_rules_says_something` and that is not a
  /// sentence anybody can act on.
  String? get problem {
    if (_name.text.trim().isEmpty) return 'Give the rule a name.';
    final hasCondition = _direction != null ||
        _says.text.trim().isNotEmpty ||
        _reference.text.trim().isNotEmpty ||
        double.tryParse(_min.text.trim()) != null ||
        double.tryParse(_max.text.trim()) != null;
    if (!hasCondition) {
      return 'A rule with no condition would match every line on the '
          'statement. Say what to look for.';
    }
    // In the order the form asks for them. The amount window belongs to
    // "look for" and is reported before "suggest", because somebody
    // filling the form downwards has not reached the account yet and
    // being told about it first reads as the form losing its place.
    final min = double.tryParse(_min.text.trim());
    final max = double.tryParse(_max.text.trim());
    if (min != null && max != null && min > max) {
      return 'The smallest amount is larger than the largest, so nothing '
          'can be inside it.';
    }
    if (_accountId == null && _contactId == null) {
      return 'A rule that suggests nothing does nothing. Choose an '
          'account, a contact, or both.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
    final contacts =
        ref.watch(contactsProvider((type: 'both', search: ''))).valueOrNull ??
            const <Contact>[];
    final why = problem;

    return AlertDialog(
      title: Text(widget.existing == null ? 'Add a rule' : 'Edit the rule'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('bank-rule-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.md),
              Text('Look for', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Space.xs),
              TextField(
                key: const ValueKey('bank-rule-says'),
                controller: _says,
                decoration: const InputDecoration(
                  labelText: 'The line says',
                  helperText: 'Any part of the description. Case does not '
                      'matter.',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                key: const ValueKey('bank-rule-reference'),
                controller: _reference,
                decoration:
                    const InputDecoration(labelText: 'The reference says'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<String>(
                      key: const ValueKey('bank-rule-direction'),
                      segments: const [
                        ButtonSegment(value: 'any', label: Text('Either way')),
                        ButtonSegment(value: 'in', label: Text('Money in')),
                        ButtonSegment(value: 'out', label: Text('Money out')),
                      ],
                      selected: {_direction ?? 'any'},
                      onSelectionChanged: (s) => setState(
                        () => _direction = s.first == 'any' ? null : s.first,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('bank-rule-min'),
                      controller: _min,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'At least',
                        helperText: 'How big the line is, either way',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('bank-rule-max'),
                      controller: _max,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'At most'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.md),
              Text('Suggest', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Space.xs),
              SearchablePicker<String>(
                key: const ValueKey('bank-rule-account'),
                options: [
                  for (final a in accounts)
                    if (!a.isGroup)
                      PickerOption(value: a.id, label: '${a.code} ${a.name}'),
                ],
                value: _accountId,
                allowEmpty: true,
                emptyLabel: 'No account',
                label: 'Account',
                onChanged: (v) => setState(() => _accountId = v),
              ),
              const SizedBox(height: Space.sm),
              SearchablePicker<String>(
                key: const ValueKey('bank-rule-contact'),
                options: contactPickerOptions(contacts),
                value: _contactId,
                allowEmpty: true,
                emptyLabel: 'No contact',
                label: 'Contact',
                onChanged: (v) => setState(() => _contactId = v),
              ),
              const SizedBox(height: Space.md),
              SwitchListTile(
                key: const ValueKey('bank-rule-active'),
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('In use'),
                subtitle: const Text(
                  'A rule switched off suggests nothing and keeps its place '
                  'in the order.',
                ),
              ),
              if (why != null) ...[
                const SizedBox(height: Space.md),
                Container(
                  key: const ValueKey('bank-rule-problem'),
                  padding: const EdgeInsets.all(Space.md),
                  decoration: BoxDecoration(
                    color: context.colors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Text(why, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(
            key: const ValueKey('bank-rule-delete'),
            onPressed: _saving ? null : _delete,
            style: TextButton.styleFrom(foregroundColor: context.colors.danger),
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('bank-rule-save'),
          onPressed: why != null || _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final done = await runWithFeedback(
      context,
      doing: 'save the rule',
      action: () => ref.read(repoProvider)!.saveBankRule(
        id: widget.existing?['id'] as String?,
        name: _name.text,
        isActive: _active,
        direction: _direction,
        descriptionContains: _says.text,
        referenceContains: _reference.text,
        amountMin: double.tryParse(_min.text.trim()),
        amountMax: double.tryParse(_max.text.trim()),
        accountId: _accountId,
        contactId: _contactId,
      ),
      successMessage: 'Saved',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (done) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: 'Delete this rule?',
      message: 'Lines it was explaining go back to needing a hand.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    final done = await runWithFeedback(
      context,
      doing: 'delete the rule',
      action: () =>
          ref.read(repoProvider)!.deleteBankRule('${widget.existing!['id']}'),
      successMessage: 'Deleted',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (done) Navigator.pop(context, true);
  }
}
