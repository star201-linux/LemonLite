package xyz.star201.lemonlite

import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `lemonlite/downloads` 通道：把「下载」这件事交给系统的 [DownloadManager]。
 *
 * 为什么用系统下载器，而不是自己在 Dart 里拉流写文件：
 *   1. **落盘权限**：Android 10 起，应用不能直接往公共「下载」目录写文件，
 *      要么走 MediaStore、要么走 SAF、要么就要 MANAGE_EXTERNAL_STORAGE
 *      （那是「管理所有文件」级别的授权，正是本项目要避免的）。而
 *      DownloadManager 是系统组件，由它把文件写进 Download 目录**不需要**
 *      我们申请任何存储权限 —— 这正是用户要的「安卓那样」的行为。
 *   2. **后台存活**：下载在系统进程里跑，宿主被切到后台甚至被杀掉都不影响，
 *      下完还有系统通知。
 *   3. **免写状态机**：续传、限速、失败重试都在系统侧，宿主只查进度。
 *
 * 代价（有意接受）：宿主不能直接读这些文件 —— 安卓 11+ 公共下载目录里的
 * 文件对外部应用是不可读的。所以「打开」走 DownloadManager 自己发的
 * content:// Uri（带临时读授权），「删除」走 DownloadManager.remove()。
 * 管理页展示的文件名 / 大小 / 时间全部来自我们自己的记录 + query 结果，
 * 不去 stat 公共目录。
 *
 * 线程：DownloadManager 的调用本身是线程安全的，但 MethodChannel.Result
 * 必须回到主线程回，所以统一 post 到主线程。
 */
class DownloadBridge(private val activity: FlutterActivity) {

    private companion object {
        /** 与 Dart 侧 DownloadService.channel 逐字一致 */
        const val CHANNEL_NAME = "lemonlite/downloads"

        /** 请求头数量上限：多到这种程度的下载请求本身就不正常 */
        const val MAX_HEADERS = 20

        /** 文件名 / 子目录长度上限（Linux 文件名上限是 255 字节，这里保守取 200 字符） */
        const val MAX_NAME_LENGTH = 200
    }

    private val handler = Handler(Looper.getMainLooper())

