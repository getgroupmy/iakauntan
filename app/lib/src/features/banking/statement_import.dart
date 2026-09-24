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
  const StatementParse(this.rows, this.problems);

  final List<StatementRow> rows;

  /// One message per line that was skipped, with its line number. Shown
  /// rather than swallowed: a statement that imports 38 of 40 lines
  /// without saying so reconciles to the wrong number.
  final List<String> problems;

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

double? _number(String raw) {
  var s = raw.replaceAll(RegExp(r'[,\s]'), '').replaceAll('RM', '');
  if (s.isEmpty) return null;
  // Statements write a withdrawal either as -120.00 or as (120.00).
  if (s.startsWith('(') && s.endsWith(')')) {
    s = '-${s.substring(1, s.length - 1)}';
  }
  return double.tryParse(s);
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
StatementParse scannedStatement(OcrExtraction? read) {
  final rows = <StatementRow>[];
  final problems = <String>[];

  final source = read?.rows ?? const <Map<String, String>>[];
  for (var i = 0; i < source.length; i++) {
    final row = source[i];
    // 1-based, and the line number a person would count to on the
    // photograph rather than an index.
    final at = i + 1;

    final rawDate = _first(row, const ['transaction_date', 'value_date']);
    final rawAmount = _first(row, const ['amount']);

    if (rawDate == null && rawAmount == null) continue;

    final date = rawDate == null ? null : parseStatementDate(rawDate);
    if (date == null) {
      problems.add(
        'Line $at: no date could be read'
        '${rawDate == null ? '' : ' from "$rawDate"'}.',
      );
      continue;
    }

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

  return StatementParse(rows, problems);
}

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
