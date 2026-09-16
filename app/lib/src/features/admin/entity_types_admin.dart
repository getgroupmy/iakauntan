import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_live.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/entity_types_repository.dart';

/// The kinds of business, from the operator's side.
///
/// `0605` turned `app.entity_type` from an enum into a table so this
/// page could exist: an eleventh kind used to need a migration and a
/// deploy.
///
/// ## The one that is not cosmetic
///
/// Everything on this page is a label and an order, except
/// `is_public_company`. `0172` decides whether a company files its
/// accounts to MBRS as a public company, and until `0605` it did so by
/// comparing the entity type against the string `bhd`. A kind added
/// here has to answer that question, and the answer defaults to no —
/// so the way to get it wrong is to say a private company is public,
/// which is visible, rather than to forget and have MBRS quietly file
/// the wrong return.
class EntityTypesAdminTab extends ConsumerWidget {
  const EntityTypesAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final types = ref.watch(allEntityTypesProvider);

    return AsyncView(
      value: types,
      onRetry: () => ref.invalidate(allEntityTypesProvider),
      builder: (rows) => SingleChildScrollView(
        child: PageBody(
          maxWidth: 900,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(
                        'The kinds of business',
                        subtitle:
                            'Offered when a contact or a company is '
                            'registered. Lower order comes first.',
                        action: FilledButton.tonalIcon(
                          key: const ValueKey('entity-type-add'),
                          onPressed: () => _edit(context, ref, null),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add a kind'),
                        ),
                      ),
                      if (rows.isEmpty)
                        const Text('Nothing on the list yet.')
                      else
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _TypeRow(
                            type: rows[i],
                            onTap: () => _edit(context, ref, rows[i]),
                          ),
                        ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.lg),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        'What a kind decides',
                        subtitle: 'And what it deliberately does not',
                      ),
                      Text(
                        'Only one thing here is read by anything: whether '
                        'a kind is a public company. That is what decides '
                        'how its accounts are filed to MBRS, so a new kind '
                        'has to say, and the answer starts at no.\n\n'
                        'SSM filing deadlines are NOT decided here. The '
                        'corporate secretarial module keeps its own list of '
                        'entity types and reads that one, so adding a kind '
                        'to this page cannot move anybody’s deadline.',
                        key: const ValueKey('entity-type-note'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.xxl),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    EntityType? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _EntityTypeDialog(existing: existing),
    );
    if (saved == true) {
      ref.invalidate(allEntityTypesProvider);
      invalidatePlatformTable(ref, 'entity_types');
    }
  }
}

class _TypeRow extends StatelessWidget {
  const _TypeRow({required this.type, required this.onTap});

  final EntityType type;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: context.scheme.onSurfaceVariant,
    );
    final where = [
      if (type.forContacts) 'contacts',
      if (type.forOrganizations) 'companies',
    ].join(' and ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: SizedBox(
        width: 44,
        child: Text('${type.sortOrder}', style: muted),
      ),
      title: Row(
        children: [
          Flexible(child: Text(type.label)),
          if (!type.isActive) ...[
            const SizedBox(width: Space.sm),
            const StatusChip('off', compact: true),
          ],
          if (type.isPublicCompany) ...[
            const SizedBox(width: Space.sm),
            const StatusChip('public company', compact: true),
          ],
        ],
      ),
      subtitle: Text(
        '${type.code}'
        '${where.isEmpty ? ' · offered nowhere' : ' · offered on $where'}'
        '${type.isBuiltin ? ' · built in' : ''}',
        style: muted,
      ),
    );
  }
}

/// Why a kind cannot be saved, in the words to show — or null.
///
/// Public and pure. The code is the value written onto every contact
/// filed as this kind, so it is checked here as well as in the
/// function: a refusal that arrives as a constraint name is a refusal
/// nobody can act on.
String? entityTypeProblem({
  required String code,
  required String label,
  required bool isNew,
}) {
  if (label.trim().isEmpty) return 'A kind needs a name.';
  if (!isNew) return null;
  final c = code.trim();
  if (c.isEmpty) return 'A kind needs a code.';
  if (!RegExp(r'^[a-z][a-z0-9_]{1,40}$').hasMatch(c)) {
    return 'A code is lower-case letters, digits and underscores, '
        'starting with a letter — for example co_operative.';
  }
  return null;
}

class _EntityTypeDialog extends ConsumerStatefulWidget {
  const _EntityTypeDialog({required this.existing});

  final EntityType? existing;

  @override
  ConsumerState<_EntityTypeDialog> createState() => _EntityTypeDialogState();
}

