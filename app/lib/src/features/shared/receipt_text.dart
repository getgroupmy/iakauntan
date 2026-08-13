/// Turning what a receipt says into what it means.
///
/// The two server-side readers are asked for fields and answer with
/// fields. ML Kit is not: it runs on the device, reads the printing, and
/// stops there. Everything below is the part that would otherwise be a
/// person squinting at a photograph — which is the whole point of the
/// feature, so it is done here and asserted in `receipt_text_test.dart`
/// against text off real Malaysian receipts.
///
/// Two rules run through all of it.
///
/// **A figure that is not printed is null, never zero.** "This receipt
/// shows no tax" and "I could not find the tax" both come back as null,
/// and a zero would claim the document printed one.
///
/// **Nothing is computed and presented as read.** Where the arithmetic
/// on the document does not foot, the printed figures are returned
/// unchanged and `note` says so. A bookkeeper can reconcile a receipt
/// that disagrees with itself; they cannot reconcile one this code
/// quietly corrected.
library;

import '../../data/ocr_repository.dart';

/// Two decimal places, because everything that is money on a Malaysian
/// receipt has them and almost nothing else does. `3` is a quantity;
/// `3.00` is a price. Thousands separators are optional and stripped.
final _money = RegExp(r'(?:RM\s*)?(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})\b');

/// Labels whose figure is not the document's total, however plainly they
/// contain the word. `TOTAL SAVINGS` on a supermarket receipt is the
/// single most likely thing to be mistaken for one.
final _notATotal = RegExp(
  r'\b(sub\s*-?\s*total|savings?|jimat|discount|diskaun|qty|quantity|'
  r'item|unit|round(?:ing)?|change|baki|cash|tunai|tender|'
  r'card|kad|paid|bayar|balance)\b',
  caseSensitive: false,
);

final _totalLabel = RegExp(
  r'\b(grand\s*total|nett?\s*total|total\s*(?:incl?u?s?i?v?e?)?|jumlah|'
  r'amount\s*due|amount\s*payable)\b',
  caseSensitive: false,
);

final _subtotalLabel =
    RegExp(r'\b(sub\s*-?\s*total|jumlah\s*kecil)\b', caseSensitive: false);

final _taxLabel = RegExp(
  r'\b(sst|gst|service\s*tax|sales\s*tax|cukai)\b',
  caseSensitive: false,
);

/// The tax *registration* line, which carries a number that is not money
/// and sits on a line that otherwise looks exactly like the tax charged.
final _taxIdLabel = RegExp(
  r'\b(?:sst|gst)\s*(?:reg(?:istration)?)?\s*(?:no|number|#)?\s*[:.\-]?\s*'
  r'([A-Z]\d{2}-\d{4}-\d{6,}|[A-Z0-9]{6,}(?:-[A-Z0-9]+)*)',
  caseSensitive: false,
);

/// What the document calls its own number.
///
/// Two lists, tried in order, because they are not equally trustworthy.
/// `Invoice No` means one thing; `Ref` on a card slip is an approval
/// code that has nothing to do with the bill — worth taking when there
/// is nothing better, and never in preference to something better.
///
/// No separator is required. `INVOICE NO 12345` with nothing but spaces
/// is the common printing, and demanding a colon is why a DirectD
/// receipt came back with no number at all.
final _docNoStrong = RegExp(
  r'\b(?:tax\s+)?(?:invoice|invois|receipt|resit|bill|cash\s+bill|'
  r'doc(?:ument)?)\b\.?\s*(?:no\b\.?|number\b|nombor\b|id\b|#)?\s*[:\-]?\s*',
  caseSensitive: false,
);

/// Weaker, and only consulted once the strong labels have found nothing.
/// `inv` is here rather than above because it is three letters and turns
/// up inside other words often enough to be worth demoting.
final _docNoWeak = RegExp(
  r'\b(?:inv|order|transaction|trans|slip|ref(?:erence)?|rujukan)\b\.?\s*'
  r'(?:no\b\.?|number\b|nombor\b|id\b|#)?\s*[:\-]?\s*',
  caseSensitive: false,
);

/// The token itself. Three characters at least, and no full stops: an
/// invoice number does not end a sentence, and allowing one is how the
/// prose after a label gets captured.
final _docNoValue = RegExp(r'^#?\s*([A-Za-z0-9][A-Za-z0-9/_\-]{2,})');

