import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/ticketing/ticket_screen.dart';

/// The ticket state machine exists twice: once in
/// `app.ticket_transition_allowed`, which decides, and once in
/// `kTicketTransitions`, which decides what buttons to draw.
///
/// The database is the one that matters — a move the UI offers but the
/// server refuses produces an error the user can read, which is
/// survivable. The dangerous direction is the other one: a legal move
/// the UI never offers is a thing the product can do that nobody can
/// reach, and nothing fails when it happens.
///
/// So rather than trusting the two to be kept in step by hand, this
/// reads the SQL and compares. It parses the CASE arms out of the
/// migration, which is crude but exact: the arms are one per line and
/// the shape has to change for the parse to break, at which point this
/// test fails loudly rather than silently passing.
void main() {
  test('the buttons match the state machine in the database', () {
    final sql = File('../supabase/migrations/0194_ticketing_lifecycle.sql')
        .readAsStringSync();

    // when 'new' then p_to in ('open','pending', ...)
    final arm = RegExp(
      r"when\s+'(\w+)'\s+then\s+p_to\s+in\s*\(([^)]*)\)",
      multiLine: true,
    );

    final fromSql = <String, List<String>>{};
    for (final m in arm.allMatches(sql)) {
      fromSql[m.group(1)!] = m
          .group(2)!
          .split(',')
          .map((s) => s.trim().replaceAll("'", ''))
          .where((s) => s.isNotEmpty)
          .toList()
        ..sort();
    }

    // `cancelled` is terminal, so it has no `in (...)` arm to match and
    // has to be added by hand. Asserted separately below rather than
    // assumed, or a parse that silently found nothing would look like a
    // machine with one terminal state.
    expect(
      sql.contains("when 'cancelled' then false"),
      isTrue,
      reason: 'cancelled is meant to be terminal in the SQL',
    );
    fromSql['cancelled'] = <String>[];

    // The positive control. If the regex stops matching — someone
    // reformats the CASE — every comparison below is vacuous, so the
    // count is asserted first.
    expect(
      fromSql.length,
      kTicketTransitions.length,
      reason: 'parsed ${fromSql.length} states out of the SQL but the Dart '
          'map has ${kTicketTransitions.length}; if the SQL was reformatted '
          'this parse needs updating',
    );
    expect(fromSql.length, greaterThanOrEqualTo(7));

    for (final entry in fromSql.entries) {
      final dart = [...?kTicketTransitions[entry.key]]..sort();
      expect(
        dart,
        entry.value,
        reason: 'from "${entry.key}" the database allows ${entry.value} but '
            'the UI offers $dart',
      );
    }
  });
}
