package app.pocketssh.pocket_ssh

import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private val prefs by lazy { getSharedPreferences("pocket_ssh", MODE_PRIVATE) }
    private val pins by lazy { getSharedPreferences("ssh_host_keys", MODE_PRIVATE) }
    private val secrets by lazy { getSharedPreferences("ssh_secrets", MODE_PRIVATE) }
    private var pending: MethodChannel.Result? = null
    private var pendingMethod = ""
    private var auth: MethodChannel.Result? = null
    private val inputs = mutableMapOf<String, InputStream>()
    private val outputs = mutableMapOf<String, OutputStream>()

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.pocketssh/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickKey", "pickUpload", "createDownload" -> {
                        if (pending != null) { result.error("busy", "文件选择器已打开", null); return@setMethodCallHandler }
                        pending = result
                        pendingMethod = call.method
                        val intent = Intent(if (call.method == "createDownload") Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            if (call.method == "createDownload") putExtra(Intent.EXTRA_TITLE, call.arguments as? String ?: "download")
                        }
                        try { startActivityForResult(intent, 8127) }
                        catch (_: Exception) { pending = null; result.error("picker", "无法打开文件选择器", null) }
                    }
                    "authenticate" -> {
                        if (auth != null) { result.error("busy", "设备认证已打开", null); return@setMethodCallHandler }
                        val manager = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
                        val intent = manager.createConfirmDeviceCredentialIntent("解锁 Pocket SSH", "使用设备认证访问保存的凭据")
                        if (intent == null) result.error("no_device_lock", "请先设置设备锁屏认证", null)
                        else { auth = result; startActivityForResult(intent, 8128) }
                    }
                    "keepAwake" -> {
                        if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(null)
                    }
                    else -> io.execute {
                        try {
                            when (call.method) {
                                "loadState" -> result.success(prefs.getString("state", null)?.let { decrypt(it) })
                                "saveState" -> { check(prefs.edit().putString("state", encrypt(call.arguments as String)).commit()); result.success(null) }
                                "readSecret" -> result.success(secrets.getString(call.arguments as String, null)?.let { decrypt(it) })
                                "writeSecret" -> {
                                    val key = call.argument<String>("key")!!
                                    val value = call.argument<String>("value")
                                    val editor = secrets.edit()
                                    if (value == null) editor.remove(key) else editor.putString(key, encrypt(value))
                                    check(editor.commit()); result.success(null)
                                }
                                "readHost" -> result.success(pins.getString(call.arguments as String, null))
                                "listHosts" -> result.success(pins.all)
                                "forgetHost" -> { check(pins.edit().remove(call.arguments as String).commit()); result.success(null) }
                                "rememberHost" -> {
                                    val endpoint = call.argument<String>("endpoint")!!
                                    val fingerprint = call.argument<String>("fingerprint")!!
                                    require(Regex("SHA256:[A-Za-z0-9+/]{43}").matches(fingerprint))
                                    val old = pins.getString(endpoint, null)
                                    check(old == null || old == fingerprint)
                                    check(pins.edit().putString(endpoint, fingerprint).commit()); result.success(null)
                                }
                                "readChunk" -> {
                                    val uri = call.arguments as String
                                    val input = inputs.getOrPut(uri) { contentResolver.openInputStream(Uri.parse(uri)) ?: error("无法读取文件") }
                                    val buffer = ByteArray(65536)
                                    val count = input.read(buffer)
                                    result.success(if (count < 0) null else buffer.copyOf(count))
                                }
                                "writeChunk" -> {
                                    val uri = call.argument<String>("uri")!!
                                    val output = outputs.getOrPut(uri) { contentResolver.openOutputStream(Uri.parse(uri), "wt") ?: error("无法写入文件") }
                                    output.write(call.argument<ByteArray>("bytes")!!); result.success(null)
                                }
                                "closeDocument" -> {
                                    val uri = call.arguments as String
                                    inputs.remove(uri)?.close(); outputs.remove(uri)?.close(); result.success(null)
                                }
                                "deleteDocument" -> {
                                    val uri = call.arguments as String
                                    inputs.remove(uri)?.close(); outputs.remove(uri)?.close()
                                    result.success(contentResolver.delete(Uri.parse(uri), null, null) > 0)
                                }
                                else -> result.notImplemented()
                            }
                        } catch (_: Exception) { result.error("device_storage", "设备存储或加密操作失败", null) }
                    }
                }
            }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("pocket_ssh_vault", null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder("pocket_ssh_vault", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        return generator.generateKey()
    }
    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return Base64.encodeToString(cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }
    private fun decrypt(value: String): String {
        val data = Base64.decode(value, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
        return String(cipher.doFinal(data.copyOfRange(12, data.size)), Charsets.UTF_8)
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 8128) { auth?.success(resultCode == Activity.RESULT_OK); auth = null; return }
        if (requestCode != 8127) return
        val reply = pending ?: return
        val method = pendingMethod
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { reply.success(null); return }
        io.execute {
            try {
                if (method == "pickKey") {
                    val bytes = contentResolver.openInputStream(uri)!!.use { it.readBytesLimited(128 * 1024) }
                    reply.success(bytes)
                } else {
                    var name = "file"
                    var size = 0L
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
                        if (it.moveToFirst()) { name = it.getString(0) ?: "file"; if (!it.isNull(1)) size = it.getLong(1) }
                    }
                    reply.success(mapOf("uri" to uri.toString(), "name" to name, "size" to size))
                }
            } catch (_: Exception) { reply.error("document", "无法访问所选文件", null) }
        }
    }
    private fun InputStream.readBytesLimited(limit: Int): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) { val count = read(buffer); if (count < 0) break; require(output.size() + count <= limit); output.write(buffer, 0, count) }
        return output.toByteArray()
    }
    override fun onDestroy() {
        pending?.success(null); pending = null
        auth?.success(false); auth = null
        io.execute { inputs.values.forEach { it.close() }; outputs.values.forEach { it.close() }; inputs.clear(); outputs.clear() }
        io.shutdown()
        super.onDestroy()
    }
}