class _EntityTypeDialogState extends ConsumerState<_EntityTypeDialog> {
  late final _code = TextEditingController(text: widget.existing?.code ?? '');
  late final _label = TextEditingController(text: widget.existing?.label ?? '');
  late final _labelMy = TextEditingController(
    text: widget.existing?.labelMy ?? '',
  );
  late final _order = TextEditingController(
    text: '${widget.existing?.sortOrder ?? 100}',
  );
  late bool _active = widget.existing?.isActive ?? true;
  late bool _public = widget.existing?.isPublicCompany ?? false;
  late bool _forContacts = widget.existing?.forContacts ?? true;
  late bool _forOrgs = widget.existing?.forOrganizations ?? true;
  bool _busy = false;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    _code.dispose();
    _label.dispose();
    _labelMy.dispose();
    _order.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final problem = entityTypeProblem(
      code: _code.text,
      label: _label.text,
      isNew: _isNew,
    );
    if (problem != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    // The same rule the landing console learned: an unreadable order is
    // not "leave it", it is a typo, and a save that silently kept the
    // old number while saying "Saved" is how a list stops matching what
    // somebody sees.
    final order = int.tryParse(_order.text.trim());
    if (_order.text.trim().isNotEmpty && order == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The order has to be a whole number.')),
      );
      return;
    }

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => ref
          .read(entityTypesRepoProvider)
          .save(
            code: _isNew ? _code.text.trim() : widget.existing!.code,
            label: _label.text.trim(),
            labelMy: _labelMy.text.trim(),
            sortOrder: order,
            isActive: _active,
            isPublicCompany: _public,
            forContacts: _forContacts,
            forOrganizations: _forOrgs,
          ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: 'Remove ${widget.existing!.label}?',
      message:
          'Only a kind nothing is filed as can be removed. If anything '
          'is, switch it off instead — a contact filed as a kind stays '
          'filed as it.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    final done = await runWithFeedback(
      context,
      successMessage: 'Removed',
      action: () =>
          ref.read(entityTypesRepoProvider).remove(widget.existing!.code),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (done) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: context.scheme.onSurfaceVariant,
    );

    return AlertDialog(
      title: Text(_isNew ? 'Add a kind of business' : 'Edit the kind'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('entity-type-code'),
                controller: _code,
                // The code is written onto every contact filed as this
                // kind. Changing it afterwards would be renaming a value
                // that is already in rows, so it is fixed once set.
                enabled: _isNew && !_busy,
                decoration: InputDecoration(
                  labelText: 'Code',
                  helperText: _isNew
                      ? 'Lower case, no spaces. Cannot be changed later.'
                      : 'Set when the kind was added and fixed since.',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('entity-type-label'),
                controller: _label,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _labelMy,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Name in Malay',
                  helperText: 'Optional. The English name is used when '
                      'there is none.',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('entity-type-order'),
                controller: _order,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Order',
                  helperText: 'Lower comes first.',
                ),
              ),
              const Divider(height: Space.xl),
              SwitchListTile(
                key: const ValueKey('entity-type-public'),
                contentPadding: EdgeInsets.zero,
                value: _public,
                onChanged: _busy ? null : (v) => setState(() => _public = v),
                title: const Text('A public company'),
                subtitle: Text(
                  'Decides how its accounts are filed to MBRS. Berhad is '
                  'the one this shipped with. Leave it off unless the kind '
                  'really is a public company.',
                  style: muted,
                ),
              ),
              SwitchListTile(
                key: const ValueKey('entity-type-contacts'),
                contentPadding: EdgeInsets.zero,
                value: _forContacts,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _forContacts = v),
                title: const Text('Offered when adding a contact'),
              ),
              SwitchListTile(
                key: const ValueKey('entity-type-orgs'),
                contentPadding: EdgeInsets.zero,
                value: _forOrgs,
                onChanged: _busy ? null : (v) => setState(() => _forOrgs = v),
                title: const Text('Offered when registering a company'),
              ),
              SwitchListTile(
                key: const ValueKey('entity-type-active'),
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: _busy ? null : (v) => setState(() => _active = v),
                title: const Text('On'),
                subtitle: Text(
                  'Off takes it out of every dropdown. Anything already '
                  'filed as it stays filed as it.',
                  style: muted,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (!_isNew && !widget.existing!.isBuiltin)
          TextButton(
            key: const ValueKey('entity-type-delete'),
            onPressed: _busy ? null : _delete,
            child: Text(
              'Remove',
              style: TextStyle(color: context.colors.danger),
            ),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('entity-type-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
