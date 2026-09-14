/// Turning what a document says into something worth asking the
/// registry.
///
/// A letterhead reads `TM TECHNOLOGY SERVICES SDN. BHD. 200201003726
/// (571389-H)`, and searching the register for all of that matches
/// nothing. A registration number, on the other hand, matches exactly
/// one company — so when the page carries one, that is the query, and
/// the name is the fallback rather than the first try.
///
/// Not to be confused with `_searchable` in `supplier_from_scan.dart`,
/// which narrows a name for a substring search of THIS company's own
/// contacts. That one is looking for a record somebody already typed;
/// this one is looking for a company in a national register, where an
/// identifier beats a spelling.
///
/// Pure string work on purpose: no network, no context, nothing to
/// mock, so the cases below can be asserted directly.
class SsmQueryHints {
  const SsmQueryHints._();

  /// The twelve-digit number issued since 2019: four-digit year, then a
  /// two-digit entity code, then a six-digit sequence.
  static final RegExp newRegNo = RegExp(
    r'(?<![\d-])((?:19|20)\d{2}0[1-9]\d{6})(?![\d-])',
  );

  /// The older form: up to three letters of state or kind, six to nine
  /// digits, a dash and a check letter. `1339519-K`, `JM0167410-V`,
  /// `LLP0012345-LGN`.
  static final RegExp oldRegNo = RegExp(
    r'(?<![\w-])([A-Z]{0,3}\d{6,9}\s*-\s*[A-Z]{1,3})(?![\w-])',
    caseSensitive: false,
  );

  /// `Co. Reg. No: 571389-H` and its many spellings, so the number can
  /// be taken off a name even when it is not in a shape the two
  /// patterns above recognise.
  static final RegExp _regNoLabel = RegExp(
    r'(?:reg(?:istration)?\.?\s*(?:no|number)?\.?|co\.?\s*(?:reg\.?\s*)?no\.?'
    r'|ssm\s*(?:no|number)?\.?|company\s*no\.?|business\s*no\.?)'
    r'\s*[:#]?\s*([A-Z0-9()\-\s]{6,40})',
    caseSensitive: false,
  );

  /// The words that say a line is a company name rather than an address
  /// or a slogan.
  static final RegExp _suffixes = RegExp(
    r'\b(SDN\.?\s*BHD\.?|SENDIRIAN\s+BERHAD|BERHAD|BHD\.?|PLT|LLP|ENTERPRISE|TRADING)\b',
    caseSensitive: false,
  );

  /// What to search first.
  ///
  /// Empty when there is nothing worth asking — three characters is the
  /// function's own minimum, and a caller should not spend a search on
  /// less.
  static String bestQuery(String? text) {
    final all = candidates(text);
    return all.isEmpty ? '' : all.first;
  }

  /// Everything worth trying, best first: the new registration number,
  /// then the old one, then the cleaned-up name.
  ///
  /// Ordered rather than combined. The registry matches a number
  /// exactly or not at all, so a wrong guess costs one search and the
  /// next candidate is still there.
  static List<String> candidates(String? text) {
    final source = text?.trim() ?? '';
    if (source.isEmpty) return const [];

    final out = <String>[];
    void add(String? candidate) {
      final v = candidate?.trim() ?? '';
      if (v.length >= 3 && !out.contains(v)) out.add(v);
    }

    add(extractNewRegNo(source));
    add(extractOldRegNo(source));
    add(cleanName(source));
    return out;
  }

  static String? extractNewRegNo(String text) =>
      newRegNo.firstMatch(text)?.group(1);

  static String? extractOldRegNo(String text) => oldRegNo
      .firstMatch(text)
      ?.group(1)
      ?.replaceAll(RegExp(r'\s+'), '')
      .toUpperCase();

  /// The name, with everything that is not the name taken off it.
  ///
  /// Registration numbers, bracketed asides and OCR noise all go; `SDN.
  /// BHD.` and `SENDIRIAN BERHAD` both become `SDN BHD`, because that
  /// is how the register spells it and a search is a string match.
  static String cleanName(String text) {
    var s = text;

    // A scan is several lines and only one of them is the company. The
    // one carrying a corporate suffix is it; failing that, the first,
    // which is where a letterhead puts the name.
    final lines = s
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length > 1) {
      s = lines.firstWhere(_suffixes.hasMatch, orElse: () => lines.first);
    }

    s = s
        .replaceAll(newRegNo, ' ')
        .replaceAll(oldRegNo, ' ')
        .replaceAll(_regNoLabel, ' ')
        .replaceAll(RegExp(r'\([^)]*\)'), ' ')
        .replaceAll(
          RegExp(r'\bSDN\.?\s*BHD\.?', caseSensitive: false),
          'SDN BHD',
        )
        .replaceAll(
          RegExp(r'\bSENDIRIAN\s+BERHAD\b', caseSensitive: false),
          'SDN BHD',
        )
        // Anything that is not a letter, a digit or punctuation a name
        // really carries. A reader turns a logo into `~|`, and those
        // characters in a query find nothing at all.
        .replaceAll(RegExp(r'[^A-Za-z0-9&/@.\-\s]'), ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim()
        .replaceAll(RegExp(r'[.\-]+$'), '')
        .trim();

    // Six words is a company name; more than that is a name plus an
    // address, and the register will not match the address.
    final words = s.split(' ');
    if (words.length > 6) s = words.take(6).join(' ');
    return s.toUpperCase();
  }

  /// Whether a query is an identifier rather than a name. The picker
  /// says so on screen, because a registration number that finds
  /// nothing means something different from a name that finds nothing.
  static bool looksLikeRegNo(String query) {
    final q = query.trim();
    return newRegNo.hasMatch(q) || oldRegNo.hasMatch(q);
  }
}
