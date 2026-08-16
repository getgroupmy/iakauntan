import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';

/// Closing your own account.
///
/// The rules are asserted in `supabase/tests/close_my_account.sql`: the
/// identity is scrubbed, the audit trail survives, and the sole owner of
/// a company is refused. What is asserted here is the one thing the
/// screen has to get right on its own — that it asks the database what
/// stands in the way *before* offering the button, rather than offering
/// it and letting the call fail.
void main() {
  ProviderContainer harness(List<Map<String, dynamic>> blockers) {
    final c = ProviderContainer(
      overrides: [
        repoProvider.overrideWithValue(null),
        accountDeletionBlockersProvider.overrideWith((ref) async => blockers),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('nothing in the way means the account can be closed', () async {
    final c = harness(const []);
    final rows = await c.read(accountDeletionBlockersProvider.future);
    expect(rows, isEmpty);
  });

  test('the sole owner of a company is told which company', () async {
    final c = harness(const [
      {
        'organization': 'Kabeer Trading Sdn Bhd',
        'reason': 'You are the only owner.',
      },
    ]);
    final rows = await c.read(accountDeletionBlockersProvider.future);
    expect(rows, hasLength(1));
    expect(rows.single['organization'], 'Kabeer Trading Sdn Bhd');
  });

  test('and more than one is listed rather than summarised', () async {
    // The message joins them, so a person who owns three companies is
    // told about three rather than "some of your companies".
    final c = harness(const [
      {'organization': 'One Sdn Bhd', 'reason': 'x'},
      {'organization': 'Two Sdn Bhd', 'reason': 'x'},
    ]);
    final rows = await c.read(accountDeletionBlockersProvider.future);
    expect(
      rows.map((r) => r['organization']).join(', '),
      'One Sdn Bhd, Two Sdn Bhd',
    );
  });
}
