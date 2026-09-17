import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/places_repository.dart';
import 'package:iakauntan/src/core/address_field.dart';

/// The address box that suggests, and the country asked before it.
///
/// `0351`. What is pressed here is the box, because two of the things
/// it has to get right are invisible when they are wrong:
///
///   * replies arrive out of order. A three-letter query can come back
///     after the five-letter one that followed it, and the list goes
///     backwards under somebody who is still typing — the suggestions
///     are real, they are just for a query that is no longer on screen;
///   * and the session token. Places bills the keystrokes leading to
///     one chosen address as a single unit *if* they carry the same
///     token. A fresh token per keystroke is a correct-looking box with
///     a bill an order of magnitude too big, and nothing on the screen
///     says so.
class _FakePlaces implements PlacesRepository {
  _FakePlaces({this.gate});

  /// Queries seen, in order, each with the session it carried.
  final asked = <({String q, String? session})>[];
  final chosen = <({String id, String? session})>[];

  /// When set, a reply waits for its completer rather than returning —
  /// which is how an out-of-order answer is arranged.
  final Map<String, Completer<List<PlaceSuggestion>>>? gate;

  @override
  Future<({List<PlaceSuggestion> suggestions, bool configured})> suggest(
    String query, {
    String? country,
    String? session,
  }) async {
    asked.add((q: query, session: session));
    final held = gate?[query];
    final list = held == null
        ? [(id: 'id-$query', line: '$query Street', detail: 'Kuala Lumpur')]
        : await held.future;
    return (suggestions: list, configured: true);
  }

  @override
  Future<PlaceAddress?> address(String placeId, {String? session}) async {
    chosen.add((id: placeId, session: session));
    return (
      line1: '12 Jalan Ampang',
      city: 'Kuala Lumpur',
      postcode: '50450',
      state: 'Wilayah Persekutuan Kuala Lumpur',
      country: 'Malaysia',
      formatted: '12 Jalan Ampang, 50450 Kuala Lumpur',
    );
  }
}

void main() {
  Widget wrap(PlacesRepository places, TextEditingController controller,
          {void Function(PlaceAddress)? onChosen}) =>
      ProviderScope(
        overrides: [placesProvider.overrideWithValue(places)],
        child: MaterialApp(
          home: Scaffold(
            body: AddressField(
              controller: controller,
              country: 'MY',
              onChosen: onChosen ?? (_) {},
            ),
          ),
        ),
      );

  testWidgets('nothing is asked until there is enough to ask about',
      (tester) async {
    // Every call is billed, and two letters is the whole index.
    final places = _FakePlaces();
    await tester.pumpWidget(wrap(places, TextEditingController()));

    await tester.enterText(find.byType(TextFormField), 'ja');
    await tester.pumpAndSettle();

    expect(places.asked, isEmpty);

    await tester.enterText(find.byType(TextFormField), 'jala');
    await tester.pumpAndSettle();

    expect(places.asked.map((a) => a.q), ['jala']);
  });

  testWidgets('a stale reply does not overwrite a newer one',
      (tester) async {
    // The failure this is written for: the answer to "jala" arriving
    // after the answer to "jalan ampang", and the list going backwards
    // under somebody who has finished typing.
    final slow = Completer<List<PlaceSuggestion>>();
    final places = _FakePlaces(gate: {'jala': slow});
    await tester.pumpWidget(wrap(places, TextEditingController()));

    await tester.enterText(find.byType(TextFormField), 'jala');
    await tester.pump();
    await tester.enterText(find.byType(TextFormField), 'jalan ampang');
    await tester.pumpAndSettle();

    expect(find.text('jalan ampang Street'), findsOneWidget);

    // And now the old one lands.
    slow.complete([(id: 'stale', line: 'jala Street', detail: '')]);
    await tester.pumpAndSettle();

    expect(find.text('jala Street'), findsNothing);
    expect(find.text('jalan ampang Street'), findsOneWidget);
  });

  testWidgets('one session covers the typing and the address it led to',
      (tester) async {
    final places = _FakePlaces();
    await tester.pumpWidget(wrap(places, TextEditingController()));

    await tester.enterText(find.byType(TextFormField), 'jala');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'jalan');
    await tester.pumpAndSettle();

    final sessions = places.asked.map((a) => a.session).toSet();
    expect(sessions.length, 1, reason: 'every keystroke, one session');
    expect(sessions.first, isNotNull);

    await tester.tap(find.text('jalan Street'));
    await tester.pumpAndSettle();

    expect(places.chosen.single.session, sessions.first,
        reason: 'the details call closes the session it belongs to');
  });

  testWidgets('and the next address starts a new one', (tester) async {
    final places = _FakePlaces();
    await tester.pumpWidget(wrap(places, TextEditingController()));

    await tester.enterText(find.byType(TextFormField), 'jalan');
    await tester.pumpAndSettle();
    await tester.tap(find.text('jalan Street'));
    await tester.pumpAndSettle();

    final first = places.asked.first.session;

    await tester.enterText(find.byType(TextFormField), 'lorong');
    await tester.pumpAndSettle();

    expect(places.asked.last.session, isNot(first),
        reason: 'a closed session must not be reused');
  });

  testWidgets('choosing one fills the boxes beside it', (tester) async {
    final places = _FakePlaces();
    final controller = TextEditingController();
    PlaceAddress? got;

    await tester.pumpWidget(
      wrap(places, controller, onChosen: (a) => got = a),
    );

    await tester.enterText(find.byType(TextFormField), 'jalan');
    await tester.pumpAndSettle();
    await tester.tap(find.text('jalan Street'));
    await tester.pumpAndSettle();

    // The street line lands in the box somebody was typing in; the
    // rest go to their own boxes, which is the point of suggesting
    // rather than pasting one long string.
    expect(controller.text, '12 Jalan Ampang');
    expect(got?.city, 'Kuala Lumpur');
    expect(got?.postcode, '50450');
  });
}
