package com.weimi95.weimi_file

import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.weimi95.weimi/file_association"
    private val VIDEO_THUMB_CHANNEL = "com.weimi95.weimi/video_thumb"
    private val SHARE_CHANNEL = "com.weimi95.weimi/share"
    private val TRANSFER_CHANNEL = "com.weimi95.weimi/transfer"
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
