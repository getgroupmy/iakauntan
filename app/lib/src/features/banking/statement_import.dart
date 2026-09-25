/// Turning a bank statement into rows the importer can take.
///
/// Two formats, because Malaysian banks give you one or the other and
/// which one depends on the account rather than the bank:
///
///   * **CSV**, which retail online banking exports, in whatever shape
///     it feels like. Read by header name rather than by column
///     position, and accepting both ways a statement expresses
///     direction: one signed amount, or separate debit and credit
///     columns.
///
///   * **MT940**, which corporate accounts get and which no amount of
///     CSV parsing will read. A SWIFT standard rather than a local
///     convention: `:61:` is a statement line and `:86:` is what it
///     says, everywhere in the world, which is why this one can be
///     written from the specification rather than from samples.
///
/// [parseStatement] picks. Nothing above it has to know which arrived,
/// which matters because what arrives is a file somebody downloaded and
/// did not look inside.
library;

import 'dart:convert';

import '../../core/csv.dart';
import '../../data/ocr_repository.dart';

/// What the import dialog should do with a file somebody chose.
///
/// Asked for in one sentence: "bank statement should allow to upload
/// pdf csv and also image not only csv". Only the CSV half was true.
/// The dialog's "Open a file" read whatever was picked with
/// `readAsString`, so a PDF or a photograph -- which is how most people
/// actually have a statement -- came back as
/// `FormatException`, reported as "Could not read the file", which
/// reads as the file being broken rather than the button being for
/// something else.
///
/// Both halves already existed and neither could be reached from here:
/// `parseStatement` reads CSV and MT940, and `scannedStatement` turns
/// an AI SmartScan reading into the same rows. This is the switch
/// between them, and it is deliberately a PURE FUNCTION over the bytes
/// -- the decision is the rule, and a rule that needs a file dialog to
/// reach is a rule nothing can assert.
enum StatementFile {
  /// CSV or MT940. Read here, costing nothing.
  text,

  /// A PDF or a photograph. Only a reader turns this into rows, and
  /// that costs a scan -- so it is never the guess for a file that
  /// could be text.
  scan,

  /// Neither, so neither path can do anything with it. A spreadsheet
  /// or an archive lands here, and saying so is the whole point: the
  /// alternative is sending it to a reader that will charge for it and
  /// find nothing.
  neither,
}

/// Which of the two importers a chosen file belongs to.
///
/// Sniffed from the BYTES first and the mime type second. A browser
/// hands over whatever the operating system guessed from the
/// extension, which on the machines this runs on is routinely
/// `application/octet-stream` for a `.sta` and empty for anything the
/// system has no association for -- and a statement renamed by the
/// person who downloaded it is the ordinary case, not the odd one.
StatementFile statementFileKind({String? mimeType, required List<int> bytes}) {
  if (_isPdf(mimeType, bytes) || _isImage(mimeType, bytes)) {
    return StatementFile.scan;
  }
  return statementText(bytes) == null
      ? StatementFile.neither
      : StatementFile.text;
}

