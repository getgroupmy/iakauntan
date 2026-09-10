/// A mobile number, in the two halves people actually type.
///
/// Somebody in Malaysia writes their number 012-345 6789. The leading
/// zero is a trunk prefix — it means "a call inside this country" and
/// is not part of the number. Dialled from outside, or written to
/// anybody's API, it is +60 12 345 6789, with the zero gone. Keep the
/// zero and the number is wrong in exactly the way nobody notices until
/// a message is not delivered: +600123456789 is not a number.
///
/// The same is true of most of the world — Britain, Germany, Indonesia,
/// Thailand — and the countries where it is not (Italy, and a handful
/// of others) do not use the zero in the first place, so stripping it
/// there removes nothing.
///
/// So the form takes a dialling code and a number, and what is stored
/// is E.164: a plus, the dialling code, and the number with no zero in
/// front of it. The rules are here rather than in the screen because
/// this is arithmetic on somebody's phone number, and the failure is
/// silent.
library;

/// Just the digits.
///
/// People write numbers with spaces, dashes, brackets and the odd full
/// stop, and all of it is decoration.
String phoneDigits(String raw) => raw.replaceAll(RegExp(r'[^0-9]'), '');

/// The national number, without the trunk prefix.
///
/// Every leading zero rather than one: `0012345678` is somebody who
/// typed the zero twice, and one zero left in front is the same wrong
/// number as two.
String nationalNumber(String raw) {
  final digits = phoneDigits(raw);
  var i = 0;
  while (i < digits.length && digits[i] == '0') {
    i++;
  }
  return digits.substring(i);
}

/// Whether the number was written with a trunk prefix.
///
/// Used to say so on the screen rather than to refuse it. Somebody
/// typing their own number the way they always write it has not made a
/// mistake, and a form that rejects them for it is a form arguing about
/// punctuation.
bool hadTrunkPrefix(String raw) {
  final digits = phoneDigits(raw);
  return digits.startsWith('0');
}

/// The number as it will be stored and dialled.
///
/// Null when there is nothing to store: an empty box, or one holding
/// only zeros and dashes. `+` and nothing else is not a phone number,
/// and storing it would be storing a shape rather than a fact.
String? e164({required String dialCode, required String number}) {
  final dial = phoneDigits(dialCode);
  final national = nationalNumber(number);
  if (dial.isEmpty || national.isEmpty) return null;
  return '+$dial$national';
}

/// The shortest and longest a national number can be.
///
/// E.164 allows fifteen digits including the dialling code. Below about
/// six there is no country where it is a mobile number, and this is a
/// sanity check rather than a validator: knowing which lengths are
/// valid in two hundred countries is a library, and being wrong about
/// it refuses real numbers.
const _minNational = 6;
const _maxE164Digits = 15;

/// What is wrong with what was typed, or null if nothing is.
String? phoneError({
  required String dialCode,
  required String number,
  bool required = true,
}) {
  final digits = phoneDigits(number);
  if (digits.isEmpty) {
    return required ? 'Enter your mobile number' : null;
  }
  final national = nationalNumber(number);
  if (national.isEmpty) return 'Enter your mobile number';
  if (national.length < _minNational) return 'That is too short';
  if (phoneDigits(dialCode).length + national.length > _maxE164Digits) {
    return 'That is too long';
  }
  return null;
}

/// What the box says under itself once a trunk prefix has been typed.
///
/// It shows the number that will actually be stored. The zero is being
/// removed from what somebody typed, and doing that silently is how a
/// form gets accused of losing a digit.
String? phoneNote({required String dialCode, required String number}) {
  if (!hadTrunkPrefix(number)) return null;
  final full = e164(dialCode: dialCode, number: number);
  if (full == null) return null;
  return 'Saved as $full — the 0 is not part of the number when the '
      'country code is there.';
}

/// The label on the box.
const phoneFieldLabel = 'Mobile number';

/// The dialling code the box starts on.
///
/// Malaysia, for the reason `home_country.dart` gives about the country
/// picker: this is a Malaysian product, and the commonest answer should
/// be the one already there.
const homeDialCode = '60';

/// The label on the dialling code beside it.
const dialCodeFieldLabel = 'Code';

/// How a dialling code reads in the list: `+60 Malaysia`.
///
/// The code first because that is what somebody is looking for, and it
/// is what stays visible when the control is narrow.
String dialCodeLabel(Map<String, dynamic> country) =>
    '+${phoneDigits('${country['dial_code'] ?? ''}')} ${country['name']}';

/// The countries that can be picked from, which is those that have a
/// dialling code.
///
/// `ref_countries.dial_code` has been there since `0011` and is not
/// filled in for every row. A country with no code cannot be picked,
/// because picking it would build a number with no country in it.
List<Map<String, dynamic>> withDialCodes(List<Map<String, dynamic>> rows) => [
      for (final row in rows)
        if (phoneDigits('${row['dial_code'] ?? ''}').isNotEmpty) row,
    ];

/// The label on the title box.
const salutationFieldLabel = 'Title';

/// The second line under a title in the picker: which group it belongs
/// to, and the note where there is one.
String salutationSublabel(Map<String, dynamic> row) {
  final note = '${row['note'] ?? ''}'.trim();
  final group = '${row['grouping'] ?? ''}'.trim();
  if (note.isEmpty) return group;
  return group.isEmpty ? note : '$group · $note';
}

/// What is wrong with the title, or null if nothing is.
///
/// Required, along with everything else on that form. A registration
/// that asks for a title and accepts a blank one is a column that is
/// null on half the rows, and a letter that cannot be addressed.
String? salutationError(String? name) =>
    (name ?? '').trim().isEmpty ? 'Choose how to be addressed' : null;
