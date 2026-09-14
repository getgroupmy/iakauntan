import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/ocr_repository.dart';

/// Correcting a misread letterhead before it becomes a contact.
///
/// The supplier drawn out of a scan used to be written exactly as read:
/// the details were shown and the button saved them unchanged. The file
/// that did it already carried the argument against — a contact is a
/// lasting thing that turns up in reports, on statements and in the
/// e-Invoice submission — and had no moment at which anybody could
/// correct a lost digit.
///
/// The dialog needs a browser to drive properly, so what is asserted
/// here is the part that was silently wrong when the dialog was first
/// written: that an edit can CLEAR a field, not only change it.
void main() {
  OcrExtraction read() => const OcrExtraction(
    supplierName: 'TM Technology Services Sdn Bhd',
    supplierTaxId: 'W10-1808-31000123',
    supplierRegistrationNo: '200201003726',
    supplierEmail: 'billing@example.test',
    supplierPhone: '03-2222 3333',
    supplierAddress: 'Menara TM, Jalan Pantai Baharu',
    documentNo: 'INV-1',
    documentDate: null,
    currency: 'MYR',
    subtotal: null,
    taxAmount: null,
    totalAmount: 100,
    lines: [],
    note: null,
    rawText: null,
  );

  group('editing what was read', () {
    test('changes a field', () {
      final edited = read().copyWith(supplierRegistrationNo: '201901030189');
      expect(edited.supplierRegistrationNo, '201901030189');
      // And leaves the rest of the reading alone, which is why the
      // dialog hands back an extraction rather than a contact.
      expect(edited.totalAmount, 100);
      expect(edited.documentNo, 'INV-1');
    });

    test('but null does NOT clear one — this is the trap', () {
      // `copyWith` is written `supplierTaxId ?? this.supplierTaxId`, so
      // null means "leave it alone". A dialog that passed null for a
      // box somebody had emptied would silently keep the misread value,
      // which is the exact failure the dialog exists to prevent.
      final edited = read().copyWith(supplierRegistrationNo: null);
      expect(edited.supplierRegistrationNo, '200201003726');
    });

    test('so an emptied box travels as an empty string', () {
      // Which is what `_SupplierDraft._text` returns, and what `_create`
      // turns back into null on the way into the contact.
      final edited = read().copyWith(supplierRegistrationNo: '');
      expect(edited.supplierRegistrationNo, isEmpty);
    });
  });

  group('what reaches the contact', () {
    // `_create` is private, so this asserts the rule it applies rather
    // than calling it: an empty field becomes null, never an empty
    // string, because '' on a statement is a blank line somebody typed
    // and null is a field nobody filled in.
    String? clean(String? v) {
      final t = v?.trim() ?? '';
      return t.isEmpty ? null : t;
    }

    test('an emptied field becomes null and not an empty string', () {
      expect(clean(''), isNull);
      expect(clean('   '), isNull);
    });

    test('and a real value survives, trimmed', () {
      expect(clean('  200201003726 '), '200201003726');
    });
  });
}
