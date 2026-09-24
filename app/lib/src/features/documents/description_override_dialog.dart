import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import 'line_draft.dart';

/// Which description this line should carry, asked rather than decided.
///
/// Reported from a bill scanned off a supplier's PDF. The reading had
/// filled four lines with "Google Workspace Business Starter Usage",
/// an item was assigned afterwards, and every one of them was replaced
/// by the item master's name without a word — and the supplier's own
/// wording is often the more useful of the two, because it is what the
/// paper says and what somebody reconciling the bill will look for.
///
/// Both texts are on screen, side by side, because the question cannot
/// be answered without seeing them: "override the description?" with
/// neither of them shown is a question about an abstraction.
///
/// Returns true to take the item's, false to keep what is there. **A
/// dismissal returns null and the caller keeps what is there** — the
/// destructive answer is never the default one, and pressing Escape
/// must not lose a line of somebody's typing.
///
/// The rest of the item is applied either way. This is a question about
/// the description and nothing else: the price, the unit, the tax code
/// and the classification come from the item whichever way it is
/// answered, because those are what binding a line to an item is FOR.
Future<bool?> askDescriptionOverride(
  BuildContext context, {
  required String current,
  required String suggested,
}) =>
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace the description?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'This line already says something. The item has a name of '
                'its own.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              _Side(
                key: const ValueKey('description-override-current'),
                label: 'On the line now',
                text: current,
              ),
              const SizedBox(height: Space.sm),
              _Side(
                key: const ValueKey('description-override-suggested'),
                label: 'From the item',
                text: suggested,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('description-override-keep'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep what is there'),
          ),
          FilledButton(
            key: const ValueKey('description-override-take'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Use the item's"),
          ),
        ],
      ),
    );

/// The description a line should end up with once [item] is applied.
///
/// One function, because the editor answers this question TWICE — once
/// in the wide grid and once in the narrow card — and this file's own
/// subject is a drift between those two copies: the narrow one once set
/// everything except the tax code, so a line added on a phone silently
/// carried no SST. Two copies of a judgement is two copies that drift.
///
/// Returns the text to use, or **null where the editor went away while
/// the question was on screen** — the caller applies nothing at all
/// then, because it has no box left to put an answer in.
Future<String?> descriptionAfterApplying(
  BuildContext context, {
  required String current,
  required Item item,
  String? boundItemName,
}) async {
  if (!descriptionIsWorthKeeping(
    current: current,
    suggested: item.name,
    boundItemName: boundItemName,
  )) {
    return item.name;
  }

  final answer = await askDescriptionOverride(
    context,
    current: current,
    suggested: item.name,
  );
  if (!context.mounted) return null;
  // A dismissal is null and KEEPS what is there. The destructive answer
  // is never the one pressing Escape gives.
  return answer == true ? item.name : current;
}

/// One of the two texts, labelled and boxed so they read as a pair
/// rather than as a paragraph.
class _Side extends StatelessWidget {
  const _Side({super.key, required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Space.sm),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          // Selectable, because the answer is sometimes "neither of
          // those, but I want to paste half of one".
          child: SelectableText(
            text.trim().isEmpty ? '(empty)' : text,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}
