import 'package:flutter/material.dart';

import 'theme.dart';

/// One thing a list row offers to do.
class RowAction {
  const RowAction({
    required this.label,
    required this.onTap,
    this.actionKey,
    this.icon,
    this.iconOnly = false,
    this.emphasis = RowActionEmphasis.plain,
  });

  final String label;
  final VoidCallback onTap;

  /// A key of its own, so two rows in one list do not collide and a
  /// test can name the row it means.
  final String? actionKey;

  final IconData? icon;

  /// Shown as an icon alone on a wide screen, with [label] as its
  /// tooltip. In the MENU it is a normal line with its words on it,
  /// because a menu of unlabelled icons is a menu nobody can read.
  /// Requires [icon].
  final bool iconOnly;

  /// How much the wide layout should shout. Ignored in the menu, where
  /// every entry looks the same and the order carries the emphasis.
  final RowActionEmphasis emphasis;
}

enum RowActionEmphasis { plain, outlined, filled }

/// A row's actions: buttons on a wide screen, ONE MENU on a phone.
///
/// `ListTile` hands its `trailing` the width it asks for and gives the
/// title and subtitle whatever is left. Nothing warns when that is
/// nothing — the text is not overflowing its box, it has been GIVEN a
/// box two pixels wide, and it wraps the only way it can: one letter
/// per line, a tall column of single characters.
///
/// That shipped, on the items list, where a row carried a price and
/// four buttons wanting about 600 logical pixels on a screen with 440.
/// This is the shape that stops it happening again, and
/// `scripts/check_narrow_rows.py` fails a build that grows a wide
/// trailing without one.
///
/// WHY A MENU RATHER THAN A WRAP. Wrapping the buttons onto a second
/// line makes every row in the list twice as tall for the sake of a
/// button most people will not press, and a list you scroll twice as
/// far is a worse list. The menu costs one tap and nothing else.
class RowActions extends StatelessWidget {
  const RowActions({
    super.key,
    required this.actions,
    this.leading,
    this.narrowAt = 700,
    this.menuKey,
    this.menuTooltip = 'More',
  });

  /// In the order they should appear, and in the order they appear in
  /// the menu. The first is the one somebody reaches for.
  final List<RowAction> actions;

  /// What sits before them and stays put at every width — a price, a
  /// chip, a status. It is not an action, so it is never in the menu.
  final Widget? leading;

  /// Below this width the buttons become a menu. 700 is the threshold
  /// the rest of the product uses to mean "a phone or a narrow window".
  final double narrowAt;

  final String? menuKey;
  final String menuTooltip;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < narrowAt;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) leading!,
        if (actions.isEmpty)
          const SizedBox.shrink()
        else if (narrow)
          PopupMenuButton<int>(
            // `ValueKey<String?>` is NOT equal to `ValueKey<String>` —
            // the type is part of the equality — so a nullable field
            // passed straight in makes a key no `find.byKey` will ever
            // match. The generic is written out for that reason.
            key: menuKey == null ? null : ValueKey<String>(menuKey!),
            tooltip: menuTooltip,
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (i) => actions[i].onTap(),
            itemBuilder: (_) => [
              for (var i = 0; i < actions.length; i++)
                PopupMenuItem<int>(
                  value: i,
                  key: actions[i].actionKey == null
                      ? null
                      : ValueKey<String>(actions[i].actionKey!),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (actions[i].icon != null) ...[
                        Icon(actions[i].icon, size: 18),
                        const SizedBox(width: Space.sm),
                      ],
                      // Flexible, because a menu on a 360px phone is
                      // narrower than a label like "Move to
                      // Shortlisted" and an unflexed Text in a Row
                      // overflows rather than wrapping.
                      Flexible(child: Text(actions[i].label)),
                    ],
                  ),
                ),
            ],
          )
        else
          for (final action in actions) ...[
            const SizedBox(width: Space.sm),
            _button(action),
          ],
      ],
    );
  }

  Widget _button(RowAction action) {
    final key = action.actionKey == null
        ? null
        : ValueKey<String>(action.actionKey!);
    if (action.iconOnly && action.icon != null) {
      return IconButton(
        key: key,
        tooltip: action.label,
        icon: Icon(action.icon, size: 18),
        onPressed: action.onTap,
      );
    }
    final label = Text(action.label);
    return switch (action.emphasis) {
      RowActionEmphasis.filled => FilledButton.tonal(
        key: key,
        onPressed: action.onTap,
        child: label,
      ),
      RowActionEmphasis.outlined => OutlinedButton(
        key: key,
        onPressed: action.onTap,
        child: label,
      ),
      RowActionEmphasis.plain => TextButton(
        key: key,
        onPressed: action.onTap,
        child: label,
      ),
    };
  }
}
