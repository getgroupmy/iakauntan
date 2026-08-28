import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/address_field.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/places_repository.dart';

/// The places a company trades from.
///
/// A branch is a location under the *same* registration and the same
/// ledger — two shops sharing one SSM number. Where the shops have their
/// own registrations they are separate companies, and no amount of
/// software should pretend otherwise: that is a group, handled by the
/// card below this one. The database agrees, and says so out loud — a
/// trigger refuses a document that names another company's branch.
///
/// A branch may carry its own registration number, TIN or SST number
/// without being a separate company, which happens often enough to be
/// worth the three fields. Left empty it uses the company's.
class BranchesCard extends ConsumerWidget {
  const BranchesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branches = ref.watch(branchesProvider);
    final canEdit = ref.watch(canPostProvider);

    Future<void> edit([Map<String, dynamic>? existing]) async {
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => _BranchDialog(existing: existing),
      );
      if (saved == true) ref.invalidate(branchesProvider);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Branches',
              subtitle: 'Places this company trades from, under one '
                  'registration',
              action: canEdit
                  ? TextButton.icon(
                      key: const ValueKey('add-branch'),
                      onPressed: () => edit(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add'),
                    )
                  : null,
            ),
            AsyncView(
              value: branches,
              onRetry: () => ref.invalidate(branchesProvider),
              loading: const LinearProgressIndicator(),
              builder: (list) => list.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'None. Everything belongs to the company itself, '
                        'which is right until you trade from a second '
                        'place.',
                        style: TextStyle(fontSize: 13),
                      ),
                    )
                  : Column(
                      children: [
                        for (final b in list)
                          InkWell(
                            key: ValueKey('branch-${b['code']}'),
                            onTap: canEdit ? () => edit(b) : null,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 72,
                                    child: Text(
                                      b['code']?.toString() ?? '',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(b['name']?.toString() ?? ''),
                                        if ((b['registration_no'] ?? '')
                                            .toString()
                                            .isNotEmpty)
                                          Text(
                                            'Own registration '
                                            '${b['registration_no']}',
                                            style: const TextStyle(
                                                fontSize: 11),
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (b['is_default'] == true)
                                    const Padding(
                                      padding: EdgeInsets.only(right: 8),
                                      child:
                                          StatusChip('default', compact: true),
                                    ),
                                  if (canEdit)
                                    const Icon(Icons.chevron_right, size: 18),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BranchDialog extends ConsumerStatefulWidget {
  const _BranchDialog({this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_BranchDialog> createState() => _BranchDialogState();
}

class _BranchDialogState extends ConsumerState<_BranchDialog> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _regNo = TextEditingController();
  final _tin = TextEditingController();
  final _sst = TextEditingController();
  final _line1 = TextEditingController();
  final _postcode = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  bool _saving = false;

  bool get _isNew => widget.existing == null;
  String get _id => widget.existing!['id'] as String;

  @override
  void initState() {
    super.initState();
    final b = widget.existing;
    String v(String k) => b?[k]?.toString() ?? '';
    _code.text = v('code');
    _name.text = v('name');
    _regNo.text = v('registration_no');
    _tin.text = v('tin');
    _sst.text = v('sst_registration_no');
    _line1.text = v('address_line1');
    _postcode.text = v('postcode');
    _city.text = v('city');
    _state.text = v('state_code');
    _phone.text = v('phone');
    _email.text = v('email');
  }

  @override
  void dispose() {
    for (final c in [
      _code, _name, _regNo, _tin, _sst, _line1, _postcode, _city, _state,
      _phone, _email,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid =>
      _code.text.trim().isNotEmpty && _name.text.trim().isNotEmpty;

  Future<void> _save() async {
    setState(() => _saving = true);
    final repo = ref.read(repoProvider)!;
    final ok = await runWithFeedback(
      context,
      action: () => _isNew
          ? repo.createBranch(
              code: _code.text.trim().toUpperCase(),
              name: _name.text.trim(),
              registrationNo: _regNo.text,
              tin: _tin.text,
              sstRegistrationNo: _sst.text,
              addressLine1: _line1.text,
              postcode: _postcode.text,
              city: _city.text,
              stateCode: _state.text,
              phone: _phone.text,
              email: _email.text,
            )
          : repo.updateBranch(
              _id,
              code: _code.text.trim().toUpperCase(),
              name: _name.text.trim(),
              registrationNo: _regNo.text,
              tin: _tin.text,
              sstRegistrationNo: _sst.text,
              addressLine1: _line1.text,
              postcode: _postcode.text,
              city: _city.text,
              stateCode: _state.text,
              phone: _phone.text,
              email: _email.text,
            ),
      successMessage: _isNew ? 'Branch added' : 'Branch saved',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    // Watched rather than read, so the reference list is on its
    // way before anybody picks a suggestion.
    final states = ref.watch(refStatesProvider).valueOrNull ?? const [];
    final country = ref.watch(orgCountryAlpha2Provider);

    return AlertDialog(
      title: Text(_isNew ? 'New branch' : 'Edit ${_code.text}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: TextField(
                      key: const ValueKey('branch-code'),
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
                      key: const ValueKey('branch-name'),
                      controller: _name,
                      enabled: !_saving,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              AddressField(
                controller: _line1,
                enabled: !_saving,
                country: country,
                onChosen: (a) => fillAddressBoxes(
                  a,
                  states,
                  postcode: _postcode,
                  city: _city,
                  stateCode: _state,
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _postcode,
                    enabled: !_saving,
                    decoration: const InputDecoration(labelText: 'Postcode'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _city,
                    enabled: !_saving,
                    decoration: const InputDecoration(labelText: 'City'),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _state,
                    enabled: !_saving,
                    decoration: const InputDecoration(labelText: 'State'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _phone,
                    enabled: !_saving,
                    decoration: const InputDecoration(labelText: 'Phone'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _email,
                    enabled: !_saving,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                ),
              ]),
              const Divider(height: Space.xl),
              Text('Its own numbers',
                  style: Theme.of(context).textTheme.titleSmall),
              const Text(
                'Only where this branch is registered in its own right. '
                'Left empty it uses the company\'s. A branch with a '
                'different company registration is not a branch at all — '
                'it is another company, and belongs in the group below.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _regNo,
                enabled: !_saving,
                decoration:
                    const InputDecoration(labelText: 'Branch registration'),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _tin,
                    enabled: !_saving,
                    decoration: const InputDecoration(labelText: 'TIN'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _sst,
                    enabled: !_saving,
                    decoration: const InputDecoration(labelText: 'SST number'),
                  ),
                ),
              ]),
              if (!_isNew) ...[
                const Divider(height: Space.xl),
                Row(
                  children: [
                    if (widget.existing!['is_default'] != true)
                      TextButton(
                        onPressed: _saving ? null : _makeDefault,
                        child: const Text('Make default'),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: _saving ? null : _retire,
                      child: Text('Close',
                          style: TextStyle(color: context.colors.danger)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
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

  Future<void> _makeDefault() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.setDefaultBranch(_id),
      successMessage: 'Default branch changed',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _retire() async {
    final sure = await confirm(
      context,
      title: 'Close ${_code.text}?',
      message: 'It stops being offered on new documents. Everything already '
          'filed against it is kept, so last year still explains itself.',
      confirmLabel: 'Close',
      destructive: true,
    );
    if (!sure || !mounted) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.retireBranch(_id),
      successMessage: 'Branch closed',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }
}
