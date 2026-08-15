/*
 * The service worker that draws a notification when the app is closed.
 *
 * Registered at the /push/ scope rather than at the root, deliberately.
 * This app is built with --pwa-strategy=none and index.html unregisters
 * any worker it finds at the root, because a stale Flutter worker can
 * pin the whole application to old code. A push worker at its own scope
 * is exempt from that rescue and cannot serve a single asset, so it can
 * never cache the app or shadow a deploy.
 *
 * Nothing under /push/ exists or needs to. The scope decides which pages
 * a worker controls; it does not limit what it may be woken for.
 *
 * ---------------------------------------------------------------------
 * What is in the payload, and what is not
 *
 * Not the message. A notification lands on a lock screen anybody near
 * the desk can read, and this application's chat carries payslips and
 * bank details. So the push says who and where, this file composes a
 * sentence from that, and the words themselves are fetched when the app
 * is opened by somebody who has authenticated.
 */

self.addEventListener('push', function (event) {
  // A push with no data is a browser waking us for its own reasons. The
  // permission model on some browsers revokes the subscription if a push
  // shows nothing at all, so it still draws something rather than
  // returning silently.
  var payload = {};
  if (event.data) {
    try {
      payload = event.data.json();
    } catch (e) {
      payload = {};
    }
  }

  var isCall = payload.kind === 'call';
  var who = payload.sender_name || 'Somebody';
  var title = payload.title || who;
  var body = isCall
    ? (payload.video === 'true' || payload.video === true
        ? who + ' is calling with video'
        : who + ' is calling')
    : who + ' sent a message';

  event.waitUntil(
    self.registration.showNotification(title, {
      body: body,
      icon: '/icons/Icon-192.png',
      badge: '/icons/Icon-192.png',
      // One notification per conversation, replaced rather than stacked:
      // a room that has been busy for an hour should not be an hour of
      // separate notifications to swipe away.
      tag: 'chat-' + (payload.conversation_id || 'unknown'),
      renotify: true,
      // A call interrupts; a message waits to be noticed.
      requireInteraction: isCall,
      data: {
        conversation_id: payload.conversation_id || null,
        call_id: payload.call_id || null,
        kind: payload.kind || 'message',
      },
    })
  );
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();

  var conversation = event.notification.data && event.notification.data.conversation_id;
  var target = conversation ? '/chat?c=' + conversation : '/chat';

  event.waitUntil(
    // `includeUncontrolled`, because the app's own window is at the root
    // scope and this worker controls nothing there. Without it the list
    // is always empty and every click opens a second copy of the app.
    self.clients
      .matchAll({ type: 'window', includeUncontrolled: true })
      .then(function (windows) {
        for (var i = 0; i < windows.length; i++) {
          var client = windows[i];
          if (new URL(client.url).origin !== self.location.origin) continue;
          if ('focus' in client) {
            if ('navigate' in client) client.navigate(target);
            return client.focus();
          }
        }
        return self.clients.openWindow(target);
      })
  );
});

// A subscription the browser rotates behind our back. The app
// re-registers on every start, so the register catches up then; this
// exists so the reason is written down rather than looking like an
// oversight. Re-subscribing from here would need the application server
// key, which would mean shipping it twice and letting the two copies
// disagree.
self.addEventListener('pushsubscriptionchange', function () {
  // Deliberately empty. See above.
});
