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
///
/// ## Except for the one byte that is not a letter
///
/// That reasoning is about LETTERS. A 160-row export was refused on the
/// strength of two bytes, both `0xA0`, one trailing "GOH KOK HUAT" and
/// one in front of "TF AUTO PARTS SDN. BHD" — a non-breaking space,
/// which somebody's spreadsheet picked up from a web page years ago.
///
/// Refusing that protects nothing. There is no name to mangle: 0xA0 is
/// a space in Latin-1, in code page 1252 and in Unicode alike, and
/// `String.trim()` removes it along with the ordinary kind, so it never
/// reaches the database at all.
///
/// Worse, the advice was wrong for this file. Re-saving it as "CSV
/// UTF-8" succeeds — and leaves the non-breaking space INSIDE the name,
/// now as legal UTF-8, where it stops "GOH KOK HUAT" matching "GOH KOK
/// HUAT" for ever after. The refusal was sending people towards the
/// exact fault it exists to prevent.
///
/// So a lone 0xA0 is swapped for a space and the file is read. Nothing
/// else is guessed at: the swapped bytes are decoded STRICTLY again,
/// and that only succeeds if every other byte in the file was already
/// valid UTF-8. A 0xA0 that is part of a real multi-byte character
/// cannot be rescued this way and is not — replacing a continuation
/// byte with a space always breaks the sequence, so the retry fails and
/// the file is refused exactly as before.
library;

import 'dart:convert';
import 'dart:typed_data';

/// What came back from reading an uploaded file.
///
/// A record rather than an exception, because "the file is not UTF-8"
/// is a thing the screen shows in its own error panel beside the other
/// import failures, not something to throw through a button handler.
typedef ImportFileRead = ({String? text, String? problem, String? note});

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
    return (text: null, problem: 'That file is empty.', note: null);
  }
  if (bytes.length > importFileLimit) {
    return (
      text: null,
      problem:
          'That file is ${(bytes.length / (1024 * 1024)).toStringAsFixed(1)} '
          'MB, and this reads up to 2 MB. Split it, or import it in '
          'batches.',
      note: null,
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

  var text = _strict(bytes, start);
  String? note;

  if (text == null) {
    // The non-breaking space, and only that. See the note above: it is
    // whitespace in every encoding this could be, so swapping it for a
    // space decides nothing about a letter.
    final swapped = Uint8List.fromList(bytes);
    var found = 0;
    for (var i = start; i < swapped.length; i++) {
      if (swapped[i] == 0xA0) {
        swapped[i] = 0x20;
        found++;
      }
    }
    if (found > 0) {
      text = _strict(swapped, start);
      if (text != null) {
        note =
            'Read it, with ${found == 1 ? 'one non-breaking space' : '$found '
                  'non-breaking spaces'} treated as ordinary '
            '${found == 1 ? 'space' : 'spaces'}. They were the only thing '
            'in it that was not UTF-8, and a space either way is not part '
            'of anybody’s name.';
      }
    }
  }

  if (text == null) {
    return (
      text: null,
      problem:
          '${name ?? 'That file'} is not UTF-8 — it was probably saved by '
          'Excel as "CSV". ${_whereItIs(bytes, start)}Save it again as '
          '"CSV UTF-8", or paste it into the box below instead. Reading '
          'it anyway would put a black diamond in somebody’s name and '
          'leave it there.',
      note: null,
    );
  }

  if (text.trim().isEmpty) {
    return (
      text: null,
      problem: 'There is nothing in that file.',
      note: null,
    );
  }
  return (text: text, problem: null, note: note);
}

/// Strict UTF-8, or null where it will not decode.
String? _strict(Uint8List bytes, int start) {
  try {
    return const Utf8Decoder(allowMalformed: false).convert(bytes, start);
  } on FormatException {
    return null;
  }
}

/// Which line the trouble is on, so somebody can go and look at it.
///
/// Without this the message is unactionable on any file worth
/// importing: the report that prompted it was 160 rows with two bad
/// bytes in it, both invisible. "Save it again as CSV UTF-8" is not
/// advice somebody can check the result of when they cannot see what
/// was wrong.
String _whereItIs(Uint8List bytes, int start) {
  for (var i = start; i < bytes.length; i++) {
    if (bytes[i] < 0x80) continue;
    // The first byte the decoder could not use. Re-decoding the run up
    // to here is the cheapest way to be sure it is that byte and not a
    // legal multi-byte character earlier in the line.
    if (_strict(Uint8List.sublistView(bytes, start, i + 1), 0) != null) {
      continue;
    }
    var line = 1;
    for (var j = start; j < i; j++) {
      if (bytes[j] == 0x0A) line++;
    }
    final hex = bytes[i].toRadixString(16).padLeft(2, '0').toUpperCase();
    return 'The first byte it cannot read is 0x$hex, on line $line. ';
  }
  return '';
}
