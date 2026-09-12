import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/banking/bank_feed.dart';

Map<String, dynamic> _feed({
  String status = 'connected',
  String? lastPulled,
  String? lastError,
  int imported = 0,
}) =>
    {
      'provider': 'maybank',
      'status': status,
      'has_api_key': true,
      'last_pulled_at': lastPulled,
      'last_error': lastError,
      'last_run': {'ok': lastError == null, 'imported': imported, 'skipped': 0},
    };

/// What a bank feed's state means on a screen.
///
/// `0567` built the feed and nothing in the app reached it — the same
/// fault `docs/unreachable.md` exists to catch, committed hours after
/// the lesson was written into it. This is the screen's half, and the
/// assertion worth the file is the one the database cannot make.
void main() {
  group('whether there is a feed at all', () {
    test('null is no feed, and says what to do instead', () {
      expect(hasFeed(null), isFalse);
      expect(feedHeadline(null), 'Not connected');
      expect(feedDetail(null).toLowerCase(), contains('by hand'));
    });

    test('and a connected one is live', () {
      expect(feedIsLive(_feed()), isTrue);
      expect(feedIsLive(_feed(status: 'paused')), isFalse);
      expect(feedIsLive(_feed(status: 'failed')), isFalse);
      expect(feedIsLive(null), isFalse);
    });
  });

  group('the headline', () {
    test('says the state in the words somebody uses', () {
      expect(feedHeadline(_feed()), 'Connected');
      expect(feedHeadline(_feed(status: 'paused')), 'Paused');
      expect(feedHeadline(_feed(status: 'failed')), 'Not working');
      expect(feedHeadline(_feed(status: 'revoked')), 'Disconnected');
    });

    test('and a state it has never heard of does not take the page down', () {
      // The status is a string from the database. A screen that threw on
      // an unrecognised one would lose the whole settings page over a
      // migration adding a fifth word.
      expect(feedHeadline(_feed(status: 'something_new')), 'Unknown');
    });

    test('only a failure is a problem', () {
      // Paused is a choice somebody made; revoked is a company that left
      // its bank. Neither should be drawn in red.
      expect(feedNeedsAttention(_feed(status: 'failed')), isTrue);
      expect(feedNeedsAttention(_feed(status: 'paused')), isFalse);
      expect(feedNeedsAttention(_feed(status: 'revoked')), isFalse);
      expect(feedNeedsAttention(null), isFalse);
    });
  });

  group('the line underneath', () {
    final now = DateTime(2026, 3, 10, 12);

    test('an error says what it was and how to mend it', () {
      final line = feedDetail(
        _feed(status: 'failed', lastError: 'The token has expired'),
        now: now,
      );
      expect(line, contains('The token has expired'));
      expect(line.toLowerCase(), contains('re-enter the key'));
    });

    test('a feed that has never pulled says so', () {
      expect(feedDetail(_feed(), now: now).toLowerCase(),
          contains('has not pulled yet'));
    });

    test('and nothing new reads as success, not as zero', () {
      // The ordinary answer. A feed re-delivers the same overlapping
      // window every run and the import skips what it has seen, so a
      // screen showing that as 0 would look like a failure every day
      // but the first.
      final line = feedDetail(
        _feed(lastPulled: '2026-03-10T11:00:00Z', imported: 0),
        now: now,
      );
      expect(line, contains('nothing new'));
      expect(line, isNot(contains('0 lines')));
    });

    test('and counts what did arrive, singular and plural', () {
      expect(
        feedDetail(_feed(lastPulled: '2026-03-10T11:00:00Z', imported: 1),
            now: now),
        contains('1 line.'),
      );
      expect(
        feedDetail(_feed(lastPulled: '2026-03-10T11:00:00Z', imported: 6),
            now: now),
        contains('6 lines'),
      );
    });
  });

  group('a feed that has gone quiet', () {
    final now = DateTime(2026, 3, 10, 12);

    test('is caught, and the database cannot catch it', () {
      // THE ASSERTION THIS FILE EXISTS FOR. Nothing sets `failed` unless
      // a pull ran and failed, and a feed whose scheduler stopped never
      // pulls at all — so it sits at "Connected" forever, and the gap is
      // found at month end by somebody trying to reconcile.
      expect(
        feedHasGoneQuiet(_feed(lastPulled: '2026-03-01T09:00:00Z'), now: now),
        isTrue,
      );
    });

    test('but a feed that pulled this morning is not quiet', () {
      expect(
        feedHasGoneQuiet(_feed(lastPulled: '2026-03-10T09:00:00Z'), now: now),
        isFalse,
      );
    });

    test('and a paused one is not quiet, it is stopped', () {
      // Somebody chose that. Warning them about it is the screen
      // arguing with a decision.
      expect(
        feedHasGoneQuiet(
          _feed(status: 'paused', lastPulled: '2026-03-01T09:00:00Z'),
          now: now,
        ),
        isFalse,
      );
    });

    test('nor is one that has never pulled yet', () {
      // It was connected a minute ago. "Nothing for two days" would be
      // false.
      expect(feedHasGoneQuiet(_feed(), now: now), isFalse);
      expect(feedHasGoneQuiet(null, now: now), isFalse);
    });
  });

  group('the button that stops it', () {
    test('says which direction it goes', () {
      expect(pauseLabel(_feed()), 'Pause it');
      expect(pauseLabel(_feed(status: 'paused')), 'Start it again');
    });
  });

  group('which banks can be connected', () {
    test('none yet, and the card says so rather than drawing an empty box', () {
      // `0567` wrote no connector on purpose: there is no bank API in
      // the environment it was built in, and one written against a
      // guessed response shape would look finished. This list is how
      // the card knows to say that.
      expect(bankFeedProviders, isEmpty);
    });
  });
}
