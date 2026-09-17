/// Why a deal closed, and what the form has to insist on.
///
/// `opportunities.won_reason`, `lost_reason` and `competitor` have been
/// columns since `0008` and none was ever written: dragging a card onto
/// Closed Lost is one update of `stage_id`, and the trigger sets the
/// status and the close date. The pipeline recorded that a deal died,
/// on what day, for how much — and nothing about why, which is the one
/// question it exists to answer.
///
/// `close_opportunity` is the enforcement. These are its rules restated
/// so the button greys instead of the save failing.
library;

/// The three ways a deal ends.
///
/// `abandoned` is here because it is genuinely different and, until
/// `0373`, unreachable: `opportunities.status` allowed it and
/// `pipeline_stages.stage_type` did not, so no stage could produce it.
/// Lost is a customer buying elsewhere — there is a competitor and a
/// price. Abandoned is one that went quiet or that the firm walked away
/// from, and a pipeline calling those the same thing reports a loss rate
/// that is not true.
const dealOutcomes = <String, String>{
  'won': 'Won',
  'lost': 'Lost',
  'abandoned': 'Abandoned',
};

/// Whether this outcome has to say why.
///
/// The whole point. An optional field on a form nobody has time for is
/// a field that stays empty, and the report built on it stays empty with
/// it. Winning is not asked, because no decision is waiting on why
/// somebody said yes and the easy path should stay easy.
bool outcomeNeedsReason(String outcome) => outcome != 'won';

/// The reasons offered as chips, so most closes are one tap.
///
/// Free text is still accepted — a list that cannot express what
/// actually happened teaches people to pick the nearest wrong one, and
/// then the report is confidently wrong rather than thin.
const lostReasons = <String>[
  'Price',
  'Went with a competitor',
  'No budget',
  'No decision',
  'Bad timing',
  'Missing a feature',
];

const abandonedReasons = <String>[
  'Went quiet',
  'Contact left',
  'We withdrew',
  'Not a fit',
];

const wonReasons = <String>[
  'Price',
  'Relationship',
  'Product fit',
  'Existing customer',
];

/// The chips for an outcome.
List<String> reasonsFor(String outcome) => switch (outcome) {
      'won' => wonReasons,
      'abandoned' => abandonedReasons,
      _ => lostReasons,
    };

/// Why this cannot be saved yet, or null when it can.
String? outcomeBlockedBecause({
  required String outcome,
  required String reason,
  required String status,
}) {
  if (!dealOutcomes.containsKey(outcome)) {
    return 'Choose whether it was won, lost or abandoned.';
  }
  if (status != 'open') {
    return 'This deal is already closed as ${dealOutcomes[status] ?? status}.';
  }
  if (outcomeNeedsReason(outcome) && reason.trim().isEmpty) {
    return 'Say why. A pipeline that records that deals died and not why '
        'cannot answer the only question it is for.';
  }
  return null;
}

/// The label on the button, so the confirmation names the outcome.
String closeButtonLabel(String outcome) =>
    'Close as ${(dealOutcomes[outcome] ?? outcome).toLowerCase()}';
