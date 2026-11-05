package xyz.star201.lemonlite

import android.app.Activity
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable
import android.os.Handler
import android.os.Looper
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors

/**
 * NFC 原生桥（Reader Mode）。
 *
 * 为什么用 Reader Mode 而不是前台调度（enableForegroundDispatch）：
 *   Reader Mode 专门为「应用在前台读卡」设计，能指定只关心哪些技术，
 *   并且可以在没有 Activity 的 Intent 过滤的情况下工作；它也不会让系统
 *   弹出「用哪个应用打开」的选择器。对小程序这种「我现在想读一张卡」的
 *   语义来说，它是唯一的正确模型。
 *
 * 一次调用只等一张卡：read()/writeText() 返回时 Reader Mode 自动关闭，
 * 不会出现「页面退出了还在监听」的泄漏。超时 / 取消由 Handler 兜底。
 *
 * NFC 是安装期权限（normal），不需要运行时授权；但应用内的权限弹窗仍然
 * 由 Dart 层在调用前负责 —— 这一层只处理「设备有没有 NFC、开没开」。
 */
class NfcBridge(private val activity: Activity) {

    companion object {
        /** 与 Dart 侧 NfcBridge.channel 逐字一致。 */
        const val CHANNEL_NAME = "lemonlite/nfc"

        private val URI_PREFIXES = arrayOf(
            "", "http://www.", "https://www.", "http://", "https://", "tel:",
            "mailto:", "ftp://anonymous:anonymous@", "ftp://ftp.", "ftps://",
            "sftp://", "smb://", "nfs://", "ftp://", "dav://", "news:",
            "telnet://", "imap:", "rtsp://", "urn:", "pop:", "sip:", "sips:",
            "tftp:", "btspp://", "btl2cap://", "btgoep://", "tcpobex://",
            "irdaobex://", "file://", "urn:epc:id:", "urn:epc:tag:",
            "urn:epc:pat:", "urn:epc:raw:", "urn:epc:", "urn:nfc:",
        )
    }

    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null

    private var pending: Pending? = null

    private val adapter: NfcAdapter?
        get() = NfcAdapter.getDefaultAdapter(activity)

    private val readerCallback = NfcAdapter.ReaderCallback { tag ->
        // ReaderCallback 在 binder 线程；所有状态都只在主线程改
        activity.runOnUiThread { onTag(tag) }
    }

