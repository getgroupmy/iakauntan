package my.iakauntan.iakauntan

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Android half of push, answering the same four methods on the
 * same channel as `AppDelegate.swift` does on iOS.
 *
 * `app/lib/src/core/push_native.dart` is the only caller and the file
 * to read first: it carries the argument for why permission gates
 * everything and why a status of "on" with no token would be a lie on
 * the settings screen. What is here is the part that needs an Android.
 *
 * ## Why Firebase, when nothing else in this system needs an account
 *
 * Web push goes straight to the browser's own push service under two
 * RFCs, and an iPhone is reached with an Apple `.p8` and no third
 * party. Android has no equivalent: FCM is Google's transport all the
 * way down, there is no protocol underneath it to speak, and a stock
 * Android handset will not wake an app for anybody else. So this is
 * the one platform where a project has to exist somewhere else before
 * a notification can arrive, and `docs/push-notifications.md` says
 * what has to be created.
 *
 * ## A build with no project at all still has to work
 *
 * `google-services.json` cannot live in this repository, so most
 * builds — every CI build, and every developer's — have no Firebase
 * configuration whatever. The SDK is still compiled in; what is
 * missing is the default [FirebaseApp], which the Gradle plugin's
 * generated resources are what create.
 *
 * That is not a broken build, it is an unconfigured one, and
 * `PushStatus.notConfigured` already exists for exactly this: the
 * settings card says so rather than offering a switch that would
 * register a token nothing can ever send to. [configured] is the whole
 * test, and it is asked before anything else on every call.
 *
 * ## Channels, and the one that is silent if it does not exist
 *
 * From Android 8 a notification naming a channel that has not been
 * created is DROPPED. Not downgraded, not shown without sound —
 * dropped, with nothing anywhere reporting it. `send-push` names
 * `chat` for a message, so `chat` has to exist before the first
 * message arrives; calls are built here and use `calls`.
 *
 * `scripts/check_push_channels.py` is what keeps those two lists
 * agreeing, because the failure is invisible from both ends: the
 * sender gets a 200 from FCM and the handset shows nothing.
 *
 * Created from BOTH [MainActivity] and [PushService]: a push can start
 * this process without any activity ever existing, and the SDK draws a
 * message banner itself without asking anything here first.
 */
object Push {
    /** The channel `push_native.dart` talks on. Named like every other
     *  channel in this app — see the note on `pushChannel` there, and
     *  `docs/handoff.md` on what an Application ID change has to touch
     *  together. */
    const val CHANNEL = "my.iakauntan.iakauntan/push"

    /** Messages. Named by `send-push` itself, in `buildMessage`. */
    const val MESSAGES = "chat"

    /** Calls, which arrive as data and are drawn by [PushService]. */
    const val CALLS = "calls"

    /** Our own request code, kept away from the plugins' by being
     *  nowhere near the small numbers they use. */
    const val PERMISSION_REQUEST = 4101

    private const val PREFS = "iakauntan.push"
    private const val ASKED = "asked"
    private const val OFF = "off"

    /**
     * Whether an activity of this app is in front of the person.
     *
     * A call arrives as a data message and is therefore delivered to
     * [PushService] whether the app is open or not — so without this,
     * somebody looking at the chat when a call comes in gets a
     * notification about it as well as the ringing screen the app
     * already puts up. Set from [MainActivity]'s own lifecycle because
     * the service runs in the same process; a lifecycle observer would
     * be a dependency for one boolean.
     */
    @Volatile
    var inForeground: Boolean = false

    /** Whether this build has a Firebase project behind it at all. */
    fun configured(context: Context): Boolean =
        FirebaseApp.getApps(context).isNotEmpty()

