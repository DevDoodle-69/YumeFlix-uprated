package yume.flix.by.nzr

import android.content.Intent
import android.net.Uri
import android.app.AlarmManager
import android.app.PendingIntent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.AlertDialog
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import android.util.Rational
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val CHANNEL = "yume.flix.by.nzr/player_pip"
    private val PLAYER_CHANNEL = "yume.flix.by.nzr/external_player"
    private val UPDATE_CHANNEL = "yume.flix.by.nzr/app_update"

    private var isPlaying = false
    private var previousUncaughtHandler: Thread.UncaughtExceptionHandler? = null

    /// The shape of the video currently playing, as the PiP window should be
    /// shaped. Null until Dart has decoded a frame and told us. Held as a
    /// field because `updatePipActions()` rebuilds the params from scratch on
    /// every play/pause flip, and a rebuild that dropped the aspect ratio
    /// would snap the window back to square in the middle of a film.
    private var pipAspectRatio: Rational? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        
        // PiP Channel
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "enterPip") {
                val playing = call.argument<Boolean>("isPlaying") ?: false
                this.isPlaying = playing // Sync state immediately
                pipAspectRatio = aspectRatioOf(
                    call.argument<Int>("videoWidth"),
                    call.argument<Int>("videoHeight"),
                ) ?: pipAspectRatio

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    updatePipActions()
                    val builder = PictureInPictureParams.Builder()
                    builder.setActions(createPipActions())
                    // Without this the window is whatever shape Android last
                    // used, so a 2.39:1 film is letterboxed inside a window
                    // that is already small.
                    pipAspectRatio?.let { builder.setAspectRatio(it) }
                    // Returns false when the user has PiP switched off for
                    // this app: no exception, and no onPictureInPictureModeChanged
                    // either. Dart needs the answer to undo its own optimism.
                    result.success(enterPictureInPictureMode(builder.build()))
                } else {
                    result.error("UNSUPPORTED", "PIP not supported", null)
                }
            } else if (call.method == "setPipState") {
                // Flutter tells us if playing or not
                val playing = call.argument<Boolean>("isPlaying") ?: false
                aspectRatioOf(
                    call.argument<Int>("videoWidth"),
                    call.argument<Int>("videoHeight"),
                )?.let { pipAspectRatio = it }
                // Always update state and force refresh actions
                // The user reported sync issues, so we shouldn't skip update if values match
                this.isPlaying = playing
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    updatePipActions()
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        // External Player Channel — uses native Intent to avoid Uri.parse() issues
        MethodChannel(messenger, PLAYER_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "launchVideoInPlayer") {
                val videoUrl = call.argument<String>("url") ?: run {
                    result.error("INVALID_ARGS", "url is required", null)
                    return@setMethodCallHandler
                }
                val packageName = call.argument<String>("package")
                val mimeType = call.argument<String>("mimeType") ?: "video/*"
                val title = call.argument<String>("title")

                try {
                    val uri = if (videoUrl.startsWith("file://") || (videoUrl.startsWith("/") && File(videoUrl).exists())) {
                        val filePath = if (videoUrl.startsWith("file://")) {
                            videoUrl.substring(7)
                        } else {
                            videoUrl
                        }
                        FileProvider.getUriForFile(this, "${applicationContext.packageName}.fileProvider", File(filePath))
                    } else {
                        Uri.parse(videoUrl)
                    }

                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, mimeType)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        if (!packageName.isNullOrEmpty()) setPackage(packageName)
                        if (!title.isNullOrEmpty()) {
                            putExtra("title", title)
                            putExtra("android.intent.extra.TITLE", title)
                        }
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (e: android.content.ActivityNotFoundException) {
                    result.success(false) // Player not installed / not found
                } catch (e: Exception) {
                    result.error("LAUNCH_ERROR", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }

        // In-app updates (YumeFlix 2.11.0) — see
        // lib/features/update/app_update_installer.dart (Dart side).
        //
        // The system installer is the only way to install an APK the app
        // downloaded itself, and Android requires the user to confirm the
        // install tap: the app opens the installer, it never installs
        // silently. REQUEST_INSTALL_PACKAGES is declared in
        // AndroidManifest.xml; the FileProvider entry there already serves
        // the application documents directory the APK is downloaded to.
        MethodChannel(messenger, UPDATE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "canRequestInstall" -> {
                    result.success(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else {
                            true
                        },
                    )
                }
                "requestInstallPermission" -> {
                    // Opens the system "Install unknown apps" page for this
                    // app. The user flips the switch there; the app cannot
                    // do it for them. Returns to the app via the back stack.
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val intent = Intent(
                                android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        result.error("SETTINGS_ERROR", e.message, null)
                    }
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "path is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(path)
                        if (!file.exists()) {
                            result.error("NOT_FOUND", "APK file not found", null)
                            return@setMethodCallHandler
                        }
                        val uri = FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileProvider",
                            file,
                        )
                        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: android.content.ActivityNotFoundException) {
                        result.error("NO_INSTALLER", e.message, null)
                    } catch (e: Exception) {
                        result.error("INSTALL_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    
    // Action Constants
    //
    // Namespaced, and paired with RECEIVER_NOT_EXPORTED below. The bare
    // "media_control" string was registered as an exported receiver, so any
    // app on the device could broadcast it and pause, resume or seek whatever
    // the user was watching.
    private val ACTION_MEDIA_CONTROL = "yume.flix.by.nzr.MEDIA_CONTROL"
    private val EXTRA_CONTROL_TYPE = "control_type"
    private val CONTROL_TYPE_PLAY = 1
    private val CONTROL_TYPE_PAUSE = 2
    private val CONTROL_TYPE_REWIND = 3
    private val CONTROL_TYPE_FORWARD = 4

    private val receiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: android.content.Intent?) {
            if (intent?.action == ACTION_MEDIA_CONTROL) {
                val type = intent.getIntExtra(EXTRA_CONTROL_TYPE, 0)
                val method = when (type) {
                    CONTROL_TYPE_PLAY -> "play"
                    CONTROL_TYPE_PAUSE -> "pause"
                    CONTROL_TYPE_REWIND -> "seekBackward"
                    CONTROL_TYPE_FORWARD -> "seekForward"
                    else -> null
                }
                if (method != null) {
                    flutterEngine?.dartExecutor?.binaryMessenger?.let {
                        MethodChannel(it, CHANNEL).invokeMethod(method, null)
                    }
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        installBoundedCrashRecovery()
        super.onCreate(savedInstanceState)
        // Tamper protection: a copy re-signed by APK Editor / MT Manager (or
        // any other certificate) must not run. Checked before the Flutter UI
        // becomes usable; on mismatch a non-dismissible warning is shown and
        // the activity finishes. This stops casual re-signing/modification —
        // it is not proof against a determined reverser.
        if (!isReleaseSignatureValid()) {
            showClonedAppWarning()
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val filter = android.content.IntentFilter(ACTION_MEDIA_CONTROL)
            // ContextCompat rather than registerReceiver(..., RECEIVER_NOT_EXPORTED)
            // directly: below Android 13 there is no flag, and the plain
            // two-argument overload the old code used there is exported by
            // default. ContextCompat closes that gap by registering with a
            // signature-level permission only this app holds.
            //
            // The PiP buttons still work: their PendingIntents are sent with
            // this app's own identity and uid, and a same-uid broadcast
            // reaches a non-exported receiver. The intents below also name
            // this package explicitly, so the broadcast never leaves the app.
            ContextCompat.registerReceiver(
                this,
                receiver,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
        }
    }

    /**
     * Tamper protection (see onCreate). The expected release-certificate
     * SHA-256 is stored split into indexed chunks in shuffled order, never
     * as one plain literal, and reassembled at runtime.
     */
    private fun isReleaseSignatureValid(): Boolean {
        return try {
            val expected = EXPECTED_CERT_HASH_PARTS
                .sortedBy { it.first }
                .joinToString("") { it.second }
            val signatures = currentSignatures()
            signatures.any { signature ->
                val digest = MessageDigest.getInstance("SHA-256")
                    .digest(signature.toByteArray())
                digest.joinToString("") { "%02X".format(it.toInt() and 0xFF) } == expected
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun currentSignatures(): Array<out Signature> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
            val signingInfo = info.signingInfo
            if (signingInfo == null) {
                @Suppress("DEPRECATION")
                info.signatures ?: emptyArray()
            } else if (signingInfo.hasMultipleSigners()) {
                signingInfo.apkContentsSigners ?: emptyArray()
            } else {
                signingInfo.signingCertificateHistory ?: emptyArray()
            }
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNATURES,
            ).signatures ?: emptyArray()
        }
    }

    private fun showClonedAppWarning() {
        try {
            val dialog = AlertDialog.Builder(this)
                .setTitle("This app is cloned")
                .setMessage(
                    "Do not try to modify the source code of this app. " +
                        "You never can do this. This is protected.\n\nBy NZ R",
                )
                .setCancelable(false)
                .setPositiveButton("OK") { _, _ -> finish() }
                .create()
            dialog.setOnDismissListener { finish() }
            dialog.show()
        } catch (_: Exception) {
            finish()
        }
    }

    /**
     * Relaunches the activity after a process-level crash, but caps retries to
     * two launches in a 60-second window so a bad device/plugin cannot spin
     * forever. Flutter-level errors are handled by Dart's recovery surfaces.
     */
    private fun installBoundedCrashRecovery() {
        previousUncaughtHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            val prefs = getSharedPreferences("crash_recovery", MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val windowStart = prefs.getLong("window_start", 0L)
            val attempts = if (now - windowStart < 60_000L) {
                prefs.getInt("attempts", 0)
            } else {
                0
            }
            if (attempts < 2) {
                prefs.edit()
                    .putLong("window_start", if (attempts == 0) now else windowStart)
                    .putInt("attempts", attempts + 1)
                    .apply()
                val restartIntent = packageManager.getLaunchIntentForPackage(packageName)
                    ?.apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    }
                if (restartIntent != null) {
                    val pending = PendingIntent.getActivity(
                        this,
                        7719,
                        restartIntent,
                        PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE,
                    )
                    (getSystemService(ALARM_SERVICE) as? AlarmManager)?.set(
                        AlarmManager.RTC,
                        now + 1_000L,
                        pending,
                    )
                }
            }
            previousUncaughtHandler?.uncaughtException(thread, throwable)
                ?: android.os.Process.killProcess(android.os.Process.myPid())
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(receiver)
        } catch (e: Exception) {}
    }

    private fun createPipActions(): List<android.app.RemoteAction> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return emptyList()

        val actions = mutableListOf<android.app.RemoteAction>()

        // 1. Rewind (Use custom 10s icon)
        val rewindIntent = android.content.Intent(ACTION_MEDIA_CONTROL).apply {
            setPackage(packageName)
            putExtra(EXTRA_CONTROL_TYPE, CONTROL_TYPE_REWIND)
        }
        val rewindPendingIntent = android.app.PendingIntent.getBroadcast(
            this, CONTROL_TYPE_REWIND, rewindIntent, android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val rewindIcon = android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_replay_10)
        actions.add(android.app.RemoteAction(rewindIcon, "Rewind", "Rewind 10s", rewindPendingIntent))

        // 2. Play/Pause
        val playPauseIntent = android.content.Intent(ACTION_MEDIA_CONTROL).apply {
            setPackage(packageName)
            putExtra(EXTRA_CONTROL_TYPE, if (isPlaying) CONTROL_TYPE_PAUSE else CONTROL_TYPE_PLAY)
        }
        // Unique Request Code is Critical
        val playPauseReqCode = if (isPlaying) CONTROL_TYPE_PAUSE else CONTROL_TYPE_PLAY
        val playPausePendingIntent = android.app.PendingIntent.getBroadcast(
            this, playPauseReqCode, playPauseIntent, android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val playPauseIconIdx = if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play_arrow
        val playPauseTitle = if (isPlaying) "Pause" else "Play"
        val playPauseIcon = android.graphics.drawable.Icon.createWithResource(this, playPauseIconIdx)
        actions.add(android.app.RemoteAction(playPauseIcon, playPauseTitle, playPauseTitle, playPausePendingIntent))

        // 3. Forward (Use custom 10s icon)
        val forwardIntent = android.content.Intent(ACTION_MEDIA_CONTROL).apply {
            setPackage(packageName)
            putExtra(EXTRA_CONTROL_TYPE, CONTROL_TYPE_FORWARD)
        }
        val forwardPendingIntent = android.app.PendingIntent.getBroadcast(
            this, CONTROL_TYPE_FORWARD, forwardIntent, android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val forwardIcon = android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_forward_10)
        actions.add(android.app.RemoteAction(forwardIcon, "Forward", "Forward 10s", forwardPendingIntent))

        return actions
    }

    private fun updatePipActions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val builder = PictureInPictureParams.Builder()
                .setActions(createPipActions())
            pipAspectRatio?.let { builder.setAspectRatio(it) }
            setPictureInPictureParams(builder.build())
        }
    }

    /**
     * The video's shape as a [Rational] PiP will accept, or null when Dart has
     * not decoded a frame yet and there is nothing to say.
     *
     * Clamped, and that is the load-bearing part: Android rejects any aspect
     * ratio outside roughly 1:2.39 .. 2.39:1 by throwing
     * IllegalArgumentException out of `enterPictureInPictureMode`, which would
     * crash the app on the way into the window. A 2.76:1 Ultra Panavision
     * transfer or a phone-shot vertical clip is not a hypothetical, so the
     * bound is applied a hair inside the documented limit rather than at it.
     */
    private fun aspectRatioOf(width: Int?, height: Int?): Rational? {
        if (width == null || height == null || width <= 0 || height <= 0) {
            return null
        }
        val ratio = (width.toDouble() / height.toDouble())
            .coerceIn(1.0 / MAX_PIP_ASPECT, MAX_PIP_ASPECT)
        return Rational((ratio * 10_000).roundToInt(), 10_000)
    }

    companion object {
        /**
         * Android's documented ceiling is 2.39:1 (and its reciprocal). Held a
         * hair inside it so a film that *is* exactly 2.39:1 cannot land on the
         * wrong side of a float comparison inside the framework.
         */
        private const val MAX_PIP_ASPECT = 2.38

        // Expected release-certificate SHA-256, split into indexed 8-char
        // chunks in shuffled order (reassembled sorted by index in
        // isReleaseSignatureValid()). Matches the yumeflix-release.keystore
        // certificate used to sign the 2.5.0 release APK.
        private val EXPECTED_CERT_HASH_PARTS = listOf(
            3 to "3A18D819",
            0 to "5BF1808B",
            6 to "3EA2FF04",
            1 to "2EBE35B1",
            7 to "EFC9A9E9",
            4 to "D637461D",
            2 to "C8DAE32E",
            5 to "5048388E",
        )
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        // Safe call, not !!. Closing the PiP window is one of the ways this
        // activity is torn down, and the engine can already be detached by the
        // time the leave-PiP callback lands — which crashed the app on exit.
        // The receiver above uses the same guarded form for the same reason.
        flutterEngine?.dartExecutor?.binaryMessenger?.let {
            MethodChannel(it, CHANNEL).invokeMethod("pipModeChanged", isInPictureInPictureMode)
        }
    }
}
