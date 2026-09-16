/// Working out what a scanned paper is.
///
/// `0614`. The reader gives back text and a handful of fields; this
/// decides which of `scan_document_kinds` it looks like, so somebody
/// holding a stack of paper does not have to sort it first.
///
/// ## Why the rules are here and not in SQL
///
/// They are string matching against letterheads. Maybank writes
/// "PENYATA AKAUN" and CIMB writes "ACCOUNT STATEMENT"; a supplier's
/// bill says "INVOICE", "TAX INVOICE", "INVOIS" or "BIL" depending on
/// who printed it. Every one of those is a line of Dart and a test, and
/// putting them in the database would mean a migration each time
/// somebody notices a new wording.
///
/// What IS in the database is the list of kinds and what each is for.
/// This chooses between rows; it does not invent them.
///
/// ## Why it suggests rather than decides
///
/// A first reading of a faded thermal receipt is a draft. The kind is
/// shown with the reason it was chosen and can be changed in one tap —
/// the same bargain the rest of this flow already makes with the
/// figures, and for the same reason: a wrong answer nobody looked at is
/// worse than a blank one.
library;

/// What the paper looks like, and why.
class DocumentGuess {
  const DocumentGuess({
    required this.kind,
    required this.confidence,
    required this.because,
  });

  /// A `scan_document_kinds.code`.
  final String kind;

  /// How sure, from 0 to 1. Not a probability — a score, and it is used
  /// for one thing: whether the screen says "this is" or "this might
  /// be". Three bands, and the bands are what the tests assert rather
  /// than the numbers.
  final double confidence;

  /// The words that decided it, to show under the choice. "Says TAX
  /// INVOICE" reads as a reason; "87% confident" reads as a machine
  /// being sure about something it cannot be sure about.
  final String because;

  bool get isSure => confidence >= 0.7;
  bool get isGuess => confidence < 0.4;
}

/// What each kind is recognised by.
///
/// Two lists, not one, and the split is the whole of how this reads a
/// document the way a person does.
///
/// **Names** are what the paper CALLS ITSELF: "TAX INVOICE", "PENYATA
/// BANK". One of these at the top settles it.
///
/// **Hints** are what such a document tends to carry: "amount due",
/// "closing balance", "withdrawal". They support a name and cannot
/// stand for one — a bill's covering letter mentioning an amount due
/// does not make the letter a bill.
///
/// The first version of this scored by the LENGTH of the longest
/// matching phrase, which is a proxy for the same idea and a bad one:
/// "tax invoice" is eleven characters and is the least ambiguous string
/// on the list, while "outstanding as at" is seventeen and is a hint.
///
/// Both languages throughout, because half the paper in a Malaysian
/// office is in Malay and a reader that only knows English words files
/// every one of those as "something else".
class _Marks {
  const _Marks({this.names = const [], this.hints = const [],
                this.against = const []});

  /// What the paper calls itself.
  final List<String> names;

  /// What it tends to carry. Support, never proof.
  final List<String> hints;

  /// What means it is NOT this, however well it scored.
  final List<String> against;
}

const _marks = <String, _Marks>{
  'bank_statement': _Marks(
    names: ['penyata bank', 'bank statement', 'penyata akaun'],
    hints: [
      'opening balance', 'closing balance', 'baki akhir', 'baki awal',
      'withdrawal', 'deposit', 'pengeluaran', 'statement of account',
      'account statement',
    ],
    // A supplier's statement of account says the same three words at
    // the top. This is the confusion that matters: filing a supplier
    // ledger into the bank reconciliation invents transactions that
    // never touched the bank, and every other confusion here costs
    // somebody a retype.
    against: [
      'tax invoice', 'invois cukai', 'quotation', 'sebut harga',
      'delivery order', 'nota penghantaran',
      'ageing', 'aging', 'outstanding as at', 'baki tertunggak',
    ],
  ),
  'bill': _Marks(
    names: ['tax invoice', 'invois cukai', 'invoice', 'invois'],
    hints: ['amount due', 'jumlah perlu dibayar', 'payment due', 'terms',
            'bil'],
  ),
  'receipt': _Marks(
    names: ['official receipt', 'resit rasmi', 'receipt', 'resit'],
    hints: [
      'cash sale', 'jualan tunai', 'thank you for your patronage',
      'terima kasih',
    ],
    against: ['tax invoice', 'invois cukai', 'amount due'],
  ),
  'quotation': _Marks(
    names: ['quotation', 'sebut harga', 'proforma'],
    hints: ['quote no', 'valid until', 'sah sehingga'],
  ),
  'delivery_order': _Marks(
    names: ['delivery order', 'nota penghantaran'],
    hints: ['do no', 'd/o no', 'received in good condition',
            'goods received'],
  ),
  'ssm_document': _Marks(
    names: [
      'suruhanjaya syarikat malaysia',
      'companies commission of malaysia',
      'perakuan pemerbadanan',
      'certificate of incorporation',
    ],
    hints: ['ssm', 'borang 9', 'borang 49', 'section 17', 'section 14'],
  ),
  'statement_of_account': _Marks(
    names: ['statement of account', 'penyata akaun'],
    hints: ['ageing', 'aging', 'outstanding as at', 'baki tertunggak'],
    // The other side of the confusion above.
    against: ['withdrawal', 'deposit', 'pengeluaran', 'bank statement',
              'penyata bank'],
  ),
};

