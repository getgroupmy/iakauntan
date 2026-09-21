/// What a screen draws while its rows are on the way.
///
/// A grey outline of the content to come, shimmering, instead of a
/// spinner on an empty page. `skeletonizer` does the painting: any
/// ordinary widget tree inside [Skeletonizer] is drawn as bones rather
/// than as itself, so what is written here is the SHAPE and nothing
/// else — no colours to keep in step with the theme, and no second
/// rendering of a list to maintain beside the real one.
///
/// ## When a skeleton is honest and when it is not
///
/// `core/page_waiting.dart` argues the opposite case and is still
/// right about it. The pages a visitor sees before signing in are
/// operator-edited: how many bullets sit beside the form, whether
/// there is a panel at all, what the headline says. A skeleton there is
/// a GUESS at a shape the payload is about to decide, and a guess that
/// turns out wrong is the same flicker in fainter grey. Those pages
/// keep their circle.
///
/// A list of invoices is not that. The shape is known before the data
/// arrives — rows, in a list, each with a name and an amount — and
/// drawing it says something true about what is coming. That is the
/// line: a skeleton belongs where the LAYOUT is already decided and
/// only the values are missing.
///
/// ## And never for an action
///
/// A spinner inside a button means "your press is being dealt with".
/// It is about time passing, not about a shape, and a bone in its place
/// would say nothing. Saving, submitting, uploading and deleting keep
/// their spinners; so does anything a person has just pressed.
library;

import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

import 'theme.dart';

/// Rows on the way, in the shape of a list.
///
/// [rows] is a count, not a promise. Enough to fill the part of the
/// screen an eye lands on and no more: a skeleton longer than the
/// answer looks like content that vanished.
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({
    super.key,
    this.rows = 6,
    this.leading = true,
    this.trailing = true,
    this.subtitle = true,
  });

  /// How many rows to outline.
  final int rows;

  /// Whether each row starts with an avatar or icon.
  final bool leading;

  /// Whether each row ends with a value — an amount, a date, a chip.
  final bool trailing;

  /// Whether rows carry a second line.
  final bool subtitle;

  @override
  Widget build(BuildContext context) => Skeletonizer(
    child: ListView.builder(
      // The skeleton must not scroll. It is not content, and a list
      // that can be dragged before there is anything in it is a
      // gesture that does nothing — worse, it steals the drag from a
      // pull-to-refresh that would have helped.
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: rows,
      itemBuilder: (_, i) => ListTile(
        leading: leading ? const Bone.circle(size: 40) : null,
        // Varied widths, and not for decoration. Every line the same
        // length reads as a table of one repeated thing; names are
        // not all the same length and the outline should not claim
        // they are.
        title: Bone.text(words: 2 + i % 3),
        subtitle: subtitle ? Bone.text(words: 3 + i % 2) : null,
        trailing: trailing ? const Bone.text(words: 1) : null,
      ),
    ),
  );
}

/// Rows on the way, in the shape of a table.
///
/// For the screens that draw a `DataTable` on a wide display. The
/// column count is what makes this worth having separately: a table
/// skeleton with the wrong number of columns reflows the moment the
/// data lands, which is the flicker a skeleton is meant to remove.
class TableSkeleton extends StatelessWidget {
  const TableSkeleton({super.key, required this.columns, this.rows = 8});

  /// How many columns the real table has.
  final int columns;

  /// How many rows to outline.
  final int rows;