/// What a company is called in Malaysia, more or less.
final _companySuffix = RegExp(
  r'\b(sdn\.?\s*bhd|berhad|bhd|enterprise|trading|resources|holdings|'
  r'services|sdn|plt|marketing|industries|restoran|restaurant|mart|'
  r'pharmacy|farmasi|kedai)\b',
  caseSensitive: false,
);

/// The SSM number, in both forms a Malaysian company carries.
///
/// Since 2019 the registrar issues a twelve-digit number — `201901030189`
/// — and every company registered before that also keeps its old one,
/// `571389-H`. A letterhead usually prints both, one after the other,
/// which is why this finds either and the caller prefers the new form.
///
/// The leading twelve digits are anchored on a word boundary and *not*
/// preceded by a digit, so a phone number or an account number running
/// to twelve digits is not mistaken for a registration.
final _newRegistration =
    RegExp(r'(?<![\d-])(20\d{10}|19\d{10})(?![\d-])');

final _oldRegistration = RegExp(
  r'(?<![\w-])(\d{5,8}\s*-\s*[A-Z])(?![\w-])',
  caseSensitive: false,
);

/// Labelled explicitly, which government and utility bills tend to do.
final _registrationLabel = RegExp(
  r'\b(?:ssm|co(?:mpany)?|reg(?:istration|istered)?|syarikat|no\.?\s*pendaftaran)'
  r'[\s.]*(?:no|number|#)?\s*[:.\-]?\s*'
  r'(20\d{10}|19\d{10}|\d{5,8}\s*-\s*[A-Z])\b',
  caseSensitive: false,
);

/// Deliberately conservative. A receipt is full of things with an `@` in
/// them once a reader has had its way with the printing, and a wrong
/// email address on a supplier record is worse than none: it is where a
/// remittance advice gets sent.
final _email = RegExp(
  r'\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b',
);

/// A Malaysian telephone number as printed.
///
/// `03-1234 5678`, `+603 1234 5678`, `012-345 6789`, `1-300-88-9515`.
/// Anchored on `0`, `+6` or `1-300`, because an unanchored run of nine
/// digits matches half the numbers on a till roll.
final _phone = RegExp(
  r'(?<![\d])((?:\+?60|0)\s*\d{1,2}[\s\-]?\d{3,4}[\s\-]?\d{4}'
  r'|1[\s\-]?300[\s\-]?\d{2}[\s\-]?\d{4})(?![\d])',
);

/// The line a phone number sits on, when it is labelled.
final _phoneLabel = RegExp(
  r'\b(?:tel|telephone|phone|hp|h/p|mobile|fax|faks|no\.?\s*tel)\b',
  caseSensitive: false,
);

/// Five digits on their own, which in Malaysia is a postcode and is the
/// most reliable marker that a run of lines is an address.
final _postcode = RegExp(r'(?<![\d])\d{5}(?![\d])');

const _months = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  // Malay, which appears on plenty of receipts and on every government
  // one. `mac`, `ogo`, `okt` and `dis` are the four that differ.
  'mac': 3, 'mei': 5, 'ogo': 8, 'okt': 10, 'dis': 12,
};

/// Reads the recognized text of one document.
OcrExtraction parseReceiptText(String text) {
  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  final total = _labelledAmount(lines, _totalLabel, exclude: _notATotal);
  final subtotal = _labelledAmount(lines, _subtotalLabel);
  final tax = _taxAmount(lines);

  final notes = <String>[];
  if (total == null) {
    notes.add('No total could be read — check the amount against the paper.');
  } else if (subtotal != null && tax != null) {
    // Rounded to the cent before comparing: the figures came off a
    // photograph, not a calculator, and 0.001 of float noise is not a
    // discrepancy worth telling somebody about.
    final foots = ((subtotal + tax) * 100).round() == (total * 100).round();
    if (!foots) {
      notes.add('The printed figures do not add up: '
          '${_cents(subtotal)} + ${_cents(tax)} is not ${_cents(total)}.');
    }
  }

  final supplier = _supplier(lines);

  return OcrExtraction(
    supplierName: supplier,
    supplierTaxId: _taxId(lines),
    supplierRegistrationNo: _registrationNo(lines, text),
    supplierEmail: _email2(text),
    supplierPhone: _phoneNo(lines),
    supplierAddress: _address(lines, supplier),
    documentNo: _documentNo(lines),
    documentDate: _date(lines),
    // Nothing on a Malaysian till roll says MYR; the RM prefix and the
    // absence of anything else is what says it. A document in another
    // currency will say so, and this returns null rather than claiming
    // ringgit for it.
    currency: _currency(text),
    subtotal: subtotal,
    taxAmount: tax,
    totalAmount: total,
    lines: _lineItems(lines),
    note: notes.isEmpty ? null : notes.join(' '),
  );
}