    fun attach(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, CHANNEL_NAME)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            activity.runOnUiThread { handle(call, result) }
        }
    }

    fun onPause() {
        val current = pending ?: return
        pending = null
        current.timeout?.let { handler.removeCallbacks(it) }
        disableReaderMode()
        current.result.error("cancelled", "页面已离开，NFC 读取已取消", null)
    }

    fun onDestroy() {
        onPause()
        executor.shutdownNow()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // ---------------------------------------------------------------- 分发

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(statusMap())
                "read" -> start(
                    mode = Mode.READ,
                    text = "",
                    timeoutMs = call.argument<Number>("timeoutMs")?.toInt() ?: 15000,
                    formatIfNeeded = true,
                    result = result,
                )
                "writeText" -> start(
                    mode = Mode.WRITE,
                    text = call.argument<String>("text") ?: "",
                    timeoutMs = call.argument<Number>("timeoutMs")?.toInt() ?: 15000,
                    formatIfNeeded = call.argument<Boolean>("formatIfNeeded") ?: true,
                    result = result,
                )
                "cancel" -> cancel(result)
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            result.error("permission_denied", "缺少 NFC 权限：${e.message}", null)
        } catch (e: Exception) {
            result.error("native_error", e.message ?: e.toString(), null)
        }
    }

    private fun statusMap(): Map<String, Any> {
        val a = adapter
        return mapOf(
            "supported" to (a != null),
            "enabled" to (a?.isEnabled == true),
        )
    }

    // ------------------------------------------------------------ 读 / 写

    private fun start(
        mode: Mode,
        text: String,
        timeoutMs: Int,
        formatIfNeeded: Boolean,
        result: MethodChannel.Result,
    ) {
        val a = adapter
        if (a == null) {
            result.error("unsupported", "这台设备不支持 NFC", null)
            return
        }
        if (!a.isEnabled) {
            result.error("disabled", "NFC 未打开，请到系统设置里打开", null)
            return
        }
        if (mode == Mode.WRITE && text.isBlank()) {
            result.error("bad_args", "写入内容不能为空", null)
            return
        }
        if (pending != null) {
            result.error("busy", "上一次读卡 / 写卡还没结束", null)
            return
        }

        val timeout = Runnable {
            val current = pending ?: return@Runnable
            pending = null
            disableReaderMode()
            current.result.error("timeout", "等待 NFC 标签超时", null)
        }

        pending = Pending(mode, text, formatIfNeeded, result, timeout)
        try {
            a.enableReaderMode(activity, readerCallback, readerFlags(), null)
        } catch (e: Exception) {
            pending = null
            result.error("native_error", "无法开启 NFC 读卡：${e.message}", null)
            return
        }
        handler.postDelayed(timeout, timeoutMs.coerceIn(2000, 60000).toLong())
    }

    private fun cancel(result: MethodChannel.Result) {
        val current = pending
        if (current == null) {
            result.success(mapOf("cancelled" to false))
            return
        }
        pending = null
        current.timeout?.let { handler.removeCallbacks(it) }
        disableReaderMode()
        current.result.error("cancelled", "NFC 操作已取消", null)
        result.success(mapOf("cancelled" to true))
    }

    private fun onTag(tag: Tag) {
        val current = pending ?: return
        pending = null
        current.timeout?.let { handler.removeCallbacks(it) }
        disableReaderMode()

        if (current.mode == Mode.READ) {
            try {
                val data = tagMap(tag)
                current.result.success(data)
            } catch (e: Exception) {
                current.result.error("read_failed", "读取标签失败：${e.message}", null)
            }
            return
        }

        // 写入是阻塞 I/O，不能放在主线程
        executor.execute {
            try {
                val data = writeTextToTag(tag, current.text, current.formatIfNeeded)
                activity.runOnUiThread { current.result.success(data) }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    current.result.error("write_failed", e.message ?: "写入失败", null)
                }
            }
        }
    }

    private fun writeTextToTag(tag: Tag, text: String, formatIfNeeded: Boolean): Map<String, Any?> {
        val record = NdefRecord.createTextRecord("en", text)
        val message = NdefMessage(arrayOf(record))

        val ndef = try {
            Ndef.get(tag)
        } catch (_: Exception) {
            null
        }
        if (ndef != null) {
            if (!ndef.isWritable) throw IOException("这张标签是只读的")
            ndef.connect()
            try {
                ndef.writeNdefMessage(message)
            } finally {
                try { ndef.close() } catch (_: Exception) {}
            }
        } else {
            if (!formatIfNeeded) throw IOException("这张标签还没有格式化")
            val formatable = try {
                NdefFormatable.get(tag)
            } catch (_: Exception) {
                null
            } ?: throw IOException("这张标签不支持 NDEF 写入")
            formatable.connect()
            try {
                formatable.format(message)
            } finally {
                try { formatable.close() } catch (_: Exception) {}
            }
        }

        return tagMap(tag) + mapOf("written" to true)
    }

    // -------------------------------------------------------------- 标签解析

    private fun tagMap(tag: Tag): Map<String, Any?> {
        val uid = tag.id?.joinToString("") { String.format("%02x", it) } ?: ""
        val tech = tag.techList?.map { it.substringAfterLast('.') } ?: emptyList<String>()

        val ndef = try {
            Ndef.get(tag)
        } catch (_: Exception) {
            null
        }
        val message = try {
            ndef?.cachedNdefMessage
        } catch (_: Exception) {
            null
        }

        val records = message?.records?.map { record ->
            mapOf<String, Any?>(
                "tnf" to record.tnf,
                "type" to String(record.type ?: ByteArray(0), Charsets.UTF_8),
                "payload" to Base64.encodeToString(record.payload ?: ByteArray(0), Base64.NO_WRAP),
                "text" to textOf(record),
                "uri" to uriOf(record),
            )
        } ?: emptyList<Map<String, Any?>>()

        val formatable = try {
            NdefFormatable.get(tag)
        } catch (_: Exception) {
            null
        }

        return mapOf(
            "id" to uid,
            "techList" to tech,
            "ndefSupported" to (ndef != null),
            "writable" to (ndef?.isWritable == true),
            "formatable" to (formatable != null),
            "maxSize" to (ndef?.maxSize ?: 0),
            "records" to records,
        )
    }

    private fun textOf(record: NdefRecord): String? {
        if (record.tnf != NdefRecord.TNF_WELL_KNOWN) return null
        if (record.type == null || !record.type.contentEquals(NdefRecord.RTD_TEXT)) return null
        val payload = record.payload ?: return null
        if (payload.isEmpty()) return ""
        val status = payload[0].toInt() and 0xFF
        val languageLength = status and 0x3F
        val encoding = if ((status and 0x80) != 0) Charsets.UTF_16 else Charsets.UTF_8
        val start = 1 + languageLength
        if (start > payload.size) return ""
        return String(payload, start, payload.size - start, encoding)
    }

    private fun uriOf(record: NdefRecord): String? {
        if (record.tnf != NdefRecord.TNF_WELL_KNOWN) return null
        if (record.type == null || !record.type.contentEquals(NdefRecord.RTD_URI)) return null
        val payload = record.payload ?: return null
        if (payload.isEmpty()) return null
        val code = payload[0].toInt() and 0xFF
        val prefix = URI_PREFIXES.getOrElse(code) { "" }
        val rest = String(payload, 1, payload.size - 1, Charsets.UTF_8)
        return prefix + rest
    }

    // ------------------------------------------------------------------ 工具

    private fun readerFlags(): Int =
        NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or
            NfcAdapter.FLAG_READER_NFC_V

    private fun disableReaderMode() {
        try {
            adapter?.disableReaderMode(activity)
        } catch (_: Exception) {
            // 没有开启过 / Activity 已销毁：忽略
        }
    }

    private enum class Mode { READ, WRITE }

    private data class Pending(
        val mode: Mode,
        val text: String,
        val formatIfNeeded: Boolean,
        val result: MethodChannel.Result,
        val timeout: Runnable?,
    )
}
