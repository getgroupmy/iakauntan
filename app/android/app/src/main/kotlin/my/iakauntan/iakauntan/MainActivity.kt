package my.iakauntan.iakauntan

import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The document scanner hands back `content://` URIs, and Dart cannot
 * open one.
 *
 * ML Kit's Document Scanner returns its cropped, deskewed pages as
 * FileProvider URIs owned by another package's provider. `java.io.File`
 * will not open those and neither will Dart's `File`; only Android's
 * ContentResolver will, because the grant that makes them readable is
 * attached to the URI and understood by the resolver alone.
 *
 * Everything downstream of a capture in this app wants bytes — the
 * upload wants them, and the on-device reader wants a real file it can
 * hand ML Kit a path to. So this is where a content URI stops being one.
 *
 * Deliberately ours rather than a package. It is twenty lines against
 * another dependency to track, and the alternative found on pub.dev is
 * a general-purpose file utility whose surface is far wider than the
 * one call needed here.
 */
class MainActivity : FlutterActivity() {
    private val channel = "my.iakauntan.iakauntan/content"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readContentUri" -> readContentUri(call.argument("uri"), result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun readContentUri(uri: String?, result: MethodChannel.Result) {
        if (uri.isNullOrBlank()) {
            result.error("no-uri", "No URI was given", null)
            return
        }
        try {
            // `use` on the stream, not on the resolver: leaving the
            // descriptor open holds the other app's provider alive, and
            // a scanner used a dozen times in a morning would leak a
            // dozen of them.
            val bytes = contentResolver.openInputStream(Uri.parse(uri))?.use {
                it.readBytes()
            }
            if (bytes == null) {
                result.error("unreadable", "Nothing could be read from $uri", null)
            } else {
                result.success(bytes)
            }
        } catch (e: SecurityException) {
            // The grant on a scanner URI is scoped to this task and does
            // not survive it. Worth its own message: "permission denied"
            // on a file the user just scanned themselves reads as a bug
            // unless it says why.
            result.error(
                "expired",
                "The scan is no longer readable — it was handed over for " +
                    "this screen only. Scan it again.",
                e.message,
            )
        } catch (e: Exception) {
            result.error("unreadable", e.message ?: "Could not read $uri", null)
        }
    }
}
