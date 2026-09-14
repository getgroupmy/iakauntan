import 'file_shape.dart';
import 'import_screen.dart';

/// A blank file with the right headings, for somebody about to fill one
/// in.
///
/// The screen already shows which columns exist and which are required,
/// as chips. That tells you what to type but not what to type it into —
/// so the first thing anybody does is open a spreadsheet and guess at
/// the spelling, and the importer's alias table exists largely to
/// forgive those guesses. A file with the exact headings already in it
/// removes the guess.
///
/// ## Headings only, and no example row
///
/// A template carrying a worked example is a template that imports the
/// example. This screen is used once, at changeover, into books that are
/// about to become the real ones, and a fictional customer or a
/// fictional account in the opening chart is not a tidy thing to
/// discover a month later. The formats that actually catch people out —
/// dates above all — are stated on the screen instead, where they are
/// visible whether or not anybody downloaded this.
///
/// ## Why the canonical names and not the aliases
///
/// Every column has a preferred name and a list of things other systems
/// call it. The template uses the preferred one, so a file made from it
/// needs no aliasing at all and a heading that fails to map is
/// unambiguous evidence the file was edited rather than a near miss the
/// importer half-understood.
String importTemplateCsv(ImportKind kind) =>
    '${importTemplateColumns(kind).join(',')}\n';

/// The headings, in the order the importer thinks about them.
///
/// Separate from the CSV so a test can assert on the columns without
/// parsing anything, and so the filename and the file cannot disagree
/// about which kind they are for.
///
/// `importColumnsFor` is `file_shape.dart`'s, built from the same maps
/// the importers use. Writing a second switch here would be a second
/// list to keep in step, and the one thing a template must never be is
/// out of date with the thing it is a template for.
List<String> importTemplateColumns(ImportKind kind) =>
    importColumnsFor(kind).keys.toList();

/// What the browser will call it.
///
/// Named for the kind rather than "template.csv", because somebody
/// preparing a changeover downloads all seven and then has to tell them
/// apart in a downloads folder.
String importTemplateFilename(ImportKind kind) =>
    '${importKindLabel(kind).toLowerCase().replaceAll(' ', '-')}-template.csv';
