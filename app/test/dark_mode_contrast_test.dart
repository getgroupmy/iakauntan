import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';

/// Text you cannot read.
///
/// The Modules row on Settings rendered its chip labels in near-black on
/// a near-black card in dark mode. The cause is a trap rather than a
/// typo: a `ChipThemeData.labelStyle` that sets the font but not the
/// colour does **not** fall through to the colour scheme. Chip fills the
/// missing fields from Material's own defaults, which assume a light
/// surface, so naming the font is enough to lose the colour.
///
/// The same trap is waiting in every other theme entry that takes a
/// TextStyle, which is why this checks the contrast rather than the
/// literal value: an assertion that the colour equals
/// `onSurfaceVariant` would pass just as happily if `onSurfaceVariant`
/// were itself unreadable.
void main() {
  /// WCAG's relative-luminance ratio. 4.5:1 is the AA threshold for body
  /// text; chips here are 12px semibold, which is body text by any
  /// reasonable reading.
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final lighter = la > lb ? la : lb;
    final darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  for (final (name, theme) in [
    ('light', AppTheme.light()),
    ('dark', AppTheme.dark()),
  ]) {
    group('$name theme', () {
      test('a chip label can be read against the chip', () {
        final chip = theme.chipTheme;
        final label = chip.labelStyle?.color;
        expect(label, isNotNull,
            reason: 'an unset colour is the bug, not a default');

        // The background Chip actually paints when the theme names no
        // backgroundColor: M3 resolves it to surfaceContainerLow.
        final background =
            chip.backgroundColor ?? theme.colorScheme.surfaceContainerLow;

        expect(contrast(label!, background), greaterThan(4.5),
            reason: 'chip label $label on $background');
      });

      test('and against the card it sits on', () {
        // Belt and braces: the Modules chips sit on a Card, and a chip
        // whose own background is transparent inherits that instead.
        final label = theme.chipTheme.labelStyle!.color!;
        final card = theme.cardTheme.color ?? theme.colorScheme.surface;
        expect(contrast(label, card), greaterThan(4.5),
            reason: 'chip label $label on card $card');
      });

      test('the icon beside it is not left to a light-mode default', () {
        expect(theme.chipTheme.iconTheme?.color, isNotNull);
      });

      test('ordinary body text can be read on the page', () {
        final body = theme.textTheme.bodyMedium?.color ??
            theme.colorScheme.onSurface;
        expect(contrast(body, theme.colorScheme.surface), greaterThan(4.5),
            reason: 'body $body on surface ${theme.colorScheme.surface}');
      });
    });
  }
}