/// The text of a statement file, or null where its bytes are not text.
///
/// A CONTROL BYTE is the test, not just a NUL. CSV and MT940 are both
/// line-oriented text and carry nothing below space except tab, newline
/// and carriage return; every binary format this is guarding against
/// carries them in its first few bytes -- `PK\x03\x04` opens a
/// spreadsheet, and UTF-16, which is what a spreadsheet writes when
/// asked for "Unicode text", is half NULs.
///
/// NUL alone was the first version of this rule and it let a short zip
/// header through: `PK\x03\x04` has no NUL in it. A real spreadsheet
/// has one a few bytes later, which is the worst way for a rule to be
/// wrong -- right on every file anybody tried and wrong on the small
/// one nobody did.
///
/// UTF-8 first, Latin-1 after. Malaysian statements are ASCII plus the
/// occasional accented payee name, and a bank that still exports
/// Latin-1 should not produce a refusal over one character in a
/// narration nobody reconciles against.
String? statementText(List<int> bytes) {
  for (final b in bytes) {
    if (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D) return null;
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

bool _isPdf(String? mimeType, List<int> bytes) =>
    mimeType == 'application/pdf' ||
    _startsWith(bytes, const [0x25, 0x50, 0x44, 0x46]); // %PDF

/// The image formats a phone or a scanner actually produces.
///
/// By magic number rather than by extension, and the mime type is only
/// a fallback: a `.jpg` that is really a PDF is a file somebody renamed,
/// and the bytes are the thing that is true.
bool _isImage(String? mimeType, List<int> bytes) {
  if (mimeType != null && mimeType.startsWith('image/')) return true;
  return _startsWith(bytes, const [0x89, 0x50, 0x4E, 0x47]) || // PNG
      _startsWith(bytes, const [0xFF, 0xD8, 0xFF]) || // JPEG
      _startsWith(bytes, const [0x47, 0x49, 0x46, 0x38]) || // GIF8
      _startsWith(bytes, const [0x42, 0x4D]) || // BMP
      // RIFF....WEBP and ....ftypheic / ftypheif / ftypmif1, both of
      // which carry their marker a few bytes in rather than at 0.
      (_startsWith(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
          _hasAt(bytes, 8, const [0x57, 0x45, 0x42, 0x50])) ||
      _hasAt(bytes, 4, const [0x66, 0x74, 0x79, 0x70]);
}

bool _startsWith(List<int> bytes, List<int> magic) => _hasAt(bytes, 0, magic);

bool _hasAt(List<int> bytes, int at, List<int> magic) {
  if (bytes.length < at + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[at + i] != magic[i]) return false;
  }
  return true;
}

/// One statement line, as read out of the paste.
class StatementRow {
  const StatementRow({
    required this.date,
    required this.amount,
    this.description,
    this.reference,
    this.balance,
  });

  final DateTime date;

  /// Signed: positive is money in.
  final double amount;
  final String? description;
  final String? reference;

  /// The account balance after this line, as the bank printed it.
  ///
  /// Null where the statement has no balance column, which is ordinary.
  /// Where it is present it is the only figure on the paste that can be
  /// checked against the rest of the paste, and `0369` checks it: a line
  /// the parser dropped or the paste clipped fails the chain on the line
  /// after the hole, instead of turning up a month later as a difference
  /// nobody can place.
  final double? balance;

  Map<String, dynamic> toJson() => {
        'transaction_date':
            '${date.year.toString().padLeft(4, '0')}-'
                '${date.month.toString().padLeft(2, '0')}-'
                '${date.day.toString().padLeft(2, '0')}',
        'amount': amount,
        'description': description,
        'reference': reference,
        'running_balance': balance,
      };
}

/// What came back from reading a paste: the rows, and the lines that
/// could not be read.
class StatementParse {
  const StatementParse(this.rows, this.problems, [this.notices = const []]);

  final List<StatementRow> rows;

  /// One message per line that was skipped, with its line number. Shown
  /// rather than swallowed: a statement that imports 38 of 40 lines
  /// without saying so reconciles to the wrong number.
  final List<String> problems;

  /// One message per line that was READ and then CHANGED.
  ///
  /// Separate from [problems] because they are different sentences to a
  /// bookkeeper: a problem is a line that will not be imported, and a
  /// notice is a line that will be, differently from how it was read.
  /// Counting them together would put "3 could not be read" over three
  /// lines that were read perfectly well and had their signs put right.
  final List<String> notices;

  bool get isEmpty => rows.isEmpty;
}

const _dateNames = ['date', 'transaction date', 'txn date', 'posting date',
                    'trans date', 'value date'];
const _amountNames = ['amount', 'transaction amount', 'value'];
const _debitNames = ['debit', 'withdrawal', 'debit amount', 'out', 'dr'];
const _creditNames = ['credit', 'deposit', 'credit amount', 'in', 'cr'];
const _descNames = ['description', 'details', 'particulars', 'narrative',
                    'transaction description', 'remarks'];
const _refNames = ['reference', 'ref', 'cheque', 'cheque no', 'transaction ref'];
// "Baki" because half the local exports are in Malay, and a balance
// column read as nothing is a check that quietly does not happen.
const _balanceNames = ['balance', 'running balance', 'closing balance',
                       'ledger balance', 'balance (rm)', 'baki'];

/// Reads a statement, in whichever of the two formats it arrived in.
///
/// MT940 announces itself: `:61:` is a statement line and appears in
/// every MT940 that has any transactions on it, and appears in no CSV
/// header that any bank writes. Detected on that rather than on a file
/// extension, because the extension is `.txt` or `.sta` or `.940`
/// depending on the bank and is missing entirely from a paste.
StatementParse parseStatement(String text) {
  if (_looksLikeMt940(text)) return parseMt940(text);
  return parseCsvStatement(text);
}

bool _looksLikeMt940(String text) =>
    RegExp(r'^:61:', multiLine: true).hasMatch(text);

/// Reads a pasted CSV statement.
///
/// The header row is required. Guessing which column is the date by
/// looking at the data works until a statement has two date columns, and
/// then it silently reconciles against the wrong one.
StatementParse parseCsvStatement(String text) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.length < 2) {
    return const StatementParse([], ['Paste the header row and at least one line.']);
  }

  final header = splitCsvLine(lines.first).map((h) => h.trim().toLowerCase()).toList();
  int find(List<String> names) =>
      header.indexWhere((h) => names.contains(h));

  final dateAt = find(_dateNames);
  final amountAt = find(_amountNames);
  final debitAt = find(_debitNames);
  final creditAt = find(_creditNames);
  final descAt = find(_descNames);
  final refAt = find(_refNames);
  final balanceAt = find(_balanceNames);

  if (dateAt < 0) {
    return StatementParse(const [], [
      'No date column found. The header needs one of: '
          '${_dateNames.join(', ')}.'
    ]);
  }
  if (amountAt < 0 && debitAt < 0 && creditAt < 0) {
    return StatementParse(const [], [
      'No amount column found. The header needs "amount", or a "debit" '
          'and "credit" pair.'
    ]);
  }

  final rows = <StatementRow>[];
  final problems = <String>[];

  for (var i = 1; i < lines.length; i++) {
    final cells = splitCsvLine(lines[i]);
    String at(int index) =>
        index >= 0 && index < cells.length ? cells[index].trim() : '';

    final date = parseStatementDate(at(dateAt));
    if (date == null) {
      problems.add('Line ${i + 1}: could not read the date "${at(dateAt)}".');
      continue;
    }

    double? amount;
    if (amountAt >= 0) {
      amount = _number(at(amountAt));
    } else {
      final debit = _number(at(debitAt)) ?? 0;
      final credit = _number(at(creditAt)) ?? 0;
      // Debit on a bank statement is money leaving the account.
      amount = credit - debit;
    }

    if (amount == null || amount == 0) {
      problems.add('Line ${i + 1}: no amount.');
      continue;
    }

    rows.add(StatementRow(
      date: date,
      amount: amount,
      description: at(descAt).isEmpty ? null : at(descAt),
      reference: at(refAt).isEmpty ? null : at(refAt),
      // Not a problem when it is missing or unreadable: a broken link
      // stops the chain rather than failing it, and a statement with no
      // balance column still imports.
      balance: balanceAt < 0 ? null : _number(at(balanceAt)),
    ));
  }

  return StatementParse(rows, problems);
}