String _cents(double v) => v.toStringAsFixed(2);

double? _amountOn(String line) {
  final matches = _money.allMatches(line).toList();
  if (matches.isEmpty) return null;
  // The last figure on the line: a printed line reads
  // "SST 8%            2.03", and the rate is not the amount.
  final m = matches.last;
  return double.tryParse('${m.group(1)!.replaceAll(',', '')}.${m.group(2)}');
}

/// The amount beside a label, looking at the next line too.
///
/// Receipts are printed in columns, and a photograph read line by line
/// sometimes splits the label from its figure. Looking one line ahead
/// recovers that without reaching far enough to pick up a neighbour.
double? _labelledAmount(
  List<String> lines,
  RegExp label, {
  RegExp? exclude,
}) {
  double? found;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!label.hasMatch(line)) continue;
    if (exclude != null && exclude.hasMatch(line)) continue;

    final here = _amountOn(line);
    if (here != null) {
      // Keep going: where a receipt prints both a running total and a
      // final one, the last is the one that settles it.
      found = here;
      continue;
    }
    if (i + 1 < lines.length) {
      final next = lines[i + 1];
      // Only if the next line is a bare figure. A label on its own
      // followed by another label means the figure was lost, not that
      // it belongs to whatever came after.
      if (RegExp(r'^(?:RM\s*)?[\d,]+\.\d{2}$').hasMatch(next)) {
        found = _amountOn(next);
      }
    }
  }
  return found;
}

double? _taxAmount(List<String> lines) {
  for (final line in lines) {
    if (!_taxLabel.hasMatch(line)) continue;
    // The registration number lives on a line that otherwise looks just
    // like the tax charged, and `W10-1808-31000123` contains digits a
    // careless regex will happily read as money.
    if (_taxIdLabel.hasMatch(line)) continue;
    if (_notATotal.hasMatch(line)) continue;
    final amount = _amountOn(line);
    if (amount != null) return amount;
  }
  return null;
}

String? _taxId(List<String> lines) {
  for (final line in lines) {
    final m = _taxIdLabel.firstMatch(line);
    if (m != null) return m.group(1)?.toUpperCase();
  }
  return null;
}

String? _documentNo(List<String> lines) {
  // Every strong label first, across the whole document, before any weak
  // one is considered. A card slip's `Ref` often sits above the invoice
  // number rather than below it, so first-match-wins on a single pass
  // would take the wrong one.
  return _documentNoBy(lines, _docNoStrong) ??
      _documentNoBy(lines, _docNoWeak);
}

String? _documentNoBy(List<String> lines, RegExp label) {
  for (var i = 0; i < lines.length; i++) {
    final m = label.firstMatch(lines[i]);
    if (m == null) continue;

    // Beside the label, or on the line under it. Receipts are printed in
    // columns and a photograph read line by line splits the two often
    // enough that only looking beside it misses a third of them.
    final value = _docNoValueIn(lines[i].substring(m.end)) ??
        (i + 1 < lines.length ? _docNoValueIn(lines[i + 1]) : null);
    if (value != null) return value.toUpperCase();
  }
  return null;
}

String? _docNoValueIn(String rest) {
  final value = _docNoValue.firstMatch(rest.trim())?.group(1);
  if (value == null) return null;

  // A document number carries a digit. Without this the line under a
  // label yields whatever word happens to be there — `DATE`, `CASHIER`,
  // the start of an address.
  if (!RegExp(r'\d').hasMatch(value)) return null;

  // A date is not a document number, however it was labelled.
  if (RegExp(r'^\d{1,2}[/-]\d{1,2}').hasMatch(value)) return null;

  // Nor is a figure of money, which is what sits beside `Bill` on a
  // statement.
  if (RegExp(r'^\d+\.\d{2}$').hasMatch(value)) return null;

  return value;
}

