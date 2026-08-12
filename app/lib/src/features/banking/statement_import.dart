/// Turning a pasted bank statement into rows the importer can take.
///
/// Malaysian banks export CSV in whatever shape they feel like, so this
/// reads the header rather than assuming column positions, and accepts
/// the two ways a statement expresses direction: one signed amount, or
/// separate debit and credit columns.
library;

/// One statement line, as read out of the paste.
class StatementRow {
  const StatementRow({
    required this.date,
    required this.amount,
    this.description,
    this.reference,
  });

  final DateTime date;

  /// Signed: positive is money in.
  final double amount;
  final String? description;
  final String? reference;

  Map<String, dynamic> toJson() => {
        'transaction_date':
            '${date.year.toString().padLeft(4, '0')}-'
                '${date.month.toString().padLeft(2, '0')}-'
                '${date.day.toString().padLeft(2, '0')}',
        'amount': amount,
        'description': description,
        'reference': reference,
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

/// Reads a pasted CSV statement.
///
/// The header row is required. Guessing which column is the date by
/// looking at the data works until a statement has two date columns, and
/// then it silently reconciles against the wrong one.
StatementParse parseStatement(String text) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.length < 2) {
    return const StatementParse([], ['Paste the header row and at least one line.']);
  }

  final header = _split(lines.first).map((h) => h.trim().toLowerCase()).toList();
  int find(List<String> names) =>
      header.indexWhere((h) => names.contains(h));

  final dateAt = find(_dateNames);
  final amountAt = find(_amountNames);
  final debitAt = find(_debitNames);
  final creditAt = find(_creditNames);
  final descAt = find(_descNames);
  final refAt = find(_refNames);

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
    final cells = _split(lines[i]);
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
    ));
  }

  return StatementParse(rows, problems);
}

/// Splits one CSV line, honouring double quotes so a description
/// containing a comma does not shift every column after it.
List<String> _split(String line) {
  final out = <String>[];
  final buffer = StringBuffer();
  var quoted = false;

  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      // A doubled quote inside a quoted field is one literal quote.
      if (quoted && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if ((ch == ',' || ch == '\t') && !quoted) {
      out.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  out.add(buffer.toString());
  return out;
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
