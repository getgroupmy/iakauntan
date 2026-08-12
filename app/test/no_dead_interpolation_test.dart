import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A guard against a defect the analyzer cannot see.
///
/// `'\${x}'` is perfectly valid Dart: an escaped dollar, a literal
/// "${x}" printed to the user. It analyzes clean, it passes every widget
/// test that does not read the text, and it ships a settings card that
/// says "Nothing open in a currency other than ${widget.org.baseCurrency}."
///
/// That happened here, in the foreign-balances card, because the file
/// was written through a shell heredoc that ate the escape. This is the
/// cheapest possible check that it has not happened again.
void main() {
  test('no string escapes a dollar it meant to interpolate', () {
    final offenders = <String>[];

    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains(r'\${')) {
          offenders.add('${file.path}:${i + 1}  ${lines[i].trim()}');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: 'these print a literal \${...} to the user:\n'
            '${offenders.join('\n')}');
  });
}
