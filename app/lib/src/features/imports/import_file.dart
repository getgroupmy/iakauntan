/// Reading a file somebody uploads on the import screen.
///
/// The screen has taken a pasted file since it was written, and pasting
/// a two-hundred-row chart of accounts out of a spreadsheet is not a
/// thing anybody does twice. This is the same file, read rather than
/// retyped.
///
/// The decoding is the whole of the difficulty and it is worth being
/// explicit about, because the failure it prevents is silent. A CSV
/// saved by Excel on a Malaysian Windows machine is very often not
/// UTF-8: it is code page 1252, and a supplier called `Ünal` or a road
/// called `Jalan Cangkat Râja` arrives as a byte that UTF-8 cannot
/// decode. `utf8.decode` with `allowMalformed` turns those into U+FFFD
/// rather than throwing, so the file imports with a replacement
/// character sitting in a customer's name, in the database, for ever.
///
/// So the decode is strict, and a file that is not UTF-8 is refused
/// with a sentence saying what to do about it — which somebody can act
/// on in ten seconds, unlike a name with a black diamond in it that
/// nobody notices for a year.
library;

import 'dart:convert';
import 'dart:typed_data';

/// What came back from reading an uploaded file.
///
/// A record rather than an exception, because "the file is not UTF-8"
/// is a thing the screen shows in its own error panel beside the other
/// import failures, not something to throw through a button handler.
typedef ImportFileRead = ({String? text, String? problem});

/// The largest file worth reading into a text field.
///
/// Two megabytes is somewhere around twenty thousand rows of contacts,
/// which is far past what this screen is for and still small enough to
/// hold in memory on a phone. A 200 MB export picked by accident should
/// say so rather than locking the tab.
const importFileLimit = 2 * 1024 * 1024;

/// The extensions offered in the file dialog.
const importFileExtensions = ['csv', 'txt', 'tsv'];

/// Decodes an uploaded file, or says why it could not.
ImportFileRead readImportFile(Uint8List bytes, {String? name}) {
  if (bytes.isEmpty) {
    return (text: null, problem: 'That file is empty.');
  }
  if (bytes.length > importFileLimit) {
    return (
      text: null,
      problem:
          'That file is ${(bytes.length / (1024 * 1024)).toStringAsFixed(1)} '
          'MB, and this reads up to 2 MB. Split it, or import it in '
          'batches.',
    );
  }

  // A UTF-8 byte-order mark. Excel writes one, and left in place it
  // becomes an invisible character on the front of the first heading —
  // so `code` stops matching `code` and every row is missing its
  // account number for a reason nobody can see.
  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3;
  }

  try {
    final text = const Utf8Decoder(allowMalformed: false).convert(bytes, start);
    if (text.trim().isEmpty) {
      return (text: null, problem: 'There is nothing in that file.');
    }
    return (text: text, problem: null);
  } on FormatException {
    return (
      text: null,
      problem:
          '${name ?? 'That file'} is not UTF-8 — it was probably saved by '
          'Excel as "CSV". Save it again as "CSV UTF-8", or paste it into '
          'the box below instead. Reading it anyway would put a black '
          'diamond in somebody’s name and leave it there.',
    );
  }
}