/// The trading name, which is almost always at the top and almost always
/// says what kind of company it is.
String? _supplier(List<String> lines) {
  final head = lines.take(8);
  for (final line in head) {
    if (_companySuffix.hasMatch(line)) return _tidy(line);
  }
  // Otherwise the first line that is words rather than an address or a
  // rule of dashes.
  for (final line in head) {
    final letters = line.replaceAll(RegExp(r'[^A-Za-z]'), '').length;
    if (letters < 4) continue;
    if (RegExp(r'^(no\.?\s|lot\s|jalan|jln|lorong)', caseSensitive: false)
        .hasMatch(line)) {
      continue;
    }
    if (_money.hasMatch(line)) continue;
    return _tidy(line);
  }
  return null;
}

String _tidy(String s) =>
    s.replaceAll(RegExp(r'\s{2,}'), ' ').replaceAll(RegExp(r'[*=_]+'), '').trim();

/// The SSM number, preferring the twelve-digit form.
///
/// A company registered before 2019 prints both, and the new number is
/// the one the registry and LHDN now key on. A labelled match wins over
/// a bare one — `Co. Reg: 571389-H` is a statement, a stray `571389-H`
/// further down the page is a hope.
String? _registrationNo(List<String> lines, String text) {
  for (final line in lines) {
    final labelled = _registrationLabel.firstMatch(line);
    if (labelled != null) {
      final value = _tidyReg(labelled.group(1)!);
      // A labelled *old* number still loses to a new one printed
      // anywhere, because they identify the same company and only one
      // of them is what anybody will be asked for.
      final modern = _newRegistration.firstMatch(text)?.group(1);
      return modern ?? value;
    }
  }
  final modern = _newRegistration.firstMatch(text)?.group(1);
  if (modern != null) return modern;
  return _tidyRegOrNull(_oldRegistration.firstMatch(text)?.group(1));
}

String _tidyReg(String s) => s.replaceAll(RegExp(r'\s+'), '').toUpperCase();

String? _tidyRegOrNull(String? s) => s == null ? null : _tidyReg(s);

/// The first email address on the document, if there plainly is one.
String? _email2(String text) => _email.firstMatch(text)?.group(0);

/// A telephone number, preferring one on a line that says it is one.
///
/// A receipt carries plenty of digits that look like phone numbers —
/// an approval code, a terminal id — so a labelled line is worth far
/// more than the first match on the page.
String? _phoneNo(List<String> lines) {
  for (final line in lines) {
    if (!_phoneLabel.hasMatch(line)) continue;
    final match = _phone.firstMatch(line);
    if (match != null) return _tidyPhone(match.group(1)!);
  }
  // Only the head of the document unlabelled: a supplier prints its
  // number on its letterhead, and a number halfway down a till roll is
  // more likely to be somebody else's.
  for (final line in lines.take(10)) {
    final match = _phone.firstMatch(line);
    if (match != null) return _tidyPhone(match.group(1)!);
  }
  return null;
}

String _tidyPhone(String s) => s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

/// The supplier's address, as printed.
///
/// Found by its postcode: five digits on their own is a Malaysian
/// postcode and almost nothing else, and the address is the run of lines
/// around it. Taken whole rather than split into street, city and state
/// — a receipt address runs to four lines in no fixed order, and a
/// wrongly split one looks authoritative while being wrong.
///
/// Returns null rather than guessing when no postcode is printed. An
/// address is not worth inventing: it goes on a supplier record and then
/// onto correspondence.
String? _address(List<String> lines, String? supplierName) {
  final head = lines.take(14).toList();
  final at = head.indexWhere(_postcode.hasMatch);
  if (at < 0) return null;

  // Back up to the start of the address block: consecutive lines above
  // the postcode that are not the company name, not a figure and not a
  // labelled field.
  var from = at;
  while (from > 0) {
    final line = head[from - 1];
    if (line.trim().isEmpty) break;
    if (supplierName != null && _tidy(line) == supplierName) break;
    if (_money.hasMatch(line)) break;
    if (_phoneLabel.hasMatch(line) || _email.hasMatch(line)) break;
    if (_registrationLabel.hasMatch(line)) break;
    if (_docNoStrong.hasMatch(line)) break;
    from--;
  }

  final block = head
      .sublist(from, at + 1)
      .map(_tidy)
      .where((l) => l.isNotEmpty)
      .toList();
  return block.isEmpty ? null : block.join('\n');
}

