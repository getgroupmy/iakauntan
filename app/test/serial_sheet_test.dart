import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/pos/serial_sheet.dart';

/// The scan field `0540` said a till needed, and `0546` built.
///
/// What is asserted here is the design decision, not the widget: EVERY
/// SCAN GOES TO THE SERVER AS IT HAPPENS. The obvious build keeps a
/// list locally and sends it at payment, and that build refuses six
/// scans deep, in front of a queue, with the bag packed and no clue
/// which label was wrong. So the test counts the round trips and reads
/// the refusal.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<String> serials,
    required Future<List<String>> Function(String) onScan,
    Future<List<String>> Function(String)? onRemove,
  }) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SerialSheet(
              description: 'Telefon pintar',
              serials: serials,
              onScan: onScan,
              onRemove: onRemove ?? (s) async => const [],
            ),
          ),
        ),
      );

  testWidgets('nothing scanned says so', (tester) async {
    await pump(tester, serials: const [], onScan: (_) async => const []);
    expect(find.text('Nothing scanned yet.'), findsOneWidget);
    expect(find.text('Scan the serial number on each one'), findsOneWidget);
  });

  testWidgets('a scan goes to the server as it happens', (tester) async {
    final sent = <String>[];
    await pump(
      tester,
      serials: const [],
      onScan: (s) async {
        sent.add(s);
        return ['SN-A1'];
      },
    );

    await tester.enterText(find.byKey(const ValueKey('serial-field')), 'SN-A1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(sent, ['SN-A1'], reason: 'one scan, one round trip');
    expect(find.byKey(const ValueKey('serial-SN-A1')), findsOneWidget);
    expect(find.text('1 scanned'), findsOneWidget);
  });

  testWidgets('the label is trimmed, and a blank one is not sent',
      (tester) async {
    final sent = <String>[];
    await pump(
      tester,
      serials: const [],
      onScan: (s) async {
        sent.add(s);
        return [s];
      },
    );

    await tester.enterText(find.byKey(const ValueKey('serial-field')), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(sent, isEmpty, reason: 'nothing is not a serial number');

    await tester.enterText(
        find.byKey(const ValueKey('serial-field')), '  SN-B2  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(sent, ['SN-B2']);
  });

  testWidgets('a refusal names the label and the field keeps its place',
      (tester) async {
    await pump(
      tester,
      serials: const ['SN-A1'],
      onScan: (s) async => throw Exception(
          'PostgrestException(message: Serial SN-A1 is already on this '
          'line., code: 23514)'),
    );

    await tester.enterText(find.byKey(const ValueKey('serial-field')), 'SN-A1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // The server's sentence, without the exception's wrapping around
    // it. A cashier reading "PostgrestException(message: ..." at arm's
    // length on a bright counter reads none of it.
    final error = tester.widget<Text>(
      find.byKey(const ValueKey('serial-error')),
    );
    expect(error.data, 'Serial SN-A1 is already on this line.');
    expect(error.data, isNot(contains('PostgrestException')));

    // And what was already scanned is still there — a refusal is not a
    // reason to lose the four labels that went in before it.
    expect(find.byKey(const ValueKey('serial-SN-A1')), findsOneWidget);
  });

  testWidgets('a mis-scan comes off', (tester) async {
    final removed = <String>[];
    await pump(
      tester,
      serials: const ['SN-A1', 'SN-A2'],
      onScan: (_) async => const [],
      onRemove: (s) async {
        removed.add(s);
        return ['SN-A1'];
      },
    );

    expect(find.text('2 scanned'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('serial-remove-SN-A2')));
    await tester.pumpAndSettle();

    expect(removed, ['SN-A2']);
    expect(find.byKey(const ValueKey('serial-SN-A2')), findsNothing);
    expect(find.text('1 scanned'), findsOneWidget);
  });

  testWidgets('closing hands back what was scanned', (tester) async {
    List<String>? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                got = await showModalBottomSheet<List<String>>(
                  context: context,
                  builder: (_) => SerialSheet(
                    description: 'Telefon pintar',
                    serials: const ['SN-A1'],
                    onScan: (_) async => const [],
                    onRemove: (_) async => const [],
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('serial-close')));
    await tester.pumpAndSettle();
    expect(got, ['SN-A1']);
  });
}