/// A figure as a statement prints it.
///
/// Four conventions, and a Malaysian statement uses whichever its bank
/// chose. All four are ordinary and the last was not read at all:
///
///   * `1,250.00` and `RM 1,250.00` and `MYR1250.00`;
///   * `(120.00)`, brackets for a withdrawal;
///   * `120.00-`, a trailing minus, which is what a mainframe-era core
///     banking system prints;
///   * `1,250.00 DR` and `5,000.00 CR`, which is how a statement says
///     the direction when it prints no sign at all. `DR` is money out
///     of the account and `CR` is money in.
///
/// The last one used to come back NULL — `double.tryParse('1250.00DR')`
/// — so a statement in that format reported "no amount could be read"
/// on every line of it.
///
/// ## Why reading DR/CR as a sign is safe here
///
/// On a current account `DR` is money out, and on a credit card the
/// same word describes the same movement from the bank's side and the
/// opposite one from the holder's. Getting that backwards would be the
/// most expensive mistake available — except that it cannot survive:
/// `balancesDecideTheSigns` settles every sign against the running
/// balance afterwards and says so. A hint that the arithmetic checks is
/// a hint worth taking.
double? _number(String raw) {
  var s = raw.replaceAll(RegExp(r'[,\s]'), '');
  s = s.replaceFirst(RegExp(r'^(RM|MYR)', caseSensitive: false), '');
  if (s.isEmpty) return null;

  // The direction, where the figure carries it as a word. Taken off
  // before anything else looks at the string, because `1250.00DR`
  // parses as nothing at all.
  //
  // At EITHER END, because banks put it at both: `1,250.00 DR` on a
  // statement laid out in columns and `DR 1,250.00` on one laid out in
  // running text. Only one of the two used to be read, and neither was
  // read before that.
  bool? outward;
  final suffix = RegExp(r'(DR|CR)$', caseSensitive: false).firstMatch(s);
  final prefix = RegExp(r'^(DR|CR)', caseSensitive: false).firstMatch(s);
  if (suffix != null) {
    outward = suffix.group(1)!.toUpperCase() == 'DR';
    s = s.substring(0, suffix.start);
  } else if (prefix != null) {
    outward = prefix.group(1)!.toUpperCase() == 'DR';
    s = s.substring(prefix.end);
  }

  // Statements write a withdrawal either as -120.00 or as (120.00).
  if (s.startsWith('(') && s.endsWith(')')) {
    s = '-${s.substring(1, s.length - 1)}';
  }
  // Or as 120.00-, which older core banking systems print.
  if (s.endsWith('-')) s = '-${s.substring(0, s.length - 1)}';

  // No explicit empty check: `double.tryParse('')` is null, which is
  // what a bare `DR` with no figure beside it should come to anyway.
  final value = double.tryParse(s);
  if (value == null) return null;
  // A word beats a sign that was probably not printed: where both are
  // there they agree, and where they do not the word is the one the
  // bank chose to say.
  return outward == null ? value : (outward ? -value.abs() : value.abs());
}

/// Reads the date formats Malaysian banks actually export.
///
/// Day-first is assumed for the ambiguous ones, because that is what
/// every local bank writes. An ISO date is unambiguous and is read as
/// itself.
DateTime? parseStatementDate(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;

  // 2026-03-06
  final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(s);
  if (iso != null) {
    return _date(int.parse(iso.group(1)!), int.parse(iso.group(2)!),
        int.parse(iso.group(3)!));
  }

  // 06/03/2026, 6-3-26
  final dmy = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$').firstMatch(s);
  if (dmy != null) {
    var year = int.parse(dmy.group(3)!);
    if (year < 100) year += 2000;
    return _date(year, int.parse(dmy.group(2)!), int.parse(dmy.group(1)!));
  }

  // 06 Mar 2026
  final named = RegExp(r'^(\d{1,2})[\s-]([A-Za-z]{3,})[\s-](\d{2,4})$')
      .firstMatch(s);
  if (named != null) {
    const months = [
      'jan', 'feb', 'mar', 'apr', 'may', 'jun',
      'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
    ];
    final month =
        months.indexOf(named.group(2)!.toLowerCase().substring(0, 3)) + 1;
    if (month == 0) return null;
    var year = int.parse(named.group(3)!);
    if (year < 100) year += 2000;
    return _date(year, month, int.parse(named.group(1)!));
  }

  return null;
}

