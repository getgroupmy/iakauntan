/// What the receipt and payment screens say when the firm holds client
/// money.
///
/// Kept apart from the dialog that draws it for the reason
/// `module_offer.dart` is: these sentences are about somebody else's
/// money. A solicitor taking a receipt has to know, before pressing
/// anything, which of two accounts it is going into — and a sentence
/// assembled inside a `build` method among the padding is a sentence
/// nobody can assert.
///
/// The rules underneath are the Solicitors' Accounts Rules 1990 and
/// they are enforced in the database (0021, 0549). These are the words
/// that stop somebody meeting them by accident.
library;

import '../../core/format.dart';

/// Where money coming in is going.
enum ReceiptDestination {
  /// The firm's own account, settling a rendered bill. What every
  /// non-legal receipt is.
  office,

  /// The client account, held for a matter. Not income, settles
  /// nothing, and cannot be spent on anything but that matter.
  onAccount,

  /// Out of client money already held, into the office account,
  /// settling a bill. The only lawful crossing between the two.
  fromClientAccount,
}

/// Where money going out is coming from.
enum PaymentSource {
  /// The firm's own money.
  office,

  /// The client's, held for a matter — a disbursement paid on their
  /// behalf, or the balance returned when the matter closes.
  clientAccount,
}

String receiptDestinationLabel(ReceiptDestination d) => switch (d) {
  ReceiptDestination.office => 'Into the office account',
  ReceiptDestination.onAccount => 'Into the client account, on account',
  ReceiptDestination.fromClientAccount => 'From client money already held',
};

/// The line under each choice. What it does, and what it does not.
String receiptDestinationHint(ReceiptDestination d) => switch (d) {
  ReceiptDestination.office =>
    'The firm has been paid. Allocate it to the bills it settles.',
  ReceiptDestination.onAccount =>
    'Held for the matter until there is a bill to settle. It is not '
        'income, it settles nothing, and it stays the client’s.',
  ReceiptDestination.fromClientAccount =>
    'Money already held for this matter pays the bill. It leaves the '
        'client account and arrives in the office one.',
};

String paymentSourceLabel(PaymentSource s) => switch (s) {
  PaymentSource.office => 'From the office account',
  PaymentSource.clientAccount => 'From the client account, for a matter',
};

String paymentSourceHint(PaymentSource s) => switch (s) {
  PaymentSource.office => 'The firm’s own money.',
  PaymentSource.clientAccount =>
    'A disbursement paid on the client’s behalf, out of what is held '
        'for this matter.',
};

/// What a matter holds, under the picker.
///
/// Nothing held is said in words rather than as "RM 0.00", because a
/// zero balance is the answer to "can I pay this out of it" and it
/// should not have to be read as a number to be understood.
String matterBalanceLine(double held) => held <= 0
    ? 'Nothing is held for this matter.'
    : '${Fmt.money(held)} held in the client account for this matter.';

/// The refusal shown before the server's, when the amount is more than
/// the matter holds.
///
/// The database refuses this too (0549) and its message is the one that
/// matters. This exists so the person is told while they are still
/// looking at the field rather than after pressing Save.
String? overdrawWarning({required double held, required double amount}) =>
    amount > held
    ? 'This matter holds ${Fmt.money(held)}. Money held for one client '
          'cannot fund another.'
    : null;

/// What the confirmation says once it has worked.
String receiptDone(ReceiptDestination d) => switch (d) {
  ReceiptDestination.office => 'Receipt recorded and posted',
  ReceiptDestination.onAccount => 'Received into the client account',
  ReceiptDestination.fromClientAccount =>
    'Transferred to office and the bill settled',
};

String paymentDone(PaymentSource s) => switch (s) {
  PaymentSource.office => 'Payment recorded and posted',
  PaymentSource.clientAccount => 'Paid out of the client account',
};
