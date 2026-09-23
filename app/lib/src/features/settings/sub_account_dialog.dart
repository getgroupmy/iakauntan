/// Filing a new account under an existing one.
///
/// Asked for as a chart that breaks down to any depth —
/// `1120` Bank accounts, `1120-1000` Maybank, `1120-1000-1000` Multi
/// Currency — with a sub-account allowed only while the parent has no
/// transactions.
///
/// ## Why this is a second dialog and not a field on the first
///
/// `NewAccountDialog` asks for a number, a name, a type and a subtype,
/// because a top-level account decides all four. A sub-account decides
/// almost none of them: its type is its parent's, always; its subtype
/// is its parent's unless somebody says otherwise; and its number is
/// the next one under the parent unless somebody types one. Offering
/// the same four boxes would be asking four questions with three
/// answers already known, and inviting a wrong answer to the one that
/// must not be wrong — a sub-account filed under a different type
/// appears on one statement by its type and another by its position.
///
/// ## The warning is the point of the screen
///
/// Filing something under a posting account PROMOTES that account to a
/// heading, and a heading holds no balance: `0014`, `0016` and `0100`
/// sum leaves. `0655` refuses the promotion where it would cost
/// something — a posted line, an opening balance, or a number the
/// ledger posts to. Since `0693` that is not a reason the child cannot
/// exist: the sub-account goes in either way and the parent simply
/// goes on posting. This dialog asks the question before it draws
/// anything so that the note says which of the two is about to
/// happen.
///
/// Where it is allowed, [promotionNote] says plainly what is about to
/// happen to the parent. "1120 Travel will stop being an account you
/// can post to" is the consequence somebody needs before they press
/// Add, not after.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import 'new_account_dialog.dart' show accountSubtypes;

/// What is about to happen to the parent, or null where nothing is.
///
/// Null for an account that is already a heading: it posts nothing
/// today and taking another child changes nothing at all. A note that
/// appeared either way would be a warning people learn to skip.
///
/// [refusal] is the server's answer to "may this become a heading?" —
/// `app.sub_account_refusal`. Null means it may, and the note warns
/// that it is about to stop being postable. Non-null means it may not,
/// and since `0693` that no longer stops the sub-account: the child
/// goes in and the parent goes on posting, which is the other thing
/// worth saying before somebody presses Add.
String? promotionNote(Account parent, {String? refusal}) {
  if (parent.isGroup) return null;
  if (refusal != null) {
    return '${parent.code} ${parent.name} stays an account you can post '
        'to, and keeps its own balance. The new account is filed under '
        'it rather than replacing it.';
  }
  return '${parent.code} ${parent.name} becomes a heading. A heading '
      'groups the accounts under it and cannot be posted to itself, so '
      'it will stop being offered when you record anything. It has '
      'nothing posted to it today, so no report changes.';
}

/// The line under the title saying where this is going.
String subAccountBlurb(Account parent) =>
    'Filed under ${parent.code} ${parent.name}.';

/// What to call the new account's number box.
///
/// The hint names the parent rather than an example, because the number
/// is generated from it and somebody typing one should type one that
/// fits.
String codeHint(Account parent) =>
    'Left empty, the next number under ${parent.code} is used';

/// How deep a code sits in the chart, from the code alone.
///
/// `1120` is 0, `1120-1000` is 1, `1120-1000-1000` is 2. The chart is
/// listed in code order, which puts a child immediately under its
/// parent already — this is what makes that visible as a shape rather
/// than as a longer number somebody has to read carefully.
///
/// Read from the CODE and not from `parent_id`, because the list is
/// flat and indenting by parent would need the whole tree walked for
/// every row. The two agree for anything this product creates; where a
/// hand-typed code disagrees, the indent is cosmetic and the code is
/// what people go by.
int chartIndentDepth(String code) {
  final segments = code.trim().split('-').where((s) => s.isNotEmpty).length;
  return segments <= 1 ? 0 : segments - 1;
}

/// Ask, then add. Returns the new account's id, or null.
Future<String?> showSubAccountDialog(
  BuildContext context, {
  required Account parent,
  String? seed,
}) => showDialog<String>(
  context: context,
  builder: (_) => SubAccountDialog(parent: parent, seed: seed),
);

class SubAccountDialog extends ConsumerStatefulWidget {
  const SubAccountDialog({super.key, required this.parent, this.seed});

  final Account parent;

  /// What was typed into the picker that offered this, where one did.
  final String? seed;

  @override
  ConsumerState<SubAccountDialog> createState() => _SubAccountDialogState();
}

