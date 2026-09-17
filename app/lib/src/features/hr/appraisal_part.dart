/// Which part of an appraisal the person looking at it holds, and what
/// the appraisal is waiting for from them.
///
/// The rule about *who holds which part* is not worked out here. It
/// lives in `app.appraisal_part_of` and the trigger `0379` put on
/// `appraisals`, and the screen asks for it through
/// `my_appraisal_parts` — because two implementations of one permission
/// rule disagree eventually, and the copy that is wrong is the one a
/// person actually reads. [partFromName] parses that answer.
///
/// What is worked out here is the *next step*, which is a fact about the
/// state of the appraisal rather than about permission: given the part
/// somebody holds and how far the appraisal has got, there is exactly
/// one thing it is waiting for from them. Offering two is a screen that
/// has not decided; offering one the database would refuse is how
/// somebody learns to distrust the software.
library;

/// The four answers, in the order they beat each other.
enum AppraisalPart {
  /// The person being appraised. Beats every other part somebody holds:
  /// an HR manager is HR on everybody's appraisal except their own.
  subject,

  /// The named reviewer, or — where none is named — whoever they report
  /// to. Writes the manager half.
  reviewer,

  /// Runs the process. Settles the final rating, names reviewers, and
  /// reopens a submitted half. Writes neither half.
  hr,

  /// Nothing to do with this appraisal.
  none,
}

/// Reads what `my_appraisal_parts` said.
///
/// An unknown or missing name is [AppraisalPart.none] rather than a
/// guess: an appraisal the database would not name a part on is one this
/// person should be offered nothing on.
AppraisalPart partFromName(String? name) => switch (name) {
      'subject' => AppraisalPart.subject,
      'reviewer' => AppraisalPart.reviewer,
      'hr' => AppraisalPart.hr,
      _ => AppraisalPart.none,
    };

/// What this person can do next, given where the appraisal has got to.
///
/// One value rather than a set of booleans, because at any moment there
/// is exactly one thing the appraisal is waiting for from this person —
/// and a screen that offers two is a screen that has not decided.
enum AppraisalAction {
  /// Write and submit the self review.
  writeSelf,

  /// Write and submit the manager review.
  writeManager,

  /// Settle the final rating.
  finalise,

  /// Nothing, and the reason is worth showing rather than an empty row.
  waiting,
}

/// What the appraisal is waiting for from [part].
///
/// [selfDue] is the cycle's `self_review_due` and is what releases the
/// manager to write theirs when the employee never did: before that day
/// the manager is waiting on the employee, after it the cycle moves on
/// without the half nobody wrote.
AppraisalAction appraisalAction({
  required AppraisalPart part,
  required bool selfSubmitted,
  required bool managerSubmitted,
  required bool completed,
  DateTime? selfDue,
  required DateTime today,
}) {
  if (completed) return AppraisalAction.waiting;
  switch (part) {
    case AppraisalPart.subject:
      return selfSubmitted ? AppraisalAction.waiting : AppraisalAction.writeSelf;
    case AppraisalPart.reviewer:
      if (managerSubmitted) return AppraisalAction.waiting;
      if (selfSubmitted) return AppraisalAction.writeManager;
      // Their half is the answer to the employee's, until the day the
      // employee's was due.
      if (selfDue != null && selfDue.isBefore(_midnight(today))) {
        return AppraisalAction.writeManager;
      }
      return AppraisalAction.waiting;
    case AppraisalPart.hr:
      return managerSubmitted
          ? AppraisalAction.finalise
          : AppraisalAction.waiting;
    case AppraisalPart.none:
      return AppraisalAction.waiting;
  }
}

DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);

/// Whether [rating] is a rating at all in a cycle scored out of [max].
///
/// Nought is not one: it is what a numeric field holds when somebody
/// tabbed past it.
bool isRatingInScale(num? rating, int max) =>
    rating != null && rating > 0 && rating <= max;

/// Whether the goals on an appraisal weigh the whole job.
///
/// No goals at all is not a shortfall — some cycles are an overall
/// rating and a conversation — which is why this takes the list rather
/// than the sum.
bool goalsWeighWholeJob(List<num> weights) {
  if (weights.isEmpty) return true;
  final total = weights.fold<double>(0, (sum, w) => sum + w.toDouble());
  return (total - 100).abs() < 0.005;
}
