package app.pocketssh.pocket_ssh

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private var keyRequest: MethodChannel.Result? = null
    private val pins by lazy { getSharedPreferences("ssh_host_keys", MODE_PRIVATE) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.pocketssh/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readHost", "forgetHost", "rememberHost" -> {
                        val endpoint = if (call.method == "rememberHost") {
                            call.argument<String>("endpoint")
                        } else {
                            call.arguments as? String
                        }
                        val fingerprint = if (call.method == "rememberHost") {
                            call.argument<String>("fingerprint")
                        } else null
                        if (endpoint.isNullOrBlank() ||
                            (call.method == "rememberHost" &&
                                (fingerprint == null || !FINGERPRINT.matches(fingerprint)))
                        ) {
                            result.error("invalid_arguments", "Invalid host or fingerprint", null)
                            return@setMethodCallHandler
                        }
                        io.execute {
                            try {
                                val value = when (call.method) {
                                    "readHost" -> pins.getString(endpoint, null)
                                    "forgetHost" -> {
                                        if (!pins.edit().remove(endpoint).commit()) throw IOException()
                                        null
                                    }
                                    else -> {
                                        val existing = pins.getString(endpoint, null)
                                        if (existing != null && existing != fingerprint) throw IOException()
                                        if (!pins.edit().putString(endpoint, fingerprint).commit()) throw IOException()
                                        null
                                    }
                                }
                                result.success(value)
                            } catch (_: Exception) {
                                result.error("host_store", "Unable to access host trust records", null)
                            }
                        }
                    }
                    "pickKey" -> pickKey(result)
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun pickKey(result: MethodChannel.Result) {
        if (keyRequest != null) {
            result.error("picker_busy", "A document request is already open", null)
            return
        }
        keyRequest = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            startActivityForResult(intent, PICK_KEY)
        } catch (_: Exception) {
            keyRequest = null
            result.error("key_picker", "Unable to open the document picker", null)
        }
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_KEY) return
        val reply = keyRequest ?: return
        keyRequest = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            reply.success(null)
            return
        }
        io.execute {
            try {
                val key = contentResolver.openInputStream(uri)?.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (output.size() + count > MAX_KEY_BYTES) throw IOException()
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                } ?: throw IOException()
                reply.success(key)
            } catch (_: Exception) {
                reply.error("key_read", "Unable to read private key file", null)
            }
        }
    }

    override fun onDestroy() {
        keyRequest?.success(null)
        keyRequest = null
        io.shutdown()
        super.onDestroy()
    }

    private companion object {
        const val PICK_KEY = 8127
        const val MAX_KEY_BYTES = 128 * 1024
        val FINGERPRINT = Regex("SHA256:[A-Za-z0-9+/]{43}")
    }
}