  @override
  Widget build(BuildContext context) => Skeletonizer(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < rows; r++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.sm),
            child: Row(
              children: [
                for (var c = 0; c < columns; c++)
                  Expanded(
                    // The last column is usually a number or a chip and
                    // is narrower than a name. Said in the shape rather
                    // than left to the eye to forgive.
                    flex: c == columns - 1 ? 1 : 2,
                    child: Padding(
                      padding: const EdgeInsets.only(right: Space.sm),
                      child: Bone.text(words: c == 0 ? 3 : 1),
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// How many columns a grid of metric tiles draws at this width.
///
/// Shared between the real grids and [TilesSkeleton], and shared rather
/// than repeated for one reason: a skeleton grid with a different
/// column count from the real one reflows the instant the data lands,
/// which is precisely the flicker a skeleton exists to remove. Two
/// copies of `width >= 1100 ? 4 : ...` is two places for that to drift
/// apart silently, and nothing would report it — the skeleton and the
/// content are never on screen at the same moment.
int tileColumns(double width, {double wideAt = 1100, double mediumAt = 700}) =>
    width >= wideAt ? 4 : (width >= mediumAt ? 2 : 1);

/// Figures on the way, in the shape of the tiles that hold them.
///
/// The dashboard's own case. Its tiles are a fixed set decided by the
/// modules a company holds and the cards its user has chosen, not by
/// the numbers — so the shape is known before any figure arrives, which
/// is exactly when a skeleton is the honest thing to draw.
///
/// The geometry is passed in rather than guessed, and that is the whole
/// reason this is a widget and not three lines at the call site. A
/// skeleton grid with a different column count from the real one
/// reflows the moment the data lands, which is the flicker a skeleton
/// exists to remove — so the breakpoints, the spacing and the aspect
/// ratio have to be the same numbers the real grid uses, read off it
/// rather than remembered.
class TilesSkeleton extends StatelessWidget {
  const TilesSkeleton({
    super.key,
    this.count = 4,
    this.wideAt = 1100,
    this.mediumAt = 700,
    this.spacing = 12,
    this.wideAspect = 1.75,
    this.narrowAspect = 3.2,
  });

  /// How many tiles the real row has.
  final int count;

  /// The width at and above which the real grid draws four columns.
  final double wideAt;

  /// The width at and above which it draws two.
  final double mediumAt;

  /// The gap between tiles, in both directions.
  final double spacing;

  /// The tile aspect ratio at two columns and above.
  final double wideAspect;

  /// And at one column, where a tile is a wide strip.
  final double narrowAspect;

  @override
  Widget build(BuildContext context) {
    // `MediaQuery.sizeOf`, not a `LayoutBuilder`, because that is what
    // the real grid reads. The two do not always agree — a grid inside
    // a padded column is narrower than the window — and disagreeing
    // here is the reflow this is meant to avoid.
    final width = MediaQuery.sizeOf(context).width;
    final columns = tileColumns(width, wideAt: wideAt, mediumAt: mediumAt);
    return Skeletonizer(
      child: GridView.count(
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        crossAxisCount: columns,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: columns == 1 ? narrowAspect : wideAspect,
        children: [
          for (var i = 0; i < count; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(Space.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
                    // The label, the figure, and the line underneath
                    // that says which way it is going.
                    Bone.text(words: 2),
                    Bone.text(words: 1),
                    Bone.text(words: 2),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Fields on the way, in the shape of a form.
///
/// For an editor opened on an existing record, where the boxes are
/// drawn and empty until the record arrives. NOT for a new one: there
/// is nothing coming, the boxes are already right, and a skeleton over
/// them would say a value is on its way when none is.
class FormSkeleton extends StatelessWidget {
  const FormSkeleton({super.key, this.fields = 5});

  /// How many boxes the real form has.
  final int fields;

  @override
  Widget build(BuildContext context) => Skeletonizer(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < fields; i++)
          Padding(
            // Keyed for the same reason [CardRowsSkeleton]'s rows are:
            // a screen wired to draw this can be asserted to draw it,
            // and -- the part that matters -- asserted to draw more
            // than nothing. `FormSkeleton(fields: 0)` is a live
            // outline with no boxes in it, and every assertion about
            // "no spinner, no fields yet" is true of it.
            key: ValueKey('skeleton-form-field-$i'),
            padding: const EdgeInsets.only(bottom: Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Bone.text(words: 1),
                const SizedBox(height: Space.xs),
                Bone.square(size: 48, borderRadius: BorderRadius.circular(4)),
              ],
            ),
          ),
      ],
    ),
  );
}

/// Rows on the way, in the shape a CARD draws them.
///
/// [ListSkeleton] outlines a `ListTile`, which is 56 pixels tall on its
/// own and 72 with a second line. Plenty of this app's rows are not
/// `ListTile`s: a card with a leading icon and two lines of text, or a
/// list of to-dos built from a `Checkbox` and a `Column`, comes out
/// around 48. Outlining those with tiles makes a five-row skeleton half
/// as tall again as the five rows that replace it, and the whole card
/// jumps the moment the data lands — the flicker a skeleton exists to
/// remove, in the direction that is easiest to miss because it happens
/// once and looks like the page settling.
///
/// So the geometry is passed in rather than assumed: how big the thing
/// at the front is, how many lines of words follow it, and how many
/// controls sit at the end.
///
/// It is not pixel-exact and is not meant to be. What it is meant to be
/// is the same ORDER of height as the content, which a `ListTile` is
/// not.
class CardRowsSkeleton extends StatelessWidget {
  const CardRowsSkeleton({
    super.key,
    this.rows = 1,
    this.leading = true,
    this.leadingSize = 40,
    this.leadingHeight,
    this.lines = 2,
    this.trailing = 0,
    this.trailingWidth = 32,
    this.rowGap = Space.sm,
  });

  /// How many rows to outline.
  final int rows;

  /// Whether each row starts with an icon, a checkbox or an avatar.
  final bool leading;

  /// How big that is, on a side. A checkbox is not an avatar.
  final double leadingSize;

  /// How TALL it is, where that is not the same as how wide.
  ///
  /// The settings cards do not start a row with an avatar. They start
  /// it with a short piece of text in a fixed column -- a branch code,
  /// a warehouse code -- seventy-odd pixels wide and one line high. A
  /// square bone of that width would be seventy pixels TALL, which is
  /// half again the height of the row it is outlining, and the card
  /// would visibly shrink the moment the codes arrived.
  ///
  /// Null means square, which is what an avatar and a checkbox are.
  final double? leadingHeight;

  /// How many lines of words follow it. One for a bare label, two for
  /// the usual title-and-detail.
  final int lines;

  /// How many controls sit at the end of the row. A count rather than a
  /// flag because a card row often carries two — an icon button and a
  /// filled one — and outlining one of them moves the words across.
  final int trailing;

  /// How wide each of those is. A default of 32 outlines an icon
  /// button; the amount box on a settlement row is 130, and outlining
  /// it as an icon leaves the words a hundred pixels too wide.
  final double trailingWidth;

  /// The vertical breathing room around each row.
  final double rowGap;

  @override
  Widget build(BuildContext context) => Skeletonizer(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      // As tall as its rows and no taller. A skeleton that takes the
      // whole of the space it is given is an outline claiming the
      // content fills the card, and the card shrinks when it does not.
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < rows; r++)
          Padding(
            key: ValueKey('skeleton-card-row-$r'),
            padding: EdgeInsets.symmetric(vertical: rowGap / 2),
            child: Row(
              children: [
                if (leading) ...[
                  Bone(
                    // Keyed so its SIZE can be asserted. `Bone` is
                    // abstract and its concrete classes are private, so
                    // `find.byType` cannot reach one, and a wrong
                    // height here is invisible to every assertion that
                    // counts children instead.
                    key: ValueKey('skeleton-card-row-$r-leading'),
                    width: leadingSize,
                    height: leadingHeight ?? leadingSize,
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  const SizedBox(width: Space.lg),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < lines; i++)
                        Padding(
                          padding: EdgeInsets.only(top: i == 0 ? 0 : 2),
                          // Varied, and not for decoration: every line
                          // the same length reads as one repeated
                          // thing, and rows are not all alike.
                          child: Bone.text(words: i == 0 ? 2 + r % 3 : 3),
                        ),
                    ],
                  ),
                ),
                for (var c = 0; c < trailing; c++)
                  Padding(
                    padding: const EdgeInsets.only(left: Space.sm),
                    child: Bone(
                      width: trailingWidth,
                      height: 32,
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}