/// A day and a month with NO YEAR, which is what most statement lines
/// actually print.
///
/// Maybank, CIMB and Public Bank all print `03/09` or `03 SEP` on each
/// line and put the period in the header once. `parseStatementDate`
/// returns null for all of them, so a photographed statement in that
/// format came back as forty lines of "no date could be read" — every
/// single line of it, on the commonest layout there is.
///
/// Returned as a day and a month rather than a date, because a date it
/// is not: the year has to come from somewhere else on the page, and
/// guessing one here is how a December transaction gets filed in the
/// wrong financial year.
({int day, int month})? parsePartialStatementDate(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;

  // 03/09, 3-9. Exactly two fields: `6-3-26` is a whole date and is
  // read by `parseStatementDate` before this is ever asked.
  final dm = RegExp(r'^(\d{1,2})[/-](\d{1,2})$').firstMatch(s);
  if (dm != null) {
    final day = int.parse(dm.group(1)!);
    final month = int.parse(dm.group(2)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return (day: day, month: month);
  }

  // 03 SEP, 3-Sep, 03 September
  final named = RegExp(r'^(\d{1,2})[\s-]([A-Za-z]{3,})$').firstMatch(s);
  if (named != null) {
    final month = _monthNumber(named.group(2)!);
    if (month == null) return null;
    final day = int.parse(named.group(1)!);
    if (day < 1 || day > 31) return null;
    return (day: day, month: month);
  }

  return null;
}

/// Which year a day and a month belong to, given a date on the same
/// statement.
///
/// THE NEAREST OCCURRENCE, which is the only rule that survives a
/// statement crossing new year. A statement dated 5 January 2027 with a
/// line reading `28/12` means December 2026, and one reading `03/01`
/// means January 2027 — and taking the header's year for both would
/// file a December transaction twelve months out, into a financial year
/// that may already be closed.
///
/// Six months is the cut because it is the half-way point: beyond it
/// the other year is nearer, and no statement covers more than a year
/// without printing years on its lines.
DateTime resolveStatementYear({
  required int day,
  required int month,
  required DateTime near,
}) {
  final candidates = [
    _date(near.year - 1, month, day),
    _date(near.year, month, day),
    _date(near.year + 1, month, day),
  ].whereType<DateTime>();

  DateTime? best;
  var bestGap = 1 << 30;
  for (final c in candidates) {
    final gap = c.difference(near).inDays.abs();
    if (gap < bestGap) {
      bestGap = gap;
      best = c;
    }
  }
  // 29 February in a year that has none leaves nothing to pick, and a
  // date invented to fill the gap is worse than the line being
  // reported. The caller treats null as "no date could be read".
  return best ?? _date(near.year, month, day) ?? near;
}

/// The statement's own date, read off a PDF's own text layer.
///
/// ## The failure this exists for
///
/// Found live, and it cost fifty-five lines of somebody's October
/// statement. RHB exports a TEXT PDF: the period is printed on page one
/// as selectable text, and this repository has vendored `pdf.js` for
/// two years. We sent the page to a vision model as a picture instead,
/// asked it for `document_date`, and it returned null — so
/// `resolveStatementYear` had no anchor, refused to guess, and every
/// line of a faultless reading went on the floor.
///
/// A model is ASKED. A text layer is READ. Where the evidence is
/// printed and deterministic it should not be a model's to withhold.
///
/// ## What it reads
///
/// A LABEL, and the date beside it — `Statement Date`, `Tarikh
/// Penyata`, and the period forms in both languages, from which it
/// takes the LATER date, because that is what a statement is named by
/// and the end a running balance closes at.
///
/// ## And what it refuses to read
///
/// Loose dates. A statement's text layer is thick with them: a print
/// date, a payment due date, a "customer since", every transaction
/// line, and an address whose postcode reads like a year. Taking the
/// first thing shaped like a date is exactly how a statement gets filed
/// twelve months out — the failure this whole chain exists to refuse.
///
/// With no label it will accept ONE named month and year in the header
/// and nothing else. Numeric `10/2025` is not enough: it is also the
/// middle of `01/10/2025`, and a header that offers two different
/// months is two plausible readings, which is a null and a sentence
/// rather than a guess.
({DateTime date, String evidence})? statementPeriodFromText(String text) {
  final lines = text
      .split(RegExp(r'[\r\n]+'))
      .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) return null;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final lower = line.toLowerCase();
    for (final label in _periodLabels) {
      final at = lower.indexOf(label);
      if (at < 0) continue;

      // Normally on the same line, after the label. A table that puts
      // the label in one cell and the date in the next comes out of
      // `pdf.js` as two lines, so the next one is tried before giving
      // up on a label that is plainly there.
      var found = _datesIn(line.substring(at + label.length));
      if (found.isEmpty && i + 1 < lines.length) {
        found = _datesIn(lines[i + 1]);
      }
      if (found.isEmpty) continue;

      // A period is two dates and a statement date is one. Taking the
      // later covers both: the end of the period, or the only date
      // there was.
      found.sort();
      return (date: found.last, evidence: line);
    }
  }

  // No label anywhere. The header may still name its month outright —
  // "PENYATA BAGI OKTOBER 2025" with the words split across cells, or
  // a plain "October 2025" under the account number.
  //
  // The header only. Past it are the transaction lines, and a
  // description carrying a month and a year would otherwise vote.
  const header = 40;
  DateTime? only;
  String? evidence;
  final seen = <String>{};
  for (final line in lines.take(header)) {
    for (final m in RegExp(r'\b([A-Za-z]{3,9})\.?\s+(\d{4})\b').allMatches(line)) {
      final month = _monthNumber(m.group(1)!);
      if (month == null) continue;
      final year = int.parse(m.group(2)!);
      // A statement is not from 1904 and not from 2400. A four-digit
      // number beside a word that happens to start like a month is
      // otherwise a period.
      if (year < 1990 || year > 2100) continue;
      if (seen.add('$year-$month')) {
        // The last day of the month, because that is where the period
        // ends and what every line on it is nearest to.
        only = DateTime(year, month + 1, 0);
        evidence = line;
      }
    }
  }
  if (seen.length == 1 && only != null && evidence != null) {
    return (date: only, evidence: evidence);
  }
  return null;
}

/// What a Malaysian statement calls its own date, in both languages.
///
/// Ordered so nothing here is a prefix of a later entry in a way that
/// would take the wrong half: every one is matched on the whole phrase.
const _periodLabels = <String>[
  'statement date',
  'tarikh penyata',
  'date of statement',
  'statement period',
  'penyata bagi tempoh',
  'tempoh penyata',
  'bagi tempoh',
  'for the period',
  'period covered',
  'period from',
];

/// Every whole date in one line of text, in the orders Malaysia writes.
///
/// NEVER MM/DD/YYYY. `05/03/2026` is the fifth of March here and the
/// third of May in an American layout, and there is nothing in the
/// string to tell them apart — so the rule is the local one, applied
/// without exception rather than guessed at per document.
List<DateTime> _datesIn(String text) {
  final out = <DateTime>[];
  void add(DateTime? d) {
    if (d != null && !out.contains(d)) out.add(d);
  }

  // 2025-10-31. Taken first: run after the day-first pattern it would
  // be reading the tail of its own match.
  for (final m
      in RegExp(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b').allMatches(text)) {
    add(_date(int.parse(m.group(1)!), int.parse(m.group(2)!),
        int.parse(m.group(3)!)));
  }

  // 31/10/2025, 31-10-25, 31.10.2025
  for (final m in RegExp(r'\b(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})\b')
      .allMatches(text)) {
    var year = int.parse(m.group(3)!);
    if (year < 100) year += 2000;
    add(_date(year, int.parse(m.group(2)!), int.parse(m.group(1)!)));
  }

  // 31 OCT 2025, 31 Oktober 2025, 31-Dis-2025
  for (final m
      in RegExp(r'\b(\d{1,2})[\s-]([A-Za-z]{3,9})\.?[\s-](\d{2,4})\b')
          .allMatches(text)) {
    final month = _monthNumber(m.group(2)!);
    if (month == null) continue;
    var year = int.parse(m.group(3)!);
    if (year < 100) year += 2000;
    add(_date(year, month, int.parse(m.group(1)!)));
  }

  return out;
}

/// A month name in either of the languages a Malaysian statement is
/// printed in.
///
/// Matched on the first three letters, which is what distinguishes
/// every month in both languages and costs nothing — `Sep`, `September`
/// and `SEPTEMBER` are one entry, and so are `Ogo` and `OGOS`.
///
/// THE MALAY HALF WAS MISSING, and it was missing silently. A statement
/// printing `03 OGOS` or `17 DIS` returned null here, which the caller
/// reads as "no date could be read" — so a Bahasa Melayu statement came
/// back as every line unreadable, over the language it was printed in.
/// Maybank, CIMB and Bank Islam all issue them.
///
/// Five of the twelve differ enough to matter: MAC, MEI, OGOS, OKTOBER
/// and DISEMBER. The other seven share their first three letters with
/// English and were already being read by accident.
int? _monthNumber(String name) {
  const months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    // Bahasa Melayu, where it differs. `apr`, `jan`, `feb`, `jun`,
    // `jul`, `nov` and `sep` are spelled the same for three letters.
    'mac': 3, 'mei': 5, 'ogo': 8, 'okt': 10, 'dis': 12,
  };
  if (name.length < 3) return null;
  return months[name.toLowerCase().substring(0, 3)];
}

