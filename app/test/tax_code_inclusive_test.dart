import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/line_draft.dart';

/// A price that already contains its tax — 0641.
///
/// Whether a price includes the tax is a property of the tax CODE, and
/// `app.calc_document_line` resolves it onto the line the moment the
/// code is chosen. Two things have to hold on this side of the wire:
/// the flag survives the round trip through PostgREST JSON, and the
/// figures the editor shows are the figures the trigger will store.
///
/// The second is the one worth a file. `computeLine` mirrors that
/// trigger, so a line that reads the code's flag and a preview that
/// does not is a screen quoting RM 108 and an invoice charging
/// RM 116.64 — and nobody looks at the total twice on the way to
/// pressing Post.
void main() {
  TaxCode code({
    double rate = 8,
    bool inclusive = false,
    String c = 'ST8',
  }) => TaxCode(
    id: 't-$c',
    code: c,
    name: 'Service tax',
    rate: rate,
    taxTypeCode: '02',
    isInclusive: inclusive,
  );

  group('the flag comes off the wire', () {
    test('as true only when the column says so', () {
      expect(
        TaxCode.fromJson({
          'id': 't1',
          'code': 'ST8',
          'name': 'Service tax',
          'rate': 8,
          'is_inclusive': true,
        }).isInclusive,
        isTrue,
      );
      expect(
        TaxCode.fromJson({'id': 't1', 'rate': 8}).isInclusive,
        isFalse,
      );
    });

    test('and a row that does not carry the column at all is exclusive', () {
      // Every code in every deployment is exclusive until somebody
      // turns this on — the column was never writable before 0641 — so
      // a missing key has to read as false rather than as null.
      expect(TaxCode.fromJson({'id': 't1'}).isInclusive, isFalse);
    });
  });

  group('how a code reads in a picker', () {
    test('an inclusive code says so beside its rate', () {
      expect(code(inclusive: true).pickerLabel, 'ST8 (8% incl.)');
    });

    test('and an exclusive one at the same rate does not', () {
      // The point of the marker: a company quoting retail inclusive and
      // trade exclusive has two codes at 8%, and without it they are
      // the same row twice in every list on every document.
      expect(code().pickerLabel, 'ST8 (8%)');
      expect(code().pickerLabel, isNot(code(inclusive: true).pickerLabel));
    });

    test('a zero-rated code says nothing either way', () {
      // `if new.is_tax_inclusive and coalesce(new.tax_rate, 0) > 0` —
      // the trigger's inclusive branch is not taken at a zero rate, so
      // the two compute identically and a marker would name a
      // difference that does not exist.
      expect(code(rate: 0, c: 'ZR').pickerLabel, 'ZR');
      expect(code(rate: 0, c: 'ZR', inclusive: true).pickerLabel, 'ZR');
    });
  });

  group('what the editor shows is what the trigger stores', () {
    ({double net, double tax, double total}) shown(TaxCode t, double price) {
      // Exactly what the tax picker's `onChanged` does to the line.
      final line = LineDraft(unitPrice: price)
        ..taxCodeId = t.id
        ..taxRate = t.rate
        ..isTaxInclusive = t.isInclusive;
      return line.totals;
    }

    test('RM 108 against an inclusive 8% code is RM 100 and RM 8', () {
      // The same line the SQL asserts in
      // `supabase/tests/pricing_and_dimensions.sql`. Both sides, on the
      // same numbers, because two implementations of one rule drift in
      // silence.
      final r = shown(code(inclusive: true), 108);

      expect(r.net, 100);
      expect(r.tax, 8);
      expect(r.total, 108);
    });

    test('and against the exclusive one it is RM 108 and RM 8.64', () {
      final r = shown(code(), 108);

      expect(r.net, 108);
      expect(r.tax, 8.64);
      expect(r.total, 116.64);
    });

    test('26 sen inclusive of 6% leaves a sen of tax, not two', () {
      // Where taking the tax by subtraction and recomputing it from the
      // net part company. Recomputing gives 2 sen and a line that
      // totals 27 against a price typed as 26. The SQL sweep had a
      // mutant survive on this until the same numbers went in there.
      final r = shown(code(rate: 6, inclusive: true, c: 'SR6'), 0.26);

      expect(r.net, 0.25);
      expect(r.tax, 0.01);
      expect(r.total, 0.26);
    });

    test('and a line the draft sends carries the flag with it', () {
      // `LineDraft.toJson` is what `saveDocument` inserts. The trigger
      // overrules it from the code anyway, but a draft that sent the
      // wrong flag would still have shown the wrong total for as long
      // as it was on screen.
      final line = LineDraft(unitPrice: 108, taxRate: 8)
        ..isTaxInclusive = true;

      expect(line.toJson()['is_tax_inclusive'], isTrue);
    });
  });
}
