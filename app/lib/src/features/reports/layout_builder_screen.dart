import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'layout_builder.dart';

/// Where a company decides what its P&L says.
///
/// `0637`. The rows are reordered, renamed and re-selected here; the
/// arithmetic stays in the database, so what this screen edits is the
/// LAYOUT and never the figures.
///
/// Reachable from the reports screen. A company that has never opened
/// it has no stored layout at all and its reports come from
/// `app.builtin_layout_rows` — so this screen's first act, for most
/// companies, is to copy that standard layout into something editable.
class LayoutBuilderScreen extends ConsumerStatefulWidget {
  const LayoutBuilderScreen({super.key, required this.kind});

  /// `profit_loss` or `balance_sheet`.
  final String kind;

  @override
  ConsumerState<LayoutBuilderScreen> createState() =>
      LayoutBuilderScreenState();
}

class LayoutBuilderScreenState extends ConsumerState<LayoutBuilderScreen> {
  List<LayoutRow>? _rows;
  String? _layoutId;
  bool _busy = false;
  String? _error;

  String get _title =>
      widget.kind == 'profit_loss' ? 'Profit & loss layout' : 'Balance sheet layout';

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider)!;
      final layouts = await repo.reportLayouts(widget.kind);
      final active = _layoutId == null
          ? layouts.where((l) => l.isActive).firstOrNull
          : layouts.where((l) => l.id == _layoutId).firstOrNull;
      // No layout means this company is on the standard one, which is
      // not stored. Copying it is what makes it editable, and it is
      // the only write this screen makes without being asked.
      final id = active?.id ??
          await repo.createLayoutFromBuiltin(widget.kind);
      final rows = await repo.layoutRows(id);
      if (!mounted) return;
      setState(() {
        _layoutId = id;
        _rows = rows;
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _save() async {
    final rows = _rows;
    final id = _layoutId;
    if (rows == null || id == null) return;

    final problem = layoutProblem(rows);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(repoProvider)!.saveLayoutRows(id, rows);
      // Every report the layout feeds, not just the one behind this
      // screen: a balance sheet left showing the old arrangement after
      // a save reads as the save having failed.
      ref.invalidate(reportLayoutsProvider(widget.kind));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _onMenu(String choice) async {
    final repo = ref.read(repoProvider)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (choice == 'new') {
        _layoutId = await repo.createLayoutFromBuiltin(widget.kind);
      } else if (choice == 'retire') {
        await repo.archiveReportLayout(_layoutId!);
        // Retiring the active one leaves the company on the standard
        // layout, which still draws — so the screen reloads onto a
        // fresh copy rather than onto nothing.
        _layoutId = null;
      } else if (choice.startsWith('use:')) {
        await repo.activateReportLayout(choice.substring(4));
        _layoutId = null;
      }
      ref.invalidate(reportLayoutsProvider(widget.kind));
      if (!mounted) return;
      setState(() => _rows = null);
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  void _move(int from, int to) {
    final rows = _rows;
    if (rows == null) return;
    final next = moveRow(rows, from, to);
    if (next == null) {
      // The move would have put a formula above something it needs.
      // Said rather than silently ignored, because a button that does
      // nothing reads as broken.
      setState(() => _error =
          'That row cannot move there: a total has to come after the '
          'rows it adds up.');
      return;
    }
    setState(() {
      _rows = next;
      _error = null;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          // The layouts this company keeps for this report. A firm
          // that maintains a statutory layout and a management one
          // switches between them here rather than rebuilding.
          Consumer(
            builder: (context, ref, _) {
              final layouts =
                  ref.watch(reportLayoutsProvider(widget.kind)).valueOrNull ??
                      const <ReportLayout>[];
              if (layouts.length < 2 && _layoutId == null) {
                return const SizedBox.shrink();
              }
              return PopupMenuButton<String>(
                key: const ValueKey('layout-menu'),
                tooltip: 'Layouts',
                itemBuilder: (_) => [
                  for (final l in layouts)
                    PopupMenuItem(
                      value: 'use:${l.id}',
                      child: Row(children: [
                        Icon(
                          l.isActive
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 16,
                        ),
                        const SizedBox(width: Space.sm),
                        Expanded(child: Text(l.name)),
                      ]),
                    ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'new',
                    child: Text('Start another from the standard one'),
                  ),
                  if (_layoutId != null)
                    const PopupMenuItem(
                      value: 'retire',
                      child: Text('Retire this layout'),
                    ),
                ],
                onSelected: _onMenu,
              );
            },
          ),
          TextButton(
            key: const ValueKey('layout-save'),
            onPressed: _busy || rows == null ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: rows == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Space.lg),
              children: [
                Text(
                  'The order here is the order on the report. A total '
                  'can only add up rows above it.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: Space.md),
                if (_error != null) ...[
                  Card(
                    color: context.colors.danger.withValues(alpha: 0.08),
                    child: Padding(
                      padding: const EdgeInsets.all(Space.md),
                      child: Text(
                        _error!,
                        key: const ValueKey('layout-error'),
                        style: TextStyle(color: context.colors.danger),
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.md),
                ],
                for (var i = 0; i < rows.length; i++)
                  _RowTile(
                    key: ValueKey('layout-row-${rows[i].rowKey}'),
                    row: rows[i],
                    onUp: i == 0 ? null : () => _move(i, i - 1),
                    onDown:
                        i == rows.length - 1 ? null : () => _move(i, i + 1),
                    onRename: (name) => setState(() {
                      // The KEY is left alone on a rename, which is why
                      // it exists: a formula pointing at this row keeps
                      // pointing at it.
                      _rows = [...rows]..[i] = rows[i].copyWith(label: name);
                    }),
                    onRemove: rows.length == 1
                        ? null
                        : () => setState(() {
                              final next = [...rows]..removeAt(i);
                              final problem = layoutProblem(next);
                              if (problem != null) {
                                _error =
                                    'That row cannot go: a total below '
                                    'it adds it up.';
                                return;
                              }
                              _rows = next;
                              _error = null;
                            }),
                  ),
              ],
            ),
    );
  }
}

class _RowTile extends StatelessWidget {
  const _RowTile({
    super.key,
    required this.row,
    this.onUp,
    this.onDown,
    this.onRename,
    this.onRemove,
  });

  final LayoutRow row;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final void Function(String)? onRename;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            SizedBox(width: row.depth * 16.0),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.label,
                    style: TextStyle(
                      fontWeight:
                          row.emphasise ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(layoutRowSummary(row), style: muted),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_upward, size: 18),
              tooltip: 'Move up',
              onPressed: onUp,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_downward, size: 18),
              tooltip: 'Move down',
              onPressed: onDown,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: 'Remove',
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}
