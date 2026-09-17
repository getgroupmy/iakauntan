import 'mia_credential.dart';

/// One row copied out of MIA's results table.
class MiaParsedRow {
  const MiaParsedRow(this.kind, this.fields, this.raw);

  final MiaKind kind;

  /// Keyed by the column name the database uses, so the caller hands
  /// this to the RPC without a second mapping to get wrong.
  final Map<String, String?> fields;

  /// Exactly what was pasted.
  final String raw;

  String? operator [](String key) => fields[key];
}

/// Reads a row somebody copied out of MIA's members and firms search.
///
/// The register renders an HTML table server-side, so copying a row
/// gives tab-separated cells — and the Contact Details cell contains
/// newlines, which is the part that makes this more than a `split`.
///
/// ## It only ever prefills
///
/// Every field stays editable and plain manual entry works without
/// pasting anything. A parser that refuses is a parser somebody works
/// around by typing the number into the wrong box, so where this cannot
/// tell what it is looking at it returns null and the form asks.
class MiaResultParser {
  const MiaResultParser();

  /// A firm number: one to three letters, an optional space, three to
  /// five digits. `AF 0759`, `AF0759`, `af 0759`.
  static final _firmNo = RegExp(r'^([A-Za-z]{1,3})\s?(\d{3,5})\b');

  /// A member number: digits, and nothing else in front of them.
  static final _memberNo = RegExp(r'^\d{3,6}\b');

  /// The fallback for a row that arrived without its tabs — copied out
  /// of a PDF, or retyped.
  static final _memberPlain = RegExp(
    r'^(\d{3,6})\s+(.+?)\s+(CA|LA|AM)\s+(.+?)\s+(Yes|No)$',
    caseSensitive: false,
  );

  MiaParsedRow? parse(String input) {
    final text = input.replaceAll('\r', '').trim();
    if (text.isEmpty) return null;

    // A search that found nothing still renders one empty row, and
    // somebody copying the table gets it. It is not a credential and
    // must not become one: `, , ,` is the address cell of a row with
    // nothing in it.
    if (text.startsWith(', , ,')) return null;

    if (_firmNo.hasMatch(text)) return _firm(text);
    if (_memberNo.hasMatch(text)) return _member(text);
    return null;
  }

  MiaParsedRow? _member(String text) {
    final cells = _cells(text);
    if (cells.length >= 5) {
      return MiaParsedRow(MiaKind.member, {
        'member_no': _blank(cells[0]),
        'member_name': _blank(cells[1]),
        'member_type': _blank(cells[2])?.toUpperCase(),
        'state': _blank(cells[3]),
        'pc_holder': _yesNo(cells[4]),
      }, text);
    }

    final m = _memberPlain.firstMatch(text.replaceAll('\n', ' '));
    if (m == null) return null;
    return MiaParsedRow(MiaKind.member, {
      'member_no': m.group(1),
      'member_name': _blank(m.group(2)!),
      'member_type': m.group(3)!.toUpperCase(),
      'state': _blank(m.group(4)!),
      'pc_holder': _yesNo(m.group(5)!),
    }, text);
  }

  MiaParsedRow? _firm(String text) {
    final cells = _cells(text);
    if (cells.length < 2) return null;

    // Cells 0-4 are the number, name, address, state and country. The
    // contact block is cell 5 and the website the last cell — but the
    // block holds newlines, so a paste that turned those into cell
    // breaks leaves everything between the country and the website
    // belonging to it. Re-joined rather than indexed, or a firm with no
    // fax number shifts its own website into the tel field.
    String at(int i) => i < cells.length ? cells[i] : '';
    final website = cells.length > 6 ? cells.last : at(6);
    final contact = cells.length > 6
        ? cells.sublist(5, cells.length - 1).join('\n')
        : at(5);

    return MiaParsedRow(MiaKind.firm, {
      'firm_no': normaliseFirmNo(at(0)),
      'firm_name': _blank(at(1)),
      'address': _blank(at(2)),
      'state': _blank(at(3)),
      // Cell 4 is the country, which the register renders as "MYR".
      // Not stored: it is a currency code standing in for a country and
      // means nothing either way.
      'tel': _after(contact, 'Tel'),
      'fax': _after(contact, 'Fax'),
      'email': _after(contact, 'Email'),
      'website': _blank(website),
    }, text);
  }

  /// Tabs, or newlines where a paste has lost them.
  List<String> _cells(String text) {
    if (text.contains('\t')) return text.split('\t');
    return text.split('\n');
  }

  static String? _blank(String v) {
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  static String? _yesNo(String v) {
    final t = v.trim().toLowerCase();
    if (t == 'yes') return 'true';
    if (t == 'no') return 'false';
    return null;
  }

  /// `Tel: 60312345678` out of a block that also holds a fax and an
  /// e-mail. Anchored to the start of a line so an address containing
  /// the word does not match.
  static String? _after(String block, String label) {
    // `[ \t]*` and not `\s*` after the colon. `\s` matches a NEWLINE,
    // so a blank "Fax:" line let the match run on to the next line and
    // the e-mail address arrived in the fax box — which is a record
    // worse than no record.
    final m = RegExp('^[ \\t]*$label:[ \\t]*(.*)\$', multiLine: true)
        .firstMatch(block);
    return m == null ? null : _blank(m.group(1)!);
  }

  /// `AF0759`, `af 0759` and `AF  0759` are one firm.
  ///
  /// Normalised here as well as in `upsert_mia_credential`, and
  /// deliberately: the form shows what it will save before it saves it,
  /// and a number that changed shape on the way to the database would
  /// be a screen disagreeing with a record.
  static String? normaliseFirmNo(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final m = _firmNo.firstMatch(t);
    if (m == null) return t;
    return '${m.group(1)!.toUpperCase()} ${m.group(2)}';
  }
}
