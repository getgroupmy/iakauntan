import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_live.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/search_registers_repository.dart';

/// The registers Entity Search offers, from the operator's side.
///
/// `0606`. The button used to say "Check the SSM register" and knew
/// about one register; a contact can as easily be an audit firm or a
/// law firm, and the register that knows about each of those is a
/// different one.
///
/// ## The one field that is not a label
///
/// `can_search` says whether this application can ASK the register.
/// It is not a to-do list: SSM answers, MIA's register is behind a bot
/// challenge with no API, and nobody has established what the Bar
/// offers. Switching it on for a register nothing knows how to search
/// does not make a search appear — the picker falls back to opening
/// the register's own site — but it does take away the words that told
/// somebody that is what would happen.
class SearchRegistersAdminTab extends ConsumerWidget {
  const SearchRegistersAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registers = ref.watch(allSearchRegistersProvider);

    return AsyncView(
      value: registers,
      onRetry: () => ref.invalidate(allSearchRegistersProvider),
      skeleton: const ListSkeleton(rows: 6, trailing: false),
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
                        'Entity Search',
                        subtitle:
                            'The registers offered when somebody looks a '
                            'contact up. Lower order comes first.',
                        action: FilledButton.tonalIcon(
                          key: const ValueKey('register-add'),
                          onPressed: () => _edit(context, ref, null),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add a register'),
                        ),
                      ),
                      if (rows.isEmpty)
                        const Text('No registers on the list.')
                      else
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _RegisterRow(
                            register: rows[i],
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
                        'Which of them answer',
                        subtitle: 'And which only open a page',
                      ),
                      Text(
                        'SSM answers: a search here returns rows. MIA does '
                        'not — its register is behind a bot challenge with '
                        'no API, so choosing it opens MIA’s own page. '
                        'Nobody has established what the Malaysian Bar '
                        'offers, so it does the same.\n\n'
                        'Switching “can be searched” on does not make a '
                        'search exist. Where nothing here knows how to ask '
                        'a register, choosing it still opens its site — but '
                        'the words that told somebody that is what would '
                        'happen are gone.',
                        key: const ValueKey('register-note'),
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
    SearchRegister? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _RegisterDialog(existing: existing),
    );
    if (saved == true) {
      ref.invalidate(allSearchRegistersProvider);
      invalidatePlatformTable(ref, 'search_registers');
    }
  }
}

class _RegisterRow extends StatelessWidget {
  const _RegisterRow({required this.register, required this.onTap});

  final SearchRegister register;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: context.scheme.onSurfaceVariant,
    );

    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: SizedBox(
        width: 44,
        child: Text('${register.sortOrder}', style: muted),
      ),
      title: Row(
        children: [
          Flexible(child: Text(register.name)),
          if (!register.isActive) ...[
            const SizedBox(width: Space.sm),
            const StatusChip('off', compact: true),
          ],
        ],
      ),
      subtitle: Text(
        [
          if (register.registers != null) register.registers!,
          register.canSearch ? 'searched from here' : 'opens their own site',
          if (register.isBuiltin) 'built in',
        ].join(' · '),
        style: muted,
      ),
    );
  }
}

/// Why a register cannot be saved, in the words to show — or null.
///
/// The address rule is the one worth having on the screen as well as in
/// the function: a register this application cannot search and that has
/// nowhere to send somebody is a choice that does nothing when it is
/// picked, and that is invisible until a user picks it.
String? searchRegisterProblem({
  required String code,
  required String name,
  required bool canSearch,
  required String url,
  required bool isNew,
}) {
  if (name.trim().isEmpty) return 'A register needs a name.';
  if (!canSearch && url.trim().isEmpty) {
    return 'A register this cannot search needs an address, so somebody '
        'can go and look.';
  }
  if (!isNew) return null;
  final c = code.trim();
  if (c.isEmpty) return 'A register needs a code.';
  if (!RegExp(r'^[a-z][a-z0-9_]{1,40}$').hasMatch(c)) {
    return 'A code is lower-case letters, digits and underscores, '
        'starting with a letter — for example bursa.';
  }
  return null;
}

class _RegisterDialog extends ConsumerStatefulWidget {
  const _RegisterDialog({required this.existing});

  final SearchRegister? existing;

  @override
  ConsumerState<_RegisterDialog> createState() => _RegisterDialogState();
}

class _RegisterDialogState extends ConsumerState<_RegisterDialog> {
  late final _code = TextEditingController(text: widget.existing?.code ?? '');
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _registers = TextEditingController(
    text: widget.existing?.registers ?? '',
  );
  late final _url = TextEditingController(text: widget.existing?.url ?? '');
  late final _order = TextEditingController(
    text: '${widget.existing?.sortOrder ?? 100}',
  );
  late bool _canSearch = widget.existing?.canSearch ?? false;
  late bool _active = widget.existing?.isActive ?? true;
  bool _busy = false;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _registers.dispose();
    _url.dispose();
    _order.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final problem = searchRegisterProblem(
      code: _code.text,
      name: _name.text,
      canSearch: _canSearch,
      url: _url.text,
      isNew: _isNew,
    );
    if (problem != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
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
          .read(searchRegistersRepoProvider)
          .save(
            code: _isNew ? _code.text.trim() : widget.existing!.code,
            name: _name.text.trim(),
            registers: _registers.text.trim(),
            canSearch: _canSearch,
            url: _url.text.trim(),
            sortOrder: order,
            isActive: _active,
          ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: 'Remove ${widget.existing!.name}?',
      message:
          'It stops being offered under Entity Search. Switching it off '
          'does the same and can be undone.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    final done = await runWithFeedback(
      context,
      successMessage: 'Removed',
      action: () =>
          ref.read(searchRegistersRepoProvider).remove(widget.existing!.code),
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
      title: Text(_isNew ? 'Add a register' : 'Edit the register'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('register-code'),
                controller: _code,
                // The code is what a recorded lookup names, so it is
                // fixed once set.
                enabled: _isNew && !_busy,
                decoration: InputDecoration(
                  labelText: 'Code',
                  helperText: _isNew
                      ? 'Lower case, no spaces. Cannot be changed later.'
                      : 'Set when the register was added and fixed since.',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('register-name'),
                controller: _name,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'What it is called: SSM, MIA, Malaysian Bar.',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _registers,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'What it registers',
                  helperText: 'Companies and businesses; accountants and '
                      'audit firms. This is what tells somebody whether '
                      'to pick it.',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('register-url'),
                controller: _url,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  helperText: 'Where somebody goes when this cannot be '
                      'searched from here.',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('register-order'),
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
                key: const ValueKey('register-can-search'),
                contentPadding: EdgeInsets.zero,
                value: _canSearch,
                onChanged: _busy ? null : (v) => setState(() => _canSearch = v),
                title: const Text('Can be searched from here'),
                subtitle: Text(
                  'Only SSM can today. Switching this on does not make a '
                  'search exist — it takes away the words telling somebody '
                  'the register will open instead.',
                  style: muted,
                ),
              ),
              SwitchListTile(
                key: const ValueKey('register-active'),
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: _busy ? null : (v) => setState(() => _active = v),
                title: const Text('Offered'),
                subtitle: Text(
                  'Off takes it out of Entity Search.',
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
            key: const ValueKey('register-delete'),
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
          key: const ValueKey('register-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
