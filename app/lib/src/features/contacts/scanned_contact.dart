import '../../core/address_field.dart' show stateCodeFor;
import '../../data/ocr_repository.dart';
import 'scanned_address.dart';

/// What a reading puts in the contact form's boxes.
///
/// Keyed by the form's own controller names rather than by column, so
/// the editor writes what it is handed and decides nothing. The state
/// is separate because it is not a text box: `state_code` is a foreign
/// key into `ref_states`, and a name written into it is not a slightly
/// wrong value but a row that will not save.
class ScannedContact {
  const ScannedContact({this.boxes = const {}, this.stateCode});

  /// Controller name to text. Only boxes there is something to put in;
  /// a key that is absent means "leave it alone", which is not the same
  /// as blanking it.
  final Map<String, String> boxes;

  /// A `ref_states.code`, or null where the reading named no state or
  /// named one no row matches.
  final String? stateCode;

  bool get isEmpty => boxes.isEmpty && stateCode == null;
}

/// Where each configured column lands in the form.
///
/// This map is the whole of it: a column that is not named here and is
/// not part of the address block below reaches no box at all. That is
/// the answer for two of the sixteen columns `scan_target_fields` asks
/// for on `contacts.contact`. `website` is not on the `Contact` model,
/// so there is nothing to put it in -- it stays visible on the scan's
/// own "What it filled in" listing, where whoever is holding the paper
/// can still read it. `address_line3` has no third box and is folded
/// into the second rather than dropped: an address that arrives on
/// three lines is an ordinary Malaysian address, not a malformed one.
///
/// The address block is deliberately absent from the map: it is decided
/// as a whole, below, because half a reader's address on top of half a
/// split one is two addresses.
const _boxFor = <String, String>{
  'name': 'name',
  'legal_name': 'legalName',
  'registration_no': 'registrationNo',
  'old_registration_no': 'oldRegistrationNo',
  'tin': 'tin',
  'sst_registration_no': 'sstNo',
  'email': 'email',
  'phone': 'phone',
  'mobile': 'mobile',
};

/// Every column the address is made of, reader-side.
const _addressColumns = {
  'address_line1',
  'address_line2',
  'address_line3',
  'postcode',
  'city',
  'state_code',
};

/// What a reading fills in on a new contact.
///
/// Two sources, and the order between them is the whole point:
///
///  * [OcrExtraction.fields] is what the READER was asked for, keyed by
///    the destination's own column names -- `0681` hands it the column
///    list and a description of each. Where it answered, that is the
///    authoritative mapping and nothing here guesses.
///  * The typed properties on [OcrExtraction] are what the app made of
///    the document afterwards, and they cover six of the sixteen
///    columns. They are the fallback, so a reading taken before `0681`
///    -- or by a reader that answered in prose -- fills the form
///    exactly as it did before.
///
/// Until this, only the typed properties were used, so eight configured
/// columns were asked for on every scan, paid for, shown in the scan's
/// own listing, and then typed in again by hand: the legal name, the
/// old registration number, the SST number, the mobile, the city, the
/// state, and the second and third address lines.
ScannedContact scannedContact(
  OcrExtraction? read, {
  Iterable<Map<String, dynamic>> states = const [],
}) {
  if (read == null) return const ScannedContact();

  final fields = <String, String>{
    for (final e in read.fields.entries)
      if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
  };
  final boxes = <String, String>{};

  void put(String box, String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return;
    boxes[box] = text;
  }

  for (final e in _boxFor.entries) {
    put(e.value, fields[e.key]);
  }

  // The six the typed properties cover, where the reader did not answer
  // in columns.
  put('name', boxes['name'] ?? read.supplierName);
  put('tin', boxes['tin'] ?? read.supplierTaxId);
  put('registrationNo',
      boxes['registrationNo'] ?? read.supplierRegistrationNo);
  put('email', boxes['email'] ?? read.supplierEmail);
  put('phone', boxes['phone'] ?? read.supplierPhone);

  // ---------------------------------------------------------------
  // The address, whole, from ONE of the two
  //
  // Not field by field. A reader that answered the address columns has
  // read one address off one letterhead, and `splitScannedAddress` has
  // split another off the printed block; taking the postcode from one
  // and the lines from the other would put a real postcode on a
  // different address, which is worse than either alone because it
  // looks right.
  // ---------------------------------------------------------------
  if (_addressColumns.any(fields.containsKey)) {
    put('address1', fields['address_line1']);
    put('address2', [fields['address_line2'], fields['address_line3']]
        .whereType<String>()
        .join(', '));
    put('postcode', fields['postcode']);
    put('city', fields['city']);
  } else {
    final address = splitScannedAddress(read.supplierAddress);
    put('address1', address.line1);
    put('address2', address.line2);
    put('postcode', address.postcode);
    // No city, deliberately: `splitScannedAddress` will not guess one,
    // and its reason holds here too.
  }

  return ScannedContact(boxes: boxes, stateCode: _state(fields, states));
}

/// The `ref_states` code the reading named, or null.
///
/// The column is called `state_code`, so a reader may answer with the
/// code -- and just as often answers with what is printed on the
/// letterhead, which is the name. Both are accepted and neither is
/// trusted: an answer matching no row returns null and leaves the
/// dropdown unset, because the column is a foreign key and an invented
/// code is a save that fails at the last step with a message about a
/// constraint.
String? _state(Map<String, String> fields, Iterable<Map<String, dynamic>> states) {
  final answer = fields['state_code'];
  if (answer == null) return null;
  for (final s in states) {
    if ('${s['code']}'.toUpperCase() == answer.toUpperCase()) {
      return s['code'] as String?;
    }
  }
  return stateCodeFor(states, answer);
}