String? _currency(String text) {
  if (RegExp(r'\bRM\b|\bMYR\b', caseSensitive: false).hasMatch(text)) {
    return 'MYR';
  }
  final other = RegExp(r'\b(SGD|USD|EUR|GBP|THB|IDR|AUD|JPY|CNY)\b')
      .firstMatch(text);
  return other?.group(1);
}

/// Dates, in the order of preference a person would use: the one next to
/// the word "date" first, then the first one on the document.
DateTime? _date(List<String> lines) {
  DateTime? fallback;
  for (final line in lines) {
    final found = _dateIn(line);
    if (found == null) continue;
    if (RegExp(r'\b(date|tarikh|dated)\b', caseSensitive: false)
        .hasMatch(line)) {
      return found;
    }
    fallback ??= found;
  }
  return fallback;
}

DateTime? _dateIn(String line) {
  // 2026-06-30, unambiguous and worth trying first.
  final iso = RegExp(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b').firstMatch(line);
  if (iso != null) {
    return _valid(int.parse(iso.group(1)!), int.parse(iso.group(2)!),
        int.parse(iso.group(3)!));
  }

  // 12 JUN 2026, and 12-JUN-26.
  final named = RegExp(
    r'\b(\d{1,2})[\s\-/]*([A-Za-z]{3})[A-Za-z]*[\s\-/,]*(\d{2,4})\b',
  ).firstMatch(line);
  if (named != null) {
    final month = _months[named.group(2)!.toLowerCase()];
    if (month != null) {
      return _valid(_year(named.group(3)!), month, int.parse(named.group(1)!));
    }
  }

  // 12/06/2026. Malaysia writes day first, so that is the reading —
  // except where the second number cannot be a month, which settles it
  // the other way without guessing.
  final numeric =
      RegExp(r'\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})\b').firstMatch(line);
  if (numeric != null) {
    final a = int.parse(numeric.group(1)!);
    final b = int.parse(numeric.group(2)!);
    final year = _year(numeric.group(3)!);
    if (b > 12 && a <= 12) return _valid(year, a, b);
    return _valid(year, b, a);
  }
  return null;
}

int _year(String raw) {
  final n = int.parse(raw);
  // A two-digit year on a receipt is this century. A receipt from 1998
  // is not a thing anybody is photographing into an expense claim.
  return n >= 100 ? n : 2000 + n;
}

DateTime? _valid(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (year < 2000 || year > 2100) return null;
  final d = DateTime(year, month, day);
  // Rejects 31 February, which DateTime would silently roll into March.
  return d.month == month && d.day == day ? d : null;
}

/// The printed lines, where there are any.
///
/// Only what sits above the first totals line, and only where there is a
/// description as well as a figure. A receipt that prints one
/// undifferentiated total returns nothing here, which is honest: the
/// form then carries a single line for the whole document rather than a
/// made-up breakdown.
List<OcrLine> _lineItems(List<String> lines) {
  final stop = lines.indexWhere(
      (l) => _subtotalLabel.hasMatch(l) || _totalLabel.hasMatch(l));
  final body = lines.take(stop < 0 ? lines.length : stop);

  final out = <OcrLine>[];
  for (final line in body) {
    final amount = _amountOn(line);
    if (amount == null) continue;
    if (_notATotal.hasMatch(line) || _taxLabel.hasMatch(line)) continue;
    if (_docNoStrong.hasMatch(line) || _dateIn(line) != null) continue;

    // Everything before the figure is the description.
    final at = _money.allMatches(line).last.start;
    final description = _tidy(line.substring(0, at));
    if (description.replaceAll(RegExp(r'[^A-Za-z]'), '').length < 3) continue;

    out.add(OcrLine(description: description, amount: amount));
  }
  return out;
}
