/// What a bank feed's state means, said in words a bookkeeper uses.
///
/// `0567` built the feed's spine — the connection, the credential held
/// so nothing can read it back, and a row per pull — and deliberately
/// wrote no connector, because there is no bank API in the environment
/// it was built in. This is the screen's half of it.
///
/// Separated from the card because all of it is decidable without a
/// widget, and because the interesting judgement is not "is it
/// connected" but "has it stopped": a feed's failure mode is silence,
/// and silence is what a status line has to be able to say out loud.
library;

/// The four states `bank_feeds.status` holds.
///
/// Deliberately not an enum over a string from the database: a status
/// this screen has never heard of must read as "something is wrong and
/// I cannot say what", not crash the settings page.
const String feedConnected = 'connected';
const String feedPaused = 'paused';
const String feedFailed = 'failed';
const String feedRevoked = 'revoked';

/// Whether the company has a feed on this account at all.
bool hasFeed(Map<String, dynamic>? status) => status != null;

/// Whether the feed is meant to be pulling right now.
bool feedIsLive(Map<String, dynamic>? status) =>
    status != null && status['status'] == feedConnected;

/// The headline, in the vocabulary of the thing rather than the column.
String feedHeadline(Map<String, dynamic>? status) {
  if (status == null) return 'Not connected';
  return switch ('${status['status']}') {
    feedConnected => 'Connected',
    feedPaused => 'Paused',
    feedFailed => 'Not working',
    feedRevoked => 'Disconnected',
    _ => 'Unknown',
  };
}

/// Whether the headline should be drawn as a problem.
///
/// Paused is not a problem: somebody chose it. Revoked is not a problem
/// either — the company left the bank, and the row is kept only so the
/// runs behind it stay readable.
bool feedNeedsAttention(Map<String, dynamic>? status) =>
    status != null && status['status'] == feedFailed;

/// The line under the headline: what happened last, and when.
///
/// The hard case is the one this exists for. A feed that says
/// "Connected" and last pulled three weeks ago is broken in the way
/// that costs somebody a month end, and the status column will not say
/// so — nothing sets `failed` unless a pull ran and failed, and a feed
/// whose scheduler stopped never pulls at all. So the age of the last
/// pull is part of the sentence, always.
String feedDetail(Map<String, dynamic>? status, {DateTime? now}) {
  if (status == null) {
    return 'Statements are imported by hand. Connect the bank to have '
        'them arrive on their own.';
  }

  final error = (status['last_error'] as String?)?.trim();
  if (error != null && error.isNotEmpty) {
    return '$error — re-enter the key to mend it.';
  }

  final pulled = DateTime.tryParse('${status['last_pulled_at'] ?? ''}');
  if (pulled == null) {
    return 'Connected, and it has not pulled yet.';
  }

  final run = status['last_run'] as Map?;
  final imported = int.tryParse('${run?['imported'] ?? 0}') ?? 0;
  final ago = _ago(pulled, now ?? DateTime.now());
  // "Nothing new" is the ordinary answer and has to read as success: a
  // feed re-delivers the same overlapping window every run, and 0567's
  // import skips what it has already seen. A screen that showed that as
  // zero would look like a failure every day but the first.
  final what = imported == 0
      ? 'nothing new'
      : '$imported ${imported == 1 ? 'line' : 'lines'}';
  return 'Last pull $ago, $what.';
}

/// Whether the feed has gone quiet without saying so.
///
/// Two days, because a bank feed that has not run since the day before
/// yesterday has missed a working day. Returns false where there is no
/// feed or it was deliberately stopped.
bool feedHasGoneQuiet(Map<String, dynamic>? status, {DateTime? now}) {
  if (!feedIsLive(status)) return false;
  final pulled = DateTime.tryParse('${status!['last_pulled_at'] ?? ''}');
  if (pulled == null) return false;
  return (now ?? DateTime.now()).difference(pulled).inHours >= 48;
}

/// What the button that stops or restarts it should say.
String pauseLabel(Map<String, dynamic>? status) =>
    feedIsLive(status) ? 'Pause it' : 'Start it again';

/// A rough age, which is all a status line needs.
String _ago(DateTime then, DateTime now) {
  final d = now.difference(then);
  if (d.inMinutes < 2) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} minutes ago';
  if (d.inHours < 24) return '${d.inHours} ${d.inHours == 1 ? 'hour' : 'hours'} ago';
  return '${d.inDays} ${d.inDays == 1 ? 'day' : 'days'} ago';
}

/// The banks a feed can be asked for.
///
/// Empty on purpose, and the card says why rather than drawing a picker
/// with nothing in it. `0567` wrote no connector: there is no bank API
/// in the environment it was built in, and a connector written against
/// a guessed response shape would look finished. Adding one here is
/// half of adding a bank; the other half is the edge function.
const List<({String code, String name})> bankFeedProviders = [];
