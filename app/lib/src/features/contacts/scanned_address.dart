/// What to do with the address a reader hands back.
///
/// `OcrExtraction.supplierAddress` is the whole address as printed,
/// newlines and all, and deliberately not split — the reader's own
/// comment says why: a Malaysian address on a letterhead runs to four
/// lines in no fixed order, and guessing which line is the city would
/// put wrong data in a field that looks authoritative.
///
/// The contact form has four boxes, so something has to be decided.
/// This decides as little as possible:
///
///   * the first line goes in the first box;
///   * everything after it goes in the second, joined back with commas
///     because the box is one line;
///   * a **postcode** is taken out when it is five digits in the last
///     two lines and is not introduced by a word that means it is
///     something else — `No.`, `Lot`, `Unit`. Malaysian postcodes are
///     exactly five digits and sit at the end of an address, so that
///     rule is safe; a five-digit lot number at the top of the address
///     is not touched;
///   * **the city is never guessed.** It is the field that would look
///     most authoritative and be wrong most often.
({String line1, String line2, String? postcode}) splitScannedAddress(
  String? address,
) {
  final lines = (address ?? '')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  if (lines.isEmpty) return (line1: '', line2: '', postcode: null);

  String? postcode;
  // The last two lines only. A postcode is the end of an address, and
  // five digits at the top of one is a building number.
  final tail = lines.length <= 2 ? lines : lines.sublist(lines.length - 2);
  for (final line in tail) {
    final match = RegExp(
      r'(?<!\w)(?<!No\.\s)(?<!Lot\s)(?<!Unit\s)(\d{5})(?!\d)',
      caseSensitive: false,
    ).firstMatch(line);
    if (match != null) {
      postcode = match.group(1);
      break;
    }
  }

  final rest = lines.skip(1).toList();
  return (
    line1: lines.first,
    line2: rest.join(', '),
    postcode: postcode,
  );
}
