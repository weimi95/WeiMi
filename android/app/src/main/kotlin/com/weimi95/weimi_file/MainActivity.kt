package com.weimi95.weimi_file

import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import android.os.Build
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties

// BiometricPrompt 要求 FragmentActivity（FlutterFragmentActivity 是其子类）
class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.weimi95.weimi/file_association"
    private val VIDEO_THUMB_CHANNEL = "com.weimi95.weimi/video_thumb"
    private val SHARE_CHANNEL = "com.weimi95.weimi/share"
    private val TRANSFER_CHANNEL = "com.weimi95.weimi/transfer"
    private val BIOMETRIC_CHANNEL = "com.weimi95.weimi/biometric"
    private val BIO_KEY_ALIAS = "weimi_vault_bio_key"
    private val BIO_PREFS = "weimi_vault_bio"
    private var initialFilePath: String? = null
    private var sharedText: String? = null
    private val sharedPaths: MutableList<String> = mutableListOf()
    private var shareChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        handleIntent(intent)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call, result ->
            when (call.method) {
                "getInitialFile" -> {
                    result.success(initialFilePath)
                }
                "deleteFile" -> {
                    val target = call.argument<String>("path")
                    result.success(if (target != null) deleteTarget(target) else false)
                }
                "shareFiles" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    result.success(shareFiles(paths))
                }
                "openWithSystem" -> {
                    val path = call.argument<String>("path")
                    result.success(if (path != null) openWithSystem(path) else false)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // 视频缩略图抽帧（MediaMetadataRetriever），返回 JPEG 字节
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VIDEO_THUMB_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getVideoThumbnail" -> {
                        val path = call.argument<String>("path")
                        val width = (call.argument<Int>("width") ?: 256).coerceIn(64, 512)
                        Thread {
                            result.success(videoThumbnail(path, width))
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }

        // 系统分享接收（任意 App 分享 → 微密文件 → 飞传页直接发送）
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialShare" -> result.success(sharePayload())
                    else -> result.notImplemented()
                }
            }
        }

        // 微密飞传 Android 前台服务（后台保活）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TRANSFER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForeground" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                            android.content.pm.PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
                        }
                        try {
                            androidx.core.content.ContextCompat.startForegroundService(
                                this, Intent(this, WeiMiTransferService::class.java)
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stopForeground" -> {
                        try {
                            stopService(Intent(this, WeiMiTransferService::class.java))
                        } catch (e: Exception) {
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // 保险箱生物识别快捷解锁（Keystore 门禁密钥 + BiometricPrompt）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BIOMETRIC_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canAuth" -> result.success(biometricCanAuth())
                    "hasSavedMaster" -> result.success(getBioPrefs().contains("master_ct"))
                    "saveMaster" -> {
                        val master = call.argument<String>("master") ?: ""
                        if (master.isEmpty()) result.success(bioFail("主密码为空"))
                        else bioSaveMaster(master, result)
                    }
                    "loadMaster" -> bioLoadMaster(result)
                    "removeMaster" -> {
                        getBioPrefs().edit().clear().apply()
                        deleteBioKey()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ==================== 保险箱生物识别 ====================

    private fun getBioPrefs() =
        getSharedPreferences(BIO_PREFS, Context.MODE_PRIVATE)

    private fun biometricCanAuth(): Boolean {
        val bm = BiometricManager.from(this)
        return if (Build.VERSION.SDK_INT >= 30) {
            bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
                BiometricManager.BIOMETRIC_SUCCESS
        } else {
            bm.canAuthenticate() == BiometricManager.BIOMETRIC_SUCCESS
        }
    }

    /// Keystore 门禁密钥：每次使用都要求生物识别验证（CryptoObject）
    private fun getOrCreateBioKey(): SecretKey? {
        return try {
            val ks = KeyStore.getInstance("AndroidKeyStore")
            ks.load(null)
            (ks.getEntry(BIO_KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
                return it.secretKey
            }
            val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            kg.init(
                KeyGenParameterSpec.Builder(
                    BIO_KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setUserAuthenticationRequired(true)
                    .setUserAuthenticationValidityDurationSeconds(-1)
                    .build()
            )
            kg.generateKey()
        } catch (e: Exception) {
            null
        }
    }

    /// 系统指纹/人脸弹窗。
    /// 注意：setAllowedAuthenticators(BIOMETRIC_STRONG) 不含 DEVICE_CREDENTIAL 时
    /// **必须**调用 setNegativeButtonText，否则 PromptInfo.build() 直接抛
    /// IllegalArgumentException，弹框压根不会出现（v1.0.64 修的坑）。
    private fun bioPrompt(
        title: String,
        subtitle: String,
        negativeText: String,
        onOk: (BiometricPrompt.AuthenticationResult) -> Unit,
        onError: (Int, String) -> Unit = { _, _ -> }
    ): Pair<BiometricPrompt, BiometricPrompt.PromptInfo> {
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setNegativeButtonText(negativeText)
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .build()
        val prompt = BiometricPrompt(
            this as FragmentActivity,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(r: BiometricPrompt.AuthenticationResult) {
                    onOk(r)
                }
                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    onError(code, msg.toString())
                }
            }
        )
        return Pair(prompt, info)
    }

    private fun bioFail(error: String) = mapOf("ok" to false, "error" to error)

    private fun bioErrorText(code: Int, msg: String): String = when (code) {
        BiometricPrompt.ERROR_NEGATIVE_BUTTON,
        BiometricPrompt.ERROR_USER_CANCELED,
        BiometricPrompt.ERROR_CANCELED -> "已取消"
        BiometricPrompt.ERROR_LOCKOUT,
        BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> "尝试次数过多已锁定，请稍后再试"
        BiometricPrompt.ERROR_NO_BIOMETRICS -> "尚未录入指纹或人脸"
        BiometricPrompt.ERROR_HW_NOT_PRESENT,
        BiometricPrompt.ERROR_HW_UNAVAILABLE -> "生物识别硬件不可用"
        else -> if (msg.isNotEmpty()) msg else "验证失败（错误码 $code）"
    }

    /// 删除门禁密钥：换指纹/屏幕锁导致旧密钥永久失效，或关闭开关时用
    private fun deleteBioKey() {
        try {
            val ks = KeyStore.getInstance("AndroidKeyStore")
            ks.load(null)
            ks.deleteEntry(BIO_KEY_ALIAS)
        } catch (e: Exception) {}
    }

    private fun bioSaveMaster(master: String, result: MethodChannel.Result) {
        try {
            val key = getOrCreateBioKey()
            if (key == null) {
                result.success(bioFail("生物识别密钥创建失败"))
                return
            }
            val cipher = try {
                Cipher.getInstance("AES/GCM/NoPadding")
                    .also { it.init(Cipher.ENCRYPT_MODE, key) }
            } catch (e: Exception) {
                // 换过指纹/屏幕锁后旧密钥会永久失效：清掉旧密钥和密文，提示重新录入
                deleteBioKey()
                getBioPrefs().edit().clear().apply()
                result.success(bioFail("生物识别密钥已失效（可能更换过指纹），请重新录入"))
                return
            }
            val iv = cipher.iv
            val (prompt, info) = bioPrompt(
                title = "录入指纹",
                subtitle = "验证指纹，之后可用指纹直接解锁保险箱",
                negativeText = "取消",
                onOk = { r ->
                    try {
                        val ct = r.cryptoObject?.cipher?.doFinal(master.toByteArray(Charsets.UTF_8))
                        if (ct == null) {
                            result.success(bioFail("加密失败，请重试"))
                        } else {
                            getBioPrefs().edit()
                                .putString("master_ct", Base64.encodeToString(ct, Base64.NO_WRAP))
                                .putString("master_iv", Base64.encodeToString(iv, Base64.NO_WRAP))
                                .apply()
                            result.success(mapOf("ok" to true))
                        }
                    } catch (e: Exception) {
                        result.success(bioFail("保存失败：${e.message}"))
                    }
                },
                onError = { code, msg ->
                    result.success(bioFail(bioErrorText(code, msg)))
                })
            prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
        } catch (e: Exception) {
            result.success(bioFail("生物识别不可用：${e.message}"))
        }
    }

    private fun bioLoadMaster(result: MethodChannel.Result) {
        try {
            val ctB64 = getBioPrefs().getString("master_ct", null)
            val ivB64 = getBioPrefs().getString("master_iv", null)
            if (ctB64 == null || ivB64 == null) {
                result.success(bioFail("尚未录入生物识别"))
                return
            }
            val key = getOrCreateBioKey()
            if (key == null) {
                result.success(bioFail("生物识别密钥缺失"))
                return
            }
            val cipher = try {
                val iv = Base64.decode(ivB64, Base64.NO_WRAP)
                Cipher.getInstance("AES/GCM/NoPadding")
                    .also { it.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv)) }
            } catch (e: Exception) {
                deleteBioKey()
                getBioPrefs().edit().clear().apply()
                result.success(bioFail("生物识别密钥已失效（可能更换过指纹），请用主密码解锁后重新录入"))
                return
            }
            val (prompt, info) = bioPrompt(
                title = "微密保险箱",
                subtitle = "验证指纹解锁保险箱",
                negativeText = "用主密码",
                onOk = { r ->
                    try {
                        val pt = r.cryptoObject?.cipher?.doFinal(Base64.decode(ctB64, Base64.NO_WRAP))
                        if (pt == null) {
                            result.success(bioFail("解密失败"))
                        } else {
                            result.success(
                                mapOf("ok" to true, "master" to pt.toString(Charsets.UTF_8)))
                        }
                    } catch (e: Exception) {
                        result.success(bioFail("解密失败：${e.message}"))
                    }
                },
                onError = { code, msg ->
                    result.success(bioFail(bioErrorText(code, msg)))
                })
            prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
        } catch (e: Exception) {
            result.success(bioFail("生物识别不可用：${e.message}"))
        }
    }

    private fun sharePayload(): Map<String, Any> {
        return mapOf(
            "text" to (sharedText ?: ""),
            "paths" to sharedPaths.toList()
        )
    }

    /// 抽视频第一关键帧，压缩为 JPEG。失败返回 null（UI 退化为类型图标）。
    private fun videoThumbnail(path: String?, width: Int): ByteArray? {
        if (path == null || !File(path).exists()) return null
        val retriever = android.media.MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val frame = retriever.getFrameAtTime(
                0,
                android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: return null
            val scaled = if (frame.width > width) {
                val h = frame.height * width / frame.width
                android.graphics.Bitmap.createScaledBitmap(frame, width, h, true)
            } else {
                frame
            }
            val bos = java.io.ByteArrayOutputStream()
            scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 60, bos)
            if (scaled !== frame) frame.recycle()
            scaled.recycle()
            bos.toByteArray()
        } catch (e: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (e: Exception) {
            }
        }
    }

    /// 删除文件：content:// URI 先解析真实路径（_data 列）再删，
    /// 失败则走 DocumentsContract.deleteDocument；普通路径直接删。
    private fun deleteTarget(target: String): Boolean {
        return try {
            if (target.startsWith("content://")) {
                val uri = Uri.parse(target)
                var deleted = false
                try {
                    val cursor: Cursor? = contentResolver.query(uri, arrayOf("_data"), null, null, null)
                    cursor?.use {
                        if (it.moveToFirst()) {
                            val idx = it.getColumnIndex("_data")
                            if (idx != -1) {
                                val p = it.getString(idx)
                                if (p != null) {
                                    val f = File(p)
                                    if (f.exists()) deleted = f.delete()
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    // 解析真实路径失败，走下方兜底
                }
                if (!deleted) {
                    deleted = try {
                        android.provider.DocumentsContract.deleteDocument(contentResolver, uri)
                    } catch (e: Exception) {
                        false
                    }
                }
                deleted
            } else {
                val f = File(target)
                f.exists() && f.delete()
            }
        } catch (e: Exception) {
            false
        }
    }

    /// 用系统默认 App 打开文件（内置查看器不支持的格式兜底，如 apk / heic）。
    /// FileProvider content:// URI + ACTION_VIEW，系统按 MIME/扩展名选 App。
    private fun openWithSystem(path: String): Boolean {
        return try {
            val f = File(path)
            if (!f.exists()) return false
            val uri = androidx.core.content.FileProvider.getUriForFile(
                this, "$packageName.fileprovider", f
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, getMimeType(path))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun getMimeType(path: String): String {
        val ext = path.substringAfterLast('.', "").lowercase()
        return android.webkit.MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(ext) ?: "*/*"
    }

    /// 通过系统分享菜单把本地文件分享出去（FileProvider content:// URI）
    private fun shareFiles(paths: List<String>): Boolean {
        return try {
            val uris = ArrayList<Uri>()
            for (p in paths) {
                val f = File(p)
                if (f.exists()) {
                    uris.add(
                        androidx.core.content.FileProvider.getUriForFile(
                            this, "$packageName.fileprovider", f
                        )
                    )
                }
            }
            if (uris.isEmpty()) return false
            val intent: Intent = if (uris.size == 1) {
                Intent(Intent.ACTION_SEND).apply {
                    type = "*/*"
                    putExtra(Intent.EXTRA_STREAM, uris[0])
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    type = "*/*"
                    putExtra(Intent.EXTRA_STREAM, uris)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            }
            startActivity(Intent.createChooser(intent, "分享文件"))
            true
        } catch (e: Exception) {
            false
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val isShare = intent.action == Intent.ACTION_SEND ||
                intent.action == Intent.ACTION_SEND_MULTIPLE
        handleIntent(intent)
        if (isShare) {
            // 通知 Dart 侧（app 已在前台运行中）
            try {
                shareChannel?.invokeMethod("onShare", sharePayload())
            } catch (e: Exception) {
            }
        }
    }

    private fun handleIntent(intent: Intent) {
        when (intent.action) {
            Intent.ACTION_VIEW -> {
                val uri: Uri? = intent.data
                if (uri != null) {
                    initialFilePath = getRealPathFromUri(uri)
                }
            }
            Intent.ACTION_SEND -> {
                // 文本分享
                val text: String? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getStringExtra(Intent.EXTRA_TEXT)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getStringExtra(Intent.EXTRA_TEXT)
                }
                if (text != null) sharedText = text
                // 文件分享
                val uri: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                if (uri != null) {
                    val path = getRealPathFromUri(uri)
                    if (path != null && !sharedPaths.contains(path)) sharedPaths.add(path)
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris: ArrayList<Uri>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                if (uris != null) {
                    for (uri in uris) {
                        val path = getRealPathFromUri(uri)
                        if (path != null && !sharedPaths.contains(path)) sharedPaths.add(path)
                    }
                }
            }
        }
    }

    private fun getRealPathFromUri(uri: Uri): String? {
        return when (uri.scheme) {
            "file" -> uri.path
            "content" -> {
                try {
                    val fileName = getFileName(uri)
                    val cacheFile = File(cacheDir, fileName ?: "temp.wemi")
                    
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(cacheFile).use { output ->
                            input.copyTo(output)
                        }
                    }
                    
                    cacheFile.absolutePath
                } catch (e: Exception) {
                    e.printStackTrace()
                    null
                }
            }
            else -> null
        }
    }

    private fun getFileName(uri: Uri): String? {
        var result: String? = null
        if (uri.scheme == "content") {
            val cursor: Cursor? = contentResolver.query(uri, null, null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val index = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index != -1) {
                        result = it.getString(index)
                    }
                }
            }
        }
        if (result == null) {
            result = uri.path
            val cut = result?.lastIndexOf('/')
            if (cut != -1 && cut != null) {
                result = result?.substring(cut + 1)
            }
        }
        return result
    }
}