/// Which kind a reading looks like.
///
/// [text] is everything the reader saw. [hasLines] and [hasTotal] are
/// what it made of it, and they are the tie-breaker rather than the
/// evidence: a paper with priced lines and a total is a transaction
/// even where nothing on it says which kind, and a paper with neither
/// is far more likely to be a card or a certificate.
DocumentGuess classifyDocument({
  required String? text,
  bool hasLines = false,
  bool hasTotal = false,
  bool hasRegistrationNo = false,
}) {
  final body = (text ?? '').toLowerCase();

  if (body.trim().isEmpty) {
    return const DocumentGuess(
      kind: 'other',
      confidence: 0,
      because: 'Nothing could be read from it',
    );
  }

  var best = '';
  var bestMark = '';
  var bestNamed = false;
  var bestScore = 0;
  var bestHints = 0;

  _marks.forEach((kind, marks) {
    // Anything that rules it out, before anything that speaks for it.
    for (final no in marks.against) {
      if (body.contains(no)) return;
    }

    // A name is worth more than any number of hints. Three weak words
    // on a covering letter must not outvote the one phrase at the top
    // that says what the paper is.
    String? named;
    for (final n in marks.names) {
      if (body.contains(n) && (named == null || n.length > named.length)) {
        named = n;
      }
    }

    var hints = 0;
    String? firstHint;
    for (final h in marks.hints) {
      if (body.contains(h)) {
        hints++;
        firstHint ??= h;
      }
    }

    if (named == null && hints == 0) return;

    // Between two named, the longer phrase is the more specific one --
    // "tax invoice" over "invoice". Between two unnamed, more hints
    // wins. The two scales are NOT comparable and are not compared:
    // the line below prefers a named match outright, whatever either
    // number says.
    //
    // The first version also added 1000 to a named score, which is the
    // same rule written twice -- and a mutation sweep found both copies
    // survivable because each masked the other. One of them is gone.
    final score = named != null ? named.length : hints;
    final named_ = named != null;
    if (named_ != bestNamed ? named_ : score > bestScore) {
      bestScore = score;
      best = kind;
      bestNamed = named_;
      bestHints = hints;
      bestMark = named ?? firstHint!;
    }
  });

  if (best.isEmpty) {
    // Nothing recognised it by name. A card is what is left when there
    // is text, a registration number, and no money on it at all — which
    // is exactly a letterhead or a name card.
    if (!hasLines && !hasTotal && hasRegistrationNo) {
      return const DocumentGuess(
        kind: 'name_card',
        confidence: 0.5,
        because: 'A company number and no amounts, which is a letterhead '
            'or a card',
      );
    }
    if (hasTotal) {
      return const DocumentGuess(
        kind: 'receipt',
        confidence: 0.3,
        because: 'A total and nothing saying what kind of document it is',
      );
    }
    return const DocumentGuess(
      kind: 'other',
      confidence: 0,
      because: 'Nothing on it says what it is',
    );
  }

  // A transaction document with no lines and no total read is a reading
  // that went badly, not a different kind of paper -- so the kind
  // stands and the confidence does not.
  final wantsMoney = best == 'bill' || best == 'receipt' ||
      best == 'quotation';
  final supported = !wantsMoney || hasTotal || hasLines;

  // Named, or hinted at enough times to amount to the same thing.
  //
  // A document that says "TAX INVOICE" at the top has told you what it
  // is. One that says "STATEMENT OF ACCOUNT" and then "OPENING
  // BALANCE", "WITHDRAWAL" and "CLOSING BALANCE" has not named itself a
  // bank statement -- a supplier's ledger uses the same first phrase --
  // and a person reading it would still be sure, because four things
  // that only appear together on one kind of paper appeared together.
  //
  // One hint is a guess. The first version treated them all as one, and
  // called a real bank statement a maybe.
  final strong = bestNamed || bestHints >= 3;
  final confidence = supported
      ? (strong ? 0.85 : (bestHints >= 2 ? 0.6 : 0.45))
      : (strong ? 0.5 : 0.3);

  return DocumentGuess(
    kind: best,
    confidence: confidence,
    because: supported
        ? (bestNamed
            ? 'Says "$bestMark"'
            : (bestHints >= 3
                ? 'Carries "$bestMark" and ${bestHints - 1} other things '
                    'only this kind of paper carries'
                : 'Carries "$bestMark"'))
        : 'Says "$bestMark", but no amounts were read',
  );
}
