import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import 'line_draft.dart';

/// What a line should keep when an item is put on it, asked rather than
/// decided.
///
/// Reported twice from the same scanned bill. First the description --
/// four lines of the supplier's own wording replaced by the item
/// master's name without a word. Then, once that was asked about, the
/// rest of it:
///
///     why when the item number is keyed in replace the unit price
///     disc% tax and amount
///
/// The price read off the paper was 23.3332258 and the item's was zero,
/// so the line went to RM 0.00 and the amount with it.
///
/// Every value is on screen, current beside suggested, because the
/// question cannot be answered without seeing them. And every row is its
/// own choice, which is the other half of what was asked: "ask in the
/// prompt to add or update the tax without changing the value" -- taking
/// the item's tax code while keeping the price off the paper is a normal
/// thing to want, and an all-or-nothing prompt cannot express it.
///
/// Returns the parts to take FROM THE ITEM. **A dismissal returns null
/// and the caller keeps everything** -- the destructive answer is never
/// the one pressing Escape gives.
///
/// The item is bound either way. This asks which of its VALUES to copy;
/// the line still points at the item afterwards, which is what putting a
/// number in the item box is for.
Future<Set<LinePart>?> askWhatToTake(
  BuildContext context, {
  required List<ItemChange> changes,
}) =>
    showDialog<Set<LinePart>>(
      context: context,
      builder: (context) => _WhatToTakeDialog(changes: changes),
    );

class _WhatToTakeDialog extends StatefulWidget {
  const _WhatToTakeDialog({required this.changes});

  final List<ItemChange> changes;

  @override
  State<_WhatToTakeDialog> createState() => _WhatToTakeDialogState();
}

class _WhatToTakeDialogState extends State<_WhatToTakeDialog> {
  /// Empty: everything defaults to KEEP.
  ///
  /// The safe way round, and the way round this was asked for. What was
  /// reported is values disappearing, so the button somebody presses
  /// without reading must not be the one that loses them.
  final _take = <LinePart>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final one = widget.changes.length == 1;

    return AlertDialog(
      title: Text(one
          ? 'Replace the ${widget.changes.single.label.toLowerCase()}?'
          : 'What should this line keep?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              one
                  ? 'This line already has one. The item has its own.'
                  : 'This line already has values of its own. Choose what '
                      'the item should replace.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            for (final change in widget.changes) ...[
              _Row(
                change: change,
                take: _take.contains(change.part),
                onChanged: (v) => setState(() {
                  if (v) {
                    _take.add(change.part);
                  } else {
                    _take.remove(change.part);
                  }
                }),
              ),
              const SizedBox(height: Space.md),
            ],
            if (!one)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('item-apply-take-all'),
                  onPressed: () => setState(
                      () => _take.addAll(widget.changes.map((c) => c.part))),
                  child: const Text("Use the item's for all of them"),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('item-apply-keep'),
          onPressed: () => Navigator.pop(context, <LinePart>{}),
          child: Text(one ? 'Keep what is there' : 'Keep all of mine'),
        ),
        FilledButton(
          key: const ValueKey('item-apply-confirm'),
          onPressed: () => Navigator.pop(context, {..._take}),
          child: Text(_take.isEmpty ? 'Apply nothing' : 'Apply'),
        ),
      ],
    );
  }
}

/// One field: what it says now, what the item would put there, and the
/// choice between them.
class _Row extends StatelessWidget {
  const _Row({
    required this.change,
    required this.take,
    required this.onChanged,
  });

  final ItemChange change;
  final bool take;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(change.label,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Space.xs),
        _Side(
          key: ValueKey('item-apply-current-${change.part.name}'),
          label: 'On the line now',
          text: change.current,
          chosen: !take,
        ),
        const SizedBox(height: 4),
        _Side(
          key: ValueKey('item-apply-suggested-${change.part.name}'),
          label: 'From the item',
          text: change.suggested,
          chosen: take,
        ),
        const SizedBox(height: Space.xs),
        // A switch and not two buttons: with four fields on screen, two
        // buttons each is eight targets and no sense of which way each
        // row is set.
        SwitchListTile(
          key: ValueKey('item-apply-switch-${change.part.name}'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: take,
          onChanged: onChanged,
          title: Text(
            take ? "Use the item's" : 'Keep what is there',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// One of the two values, labelled and boxed so they read as a pair
/// rather than as a paragraph. The chosen one is marked, because with
/// several rows on screen the switch alone is easy to lose.
class _Side extends StatelessWidget {
  const _Side({
    super.key,
    required this.label,
    required this.text,
    required this.chosen,
  });

  final String label;
  final String text;
  final bool chosen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: chosen
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: chosen
            ? Border.all(color: theme.colorScheme.primary, width: 1.5)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          // Selectable, because the answer is sometimes "neither of
          // those, but I want to paste half of one".
          SelectableText(
            text.trim().isEmpty ? '(empty)' : text,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

/// Which parts of [item] to copy onto [line], asking where that would
/// overwrite something somebody put there.
///
/// One function, because the editor answers this question TWICE -- once
/// in the wide grid and once in the narrow card -- and this file's own
/// subject is a drift between those two copies: the narrow one once set
/// everything except the tax code, so a line added on a phone silently
/// carried no SST.
///
/// Returns null where the editor went away while the question was on
/// screen; the caller applies nothing at all then, because it has no
/// boxes left to put an answer in.
Future<Set<LinePart>?> whatToTakeFrom(
  BuildContext context, {
  required LineDraft line,
  required Item item,
  required List<TaxCode> taxCodes,
  Item? previous,
}) async {
  final changes =
      itemWouldOverwrite(line, item, taxCodes, previous: previous);
  // Nothing worth asking about: a blank line takes the item's
  // everything without a word, which is the ordinary case.
  if (changes.isEmpty) return LinePart.values.toSet();

  final answer = await askWhatToTake(context, changes: changes);
  if (!context.mounted) return null;

  // Whatever was NOT in question is always taken -- those are the
  // fields the line had nothing of its own in. A dismissal is null and
  // keeps everything that WAS in question.
  final asked = changes.map((c) => c.part).toSet();
  return {
    ...LinePart.values.where((p) => !asked.contains(p)),
    ...?answer,
  };
}
