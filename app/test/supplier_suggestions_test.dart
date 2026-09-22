import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/shared/supplier_from_scan.dart';

/// The supplier a scanned bill came from, when it is not on file under
/// the name that is printed on it.
///
/// Both halves of this came off one screenshot. A phone showed:
///
///     PostgrestException(message: "failed to parse logic tree
///     ((name.ilike.%SHAHARUDIN, SHAM SUNDER & PARTNERS%, ...",
///     code: PGRST100)
///
/// `or` is not a parameter, it is a little language, and the printed
/// name was interpolated into it. Every Malaysian firm with a comma or
/// an `&` in its name was unsearchable.
///
/// The quieter half is worse and is why the user saw a bare supplier
/// picker rather than the "did you mean" dialog that already existed:
/// `resolveSupplier` catches a failed lookup and treats it as "no
/// supplier found", so the parse error arrived as an empty list of
/// near-misses next to a Create button — which is how a second contact
/// record for a company already on file gets made.
void main() {
  Contact contact({
    required String id,
    required String name,
    String code = '',
    String? registrationNo,
  }) => Contact(
    id: id,
    name: name,
    code: code,
    contactType: 'supplier',
    registrationNo: registrationNo,
  );

  group('a value inside an or() filter', () {
    // The exact name off the screenshot.
    test('a comma and an ampersand are quoted, not left as syntax', () {
      final v = Repo.orValue('%SHAHARUDIN, SHAM SUNDER & PARTNERS%');
      expect(v.startsWith('"'), isTrue);
      expect(v.endsWith('"'), isTrue);
      // The characters survive — this is quoting, not stripping. A
      // search that silently dropped the comma would find the wrong
      // supplier rather than none, which is worse.
      expect(v, contains('SHAHARUDIN, SHAM SUNDER & PARTNERS'));
    });

    test('a quote in the name cannot close the quoting', () {
      // `Sime "Darby" Bhd` — a value that ends the quoted string early
      // would put everything after it back into the grammar.
      final v = Repo.orValue('%Sime "Darby"%');
      expect(v, r'"%Sime \"Darby\"%"');
    });

    test('a backslash cannot escape the escaping', () {
      // Escaped FIRST, or `\"` would become `\\"` and the quote would
      // close after all.
      expect(Repo.orValue(r'a\b'), r'"a\\b"');
      expect(Repo.orValue(r'a\"b'), r'"a\\\"b"');
    });

    test('orLike builds one branch, escaped', () {
      expect(
        Repo.orLike('name', 'A, B'),
        'name.ilike."%A, B%"',
      );
    });
  });

  group('which supplier the document probably means', () {
    final onFile = [
      contact(id: '1', name: 'Shaharudin Sham Sunder and Partners',
          code: 'S-004'),
      contact(id: '2', name: 'Lim Hardware Trading', code: 'S-001'),
      contact(id: '3', name: 'Global Components Bhd', code: 'S-002'),
      contact(id: '4', name: 'Utara Logistik', code: 'S-003'),
    ];

    // The case from the screenshot. A substring search finds nothing —
    // the punctuation differs and `&` is spelled `and` — so without
    // this the dialog offers an empty list next to a Create button.
    test('a different spelling of the same firm is suggested', () {
      final got = rankedLikeName(
        onFile,
        'SHAHARUDIN, SHAM SUNDER & PARTNERS',
        null,
      );
      expect(got.first.id, '1');
    });

    test('and the unrelated suppliers are not', () {
      final got = rankedLikeName(
        onFile,
        'SHAHARUDIN, SHAM SUNDER & PARTNERS',
        null,
      );
      expect(got.map((c) => c.id), ['1']);
    });

    // The whole reason the generic words come off. Every second company
    // in Malaysia is a `Sdn Bhd` and half are `Trading`; a scorer that
    // counted them would rank all of them against all of them and the
    // suggestion would be noise.
    test('two companies that share only Sdn Bhd are not alike', () {
      final got = rankedLikeName([
        contact(id: '9', name: 'Kedai Basikal Ah Seng Sdn Bhd'),
      ], 'Syarikat Perabot Melaka Sdn Bhd', null);
      expect(got, isEmpty);
    });

    test('nor two that share only Trading', () {
      final got = rankedLikeName([
        contact(id: '9', name: 'Lim Hardware Trading'),
      ], 'Yusof Motor Trading', null);
      expect(got, isEmpty);
    });

    // A registration number is an identity, not a label. It settles the
    // question whatever the names say, and a supplier renamed after a
    // takeover is exactly when it matters.
    test('a matching SSM number outranks every name', () {
      final got = rankedLikeName([
        contact(id: '1', name: 'Something Else Entirely',
            registrationNo: '201901234567'),
        contact(id: '2', name: 'Shaharudin Sham Sunder and Partners'),
      ], 'SHAHARUDIN, SHAM SUNDER & PARTNERS', '2019-0123-4567');
      expect(got.first.id, '1');
    });

    // A short name on file against a long letterhead. The letterhead is
    // the long one, so scoring over the smaller set is what lets a
    // supplier saved as two words match six printed words.
    test('a short stored name matches a long letterhead', () {
      final got = rankedLikeName([
        contact(id: '1', name: 'TM Technology'),
      ], 'TM Technology Services Sdn Bhd 200201003726', null);
      expect(got.single.id, '1');
    });

    // A stored name that shares everything IT has, but only a third of
    // what the letterhead prints. Scoring over the larger set would
    // drop this, and it is the commonest shape there is: people type
    // the short trading name and letterheads print the long one.
    test('a two-word supplier matches a six-word letterhead', () {
      final got = rankedLikeName([
        contact(id: '1', name: 'Aneka Jaya'),
      ], 'Syarikat Perniagaan Aneka Jaya Kuala Lumpur', null);
      expect(got.single.id, '1');
    });

    // The other side of the same threshold. One word in common is a
    // coincidence, not a suggestion — and a dialog that offered every
    // shop with `Kedai` in its name would be worse than offering none.
    test('one word in common is a coincidence, not a match', () {
      final got = rankedLikeName([
        contact(id: '1', name: 'Kedai Buku Ilmu'),
      ], 'Kedai Runcit Pak Ali Cheras', null);
      expect(got, isEmpty);
    });

    test('nothing printed is nothing suggested', () {
      expect(rankedLikeName(onFile, '', null), isEmpty);
      expect(rankedLikeName(onFile, 'Sdn Bhd', null), isEmpty);
    });

    test('no contacts is no suggestions, not a crash', () {
      expect(rankedLikeName(const [], 'Anything At All', null), isEmpty);
    });

    // Five at the outside. A dialog listing twenty near-misses is a
    // dialog nobody reads, and the point of ranking is that the top of
    // the list is worth looking at.
    test('the list is short enough to read', () {
      final many = [
        for (var i = 0; i < 20; i++)
          contact(id: '$i', name: 'Shaharudin Sunder Number $i'),
      ];
      expect(rankedLikeName(many, 'SHAHARUDIN, SUNDER', null).length, 5);
    });
  });
}
