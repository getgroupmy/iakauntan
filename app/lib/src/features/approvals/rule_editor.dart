import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../documents/doc_types.dart';

/// Writing the rule that will hold somebody's invoice up.
///
/// Worth being careful with, because the cost of a mistake is asymmetric:
/// a rule set too loose loses a signature nobody notices, and a rule set
/// too tight stops the company invoicing on a Friday afternoon. So the
/// sheet says in a sentence what the rule will actually do, built from
/// what is in the fields rather than from what was intended.
Future<void> showApprovalRuleEditor(
  BuildContext context,
  WidgetRef ref, {
  Map<String, dynamic>? rule,
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _RuleSheet(rule: rule),
  );
  if (saved == true) ref.invalidate(approvalRulesProvider);
}

class _RuleSheet extends ConsumerStatefulWidget {
  const _RuleSheet({this.rule});

  final Map<String, dynamic>? rule;

  @override
  ConsumerState<_RuleSheet> createState() => _RuleSheetState();
}

class _RuleSheetState extends ConsumerState<_RuleSheet> {
  late String _kind;
  late String? _docType;
  late int _step;
  late final TextEditingController _min;

  /// A role or a named person, never both — the table has a check
  /// constraint saying exactly that, and a single nullable field with a
  /// mode beside it is the only shape that cannot violate it.
  late bool _byRole;
  String? _role;
  String? _userId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final r = widget.rule;
    _kind = r?['entity_kind'] as String? ?? 'purchase_document';
    _docType = r?['doc_type'] as String?;
    _step = (r?['step_no'] as num?)?.toInt() ?? 1;
    _min = TextEditingController(
      text: (r?['min_amount'] as num?)?.toString() ?? '0',
    );
    _userId = r?['approver_user_id'] as String?;
    _role = r?['approver_role'] as String? ?? 'admin';
    _byRole = _userId == null;
  }

  @override
  void dispose() {
    _min.dispose();
    super.dispose();
  }

  /// The types this kind of rule can name. A journal has none — there is
  /// one sort of manual journal — so the field disappears rather than
  /// offering a choice of one.
  Iterable<MapEntry<String, DocTypeMeta>> get _types => switch (_kind) {
    'sales_document' => docTypesFor(DocKind.sales),
    'purchase_document' => docTypesFor(DocKind.purchase),
    _ => const [],
  };

  @override
  Widget build(BuildContext context) {
    final team = ref.watch(teamProvider).valueOrNull ?? const [];
    final min = num.tryParse(_min.text.trim()) ?? 0;

    return Padding(
      padding: EdgeInsets.only(
        left: Space.lg,
        right: Space.lg,
        top: Space.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Space.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.rule == null ? 'New approval rule' : 'Approval rule',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Space.lg),

            DropdownButtonFormField<String>(
              isExpanded: true,
              value: _kind,
              decoration: const InputDecoration(labelText: 'Applies to'),
              items: const [
                DropdownMenuItem(
                  value: 'sales_document',
                  child: Text('Sales documents'),
                ),
                DropdownMenuItem(
                  value: 'purchase_document',
                  child: Text('Purchase documents'),
                ),
                DropdownMenuItem(
                  value: 'journal',
                  child: Text('Manual journals'),
                ),
              ],
              onChanged: (v) => setState(() {
                _kind = v!;
                // The old type belongs to the old kind. Keeping it would
                // write a rule for "invoices" onto purchase documents,
                // which matches nothing and looks like it should.
                _docType = null;
              }),
            ),
            const SizedBox(height: Space.md),

            if (_types.isNotEmpty) ...[
              DropdownButtonFormField<String?>(
                isExpanded: true,
                value: _docType,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Every type'),
                  ),
                  for (final e in _types)
                    DropdownMenuItem(
                      value: e.key,
                      child: Text(e.value.singular),
                    ),
                ],
                onChanged: (v) => setState(() => _docType = v),
              ),
              const SizedBox(height: Space.md),
            ],

            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _min,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'From amount',
                      prefixText: 'RM ',
                      helperText: 'Zero means every one',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    isExpanded: true,
                    value: _step,
                    decoration: const InputDecoration(labelText: 'Step'),
                    items: [
                      for (var i = 1; i <= 5; i++)
                        DropdownMenuItem(value: i, child: Text('$i')),
                    ],
                    onChanged: (v) => setState(() => _step = v!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),

            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('A role')),
                ButtonSegment(value: false, label: Text('A named person')),
              ],
              selected: {_byRole},
              onSelectionChanged: (s) => setState(() => _byRole = s.first),
            ),
            const SizedBox(height: Space.md),

            if (_byRole)
              DropdownButtonFormField<String>(
                isExpanded: true,
                value: _role,
                decoration: const InputDecoration(labelText: 'Approved by'),
                items: [
                  for (final e in memberRoles.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value.label)),
                ],
                onChanged: (v) => setState(() => _role = v),
              )
            else
              SearchablePicker<String>(
                options: [
                  // Only people who have actually joined. An invitation
                  // that has not been accepted has no user to hang a
                  // step off, so offering it would write a rule whose
                  // approver does not exist yet.
                  for (final m in team.where((m) => m.userId != null))
                    PickerOption<String>(
                      value: m.userId!,
                      label: m.displayName,
                    ),
                ],
                value: _userId,
                label: 'Approved by',
                onChanged: (v) => setState(() => _userId = v),
              ),

            const SizedBox(height: Space.lg),
            Container(
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: context.colors.warning.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _sentence(min, team),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: Space.lg),

            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: Space.sm),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// What this rule will do, in the words somebody would use to complain
  /// about it later.
  String _sentence(num min, List<TeamMember> team) {
    final what = approvalEntityLabel(_kind, _docType).toLowerCase();
    final who = _byRole
        ? roleLabel(_role)
        : team
                  .where((m) => m.userId == _userId)
                  .map((m) => m.displayName)
                  .firstOrNull ??
              'nobody yet';
    final band = min > 0 ? ' of RM$min or more' : '';
    return 'Step $_step: $what$band cannot be posted until $who has '
        'approved. Nobody may approve a document they raised themselves.';
  }

  Future<void> _save() async {
    if (!_byRole && _userId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Choose who approves it.')));
      return;
    }
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveApprovalRule(
            id: widget.rule?['id'] as String?,
            entityKind: _kind,
            docType: _docType,
            minAmount: num.tryParse(_min.text.trim()) ?? 0,
            stepNo: _step,
            approverRole: _byRole ? _role : null,
            approverUserId: _byRole ? null : _userId,
          ),
      successMessage: 'Saved',
    );

    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context, true);
  }
}