    /**
     * What Android says about notifications, in the four words
     * `push_native.dart` maps to a status.
     *
     * `areNotificationsEnabled` rather than the permission, and that is
     * deliberate. Notifications can be switched off in Settings on
     * every version of Android, including the ones with no
     * `POST_NOTIFICATIONS` to refuse, and an app that read only the
     * permission would report "on" for a handset showing nothing.
     *
     * Below Android 13 there is no prompt, so not-enabled can only
     * mean somebody went and turned it off: `denied`, which is the
     * answer that sends them to Settings rather than offering a button
     * that cannot work. From 13 the same state is either a refusal or
     * a question nobody has been asked yet, and only [asked]
     * distinguishes them — `shouldShowRequestPermissionRationale` is
     * false both before the first ask and after a permanent refusal,
     * which is the one place it is no help.
     */
    fun authorization(context: Context): String {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager?.areNotificationsEnabled() == true) return "authorized"
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return "denied"
        return if (asked(context)) "denied" else "notDetermined"
    }

    fun asked(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(ASKED, false)

    fun markAsked(context: Context) {
        remember(context, ASKED, true)
    }

    /**
     * Whether somebody has switched notifications off here.
     *
     * Remembered locally because nothing else can be, and without it
     * the settings card tells a lie the moment somebody presses **Turn
     * off**:
     *
     *   1. `disablePush` takes the token off the register and calls
     *      `deleteToken`;
     *   2. the card re-reads the status, which asks for the token;
     *   3. `getToken` on a handset with permission MINTS A NEW ONE,
     *      because that is what deleting a token means on Android;
     *   4. so the status reads `authorized` with a token — `on` — for
     *      a handset the register no longer holds.
     *
     * The person then sees "this device will be notified" and is never
     * notified again. iOS has no equivalent because `unregister` there
     * actually stops Apple issuing one.
     *
     * So an off switch is a fact about this installation, kept here,
     * and `register` is what clears it. Permission is untouched in
     * both directions — it cannot be revoked by an app and must not be
     * spent again — which is why turning it back on needs no prompt.
     */
    fun switchedOff(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(OFF, false)

    fun markOff(context: Context, off: Boolean) {
        remember(context, OFF, off)
    }

    private fun remember(context: Context, key: String, value: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(key, value)
            .apply()
    }

    /** What to call this handset in a list of somebody's devices. */
    fun label(): String {
        val maker = Build.MANUFACTURER.orEmpty()
        val model = Build.MODEL.orEmpty()
        // Many manufacturers already put their name in the model, and
        // "samsung samsung SM-G991B" is nobody's idea of a device name.
        val name = if (model.startsWith(maker, ignoreCase = true)) {
            model
        } else {
            "$maker $model".trim()
        }
        return name.ifBlank { "Android" }.replaceFirstChar { it.uppercase() }
    }

    /**
     * Create both channels, idempotently.
     *
     * Android ignores a second creation of a channel that exists, and
     * deliberately ignores every property of it as well: importance,
     * sound and vibration belong to the person once they have seen the
     * channel. So this cannot be used to make an existing channel
     * louder, which is why `calls` is its own channel rather than a
     * louder `chat`.
     */
    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
            ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                MESSAGES,
                "Chat messages",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Someone sent you a message."
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(
                CALLS,
                "Calls",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Someone is calling you."
                setShowBadge(false)
            },
        )
    }
}

/**
 * The method-channel handler, which needs an [Activity] because asking
 * for a permission does.
 *
 * One pending [MethodChannel.Result] at a time, and the reason is that
 * a `Result` must be answered exactly once: answering twice throws, and
 * never answering hangs the Dart future that the settings card is
 * waiting on. Both are worse than the "busy" error below, which cannot
 * happen from the one button that calls this.
 */
