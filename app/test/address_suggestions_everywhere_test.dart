import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/address_field.dart';
import 'package:iakauntan/src/data/places_repository.dart';

/// The address box, now that it is on every screen that asks for one.
///
/// Two things move when a box goes from the setup screen to the whole
/// product, and both are the kind that look right and are not:
///
///   * the state. `state_code` is a foreign key into `ref_states` on
///     contacts and warehouses, so what fills that box has to be the
///     code and never the name. And the names do not line up: Google
///     says "Kuala Lumpur" where LHDN publishes "Wilayah Persekutuan
///     Kuala Lumpur", "Penang" where the list says "Pulau Pinang". A
///     matcher that only compares the two strings answers nothing for
///     five of the sixteen, including the one most Malaysian companies
///     are registered in;
///   * and the deployments with no Places key. Every screen now asks,
///     so every screen must stop asking once the function has said it
///     has no key — otherwise a company that never bought Places pays
///     a round trip per keystroke, forever, for an empty list.
const _states = [
  {'code': '04', 'name': 'Melaka'},
  {'code': '05', 'name': 'Negeri Sembilan'},
  {'code': '07', 'name': 'Pulau Pinang'},
  {'code': '10', 'name': 'Selangor'},
  {'code': '14', 'name': 'Wilayah Persekutuan Kuala Lumpur'},
  {'code': '15', 'name': 'Wilayah Persekutuan Labuan'},
  {'code': '16', 'name': 'Wilayah Persekutuan Putrajaya'},
];

class _FakePlaces implements PlacesRepository {
  _FakePlaces({this.configured = true});

  final bool configured;
  final asked = <String>[];

  @override
  Future<({List<PlaceSuggestion> suggestions, bool configured})> suggest(
    String query, {
    String? country,
    String? session,
  }) async {
    asked.add(query);
    return (
      suggestions: configured
          ? [(id: 'id', line: '$query Street', detail: '')]
          : const <PlaceSuggestion>[],
      configured: configured,
    );
  }

  @override
  Future<PlaceAddress?> address(String placeId, {String? session}) async => (
    line1: '12 Jalan Ampang',
    city: 'Kuala Lumpur',
    postcode: '50450',
    state: 'Kuala Lumpur',
    country: 'Malaysia',
    formatted: null,
  );
}

void main() {
  group('the state Google names, and the code the column holds', () {
    test('a name spelt the same way matches', () {
      expect(stateCodeFor(_states, 'Selangor'), '10');
    });

    test('the names LHDN spells differently still match', () {
      // Each of these is a company that picks its own address and
      // watches the state box stay empty, if the aliases go.
      expect(stateCodeFor(_states, 'Kuala Lumpur'), '14');
      expect(stateCodeFor(_states, 'Penang'), '07');
      expect(stateCodeFor(_states, 'Malacca'), '04');
      expect(stateCodeFor(_states, 'Negri Sembilan'), '05');
      expect(stateCodeFor(_states, 'Labuan'), '15');
      expect(stateCodeFor(_states, 'Putrajaya'), '16');
    });

    test('and so does the long form of a federal territory', () {
      expect(
        stateCodeFor(_states, 'Federal Territory of Kuala Lumpur'),
        '14',
      );
      expect(
        stateCodeFor(_states, 'Wilayah Persekutuan Kuala Lumpur'),
        '14',
      );
    });

    test('a state in another country is null, not a near miss', () {
      // Null is the whole point: `state_code` is a foreign key, so a
      // name written into it is not a slightly wrong value, it is a
      // row that will not save.
      expect(stateCodeFor(_states, 'Bangkok'), isNull);
      expect(stateCodeFor(_states, 'Singapore'), isNull);
      expect(stateCodeFor(_states, ''), isNull);
      expect(stateCodeFor(_states, null), isNull);
    });
  });

  group('filling the boxes beside the address', () {
    test('writes the code, never the name', () {
      final state = TextEditingController();
      fillAddressBoxes(
        (
          line1: '12 Jalan Ampang',
          city: 'Kuala Lumpur',
          postcode: '50450',
          state: 'Kuala Lumpur',
          country: 'Malaysia',
          formatted: null,
        ),
        _states,
        stateCode: state,
      );
      expect(state.text, '14');
    });

    test('leaves alone what the suggestion did not carry', () {
      // A shop that typed its postcode and then picked a suggestion
      // with none should keep the postcode it typed.
      final postcode = TextEditingController(text: '50450');
      final city = TextEditingController(text: 'Kuala Lumpur');
      final state = TextEditingController(text: '14');

      fillAddressBoxes(
        (
          line1: 'Somewhere',
          city: null,
          postcode: null,
          state: 'Bangkok',
          country: 'Thailand',
          formatted: null,
        ),
        _states,
        postcode: postcode,
        city: city,
        stateCode: state,
      );

      expect(postcode.text, '50450');
      expect(city.text, 'Kuala Lumpur');
      expect(state.text, '14', reason: 'an unmatched state must not clear it');
    });
  });

  testWidgets('a deployment with no key is asked once, not per keystroke',
      (tester) async {
    final places = _FakePlaces(configured: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [placesProvider.overrideWithValue(places)],
        child: MaterialApp(
          home: Scaffold(
            body: AddressField(
              controller: TextEditingController(),
              onChosen: (_) {},
            ),
          ),
        ),
      ),
    );

    for (final typed in ['jala', 'jalan', 'jalan a', 'jalan am']) {
      await tester.enterText(find.byType(TextFormField), typed);
      await tester.pumpAndSettle();
    }

    expect(places.asked, ['jala'],
        reason: 'the answer to "is there a key" does not change per letter');
  });

  testWidgets('and where there is a key it keeps asking', (tester) async {
    // The other direction, so the short circuit above cannot be
    // "stopped asking" by accident.
    final places = _FakePlaces();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [placesProvider.overrideWithValue(places)],
        child: MaterialApp(
          home: Scaffold(
            body: AddressField(
              controller: TextEditingController(),
              onChosen: (_) {},
            ),
          ),
        ),
      ),
    );

    for (final typed in ['jala', 'jalan', 'jalan a']) {
      await tester.enterText(find.byType(TextFormField), typed);
      await tester.pumpAndSettle();
    }

    expect(places.asked, ['jala', 'jalan', 'jalan a']);
  });
}
