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

/// A row of tabs on the way, in the shape of a `TabBar`.
///
/// Most tabbed screens put their `TabBar` in the `AppBar`, OUTSIDE the
/// [AsyncView] — `pos/stalls_screen.dart` is the pattern — so the strip
/// is already drawn while the body waits and there is nothing here to
/// outline.
///
/// A few build the whole `DefaultTabController` inside the builder,
/// because how many tabs there are depends on the row: a strata site
/// has different tabs from a freehold one, and a company's seven tabs
/// come with it. On those the strip itself is waiting, and a body
/// skeleton with no strip above it jumps down by the height of a tab
/// bar the moment the row lands — the reflow a skeleton exists to
/// remove, in the direction that looks like the page settling.
///
/// [tabs] is a count of the tabs the screen will draw. Where the row
/// decides that too, the usual count is the honest guess: being one tab
/// out moves nothing vertically, which is the axis this is about.
class TabStripSkeleton extends StatelessWidget {
  const TabStripSkeleton({super.key, this.tabs = 3});

  /// How many tabs the real strip has.
  final int tabs;

  @override
  Widget build(BuildContext context) => Skeletonizer(
    child: SizedBox(
      // The height `TabBar` gives itself for a text-only tab. Hard-coded
      // rather than measured because the point is to occupy exactly the
      // space the real strip will, and a strip that sizes itself to its
      // bones is the wrong height by definition.
      //
      // 48 and not 46, which is what this said first and what it was
      // worth writing a test against a real `TabBar` to find out. Two
      // pixels is nothing to look at and is still the page moving when
      // the row lands, which is the whole thing this is for.
      height: 48,
      child: Row(
        children: [
          for (var i = 0; i < tabs; i++)
            Expanded(
              child: Center(
                // Keyed so a test can count them. `Bone` is abstract and
                // its concrete classes are private, so `find.byType`
                // reaches none of them.
                key: ValueKey('skeleton-tab-$i'),
                child: Bone.text(words: 1 + i % 2),
              ),
            ),
        ],
      ),
    ),
  );
}

/// A tab strip with a body under it, which is what a tabbed detail
/// screen is waiting on.
///
/// Composed rather than left to each screen because the composition has
/// a trap in it. A plain `Column` of [TabStripSkeleton] and a body
/// OVERFLOWS: the body sizes itself to its rows, the column is given
/// the height of the page, and five card rows plus a 48-pixel strip
/// came to ten pixels more than `site_screen` had to give. In a debug
/// build that is the yellow stripe; in a RELEASE build the overflow is
/// clipped silently, so the screen looks right and the outline is
/// simply missing its last row.
///
/// So the body is [Flexible] and clipped, and it cannot be dragged --
/// a skeleton is not content, and an outline that scrolls is a gesture
/// that does nothing.
class TabbedSkeleton extends StatelessWidget {
  const TabbedSkeleton({super.key, this.tabs = 3, required this.body});

  /// How many tabs the real strip has.
  final int tabs;

  /// The outline of whatever the first tab shows.
  final Widget body;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TabStripSkeleton(tabs: tabs),
      Flexible(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: body,
        ),
      ),
    ],
  );
}

/// The board while the stages and the deals are on the way.
///
/// Not one of the shared shapes in `core/skeletons.dart`, because none
/// of them is a board: this is a horizontal row of fixed-width columns,
/// and the width is what matters. A column here is 280 wide with a 12
/// margin because `crm/pipeline_screen.dart`'s stage column is, and a skeleton that let the
/// columns size themselves would be the wrong shape in the one
/// direction this screen scrolls.
///
/// Four columns rather than the real count, which is not known yet --
/// being a column out shifts nothing already drawn, and four is what
/// fits a laptop.
class BoardSkeleton extends StatelessWidget {
  const BoardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Skeletonizer(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // Not scrollable by the person. It is not content, and a
          // board that can be dragged sideways before there is
          // anything on it is a gesture that does nothing.
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(Space.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < 4; c++)
                Container(
                  key: ValueKey('skeleton-stage-$c'),
                  width: 280,
                  margin: const EdgeInsets.only(right: 12),
                  padding: const EdgeInsets.all(Space.md),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The stage name, and the total underneath it.
                      const Bone.text(words: 2),
                      const SizedBox(height: Space.xs),
                      const Bone.text(words: 1),
                      const SizedBox(height: Space.md),
                      // Fewer cards further right: a pipeline narrows,
                      // and an outline that says otherwise is claiming
                      // something about the deals it has not seen.
                      for (var d = 0; d < 3 - (c ~/ 2); d++)
                        const Padding(
                          padding: EdgeInsets.only(bottom: Space.sm),
                          child: Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: EdgeInsets.all(Space.md),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Bone.text(words: 3),
                                  SizedBox(height: Space.xs),
                                  Bone.text(words: 2),
                                ],
                              ),
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

/// A chart on the way, in the shape of the box it is drawn in.
///
/// A chart is the one place where outlining the CONTENT would be a lie:
/// bones in the shape of a line going up say the line goes up, and
/// nobody has read the figures yet. So this outlines the frame — the
/// plot area and the labels under it — and leaves the plot itself a
/// plain block.
///
/// [height] must be the height the real chart is given. A chart sits in
/// a fixed box on every screen in this app precisely so the page does
/// not jump when the series arrives, and a skeleton that sized itself
/// would undo that.
class ChartSkeleton extends StatelessWidget {
  const ChartSkeleton({super.key, required this.height, this.labels = 6});

  /// The height of the box the chart is drawn in.
  final double height;

  /// How many labels run along the bottom.
  final int labels;

  @override
  Widget build(BuildContext context) => Skeletonizer(
    child: SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Bone(
              key: const ValueKey('skeleton-chart-plot'),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
          ),
          const SizedBox(height: Space.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < labels; i++)
                Bone.text(
                  key: ValueKey('skeleton-chart-label-$i'),
                  words: 1,
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