/// Rejects the impossible rather than letting DateTime roll it over —
/// 31/02 becoming 3 March would reconcile against the wrong day.
DateTime? _date(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final d = DateTime(year, month, day);
  if (d.year != year || d.month != month || d.day != day) return null;
  return d;
}

// ---------------------------------------------------------------------
// MT940
// ---------------------------------------------------------------------
//
// The SWIFT customer statement message, which is what a Malaysian bank
// gives a corporate account and what the CSV parser above cannot read at
// all. Tags, one per line, continuing onto the next line where it does
// not start with a colon:
//
//   :20:  the statement's own reference
//   :25:  which account this is
//   :28C: statement number / sequence
//   :60F: opening balance    C/D, YYMMDD, currency, amount
//   :61:  a statement line   (below)
//   :86:  what that line says, in the bank's own words
//   :62F: closing balance
//
// A `:61:` is fixed-width at the front and free-form after it:
//
//   2603060306C1234,56NTRFNONREF//BANKREF123
//   \_____/\__/|\_____/\_/\____/  \________/
//   value  entry D/C  amount  type  customer ref, then //bank ref
//   date   date
//
// The entry date is optional and the funds code between the mark and
// the amount is optional, which is what makes a single regular
// expression the wrong tool and a left-to-right walk the right one.
//
// ## Two things this gets right that a quick version would not
//
// **The decimal separator is a comma.** Always, in every MT940, in
// every country. `1234,56` is one thousand two hundred and thirty-four
// ringgit and fifty-six sen, and read as an English number it is either
// a parse failure or -- worse, with a thousands-separator strip --
// 123456.
//
// **`RD` and `RC` are reversals, and the mark is two characters.**
// A reversal of a debit is money coming BACK, so `RD` is positive.
// Reading only the first character makes every reversal go the wrong
// way, which nets to double the error.

/// Reads an MT940 statement.
StatementParse parseMt940(String text) {
  final rows = <StatementRow>[];
  final problems = <String>[];

  final lines = text.split(RegExp(r'\r?\n'));

  // Continuation lines belong to the tag above them. Joined first so
  // the walk below sees one string per tag, which is what the format
  // means even where the file wraps at eighty characters.
  final tags = <({int line, String tag, String body})>[];
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final m = RegExp(r'^:(\d{2}[A-Z]?):(.*)$').firstMatch(raw);
    if (m != null) {
      tags.add((line: i + 1, tag: m.group(1)!, body: m.group(2)!));
    } else if (tags.isNotEmpty && raw.trim().isNotEmpty && raw != '-') {
      final last = tags.removeLast();
      tags.add((
        line: last.line,
        tag: last.tag,
        body: '${last.body}\n${raw.trim()}',
      ));
    }
  }

  ({DateTime date, double amount, String? reference})? pending;
  int? pendingLine;

  void flush({String? description}) {
    if (pending == null) return;
    rows.add(StatementRow(
      date: pending!.date,
      amount: pending!.amount,
      description: description,
      reference: pending!.reference,
      // MT940 carries a balance on :60F: and :62F: rather than per
      // line, so the running balance the CSV path checks is not
      // available here. Left null rather than computed: a figure this
      // parser worked out itself would check the parser against itself,
      // which is not a check.
      balance: null,
    ));
    pending = null;
    pendingLine = null;
  }

  for (final t in tags) {
    if (t.tag == '61') {
      flush();
      final parsed = _parseMt940Line(t.body);
      if (parsed == null) {
        problems.add('Line ${t.line}: could not read the statement line '
            '":61:${t.body.split('\n').first}".');
        continue;
      }
      pending = parsed;
      pendingLine = t.line;
    } else if (t.tag == '86') {
      if (pending == null) continue;
      // The bank's words, with the file's wrapping taken back out. A
      // description broken across three lines is one description.
      flush(description: t.body.replaceAll('\n', ' ').trim());
    } else if (t.tag == '62F' || t.tag == '62M' || t.tag == '20') {
      flush();
    }
  }
  flush();

  if (rows.isEmpty && problems.isEmpty) {
    problems.add('No statement lines found. An MT940 has a ":61:" for '
        'every transaction.');
  }
  // `pendingLine` is read here and nowhere else: a line with no :86:
  // after it is still a transaction and is kept, which is what `flush`
  // above does. Named so the reason is visible rather than looking like
  // a variable somebody forgot.
  assert(pendingLine == null);

  return StatementParse(rows, problems);
}

