import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_repository.dart';

/// How many votes a share of this class carries.
///
/// Zero is a real answer -- a non-voting preference share is the
/// ordinary case, not a mistake -- so this refuses only what cannot be
/// true. Negative votes are not a thing.
double? votesOf(String text) {
  final v = double.tryParse(text.trim());
  if (v == null || v < 0) return null;
  return v;
}

/// What a class of shares is, given what was entered.
///
/// Pure, and apart from the sheet, because `corp_share_classes` is
/// unique on (entity_id, code) and the code is what every movement and
/// every return will be filed under. A class entered as `ord` on one
/// company and `ORD` on the next is two names for one thing.
Map<String, dynamic> shareClassValues({
  required String entityId,
  required String code,
  required String name,
  required String currency,
  required double votesPerShare,
  bool isRedeemable = false,
  String? rights,
}) {
  final trimmedName = name.trim();
  final trimmedRights = rights?.trim();
  return <String, dynamic>{
    'entity_id': entityId,
    'code': code.trim().toUpperCase(),
    // The column defaults to 'Ordinary'; a blank box should mean the
    // default rather than a class with no name.
    'name': trimmedName.isEmpty ? 'Ordinary' : trimmedName,
    'currency': currency.trim().toUpperCase(),
    'votes_per_share': votesPerShare,
    'is_redeemable': isRedeemable,
    'rights': (trimmedRights == null || trimmedRights.isEmpty)
        ? null
        : trimmedRights,
  };
}

/// Add or amend a class of shares.
Future<bool> showShareClassSheet(
  BuildContext context, {
  required String entityId,
  Map<String, dynamic>? shareClass,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) =>
          _ShareClassSheet(entityId: entityId, shareClass: shareClass),
    ) ??
    false;

class _ShareClassSheet extends ConsumerStatefulWidget {
  const _ShareClassSheet({required this.entityId, this.shareClass});

  final String entityId;
  final Map<String, dynamic>? shareClass;

  @override
  ConsumerState<_ShareClassSheet> createState() => _ShareClassSheetState();
}

class _ShareClassSheetState extends ConsumerState<_ShareClassSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _code;
  late final TextEditingController _name;
  late final TextEditingController _currency;
  late final TextEditingController _votes;
  late final TextEditingController _rights;

  late bool _redeemable;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.shareClass;
    _code = TextEditingController(text: c?['code'] as String? ?? 'ORD');
    _name = TextEditingController(text: c?['name'] as String? ?? 'Ordinary');
    _currency = TextEditingController(text: c?['currency'] as String? ?? 'MYR');
    _votes = TextEditingController(text: '${c?['votes_per_share'] ?? 1}');
    _rights = TextEditingController(text: c?['rights'] as String? ?? '');
    _redeemable = c?['is_redeemable'] as bool? ?? false;
  }

  @override
  void dispose() {
    for (final c in [_code, _name, _currency, _votes, _rights]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final votes = votesOf(_votes.text);
    if (votes == null) return;

    setState(() => _saving = true);
    final values = shareClassValues(
      entityId: widget.entityId,
      code: _code.text,
      name: _name.text,
      currency: _currency.text,
      votesPerShare: votes,
      isRedeemable: _redeemable,
      rights: _rights.text,
    );

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveCorpShareClass(values, id: widget.shareClass?['id'] as String?),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(corpShareClassesProvider(widget.entityId));
      ref.invalidate(corpMembersProvider(widget.entityId));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.shareClass == null
          ? 'Add a class of shares'
          : 'Amend the class'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('share-class-code'),
                      controller: _code,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Code',
                        helperText: 'ORD, PREF',
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _name,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                  ),
                ]),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _currency,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 3,
                      decoration: const InputDecoration(
                        labelText: 'Currency',
                        counterText: '',
                      ),
                      validator: (v) => (v == null || v.trim().length != 3)
                          ? 'Three letters'
                          : null,
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextFormField(
                      controller: _votes,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Votes per share',
                        helperText: '0 for non-voting',
                      ),
                      validator: (v) =>
                          votesOf(v ?? '') == null ? 'A number, not less than zero' : null,
                    ),
                  ),
                ]),
                const SizedBox(height: Space.sm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _redeemable,
                  onChanged:
                      _saving ? null : (v) => setState(() => _redeemable = v),
                  title: const Text('Redeemable'),
                  subtitle: const Text(
                      'Redeemable preference shares under s.72, which may be '
                      'redeemed out of profits or a fresh issue.'),
                ),
                const SizedBox(height: Space.sm),
                TextFormField(
                  controller: _rights,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Rights attached',
                    helperText: 'Dividend, voting and return of capital, as '
                        'the constitution puts it.',
                  ),
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
          onPressed: _saving ? null : _save,
          key: const ValueKey('share-class-save'),
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