class _SubAccountDialogState extends ConsumerState<SubAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name = TextEditingController(
    text: widget.seed ?? '',
  );
  final _code = TextEditingController();
  final _currency = TextEditingController();
  late String _subtype = widget.parent.accountSubtype;

  /// Whether the server has answered whether this parent can take one,
  /// and what it said. Null answer means it can.
  bool _asking = true;
  String? _refusal;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  /// Before drawing the form, not after filling it in.
  Future<void> _ask() async {
    final repo = ref.read(repoProvider);
    if (repo == null) {
      setState(() {
        _asking = false;
        _refusal = 'No company is open.';
      });
      return;
    }
    try {
      final said = await repo.subAccountRefusal(widget.parent.id);
      if (mounted) {
        setState(() {
          _asking = false;
          _refusal = said;
        });
      }
    } catch (_) {
      // A question that could not be asked is not a refusal. The form
      // is drawn and the write asks again — which is where the rule
      // actually lives.
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _currency.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parent = widget.parent;
    final subtypes = accountSubtypes[parent.accountType] ?? const <String>[];
    final note = promotionNote(parent, refusal: _refusal);

    if (_asking) {
      return const AlertDialog(
        content: SizedBox(
          height: 72,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return AlertDialog(
      key: const ValueKey('sub-account-dialog'),
      title: const Text('Add a sub-account'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  subAccountBlurb(parent),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (note != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    key: const ValueKey('sub-account-promotion'),
                    padding: const EdgeInsets.all(Space.sm),
                    decoration: BoxDecoration(
                      color: context.colors.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    child: Text(
                      note,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('sub-account-name'),
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Name *',
                    hintText: 'Maybank, Multi Currency, USD',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Give it a name' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('sub-account-code'),
                  controller: _code,
                  decoration: InputDecoration(
                    labelText: 'Number',
                    hintText: codeHint(parent),
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                // The type is not asked. It is the parent's, and the
                // server sets it whatever this screen thinks.
                DropdownButtonFormField<String>(
                  key: const ValueKey('sub-account-subtype'),
                  // `accumulated_depreciation` is twenty-four
                  // characters before Fmt.label spaces it out, and a
                  // dialog is 460 wide with a label beside it.
                  isExpanded: true,
                  initialValue: subtypes.contains(_subtype) ? _subtype : null,
                  decoration: const InputDecoration(labelText: 'Filed as'),
                  items: [
                    for (final s in subtypes)
                      DropdownMenuItem(value: s, child: Text(Fmt.label(s))),
                  ],
                  onChanged: (v) => setState(() => _subtype = v ?? _subtype),
                ),
                // Only where it can mean something. A currency on an
                // expense account is a box nobody should be invited to
                // fill in; on a bank it is the USD account the request
                // asked for by name.
                if (parent.accountType == 'asset' ||
                    parent.accountType == 'liability') ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('sub-account-currency'),
                    controller: _currency,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 3,
                    decoration: const InputDecoration(
                      labelText: 'Currency',
                      hintText: 'USD — leave empty for the company\'s own',
                      counterText: '',
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    key: const ValueKey('sub-account-error'),
                    style: TextStyle(color: context.colors.danger),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('sub-account-save'),
          onPressed: _saving ? null : _save,
          child: const Text('Add'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final row = await repo.addSubAccount(
        parentId: widget.parent.id,
        name: _name.text,
        code: _code.text.trim().isEmpty ? null : _code.text.trim(),
        subtype: _subtype,
        currency: _currency.text.trim().isEmpty ? null : _currency.text.trim(),
      );
      if (!mounted) return;
      // Both, and for different reasons: the chart is what this screen
      // shows, and the pickers elsewhere read the same provider — a
      // sub-account added from an expense form has to be choosable on
      // that form a moment later.
      ref.invalidate(accountsProvider);
      // Three outcomes, and two of them are a change somebody should
      // hear about once rather than discover later: the parent has
      // stopped being postable, or — `0693` — it deliberately has not.
      final promoted = row['parent_promoted'] == true;
      final stays = row['parent_stays_postable'] == true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            promoted
                ? '${row['code']} added. ${widget.parent.code} is now a '
                      'heading.'
                : stays
                ? '${row['code']} added. ${widget.parent.code} is still '
                      'an account you can post to.'
                : '${row['code']} added.',
          ),
        ),
      );
      Navigator.of(context).pop(row['id'] as String?);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          // The server's own sentence where there is one: `0655`'s
          // refusals name the account and say what it would cost,
          // which is the part somebody can act on.
          _error = e is PostgrestException ? e.message : '$e';
        });
      }
    }
  }
}

