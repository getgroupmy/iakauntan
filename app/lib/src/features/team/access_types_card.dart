import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Access types: a company's own answer to "who may see what".
///
/// The ten built-in roles decide what *kind* of thing somebody may do —
/// post to the ledger, run payroll, administer the company — and every
/// company gets the same ten whether they fit or not. An access type
/// says which *modules* a person may reach and whether they may change
/// anything there. Both have to say yes, so an access type can only take
/// away; it is not a way to hand somebody the ledger.
///
/// The rule lives in the database, in the restrictive policies 0127
/// added. This card is where somebody writes it down.
class AccessTypesCard extends ConsumerWidget {
  const AccessTypesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final types = ref.watch(accessTypesProvider);

    Future<void> open([AccessType? existing]) async {
      final changed = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _AccessTypeSheet(existing: existing),
      );
      if (changed == true) {
        ref.invalidate(accessTypesProvider);
        ref.invalidate(teamProvider);
        ref.invalidate(myModuleAccessProvider);
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Access types',
              subtitle: 'Which modules a person may reach, and whether they '
                  'may change anything there',
              action: TextButton.icon(
                onPressed: () => open(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New'),
              ),
            ),
            AsyncView(
              value: types,
              onRetry: () => ref.invalidate(accessTypesProvider),
              skeleton: const ListSkeleton(rows: 3, leading: false),
              builder: (list) => list.isEmpty
                  // Said plainly, because "none" here is not a gap to be
                  // nagged about. Every member has full access to the
                  // modules the company holds, which is a perfectly good
                  // way for a small company to run.
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'None yet. Everybody reaches every module the '
                        'company has.',
                        style: TextStyle(fontSize: 13),
                      ),
                    )
                  : Column(
                      children: [
                        for (final t in list)
                          ListTile(
                            key: ValueKey('access-type-${t.name}'),
                            contentPadding: EdgeInsets.zero,
                            title: Text(t.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              t.grantedCount == 0
                                  ? 'No modules — reaches nothing'
                                  : '${t.grantedCount} '
                                      '${t.grantedCount == 1 ? "module" : "modules"}'
                                      '${t.description == null ? "" : " · ${t.description}"}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: () => open(t),
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

class _AccessTypeSheet extends ConsumerStatefulWidget {
  const _AccessTypeSheet({this.existing});

  final AccessType? existing;

  @override
  ConsumerState<_AccessTypeSheet> createState() => _AccessTypeSheetState();
}

class _AccessTypeSheetState extends ConsumerState<_AccessTypeSheet> {
  final _name = TextEditingController();
  final _description = TextEditingController();

  /// Held here and written as it changes, so the sheet is a live view of
  /// the access type rather than a form with a Save button that could be
  /// closed without pressing it.
  late Map<String, String> _modules;
  String? _id;
  bool _busy = false;
  bool _changed = false;

  bool get _isNew => _id == null;

  @override
  void initState() {
    super.initState();
    _id = widget.existing?.id;
    _name.text = widget.existing?.name ?? '';
    _description.text = widget.existing?.description ?? '';
    _modules = Map<String, String>.from(widget.existing?.modules ?? const {});
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _createFirst() async {
    setState(() => _busy = true);
    String? id;
    final ok = await runWithFeedback(
      context,
      action: () async {
        id = await ref.read(repoProvider)!.createAccessType(
              _name.text.trim(),
              description: _description.text.trim(),
            );
      },
      successMessage: 'Access type created',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _id = id;
        _changed = true;
      }
    });
  }

  Future<void> _setModule(String code, String access) async {
    // A brand new access type has no id to hang modules off yet, so the
    // name has to be saved first. Asking for it up front rather than
    // failing on the first switch.
    if (_id == null) return;

    final previous = _modules[code] ?? 'none';
    setState(() => _modules[code] = access);

    // Deliberately not `runWithFeedback`: this fires on every press, and
    // a company setting up six modules does not need six confirmations
    // that nothing went wrong. A failure still has to be said out loud.
    try {
      await ref.read(repoProvider)!.setModuleAccess(_id!, code, access);
      if (mounted) setState(() => _changed = true);
    } catch (e) {
      if (!mounted) return;
      // Put it back. A switch resting where it was moved while the
      // database says otherwise is worse than no switch at all.
      setState(() => _modules[code] = previous);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: ${errorText(e)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(platformModulesProvider).value ?? const [];
    final entitled = ref.watch(enabledModulesProvider).value ?? const <String>{};

    // Only the modules this company actually has. Offering to grant
    // access to one they have not bought would be writing down a
    // permission that can never do anything.
    final modules = catalog.where((m) => entitled.contains(m.code)).toList();

    // Actions inside those modules that a company can hand out on their
    // own. Not sold and never in the entitlement list, so they are
    // filtered by the module they live in instead.
    final permissions = [
      for (final p in ref.watch(accessPermissionsProvider).value ?? const [])
        if (entitled.contains('${p['module_code']}')) p,
    ];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: ListView(
          controller: scroll,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_isNew ? 'New access type' : _name.text,
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(_changed),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('access-type-name'),
              controller: _name,
              enabled: !_busy,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Purchasing clerk, Read-only partner…',
              ),
            ),
            const SizedBox(height: Space.sm),
            TextField(
              controller: _description,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'Optional',
              ),
            ),
            const SizedBox(height: Space.md),
            if (_isNew)
              FilledButton(
                onPressed: _name.text.trim().isEmpty || _busy
                    ? null
                    : _createFirst,
                child: const Text('Create, then choose modules'),
              )
            else ...[
              Text('Modules',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              const Text(
                'Anything not granted here is out of reach. The person '
                'still needs the right role for what they do inside a '
                'module — this only decides which ones they see.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: Space.sm),
              for (final m in modules)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(child: Text(m.name)),
                      SegmentedButton<String>(
                        key: ValueKey('module-access-${m.code}'),
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                        segments: const [
                          ButtonSegment(value: 'none', label: Text('None')),
                          ButtonSegment(value: 'read', label: Text('Read')),
                          ButtonSegment(value: 'write', label: Text('Write')),
                        ],
                        selected: {_modules[m.code] ?? 'none'},
                        onSelectionChanged: _busy
                            ? null
                            : (s) => _setModule(m.code, s.first),
                      ),
                    ],
                  ),
                ),
              if (permissions.isNotEmpty) ...[
                const SizedBox(height: Space.md),
                Text('Inside those modules',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                const Text(
                  'Granted the same way and by the same rule: not listed '
                  'is not allowed. Somebody with no access type at all '
                  'still has all of these, which is how every company '
                  'stands until it says otherwise.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: Space.sm),
                for (final p in permissions)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${p['name']}'),
                              if (p['description'] != null)
                                Text(
                                  '${p['description']}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Space.sm),
                        // Two states, not three: an action is done or
                        // it is not. "Read" would be a word with no
                        // meaning here.
                        Switch(
                          key: ValueKey('permission-${p['code']}'),
                          value: _modules['${p['code']}'] == 'write',
                          onChanged: _busy
                              ? null
                              : (on) => _setModule(
                                  '${p['code']}',
                                  on ? 'write' : 'none',
                                ),
                        ),
                      ],
                    ),
                  ),
              ],
              const Divider(height: Space.xl),
              Row(
                children: [
                  TextButton(
                    onPressed: _busy ? null : _rename,
                    child: const Text('Save name'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _busy ? null : _retire,
                    child: Text('Retire',
                        style: TextStyle(color: context.colors.danger)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _rename() async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.renameAccessType(
            _id!,
            _name.text.trim(),
            description: _description.text.trim(),
          ),
      successMessage: 'Saved',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _changed = true;
    });
  }

  Future<void> _retire() async {
    final sure = await confirm(
      context,
      title: 'Retire ${_name.text}?',
      message: 'Anybody holding it goes back to reaching every module the '
          'company has. Nothing they have already done is affected.',
      confirmLabel: 'Retire',
      destructive: true,
    );
    if (!sure || !mounted) return;

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.retireAccessType(_id!),
      successMessage: 'Access type retired',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok && mounted) Navigator.of(context).pop(true);
  }
}
