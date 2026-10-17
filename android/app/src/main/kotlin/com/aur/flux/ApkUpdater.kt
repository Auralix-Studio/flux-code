package com.aur.flux

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import java.util.concurrent.Executors

/**
 * Instala el APK que descargó UpdateService (Dart) por el canal
 * `flux/updater`.
 *
 * Dart ya comprobó el SHA-256 contra version.json; aquí se comprueba lo que
 * Dart no puede ver: que el archivo sea esta misma app, más nueva, y firmada
 * con la misma clave. Sin esto, un version.json alterado podría hacer que el
 * usuario instalara otra app con un toque, porque Android solo exige la misma
 * firma cuando el paquete coincide.
 */
class ApkUpdater(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private var busy = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!BuildConfig.DIRECT_DIST) { result.error("unsupported", "Store build", null); return }
        when (call.method) {
            "target" -> result.success(when (Build.SUPPORTED_ABIS.firstOrNull()) {
                "arm64-v8a" -> "android-arm64"
                "armeabi-v7a" -> "android-armv7"
                "x86_64" -> "android-x86_64"
                else -> "android-universal"
            })
            "download" -> {
                if (busy) { result.error("busy", "Download already running", null); return }
                val url = call.argument<String>("url") ?: ""
                val hash = call.argument<String>("sha256") ?: ""
                val size = call.argument<Number>("size")?.toLong() ?: 0
                if (!url.matches(Regex("https://github\\.com/Auralix-Studio/flux/releases/download/v[0-9]+\\.[0-9]+\\.[0-9]+/flux-v[0-9]+\\.[0-9]+\\.[0-9]+-(universal|arm64|armv7|x86_64)\\.apk")) ||
                    !hash.matches(Regex("[a-f0-9]{64}")) || size !in 1..1073741824L) {
                    result.error("invalid_asset", "Invalid update metadata", null); return
                }
                busy = true
                worker.execute {
                    try {
                        val file = download(url, hash, size)
                        activity.runOnUiThread { busy = false; result.success(file.path) }
                    } catch (error: Exception) {
                        activity.runOnUiThread { busy = false; result.error("download", error.message, null) }
                    }
                }
            }
            "canInstall" -> result.success(canInstall())
            "openInstallSettings" -> {
                openInstallSettings()
                result.success(null)
            }
            "install" -> {
                val path = call.argument<String>("path")
                val hash = call.argument<String>("sha256") ?: ""
                val size = call.argument<Number>("size")?.toLong() ?: 0
                worker.execute {
                    try {
                        val file = path?.let { File(it).canonicalFile }
                        val directory = File(activity.filesDir, "updates").canonicalFile
                        val valid = file != null && file.parentFile == directory && verify(file, hash, size)
                        activity.runOnUiThread {
                            try { result.success(if (valid) install(file!!) else "invalid_file") }
                            catch (error: Exception) { result.error("install", error.message, null) }
                        }
                    } catch (error: Exception) {
                        activity.runOnUiThread { result.error("install", error.message, null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun verify(file: File, expected: String, size: Long): Boolean {
        if (!file.isFile || size <= 0 || file.length() != size || !expected.matches(Regex("[a-f0-9]{64}"))) return false
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) } == expected
    }

    private fun download(url: String, hash: String, size: Long): File {
        val directory = File(activity.filesDir, "updates").apply { mkdirs() }
        val target = File(directory, "flux-update.apk")
        if (verify(target, hash, size)) return target
        val part = File(directory, "flux-update.apk.part")
        try {
            var next = URL(url)
            var complete = false
            for (redirect in 0..5) {
                require(next.protocol == "https" && (next.host == "github.com" || next.host == "release-assets.githubusercontent.com" || next.host == "objects.githubusercontent.com")) { "Untrusted download redirect" }
                val connection = next.openConnection() as HttpsURLConnection
                connection.connectTimeout = 30000
                connection.readTimeout = 30000
                connection.instanceFollowRedirects = false
                try {
                    if (connection.responseCode in listOf(301, 302, 303, 307, 308)) {
                        next = URL(next, connection.getHeaderField("Location") ?: error("Missing redirect"))
                        continue
                    }
                    require(connection.responseCode == 200) { "Download HTTP ${connection.responseCode}" }
                    connection.inputStream.use { input -> part.outputStream().use { output ->
                        val buffer = ByteArray(65536)
                        var total = 0L
                        while (true) {
                            val count = input.read(buffer); if (count < 0) break
                            total += count; require(total <= size) { "Download exceeds declared size" }
                            output.write(buffer, 0, count)
                        }
                    } }
                    complete = true
                    break
                } finally { connection.disconnect() }
            }
            require(complete && verify(part, hash, size)) { "Update checksum or size mismatch" }
            if (target.exists()) require(target.delete()) { "Cannot replace old update" }
            require(part.renameTo(target)) { "Cannot finalize update" }
            return target
        } finally { part.delete() }
    }

    /** Si Android ya autorizó a Flux a instalar apps desconocidas. */
    private fun canInstall(): Boolean =
        
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                activity.packageManager.canRequestPackageInstalls())

    /** Abre el ajuste de «instalar apps desconocidas» de Flux. */
    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        activity.startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${activity.packageName}"),
            )
        )
    }

    private fun install(file: File): String {
        
        // Solo lo que dejó el actualizador, en la carpeta que comparte el
        // FileProvider: nada de rutas arbitrarias desde Dart.
        val updates = File(activity.filesDir, "updates").canonicalFile
        val apk = file.canonicalFile
        if (apk.parentFile != updates || !apk.isFile) return "invalid_file"

        val pm = activity.packageManager
        val archive = archiveInfo(pm, apk) ?: return "invalid_file"
        val installed = pm.getPackageInfo(activity.packageName, signatureFlags())
        if (archive.packageName != activity.packageName) return "wrong_package"
        if (PackageInfoCompat.getLongVersionCode(archive) <=
            PackageInfoCompat.getLongVersionCode(installed)
        ) {
            return "not_newer"
        }
        val expected = signers(installed)
        if (expected.isEmpty() || signers(archive) != expected) return "wrong_signature"
        if (!canInstall()) return "needs_permission"

        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", apk)
        activity.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        return "started"
    }

    private fun archiveInfo(pm: PackageManager, apk: File): PackageInfo? {
        val info = pm.getPackageArchiveInfo(apk.path, signatureFlags())
        // Algunas versiones de Android no devuelven signingInfo para un APK
        // suelto; el flag antiguo sí trae las firmas.
        if (info != null && signers(info).isEmpty()) {
            @Suppress("DEPRECATION")
            return pm.getPackageArchiveInfo(apk.path, PackageManager.GET_SIGNATURES)
        }
        return info
    }

    @Suppress("DEPRECATION")
    private fun signatureFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }

    /** SHA-256 de cada certificado con que está firmado el contenido. */
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && info.signingInfo != null) {
                info.signingInfo!!.apkContentsSigners
            } else {
                info.signatures
            } ?: return emptySet()
        val sha = MessageDigest.getInstance("SHA-256")
        return signatures.map { sig ->
            sha.digest(sig.toByteArray()).joinToString("") { "%02x".format(it) }
        }.toSet()
    }
}