    private val manager: DownloadManager
        get() = activity.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL_NAME).setMethodCallHandler { call, result ->
            handler.post {
                try {
                    handle(call, result)
                } catch (e: Exception) {
                    // 原生异常一律转成错误码回 Dart：一次下载失败不该把宿主带走
                    result.error("download_error", e.message ?: e.toString(), null)
                }
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "enqueue" -> result.success(enqueue(call))
            "query" -> result.success(query(call))
            "remove" -> result.success(remove(call))
            "open" -> result.success(open(call))
            "openDirectory" -> result.success(openDirectory())
            "info" -> result.success(info())
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------- enqueue

    private fun enqueue(call: MethodCall): Map<String, Any?> {
        val url = call.argument<String>("url")?.trim().orEmpty()
        require(url.startsWith("http://") || url.startsWith("https://")) {
            "只支持 http(s) 链接：$url"
        }

        val fileName = sanitizeName(
            call.argument<String>("fileName") ?: "",
            fallback = "download-${System.currentTimeMillis()}",
        )
        val subDir = sanitizeSubDir(call.argument<String>("subDir") ?: "")
        val mime = call.argument<String>("mimeType")?.trim().orEmpty()
        // 通道回来的 Map 不保证 key/value 就是 String（Dart 侧可能传进 null
        // 或数字），统一 toString 之后再塞给系统，避免 ClassCastException。
        val headers: List<Pair<String, String>> =
            (call.argument<Map<*, *>>("headers") ?: emptyMap<Any?, Any?>())
                .entries
                .take(MAX_HEADERS)
                .mapNotNull { (key, value) ->
                    val k = key?.toString()?.trim().orEmpty()
                    if (k.isEmpty() || value == null) null else k to value.toString()
                }

        val request = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle(fileName)
            if (mime.isNotEmpty()) setMimeType(mime)
            // 完成时给一条系统通知。VISIBLE_NOTIFY_COMPLETED 只在下完时提示，
            // 不会在整个下载过程中常驻状态栏 —— 那是下载器自己的选择。
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            setAllowedOverMetered(true)
            setAllowedOverRoaming(false)

            // 目标 = 公共「下载」目录（DIRECTORY_DOWNLOADS）+ 可选的子目录。
            // API 29+ 由系统代为落盘，不需要任何存储权限；API 28 及以下需要
            // WRITE_EXTERNAL_STORAGE（清单里已按 maxSdkVersion=28 声明，
            // 调用前由 Dart 侧申请）。
            val relative = if (subDir.isEmpty()) fileName else "$subDir/$fileName"
            setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, relative)

            headers.forEach { (key, value) -> addRequestHeader(key, value) }
        }

        val id = manager.enqueue(request)
        return mapOf(
            "id" to id,
            "fileName" to fileName,
            "subDir" to subDir,
            "relativePath" to if (subDir.isEmpty()) fileName else "$subDir/$fileName",
            "url" to url,
            "mimeType" to mime,
        )
    }

    // --------------------------------------------------------------- query

    private fun query(call: MethodCall): Map<String, Any?> {
        val id = call.argument<Number>("id")?.toLong() ?: return mapOf("found" to false)

        val cursor = manager.query(DownloadManager.Query().setFilterById(id))
            ?: return mapOf("id" to id, "found" to false)
        cursor.use {
            if (!it.moveToFirst()) return mapOf("id" to id, "found" to false)

            val status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val downloaded =
                it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            val total =
                it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            val reason = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
            val localUri =
                it.getString(it.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI)).orEmpty()
            val mediaType =
                it.getString(it.getColumnIndexOrThrow(DownloadManager.COLUMN_MEDIA_TYPE)).orEmpty()

            return mapOf(
                "id" to id,
                "found" to true,
                "status" to statusName(status),
                "bytesReceived" to downloaded,
                "bytesTotal" to total,
                "reason" to reason,
                "reasonText" to reasonText(status, reason),
                "localUri" to localUri,
                "mimeType" to mediaType,
            )
        }
    }

    private fun statusName(status: Int): String = when (status) {
        DownloadManager.STATUS_PENDING -> "pending"
        DownloadManager.STATUS_RUNNING -> "running"
        DownloadManager.STATUS_PAUSED -> "paused"
        DownloadManager.STATUS_SUCCESSFUL -> "success"
        DownloadManager.STATUS_FAILED -> "failed"
        else -> "unknown"
    }

    /**
     * 失败原因的**人话**版本。
     *
     * DownloadManager 只给一个 int，直接丢给用户等于什么都没说；
     * 这里把最常见的几种翻成中文，剩下的原样带上编号方便排障。
     */
    private fun reasonText(status: Int, reason: Int): String {
        if (status == DownloadManager.STATUS_FAILED) {
            return when (reason) {
                DownloadManager.ERROR_CANNOT_RESUME -> "无法续传（服务端不支持 Range 或文件已变化）"
                DownloadManager.ERROR_DEVICE_NOT_FOUND -> "存储设备不可用"
                DownloadManager.ERROR_FILE_ALREADY_EXISTS -> "同名文件已存在"
                DownloadManager.ERROR_FILE_ERROR -> "写入文件失败"
                DownloadManager.ERROR_HTTP_DATA_ERROR -> "网络数据错误"
                DownloadManager.ERROR_INSUFFICIENT_SPACE -> "存储空间不足"
                DownloadManager.ERROR_TOO_MANY_REDIRECTS -> "重定向次数过多"
                DownloadManager.ERROR_UNHANDLED_HTTP_CODE -> "服务端返回了无法处理的 HTTP 状态码"
                DownloadManager.ERROR_UNKNOWN -> "未知错误"
                else -> "失败（原因码 $reason）"
            }
        }
        if (status == DownloadManager.STATUS_PAUSED) {
            return when (reason) {
                DownloadManager.PAUSED_WAITING_TO_RETRY -> "等待重试"
                DownloadManager.PAUSED_WAITING_FOR_NETWORK -> "等待网络"
                DownloadManager.PAUSED_QUEUED_FOR_WIFI -> "排队等待 Wi-Fi"
                DownloadManager.PAUSED_UNKNOWN -> "已暂停"
                else -> "暂停（原因码 $reason）"
            }
        }
        return ""
    }

    // -------------------------------------------------------------- remove

    private fun remove(call: MethodCall): Boolean {
        val id = call.argument<Number>("id")?.toLong() ?: return false
        // remove() 会连同文件一起删掉 —— 这正是「删除下载」的语义
        return try {
            manager.remove(id) > 0
        } catch (e: Exception) {
            // 记录已失效（例如重装后 id 不复存在）：当成已删除，别让界面卡在旧条目上
            false
        }
    }

    // ---------------------------------------------------------------- open

    private fun open(call: MethodCall): Boolean {
        val id = call.argument<Number>("id")?.toLong() ?: return false
        return try {
            val uri = manager.getUriForDownloadedFile(id) ?: return false
            val mime = queryMime(id)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, if (mime.isEmpty()) "*/*" else mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: Exception) {
            false
        }
    }

    private fun queryMime(id: Long): String {
        return try {
            val cursor = manager.query(DownloadManager.Query().setFilterById(id)) ?: return ""
            cursor.use {
                if (!it.moveToFirst()) return ""
                it.getString(it.getColumnIndexOrThrow(DownloadManager.COLUMN_MEDIA_TYPE)).orEmpty()
            }
        } catch (e: Exception) {
            ""
        }
    }

    /** 打开系统的「下载」界面（部分 ROM 没有这个 Activity，返回 false 由 Dart 侧提示）。 */
    private fun openDirectory(): Boolean {
        return try {
            val intent = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    // ---------------------------------------------------------------- info

    /**
     * 下载目录信息。
     *
     * 注意 `writable` 只是「当前进程能不能直接写这个目录」的提示：
     * API 29+ 上它几乎总是 false，但那**不影响**下载，因为落盘是
     * DownloadManager 干的（见类注释）。
     */
    private fun info(): Map<String, Any?> {
        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        return mapOf(
            "directory" to dir.absolutePath,
            "display" to "Download",
            "exists" to dir.exists(),
            "writable" to (dir.exists() && dir.canWrite()),
        )
    }

    // ------------------------------------------------------------ helpers

    /**
     * 清洗文件名。
     *
     * DownloadManager 的 setDestinationInExternalPublicDir 会拒绝含 `/` 的名字；
     * 而文件名来自服务端（Content-Disposition）或网页，属于**不可信输入**，
     * 所以这里把路径分隔符、控制字符、`..` 全部挡掉，并截断到安全长度。
     */
    private fun sanitizeName(raw: String, fallback: String): String {
        var name = raw.trim()
            .replace('\\', '_')
            .replace('/', '_')
            .replace(Regex("[\\x00-\\x1F\\x7F]"), "")
            .trim()
        // 以点开头（.bashrc / ..）一律去掉前导点：下载目录里的隐藏文件对用户是透明的
        name = name.trimStart('.')
        if (name.isEmpty() || name == "_") name = fallback
        if (name.length > MAX_NAME_LENGTH) {
            val dot = name.lastIndexOf('.')
            val ext = if (dot in 1..10) name.substring(dot) else ""
            name = name.take(MAX_NAME_LENGTH - ext.length) + ext
        }
        return name
    }

    /** 清洗子目录：只允许一层或多层相对路径，拒绝绝对路径与 `..` */
    private fun sanitizeSubDir(raw: String): String {
        val parts = raw.trim().replace('\\', '/').split('/')
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != "." }
        if (parts.any { it == ".." || it.length > MAX_NAME_LENGTH }) return ""
        return parts.joinToString("/")
    }
}