class PushChannel(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    private var pending: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // `status` and `tokens` are the same question on Android.
            // iOS has two tokens from two Apple services and has to
            // tell them apart; here there is one per installation.
            "status", "tokens" -> answer(result)
            "register" -> register(call.argument<Boolean>("ask") ?: false, result)
            "unregister" -> unregister(result)
            else -> result.notImplemented()
        }
    }

    /**
     * Was this ours? Answered from [MainActivity], which cannot know.
     *
     * Returns true for our request code even when nothing is pending,
     * so that a permission answer arriving after the activity was
     * recreated is not handed to the plugins as if it were theirs.
     */
    fun permissionAnswered(requestCode: Int): Boolean {
        if (requestCode != Push.PERMISSION_REQUEST) return false
        val waiting = pending ?: return true
        pending = null
        answer(waiting)
        return true
    }

    private fun register(ask: Boolean, result: MethodChannel.Result) {
        if (!Push.configured(activity)) {
            result.success(mapOf("authorization" to "unconfigured"))
            return
        }

        val needsAsking = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED

        // `ask` is not a convenience; see `push_native.dart`. The app
        // asks when somebody presses the button and re-registers
        // silently after that, so a person who has never decided is
        // never prompted on start-up.
        //
        // `Push.asked` is what stops a second prompt: Android 13
        // auto-denies after two refusals without showing anything, so
        // asking again looks to the app like an instant refusal and to
        // the person like a button that does nothing. Settings is the
        // only way back, and `denied` is what sends them there.
        if (needsAsking && ask && !Push.asked(activity)) {
            if (pending != null) {
                result.error(
                    "busy",
                    "A permission request is already waiting for an answer.",
                    null,
                )
                return
            }
            pending = result
            Push.markAsked(activity)
            Push.markOff(activity, false)
            activity.requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                Push.PERMISSION_REQUEST,
            )
            return
        }

        // Whatever the answer turns out to be, this handset is being
        // asked to register: if it was switched off here, it is not any
        // more. Set before the answer rather than after, because the
        // answer READS it.
        Push.markOff(activity, false)
        answer(result)
    }

    /**
     * The handset's state and, where it is allowed to have one, its
     * token.
     *
     * The token is NOT fetched when notifications are off. It would
     * succeed — FCM issues a token without any permission, exactly as
     * PushKit does on iOS — and registering it would mean this app
     * holding a live registration for somebody who said no. The iOS
     * half refuses the same thing for the same reason.
     */
    private fun answer(result: MethodChannel.Result) {
        if (!Push.configured(activity)) {
            result.success(mapOf("authorization" to "unconfigured"))
            return
        }

        // Switched off here, whatever Android thinks of the
        // permission. `notDetermined` is the right word for it: the
        // same word iOS uses for "nothing is registered and asking is
        // free", which is exactly the state this is -- pressing **Turn
        // on** registers again and raises no prompt, because the
        // permission was never given back.
        val authorization = if (Push.switchedOff(activity)) {
            "notDetermined"
        } else {
            Push.authorization(activity)
        }
        if (authorization != "authorized") {
            result.success(
                mapOf("authorization" to authorization, "label" to Push.label()),
            )
            return
        }

        FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
            val answer = mutableMapOf<String, Any?>(
                "authorization" to authorization,
                "label" to Push.label(),
            )
            if (task.isSuccessful) {
                answer["token"] = task.result
            } else {
                // A handset with no Google Play Services, which is a
                // real thing to be: a Huawei sold after 2019, a
                // de-Googled ROM, an Amazon tablet. Nothing can reach
                // it and nothing ever will, which is what the Dart
                // side reports as `unsupported` rather than as a
                // failure somebody could act on.
                answer["failure"] = task.exception?.message ?: "no token"
            }
            result.success(answer)
        }
    }

    /**
     * Stop FCM delivering here.
     *
     * Permission is left alone — an app cannot revoke it and should not
     * want to, because the prompt is spent. What this undoes is the
     * registration, and `deleteToken` is how a handset stops being
     * addressable: the next `getToken` mints a new one, so switching
     * notifications back on works.
     */
    private fun unregister(result: MethodChannel.Result) {
        // Before the delete, and regardless of whether it succeeds:
        // somebody pressed the switch, and a card that reads `on`
        // because `deleteToken` failed would be the same lie by
        // another route.
        Push.markOff(activity, true)
        if (!Push.configured(activity)) {
            result.success(null)
            return
        }
        FirebaseMessaging.getInstance().deleteToken()
            .addOnCompleteListener { result.success(null) }
    }
}
