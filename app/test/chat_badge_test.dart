import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

void main() {
  group('what a count reads as', () {
    test('the number, while the number is worth reading', () {
      expect(badgeLabel(1), '1');
      expect(badgeLabel(42), '42');
      expect(badgeLabel(99), '99');
    });

    test('and a shape once it is not', () {
      // Past a point the exact figure changes nothing about what you
      // do next, and a four-digit badge stops being a badge.
      expect(badgeLabel(100), '99+');
      expect(badgeLabel(4821), '99+');
    });
  });

  group('which destination the count belongs to', () {
    test('chat, and nothing else', () {
      expect(destCarriesUnread('/chat'), isTrue);
      expect(destCarriesUnread('/dashboard'), isFalse);
      expect(destCarriesUnread('/tickets'), isFalse);
      // Exactly that path, not anything under it. A future
      // /chat/settings is a page about chat, not a page with the
      // waiting messages on it.
      expect(destCarriesUnread('/chat/settings'), isFalse);
    });
  });

  group('what More carries on a phone', () {
    test('the count, when chat is behind it', () {
      // Chat is not a primary destination, so its badge would sit
      // inside a sheet nobody opens unless they already knew.
      expect(
        unreadOnMore(
          reachable: const ['/dashboard', '/chat', '/settings'],
          primary: const ['/dashboard'],
          unread: 7,
        ),
        7,
      );
    });

    test('nothing, when chat has a slot of its own', () {
      // Otherwise it is shown twice: once against the thing and once
      // against the drawer it is not in.
      expect(
        unreadOnMore(
          reachable: const ['/dashboard', '/chat'],
          primary: const ['/dashboard', '/chat'],
          unread: 7,
        ),
        0,
      );
    });

    test('nothing, when this company does not hold chat at all', () {
      expect(
        unreadOnMore(
          reachable: const ['/dashboard', '/settings'],
          primary: const ['/dashboard'],
          unread: 7,
        ),
        0,
      );
    });

    test('and nothing when nothing is waiting', () {
      expect(
        unreadOnMore(
          reachable: const ['/chat'],
          primary: const ['/dashboard'],
          unread: 0,
        ),
        0,
      );
    });
  });
}
