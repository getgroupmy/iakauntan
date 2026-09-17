import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/features/admin/platform_console_screen.dart';

/// Not every platform setting is a JSON object.
///
/// Reported from the console: Service settings rendered as a flat grey
/// pane with nothing in it. Eight settings are stored and seven are
/// objects; `mail_domain` is a bare JSON string, because
/// `app.mail_domain()` reads it with `#>> '{}'` and that only works on
/// a scalar. The card did
///
///     Map<String, dynamic>.from(setting['value'] as Map? ?? {})
///
/// which throws on a string — and a throw inside `build` does not lose
/// one card, it loses the tab: a release build paints Flutter's grey
/// `ErrorWidget` box over the lot, so the seven settings that were
/// perfectly fine disappeared along with the one that was not.
///
/// The second half is quieter and would have outlived the first. The
/// editor parses "key: value" pairs, so saving `mail_domain` through
/// the console turned a string into `{}` — and `app.mail_domain()` then
/// falls through to its hard-coded default with nothing to say why.
void main() {
  Widget tab(List<Map<String, dynamic>> settings) => ProviderScope(
        overrides: [
          platformSettingsProvider.overrideWith((ref) async => settings),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: platformConsoleSections
                .firstWhere((s) => s.label == 'Service settings')
                .page,
          ),
        ),
      );

  final mixed = <Map<String, dynamic>>[
    {
      'key': 'mail_domain',
      'value': 'iakauntan.com',
      'description': 'The domain reserved addresses are issued on.',
    },
    {
      'key': 'trial_days',
      'value': {'days': 30},
      'description': 'How long a new company gets.',
    },
    {
      'key': 'signup_enabled',
      'value': {'enabled': true},
      'description': 'Whether anybody may sign up.',
    },
  ];

  testWidgets('a setting stored as a bare string does not take the tab down',
      (tester) async {
    await tester.pumpWidget(tab(mixed));
    await tester.pumpAndSettle();

    // The heading is the proof the tab built at all — it is what the
    // grey box replaced.
    expect(find.text('Backend service settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('and the settings either side of it still render',
      (tester) async {
    await tester.pumpWidget(tab(mixed));
    await tester.pumpAndSettle();

    // One card per setting, the scalar included.
    expect(find.byType(Card), findsNWidgets(3));
    // The string is shown as itself, not as an empty object.
    expect(
      find.widgetWithText(TextField, 'iakauntan.com'),
      findsOneWidget,
    );
  });

  testWidgets('a scalar gets a plain box and an object gets pairs',
      (tester) async {
    await tester.pumpWidget(tab(mixed));
    await tester.pumpAndSettle();

    expect(find.text('a single value, stored as it is typed'), findsOneWidget);
    expect(find.text('key: value, comma separated'), findsOneWidget);
    // `signup_enabled` is a lone on/off, so it is a switch rather than
    // a text box — that is three settings and only two editors.
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('a setting of nothing at all is still drawn', (tester) async {
    // `value` null is not a shape the seed produces, but it is a shape
    // jsonb allows, and the card must not be the thing that decides.
    await tester.pumpWidget(tab([
      {'key': 'unset', 'value': null, 'description': null},
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Backend service settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
