package my.iakauntan.iakauntan

import android.app.PendingIntent
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * What happens when FCM delivers something.
 *
 * Only one of the two kinds of notification this app sends needs any
 * code here, and knowing which is the whole of this file:
 *
 *   * A MESSAGE carries a `notification` block, so the Firebase SDK
 *     draws the banner itself when the app is in the background — on
 *     the `chat` channel, which is why `Push.ensureChannels` has to
 *     have run before the first one arrives. When the app is in the
 *     FOREGROUND the SDK draws nothing and calls this instead, and the
 *     right thing to do is still nothing: the person is looking at the
 *     app, and `chat_live.dart` has already put the message on screen.
 *
 *   * A CALL carries data and nothing else, deliberately — see
 *     `send-push`'s `buildMessage`. A data-only message is never drawn
 *     by the SDK, so if this file does not draw it, a call to a phone
 *     with the app closed does absolutely nothing. That is the case
 *     this service exists for.
 *
 * ## Why not a full-screen ring
 *
 * Because what it would cost is out of proportion to what it adds. A
 * full-screen intent needs `USE_FULL_SCREEN_INTENT`, which from Android
 * 14 is granted at install only to apps Google has accepted as calling
 * or alarm apps, and declaring it puts a policy declaration in front of
 * every Play release of this app. A high-importance heads-up
 * notification on its own channel arrives in the same second, shows on
 * the lock screen, and taps through to the call — and `0658` already
 * says the platform that rings properly is iOS, through PushKit, which
 * FCM cannot send at all.
 *
 * ## The payload is not the message
 *
 * `docs/push-notifications.md` has the argument: a notification lands
 * on a lock screen anybody standing near the desk can read, and this
 * application's chat carries payslips. So what is drawn here says who
 * is calling and nothing else, and the call itself is joined by an app
 * that has authenticated.
 */
class PushService : FirebaseMessagingService() {

    override fun onCreate() {
        super.onCreate()
        // A push can start this process with no activity ever having
        // existed — a handset rebooted, or an app swiped away. The
        // channels are created from both places for that reason, and
        // the second creation is ignored by Android.
        Push.ensureChannels(this)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        if (data["kind"] != "call") return

        // The app is open and `IncomingCallWatcher` is already putting
        // the call screen up. A notification about the call somebody is
        // currently being shown is noise.
        if (Push.inForeground) return

        val caller = data["sender_name"].orEmpty()
        val tap = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            // Read by nothing yet. Carried because the alternative is
            // to add them later and discover that the notification
            // somebody has on their phone is from a build that did not
            // send them: the app opens on the call the watcher finds,
            // which is the right call in every case but a second
            // simultaneous one.
            putExtra("call_id", data["call_id"])
            putExtra("conversation_id", data["conversation_id"])
        }
        val intent = PendingIntent.getActivity(
            this,
            0,
            tap,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(this, Push.CALLS)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(data["title"] ?: "Incoming call")
            .setContentText(
                if (caller.isBlank()) "Someone is calling" else "$caller is calling",
            )
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            // Forty-five seconds, the same number as
            // `chat_calls.ringing_until` and the `ttl` the sender sets.
            // A notification for a call nobody is waiting on any more
            // is worse than none: it is answered into an empty room.
            .setTimeoutAfter(45_000L)
            .setContentIntent(intent)
            .build()

        // One id, so a second call replaces the first rather than
        // stacking. Two missed-call notifications for one caller is
        // not information.
        try {
            NotificationManagerCompat.from(this).notify(CALL_NOTIFICATION, notification)
        } catch (e: SecurityException) {
            // Notifications were switched off between the push being
            // sent and arriving. Nothing to do and nobody to tell.
            Log.i(
                TAG,
                "a call arrived for a handset that is not accepting "
                    + "them: ${e.message}",
            )
        }
    }

    /**
     * FCM has issued a new token for this installation.
     *
     * Nothing is sent from here, and that is on purpose rather than
     * unfinished. This can run with no Flutter engine and no signed-in
     * session — a token rotated while the app was closed — so there is
     * nobody to register as and no `Repo` to register with. What
     * catches a rotation is `pushRegistrarProvider`, which
     * re-registers silently on every start for exactly this reason:
     * `0143` keys on the token, so an unchanged one updates a single
     * row and a changed one replaces it.
     *
     * The window this leaves is one app start wide, and the sender
     * drops tokens FCM reports as `UNREGISTERED` in the meantime.
     */
    override fun onNewToken(token: String) {
        Log.i(TAG, "FCM issued a new token; it registers on the next app start")
    }

    private companion object {
        const val TAG = "iakauntan.push"
        const val CALL_NOTIFICATION = 7001
    }
}