/// One `:61:`, walked left to right because half its fields are
/// optional.
({DateTime date, double amount, String? reference})? _parseMt940Line(
  String body,
) {
  final line = body.split('\n').first;

  // Value date: six digits, YYMMDD.
  final head = RegExp(r'^(\d{6})').firstMatch(line);
  if (head == null) return null;
  final date = _mt940Date(head.group(1)!);
  if (date == null) return null;
  var at = 6;

  // Entry date: four more digits, MMDD, and optional. Only consumed
  // where what follows them is a credit/debit mark, so a statement that
  // omits it and goes straight to `C` is read correctly.
  final maybeEntry = RegExp(r'^(\d{4})([CD]|R[CD])').firstMatch(line.substring(at));
  if (maybeEntry != null) at += 4;

  // The mark. Two characters for a reversal, one otherwise, and the
  // two-character case has to be tested first or `RD` reads as `R`.
  final rest = line.substring(at);
  final mark = RegExp(r'^(RC|RD|C|D)').firstMatch(rest);
  if (mark == null) return null;
  final code = mark.group(1)!;
  at += code.length;

  // An optional one-letter funds code sits between the mark and the
  // amount. It is a letter where the amount is digits, so it is
  // distinguishable without knowing which letters are legal.
  final afterMark = line.substring(at);
  final funds = RegExp(r'^([A-Z])(?=[\d,])').firstMatch(afterMark);
  if (funds != null) at += 1;

  // The amount, up to the transaction type identifier, which is `N`
  // followed by three characters in every MT940 this will meet.
  final amountPart = RegExp(r'^([\d,]+)').firstMatch(line.substring(at));
  if (amountPart == null) return null;
  final magnitude = _mt940Amount(amountPart.group(1)!);
  if (magnitude == null) return null;
  at += amountPart.group(1)!.length;

  // `D` is money out. `RD` is the reversal of money out, which is money
  // coming back in, so it is positive — and reading only the first
  // character of the mark would send every reversal the wrong way.
  final signed = (code == 'C' || code == 'RD') ? magnitude : -magnitude;

  // What is left is the type identifier and the references. The
  // customer reference is what a person recognises; the bank's own
  // reference after `//` is not.
  final tail = line.substring(at);
  final refMatch = RegExp(r'^N.{3}(.*)$').firstMatch(tail);
  var reference = refMatch?.group(1) ?? tail;
  final bankRefAt = reference.indexOf('//');
  if (bankRefAt >= 0) reference = reference.substring(0, bankRefAt);
  reference = reference.trim();
  // `NONREF` is the SWIFT way of writing "there isn't one". Showing it
  // to somebody reconciling is worse than showing nothing.
  if (reference.isEmpty || reference.toUpperCase() == 'NONREF') {
    reference = '';
  }

  return (
    date: date,
    amount: signed,
    reference: reference.isEmpty ? null : reference,
  );
}

/// `YYMMDD`. The century is this one: MT940 has no room for four
/// digits, and a bank statement from 1974 is not what anybody is
/// importing.
DateTime? _mt940Date(String raw) {
  if (raw.length != 6) return null;
  final year = 2000 + int.parse(raw.substring(0, 2));
  final month = int.parse(raw.substring(2, 4));
  final day = int.parse(raw.substring(4, 6));
  return _date(year, month, day);
}

/// The decimal separator is a comma, in every MT940, everywhere. There
/// is no thousands separator to strip: `1234,56` is the whole of it.
double? _mt940Amount(String raw) {
  final s = raw.replaceFirst(',', '.');
  // A second comma is not a thousands separator, it is a malformed
  // line, and guessing would turn 1,234,56 into something plausible.
  //
  // Belt and braces: `double.tryParse` rejects `1.234.56` on its own,
  // so a mutation sweep finds this line EQUIVALENT and it survives. It
  // stays because it says the rule out loud where the next person can
  // read it, rather than leaving the format's one hard requirement
  // resting on a parser's incidental behaviour.
  if (s.contains(',')) return null;
  final v = double.tryParse(s);
  if (v == null || v < 0) return null;
  return v;
}


