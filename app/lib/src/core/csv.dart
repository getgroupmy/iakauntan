/// Reading the comma-separated file somebody exported from whatever
/// they were using before.
///
/// Lifted out of the bank statement importer so there is one parser
/// rather than two. The quoting rules are the part worth having in one
/// place: a description containing a comma shifts every column after it
/// if they are got wrong, and the symptom is a reconciliation against
/// the wrong number rather than an error.
library;

/// Splits one line, honouring double quotes.
///
/// Tabs count as separators too, because pasting from a spreadsheet
/// gives tabs and nobody thinks of that as a different file format.
List<String> splitCsvLine(String line) {
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

/// A file read into rows keyed by the header, with the header itself
/// kept so a screen can say which columns it recognised and which it
/// ignored.
class CsvTable {
  const CsvTable({
    required this.header,
    required this.rows,
    required this.problems,
  });

  final List<String> header;
  final List<Map<String, String>> rows;
  final List<String> problems;

  bool get isEmpty => rows.isEmpty;
}

/// Reads a pasted file, mapping each header cell through [fieldFor].
///
/// [fieldFor] returns the field name a column belongs to, or null for a
/// column nothing here understands — which is not an error. A file
/// exported from another system carries columns this one has no use
/// for, and refusing the whole file over a spare column would be a
/// reason to give up on the import rather than a reason to fix it.
CsvTable parseCsvTable(String text, String? Function(String) fieldFor) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .where((l) => l.trim().isNotEmpty)
      .toList();

  if (lines.length < 2) {
    return const CsvTable(
      header: [],
      rows: [],
      problems: ['Paste the header row and at least one line under it.'],
    );
  }

  final raw = splitCsvLine(lines.first).map((h) => h.trim()).toList();
  final fields = raw.map(fieldFor).toList();
  final problems = <String>[];

  if (fields.every((f) => f == null)) {
    return CsvTable(
      header: raw,
      rows: const [],
      problems: [
        'None of these columns were recognised: ${raw.join(', ')}. '
            'The first row has to be a header.'
      ],
    );
  }

  // The same field twice means one of them silently wins, and which one
  // depends on column order — worth stopping for.
  final seen = <String>{};
  for (final f in fields) {
    if (f != null && !seen.add(f)) {
      problems.add('The column "$f" appears more than once.');
    }
  }

  final rows = <Map<String, String>>[];
  for (var i = 1; i < lines.length; i++) {
    final cells = splitCsvLine(lines[i]);
    final row = <String, String>{};
    for (var c = 0; c < fields.length; c++) {
      final field = fields[c];
      if (field == null) continue;
      final value = c < cells.length ? cells[c].trim() : '';
      if (value.isNotEmpty) row[field] = value;
    }
    // A line of empty cells is what a trailing comma row looks like.
    if (row.isNotEmpty) rows.add(row);
  }

  if (rows.isEmpty && problems.isEmpty) {
    problems.add('The header was read but there is nothing under it.');
  }

  return CsvTable(header: raw, rows: rows, problems: problems);
}

/// Maps a header cell onto a field name, given the names each field
/// answers to. Comparison ignores case, spaces and underscores, so
/// "Credit Limit", "credit_limit" and "creditlimit" are one column.
String? Function(String) headerMapper(Map<String, List<String>> aliases) {
  String key(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[\s_\-\.]'), '');

  final lookup = <String, String>{};
  aliases.forEach((field, names) {
    lookup[key(field)] = field;
    for (final n in names) {
      lookup[key(n)] = field;
    }
  });

  return (String header) => lookup[key(header)];
}
