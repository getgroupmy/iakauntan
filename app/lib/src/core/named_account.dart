/// Why a form cannot be saved when it does not say which account the
/// money moved through.
///
/// Four one-liners rather than one parameterised sentence, because the
/// four forms are describing four different movements and a template
/// that fits all of them would say less than any of them. Each returns
/// null when there is nothing wrong, so a caller reads
///
///     final wrong = depositAccountProblem(_bank);
///     if (wrong != null) { ...show it...; return; }
///
/// ## Why they exist at all
///
/// `0727` and `0728` refuse these at the database, which is where the
/// rule lives: a rule enforced only in Dart holds for whoever uses the
/// app as written and for nobody else.
///
/// These are not belt and braces. They are the difference between
/// finding out while the form is still open with the answer one tap
/// away, and finding out through a round trip that comes back as an
/// exception, on a form somebody has just spent a minute filling in.
///
/// ## What they are guarding against
///
/// Account 1120 is "Bank Accounts" — postable, but the heading the real
/// accounts hang beneath. Every one of these paths used to post there
/// when no account was named: the entry balanced, reported, and matched
/// nothing on any statement, and no bank balance moved. Nothing
/// crashed, which is why it survived in six functions.
library;

/// A deposit taken or paid.
String? depositAccountProblem(String? bankAccountId) => bankAccountId == null
    ? 'Choose the account this moved through. A deposit that names none '
          'cannot be reconciled against any statement.'
    : null;

/// A cheque put on the register.
///
/// Asked at RECORDING rather than at clearing, which is the only place
/// it can be asked: `clear_pdc` is called from the cheque list with no
/// account argument, so the one it clears into is whichever the cheque
/// was recorded against. A cheque with none cannot be cleared at all.
String? chequeAccountProblem(String? bankAccountId) => bankAccountId == null
    ? 'Choose the account this cheque will be banked into. A cheque that '
          'names none cannot be cleared when it comes good.'
    : null;

/// A receipt from a customer or a payment to a supplier.
///
/// Both halves are asked, though only the payment half is refused by the
/// database today. Receipts are not refused there because the counter
/// writes them: every `pos_tender_types` row has no bank account, so a
/// refusal would stop the till rather than correct it. That is a
/// separate piece of work — where a card and an e-wallet settle is a
/// fact about a shop's merchant arrangements, not something to guess.
String? settlementAccountProblem(String? bankAccountId, {required bool isReceipt}) =>
    bankAccountId == null
    ? isReceipt
          ? 'Choose the account this was received into. A receipt that '
                'names none cannot be reconciled against any statement.'
          : 'Choose the account this was paid from. Every payment leaves '
                'an account, and one that names none cannot be reconciled '
                'against any statement.'
    : null;