/// A statement that was PHOTOGRAPHED rather than exported.
///
/// `0682` gave a scan target the ability to repeat: a bank statement is
/// forty records with the same four fields, not one record, so the
/// reader is asked for an array and answers in
/// [OcrExtraction.rows] — keyed by the column names a platform
/// administrator ticked in the console.
///
/// Those keys are `bank_transactions` column names, and
/// `import_bank_transactions` takes `bank_transactions` column names.
/// So the shapes already match and nothing here translates between
/// them. What this does is COERCE: the reader is asked for what is
/// printed, so a date arrives as `03/09/2026` and an amount as
/// `1,900.00` or `(250.00)`, and both have to become the ISO date and
/// the plain number the RPC casts.
///
/// It reuses `parseStatementDate` and `_number` rather than writing
/// that again. A photographed statement and a pasted one carry the same
/// Malaysian conventions — day-first dates, brackets for a withdrawal,
/// `RM` in front of the figure — and two parsers for one convention is
/// two parsers that will disagree about 03/04.
///
/// ## The sign, and why this does not try harder
///
/// A statement with separate Debit and Credit columns gives the reader
/// no sign, and the admin's field description ("negative for money
/// out") is the only thing asking for one. A model that gets it wrong
/// turns a withdrawal into a deposit, which is the most expensive
/// mistake available here.
///
/// Nothing in this function can tell. What CAN tell is the running
/// balance, and `0369` already checks it line by line inside
/// `import_bank_transactions`: a wrong sign breaks the chain and the
/// whole import is refused, naming the line. So the balance is passed
/// through whenever the reader gave one, and that check is the reason
/// this parser is allowed to be naive about the sign.
StatementParse scannedStatement(
  OcrExtraction? read, {
  /// The statement's own date, read off the file's text layer rather
  /// than asked of a model. `statementPeriodFromText`.
  ///
  /// It OUTRANKS `document_date`, and that is the point of it: one was
  /// printed on the page and extracted, the other was a question put to
  /// a reader that may decline to answer — and did, on two RHB
  /// statements, taking a hundred and two faultless lines down with it.
  ({DateTime date, String evidence})? period,
}) {
  final rows = <StatementRow>[];
  final problems = <String>[];
  final notices = <String>[];

  // The balance printed BEFORE the first line and AFTER the last, where
  // the statement prints one.
  double? leading;
  double? trailing;

  // The first line that carried a whole date, for the lines that carry
  // only a day and a month. Used only where the statement's own date is
  // missing -- the header is the better anchor because it is printed
  // once and read once, where a line's year is one more thing to have
  // been misread.
  DateTime? anchorDate;

  // Lines that printed a day and a month and could not be placed in a
  // year, because neither the statement's own date nor any other line
  // supplied one. One cause, however many lines it took down.
  var unplaceable = 0;

  // Lines placed in a year by the file's own text layer. Counted so it
  // can be SAID: a year that came from somewhere other than the line
  // itself is a thing somebody checking their statement is entitled to
  // know about, and to disagree with.
  var placedFromPeriod = 0;

  final source = read?.rows ?? const <Map<String, String>>[];
  for (var i = 0; i < source.length; i++) {
    final row = source[i];
    // 1-based, and the line number a person would count to on the
    // photograph rather than an index.
    final at = i + 1;

    final rawDate = _first(row, const ['transaction_date', 'value_date']);
    final rawAmount = _first(row, const ['amount']);

    // BAKI DIBAWA KE HADAPAN, B/F, BALANCE BROUGHT FORWARD, OPENING
    // BALANCE. Nearly every Malaysian statement opens with one and many
    // close with one, and it is NOT a transaction: a balance, a
    // description, and no amount at all.
    //
    // It used to be reported as "Line 1: no amount could be read",
    // which is a complaint about the one line on the page that has
    // nothing wrong with it — on the first line, where it is the first
    // thing anybody reads about their own statement.
    //
    // And the balance on it was thrown away, which is the more
    // expensive half: it is the anchor the whole chain hangs from, and
    // without it the FIRST real line is the one line whose sign nothing
    // can settle.
    //
    // Recognised by SHAPE AND POSITION rather than by its words. The
    // wording is different at every bank and in two languages, and a
    // keyword list is a list that is missing the one this statement
    // used. A balance with no amount in the MIDDLE of a statement is a
    // different thing entirely — a line whose amount was unreadable —
    // and is still reported.
    if (rawAmount == null && (i == 0 || i == source.length - 1)) {
      final marker = _numberOrNull(_first(row, const ['running_balance']));
      if (marker != null) {
        if (i == 0) {
          leading = marker;
        } else {
          trailing = marker;
        }
        continue;
      }
    }

    if (rawDate == null && rawAmount == null) continue;

    var date = rawDate == null ? null : parseStatementDate(rawDate);

    // A line printing only a day and a month, which is most of them.
    // The year comes off the statement's own date, or off another line
    // that carried one -- never off today, which would file last
    // December's transactions into this year.
    if (date == null && rawDate != null) {
      final partial = parsePartialStatementDate(rawDate);
      final anchor = period?.date ?? read?.documentDate ?? anchorDate;
      if (partial != null && anchor != null) {
        date = resolveStatementYear(
          day: partial.day,
          month: partial.month,
          near: anchor,
        );
        if (period != null) placedFromPeriod++;
      }
    }

    if (date == null) {
      // A day and a month that could not be placed in a year is not
      // forty-three separate failures, it is ONE -- the statement's own
      // date was not read, and nothing else on the page can supply the
      // year. Counted here and said once below; saying it per line
      // fills the dialog with the same sentence and buries the cause.
      if (rawDate != null && parsePartialStatementDate(rawDate) != null) {
        unplaceable++;
      } else {
        problems.add(
          'Line $at: no date could be read'
          '${rawDate == null ? '' : ' from "$rawDate"'}.',
        );
      }
      continue;
    }
    anchorDate ??= date;

    final amount = rawAmount == null ? null : _number(rawAmount);
    if (amount == null) {
      problems.add(
        'Line $at: no amount could be read'
        '${rawAmount == null ? '' : ' from "$rawAmount"'}.',
      );
      continue;
    }

    rows.add(StatementRow(
      date: date,
      amount: amount,
      description: _first(row, const ['description']),
      reference: _first(row, const ['reference']),
      // Passed through rather than dropped, and it is the most
      // valuable field on the row: it is what `0369` checks the rest
      // of the reading against.
      balance: _numberOrNull(_first(row, const ['running_balance'])),
    ));
  }

  if (unplaceable > 0) {
    problems.add(
      '$unplaceable ${unplaceable == 1 ? 'line prints' : 'lines print'} a '
      'day and a month with no year, and the statement\'s own date was '
      'not read — so there is nothing on the page to say which year they '
      'belong to. Nothing has been guessed. Send the page with the '
      'statement date or the period on it, or paste the statement in '
      'instead.',
    );
  }

  if (placedFromPeriod > 0 && period != null) {
    notices.add(
      '$placedFromPeriod ${placedFromPeriod == 1 ? 'line prints' : 'lines print'} '
      'a day and a month with no year. They have been placed in the year '
      'nearest ${_day(period.date)}, which is the statement\'s own date as '
      'printed on the file — "${period.evidence}". Nothing was guessed from '
      'today\'s date.',
    );
  }

  final put = balancesDecideTheSigns(rows, leading: leading, trailing: trailing);
  return StatementParse(
    put.rows,
    [...problems, ...put.problems],
    [...notices, ...put.notices],
  );
}

