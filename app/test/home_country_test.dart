import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/onboarding/home_country.dart';

/// The country the setup form starts on.
///
/// It used to start on nothing: a list of two hundred countries with no
/// answer offered, standing in front of the form. This is a Malaysian
/// product — SSM, LHDN, SST, EPF — so the commonest answer is filled in
/// and the question stays on the form for whoever it is wrong for.
///
/// What is asserted here is the pair of things that could go wrong with
/// that: a default that is not actually Malaysia, and a default that
/// cannot be changed or that quietly changes what a company outside
/// Malaysia is promised.
void main() {
  group('the answer already filled in', () {
    test('is Malaysia, in both the forms the app needs', () {
      // Three letters for `organizations.country_code`, two for Google
      // Places. Not the same string with a letter removed: MYS and MY
      // agree here by coincidence, and PRT and PT do not.
      expect(homeCountryCode, 'MYS');
      expect(homeCountryAlpha2, 'MY');
      expect(homeCountryCode.length, 3);
      expect(homeCountryAlpha2.length, 2);
    });

    test('and says so before the reference table has loaded', () {
      expect(homeCountryName, 'Malaysia');
    });

    test('the line offers a way out of it', () {
      // A default nobody can change is a decision taken away.
      expect(countryChangeLabel.toLowerCase(), 'change');
      expect(countryChangeHint.toLowerCase(), contains('not the same'));
    });
  });

  group('what the setup promises', () {
    test('names the Malaysian instruments at home', () {
      final promise = setupPromise(malaysian: true);
      expect(promise, contains('Malaysian'));
      expect(promise, contains('SST'));
    });

    test('and promises neither of them anywhere else', () {
      // The assertion that would fail if the sentence were left as one
      // string: a company in Singapore being told it is getting SST tax
      // codes has been promised something it did not want.
      final promise = setupPromise(malaysian: false);
      expect(promise, isNot(contains('Malaysian')));
      expect(promise, isNot(contains('SST')));
      expect(promise, contains('chart of accounts'));
    });
  });

  group('the list behind the line', () {
    final rows = [
      {'code': 'AUS', 'name': 'Australia', 'alpha2': 'AU'},
      {'code': 'MYS', 'name': 'Malaysia', 'alpha2': 'MY'},
      {'code': 'SGP', 'name': 'Singapore', 'alpha2': 'SG'},
    ];

    test('puts Malaysia first', () {
      final shown = countriesWithHomeFirst(rows);
      expect(shown.first['code'], 'MYS');
    });

    test('without losing or duplicating anybody', () {
      final shown = countriesWithHomeFirst(rows);
      expect(shown.length, rows.length);
      expect(
        shown.map((c) => c['code']).toSet(),
        {'AUS', 'MYS', 'SGP'},
      );
    });

    test('and keeps the rest in the order they arrived', () {
      // Alphabetical, from the query. Pinning one row must not reorder
      // the others.
      final shown = countriesWithHomeFirst(rows);
      expect(shown.map((c) => c['name']).toList(),
          ['Malaysia', 'Australia', 'Singapore']);
    });

    test('and does not put it back when a search has excluded it', () {
      // The one that matters: somebody typing "sing" is looking for
      // Singapore, and a Malaysia pinned above the thing they searched
      // for is the list arguing with them.
      final filtered = [rows[2]];
      expect(countriesWithHomeFirst(filtered), filtered);
      expect(countriesWithHomeFirst(const []), isEmpty);
    });
  });
}