/// The sign of every scanned line, settled by the column that proves it.
///
/// ## The failure this exists for
///
/// A Malaysian retail statement prints two columns, Debit and Credit,
/// and NO SIGN. So a reader looking at a photograph has to infer the
/// sign from which column a figure sits in, and it gets that wrong
/// often enough to matter -- the field description asks for it
/// ("negative for money out") and a description is not a guarantee.
///
/// A wrong sign is the most expensive mistake available here, and until
/// now the only thing that caught it was `import_bank_transactions`,
/// which walks the running balance (`0369`) and REFUSES THE WHOLE
/// IMPORT naming one line. That is the right check and the wrong
/// remedy: somebody who photographed forty lines gets an error about
/// line 12 and no way forward but to type all forty in.
///
/// ## Why this can be done rather than guessed
///
/// The running balance is not an opinion. Where two consecutive lines
/// both carry one, the amount between them is ARITHMETIC:
///
///     oldest-first:  amount[i]   = balance[i] - balance[i-1]
///     newest-first:  amount[i-1] = balance[i-1] - balance[i]
///
/// So the reader's figure is a CHECK on that, not the source of it. If
/// it agrees, nothing happens. If it agrees in magnitude and disagrees
/// in sign, the sign is put right and said so. If it disagrees in
/// magnitude, NOTHING IS TOUCHED -- that is a missing line or a misread
/// figure, and it must still reach the refusal, because silently
/// rewriting an amount to make a chain close is how a statement comes
/// to reconcile against a number nobody printed.
///
/// ## Every delta is computed from the ORIGINAL balances
///
/// So the repairs cannot cascade: line 12 being wrong does not move
/// what line 13 is compared against. The balances are read values and
/// are never rewritten.
({List<StatementRow> rows, List<String> problems, List<String> notices})
    balancesDecideTheSigns(
  List<StatementRow> rows, {
  /// The balance printed above the first line — a brought-forward row
  /// on a statement that runs oldest-first.
  ///
  /// It matters out of proportion to its size: without it the FIRST
  /// line is the one line with no pair of balances either side of it,
  /// so it is the one line whose sign nothing can settle. With it,
  /// every line on the page is provable.
  double? leading,

  /// The balance printed below the last line, which is the same
  /// anchor for a statement that runs newest-first.
  double? trailing,
}) {
  final out = [...rows];
  final problems = <String>[];
  final notices = <String>[];
  if (rows.isEmpty) return (rows: out, problems: problems, notices: notices);

  // Which way the statement runs, off its own dates -- the same
  // question `import_bank_transactions` asks, answered the same way, so
  // the two cannot disagree about which line a pair of balances
  // describes.
  final newestFirst = rows.length > 1 && rows.last.date.isBefore(rows.first.date);

  // The chain in printed order, with the markers at each end. Index -1
  // is the leading marker and index `rows.length` the trailing one, so
  // one loop covers the ordinary pairs and both anchors without a
  // special case for either.
  double? balanceAt(int i) {
    if (i < 0) return leading;
    if (i >= rows.length) return trailing;
    return rows[i].balance;
  }

  for (var i = 0; i <= rows.length; i++) {
    final before = balanceAt(i - 1);
    final after = balanceAt(i);
    if (before == null || after == null) continue;

    // Forwards, a pair of balances describes the LATER line; backwards
    // it describes the earlier one, because going backwards is undoing
    // the movement that got you there.
    final at = newestFirst ? i - 1 : i;
    if (at < 0 || at >= rows.length) continue;
    final delta = newestFirst ? before - after : after - before;
    final was = out[at].amount;

    if ((delta - was).abs() < _sen) continue; // already right

    if ((delta + was).abs() < _sen) {
      out[at] = StatementRow(
        date: out[at].date,
        amount: delta,
        description: out[at].description,
        reference: out[at].reference,
        balance: out[at].balance,
      );
      notices.add(
        'Line ${at + 1}: read as ${_money(was)} but the balance moves by '
        '${_money(delta)}, so it is ${delta < 0 ? 'money out' : 'money in'}. '
        'Corrected.',
      );
      continue;
    }

    // Neither. Said here rather than left for the RPC, so it is on
    // screen BEFORE somebody presses Import -- but not repaired, and
    // the import will still be refused if they go ahead.
    problems.add(
      'Line ${at + 1}: read as ${_money(was)}, but the balance moves by '
      '${_money(delta)}. A line is missing, or one of these figures was '
      'misread.',
    );
  }

  return (rows: out, problems: problems, notices: notices);
}

/// Half a sen, which is the right width for a figure carried to two
/// places: it absorbs the representation error in a difference of
/// doubles and nothing else. A whole sen would let a real one-sen
/// transposition through, and a one-sen transposition is a real error.
const _sen = 0.005;

/// Two places and a sign, for a sentence a person reads rather than a
/// figure a column aligns. `Fmt` is not imported here on purpose: this
/// file is parsing, and it is tested without Flutter.
String _money(double v) => v.toStringAsFixed(2);

/// A date in a sentence somebody reads, rather than in a field.
///
/// Day first, because this is Malaysia and the notice sits beside a
/// statement printed the same way.
String _day(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/${d.year}';

/// Which of the dialog's three sources is previewed and imported.
///
/// A photograph wins over whatever is in the text box, because it is
/// the thing somebody just did -- and because the two cannot be merged:
/// they are two readings of what is probably the same statement, and
/// importing both would put every line in twice under two slightly
/// different descriptions, which is exactly the case
/// `import_bank_transactions` deduplicates worst.
///
/// Its own function rather than an expression inside `build`, because
/// the precedence is the rule and a rule inside a widget that needs a
/// camera to reach cannot be asserted.
/// What stands above the notices in the import dialog.
///
/// A pure function for one line of text, because that line was WRONG in
/// production and nothing could have caught it. It read:
///
///     "$n lines were corrected against the running balance"
///
/// which was true while a sign repair was the only notice that existed
/// and false the moment a second kind did. It was wrong twice over. It
/// named a cause — the running balance — that no longer applied to
/// every notice under it, so a year taken off the statement header was
/// announced as an arithmetic correction. And it counted NOTICES as
/// LINES, which were the same number only by accident: one notice
/// covering fifty-five undated lines would have introduced itself as
/// one line.
///
/// Both facts belong to the notices themselves, each of which says its
/// own count and its own cause. So this says neither, and the dialog
/// has no arithmetic of its own left to get wrong.
String noticesHeading(int count) => count == 1
    ? 'One thing worth knowing before you import'
    : '$count things worth knowing before you import';

StatementParse? statementPreview(StatementParse? scanned, String typed) =>
    scanned ?? (typed.trim().isEmpty ? null : parseStatement(typed));

/// The first of [keys] the row actually carries, trimmed, or null.
///
/// Several keys because the console's checklist is the real columns of
/// `bank_transactions` and an administrator may reasonably tick
/// `value_date` rather than `transaction_date` — they are both dates on
/// the paper and a statement often prints only one.
String? _first(Map<String, String> row, List<String> keys) {
  for (final k in keys) {
    final v = row[k]?.trim();
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}

double? _numberOrNull(String? raw) => raw == null ? null : _number(raw);
