package xyz.star201.lemonlite

import android.Manifest
import android.app.ActivityManager
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.media.AudioManager
import android.net.Uri
import android.provider.Settings
import java.io.File
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/** 宿主 Activity：承载 Flutter 引擎，并提供 `lemonlite/native` 通道。 */
open class MainActivity : FlutterActivity() {

    private companion object {
        /** 与 Dart 侧 NativeBridge.channel 逐字一致，改一端必须改另一端。 */
        const val CHANNEL_NAME = "lemonlite/native"

        /** WindowManager 约定的「不覆盖系统亮度」值，窗口亮度读出来是它时表示跟随系统。 */
        const val FOLLOW_SYSTEM_BRIGHTNESS = -1.0

        /** 方向参数字面量；Dart 侧 MiniappOrientation.auto 对应它。 */
        const val ORIENTATION_AUTO = "auto"

        /** 读不到系统亮度设置时的兜底档位（Android 默认值，128/255 ≈ 50%）。 */
        const val DEFAULT_SYSTEM_BRIGHTNESS = 128

        /** requestRuntimePermissions 的请求码，onRequestPermissionsResult 里要按它比对。 */
        const val RUNTIME_PERMISSION_REQUEST = 0x4C4D

        /**
         * 「最近任务」卡片图标的边长上限（像素）。
         *
         * TaskDescription 要跨 Binder 传一个 Bitmap，太大不但慢，还可能撞上
         * 1MB 的事务上限直接抛 TransactionTooLargeException。192px 在 3x 屏幕上
         * 也有 576 物理像素，够清楚；再大只是浪费。
         */
        const val TASK_ICON_MAX_PX = 192
    }

    /**
     * 当前 Activity 是不是「小程序窗口」（独立任务）。
     *
     * MainActivity 是宿主本体，值为 false；MiniappTaskActivity 覆写成 true。
     * 有些通道方法（finishTask）只对窗口有意义，靠它区分。
     */
    protected open val isTaskWindow: Boolean
        get() = false

    /** 是否因为数据目录锁冲突而启用了独立的 WebView 数据目录（Dart 侧启动时会查询并写日志）。 */
    private var webviewSuffixApplied = false

    private var downloadBridge: DownloadBridge? = null

    /** 蓝牙 / NFC 原生桥。与下载桥同理：各自一个通道，生命周期跟 Activity 对齐。 */
    private var bluetoothBridge: BluetoothBridge? = null
    private var nfcBridge: NfcBridge? = null

    /** 预检用的探针 WebView，[preflightWebView] 的 finally 里销毁。 */
    private var webviewProbe: android.webkit.WebView? = null

    private var pendingPermissionResult: MethodChannel.Result? = null

    private var defaultTaskDescription: ActivityManager.TaskDescription? = null

    private var lastTaskIcon: Bitmap? = null

    /** [lastTaskIcon] 对应的文件路径；路径不变时直接复用已解码的位图。 */
    private var lastTaskIconPath: String? = null

    /** 上一次写进卡片的 `label|icon`，内容没变就跳过。 */
    private var appliedTaskKey: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        preflightWebView()
        super.onCreate(savedInstanceState)
    }

    /**
     * WebView 数据目录锁的**预检**。
     *
     * 背景（crbug.com/558377）：Android 的 WebView 全局只允许一个进程持有
     * 数据目录的锁。如果旧进程还没退出（例如：在应用运行时覆盖安装了新 APK，
     * 某些环境下安装不会立刻杀掉旧进程），新进程创建 WebView 就会抛出
     * "Using WebView from more than one process..."——而且这个异常发生在
     * 平台视图创建的异步路径上，release 包里表现为**纯白屏**，没有任何提示。
     *
     * 做法：在这里**同步**创建一个一次性 WebView，把锁冲突提前到我们能
     * 捕获的地方。冲突时给本进程分配一个独立的 WebView 数据目录
     * （`setDataDirectorySuffix`，API 28+），之后本进程的 WebView 全部
     * 落在那个目录里 —— 旧进程锁的是默认目录，与新目录互不干扰。
     *
     * 代价：冲突发生后，新进程的 cookies / localStorage 是空的（走了一次
     * 换目录）。小程序的 storage **不受影响**（那是 SharedPreferences，
     * 不在 WebView 数据目录里）。正常启动（无冲突）完全不触发，数据照常。
     */
    private fun preflightWebView() {
        try {
            webviewProbe = android.webkit.WebView(this)
        } catch (e: Throwable) {
            val message = e.message ?: ""
            if (message.contains("more than one process")) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    try {
                        // 每个活着的进程一个独立目录；后缀带 pid 保证唯一
                        android.webkit.WebView.setDataDirectorySuffix("pid-" + Process.myPid())
                        webviewSuffixApplied = true
                        android.util.Log.w("LemonLite", "WebView 数据目录锁冲突，已切换到独立数据目录", e)
                    } catch (ignored: Throwable) {
                        android.util.Log.e("LemonLite", "设置 WebView 数据目录后缀失败", ignored)
                    }
                    return
                }
                // API < 28 没有后缀机制：只能把原始异常抛回去（至少 debug 能看到）
                android.util.Log.e("LemonLite", "WebView 锁冲突且系统不支持 setDataDirectorySuffix", e)
                return
            }
            // 不是锁冲突的异常：不属于这里处理，原样抛出
            throw e
        } finally {
            // 无论成功失败，探针都要立刻销毁（它只是用来触发 provider 初始化）
            try {
                webviewProbe?.destroy()
            } catch (ignored: Throwable) {}
            webviewProbe = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val nativeChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        // 下载通道：目标目录是公共「下载」目录，落盘交给系统 DownloadManager。
        DownloadBridge(this).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
            downloadBridge = it
        }
        BluetoothBridge(this).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
            bluetoothBridge = it
        }
        NfcBridge(this).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
            nfcBridge = it
        }

        nativeChannel.setMethodCallHandler { call, result ->
            runOnUiThread {
                try {
                    handleNativeCall(call, result)
                } catch (e: Exception) {
                    result.error("native_error", e.message ?: e.toString(), null)
                }
            }
        }
    }

    /**
     * method 名与 Dart 侧 NativeBridge 里的字面量一一对应，改任一端都要同步另一端。
     * 未知 method 交给 notImplemented()，让 Dart 侧拿到 MissingPluginException 语义。
     */
    private fun handleNativeCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getVolume" -> result.success(readVolume())

            "setVolume" -> {
                // 用 Number 接收：Dart 侧可能传 double(0.5) 也可能传 int(1)，
                // 直接 call.argument<Double>() 遇到 int 会抛 ClassCastException。
                val percent =
                    (call.argument<Number>("percent")?.toDouble() ?: 0.0).coerceIn(0.0, 1.0)
                result.success(writeVolume(percent))
            }

            "getBrightness" -> result.success(readBrightness())

            "setBrightness" -> {
                // 缺参数时按「跟随系统」处理，而不是按 0 处理（0 会把屏幕压到全黑）。
                val value = call.argument<Number>("value")?.toDouble() ?: FOLLOW_SYSTEM_BRIGHTNESS
                result.success(applyWindowBrightness(value))
            }

            "setKeepScreenOn" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                result.success(applyKeepScreenOn(enabled))
            }

            "setOrientation" -> {
                val value = call.argument<String>("value") ?: ORIENTATION_AUTO
                result.success(applyOrientation(value))
            }

            "requestRuntimePermissions" -> {
                val permissions =
                    call.argument<List<String>>("permissions")?.toTypedArray() ?: emptyArray()
                requestRuntimePermissions(permissions, result)
            }

            "openAppSettings" -> result.success(openAppSettings())

            "setTaskDescription" -> {
                val label = call.argument<String>("label") ?: ""
                val iconPath = call.argument<String>("iconPath")
                result.success(applyTaskDescription(label, iconPath))
            }

            // 回到宿主（小程序转后台 / 关闭 / 回主页）：卡片恢复成轻柠自己的样子。
            "resetTaskDescription" -> result.success(resetTaskDescription())

            // 把一个小程序**作为独立任务**打开：新 Activity + 新引擎 + 新的任务卡，
            // 宿主这张卡原样留在切换器里（详见 MiniappTaskActivity）。
            "openMiniappWindow" -> {
                val appId = call.argument<String>("appId") ?: ""
                val title = call.argument<String>("title") ?: appId
                val iconPath = call.argument<String>("iconPath")
                result.success(openMiniappWindow(appId, title, iconPath))
            }

            "finishTask" -> {
                if (!isTaskWindow) {
                    result.success(false)
                } else {
                    result.success(true)
                    if (isTaskRoot()) {
                        finishAndRemoveTask()
                    } else {
                        android.util.Log.w(
                            "LemonLite",
                            "小程序窗口不在独立任务里（taskId=$taskId），只结束自己，保住宿主",
                        )
                        finish()
                    }
                }
            }

            // 启动预检的结果：Dart 侧启动时会查询并写进日志，
            // 这样导出的日志里能看出「这次是走了独立数据目录启动的」。
            "getWebviewPreflight" -> result.success(webviewSuffixApplied)

            "makeReadable" -> {
                val path = call.argument<String>("path") ?: ""
                if (path.isEmpty()) {
                    result.error("bad_args", "makeReadable 需要 path", null)
                } else {
                    val dataDir = File(applicationInfo.dataDir).canonicalPath
                    val target = File(path).canonicalFile
                    if (target.path != dataDir && !target.path.startsWith("$dataDir/")) {
                        result.error("forbidden", "只允许放开本应用的数据目录：$dataDir", null)
                    } else {
                        result.success(relaxPermissions(target))
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    override fun onPause() {
        // 页面切走：停止扫描、取消正在等待的 NFC 读卡（它们都是「此刻才成立」的操作）
        try { bluetoothBridge?.onPause() } catch (_: Throwable) {}
        try { nfcBridge?.onPause() } catch (_: Throwable) {}
        super.onPause()
    }

    override fun onDestroy() {
        try { bluetoothBridge?.onDestroy() } catch (_: Throwable) {}
        try { nfcBridge?.onDestroy() } catch (_: Throwable) {}
        super.onDestroy()
    }

    private fun requestRuntimePermissions(
        permissions: Array<String>,
        result: MethodChannel.Result,
    ) {
        if (permissions.isEmpty()) {
            result.success(true)
            return
        }

        // 蓝牙在 Android 12+ 是 BLUETOOTH_SCAN / CONNECT，11 及以下没有这两个权限，
        // 扫描改由定位权限把关。Dart 侧只写新权限名，版本差异在这里统一抹平。
        val effective = permissions.flatMap { permission ->
            when (permission) {
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        listOf(permission)
                    } else {
                        listOf(Manifest.permission.ACCESS_FINE_LOCATION)
                    }
                else -> listOf(permission)
            }
        }.distinct().toTypedArray()

        // 只保留本应用在清单里声明过的权限：没声明的申请一定会被系统立刻拒绝，
        // 提前过滤掉可以让「是否已授予」的判断更准确。
        val declared =
            effective.filter {
                try {
                    packageManager.getPermissionInfo(it, 0)
                    true
                } catch (e: PackageManager.NameNotFoundException) {
                    false
                }
            }
        if (declared.isEmpty()) {
            result.success(false)
            return
        }

        val missing =
            declared.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }

        // 上一次还没回来：先把旧的按拒绝结掉，绝不让 Dart 那边永远 await
        pendingPermissionResult?.let {
            it.success(false)
            pendingPermissionResult = null
        }
        pendingPermissionResult = result
        requestPermissions(missing.toTypedArray(), RUNTIME_PERMISSION_REQUEST)
    }

    /**
     * 系统授权框的结果。这里只回答「是不是全给了」——
     * 调用方（WebView 的 onPermissionRequest）要么整体放行、要么整体拒绝，
     * 部分授予时回 true 会让 Chromium 以为两项都拿到了。
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != RUNTIME_PERMISSION_REQUEST) return
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        val allGranted =
            grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        result.success(allGranted)
    }

    /** 写入最近任务卡片的标题与图标；`iconPath` 为空表示沿用上一次那张。 */
    @Suppress("DEPRECATION")
    protected fun applyTaskDescription(
        label: String,
        iconPath: String?,
        force: Boolean = false,
    ): Boolean {
        // 标题是给用户看的一行字：去掉首尾空白，并且限长。
        // 超长标题在最近任务里会被截断成一串省略号，不如我们自己收口。
        val title = label.trim().take(40).ifBlank { defaultLabel() }
        val path = iconPath?.takeIf { it.isNotBlank() }
        val key = "$title|${path ?: ""}"
        if (!force && key == appliedTaskKey) return true

        val decoded = when {
            path == null -> null
            path == lastTaskIconPath -> lastTaskIcon
            else -> decodeTaskIcon(path)
        }
        val icon = decoded ?: lastTaskIcon ?: appIconBitmap()
        return try {
            @Suppress("DEPRECATION")
            val description = ActivityManager.TaskDescription(title, icon)
            setTaskDescription(description)
            if (decoded != null) {
                lastTaskIcon = decoded
                lastTaskIconPath = path
            }
            appliedTaskKey = key
            true
        } catch (e: Throwable) {
            // 卡片长什么样是锦上添花：失败也只该影响最近任务的观感，绝不能让应用崩。
            android.util.Log.w("LemonLite", "设置最近任务卡片失败", e)
            false
        }
    }

    /** 恢复成宿主自己的卡片（小程序全部退到后台 / 关闭时调用）。 */
    @Suppress("DEPRECATION")
    private fun resetTaskDescription(): Boolean {
        if (appliedTaskKey == null) return true
        return try {
            setTaskDescription(defaultTaskDescription ?: buildDefaultTaskDescription().also {
                defaultTaskDescription = it
            })
            appliedTaskKey = null
            // 卡片回到宿主了，上一次那张小程序图标就过期了：
            // 不清理的话，之后打开别的小程序、又恰好没图标时会把旧图贴上去。
            lastTaskIcon = null
            lastTaskIconPath = null
            true
        } catch (e: Throwable) {
            android.util.Log.w("LemonLite", "恢复最近任务卡片失败", e)
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun buildDefaultTaskDescription(): ActivityManager.TaskDescription =
        ActivityManager.TaskDescription(defaultLabel(), appIconBitmap())

    private fun defaultLabel(): String =
        try {
            packageManager.getApplicationLabel(applicationInfo).toString()
        } catch (e: Throwable) {
            "LemonLite"
        }

    /**
     * 解码小程序图标，并按 [TASK_ICON_MAX_PX] 缩小。
     *
     * 只接受本应用数据目录内的文件：这个通道虽然只有我们自己会调，但
     * 「随便传一个路径就给读」是没有理由的宽松 —— 和 makeReadable 一样，
     * 把范围钉死在 dataDir 里。
     */
    protected fun decodeTaskIcon(path: String): Bitmap? {
        return try {
            val file = File(path).canonicalFile
            val dataDir = File(applicationInfo.dataDir).canonicalPath
            if (file.path != dataDir && !file.path.startsWith("$dataDir/")) {
                android.util.Log.w("LemonLite", "拒绝读取数据目录之外的图标：$path")
                return null
            }
            if (!file.isFile) return null

            // 先只读尺寸算出采样率，再真正解码：图标可能是 1024px 的大图，
            // 直接整张读进内存再缩，低端机上会有一瞬间的几十 MB 峰值。
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            var sample = 1
            while (
                bounds.outWidth / (sample * 2) >= TASK_ICON_MAX_PX &&
                    bounds.outHeight / (sample * 2) >= TASK_ICON_MAX_PX
            ) {
                sample *= 2
            }
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            BitmapFactory.decodeFile(file.path, options)?.let { scaleDown(it) }
        } catch (e: Throwable) {
            android.util.Log.w("LemonLite", "读取小程序图标失败：$path", e)
            null
        }
    }

    /** 宿主自己的图标（Bitmap 版），作为「小程序没有图标」时的兜底。 */
    private fun appIconBitmap(): Bitmap? {
        return try {
            val drawable = packageManager.getApplicationIcon(packageName)
            val width = drawable.intrinsicWidth.coerceAtLeast(1)
            val height = drawable.intrinsicHeight.coerceAtLeast(1)
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, canvas.width, canvas.height)
            drawable.draw(canvas)
            scaleDown(bitmap)
        } catch (e: Throwable) {
            null
        }
    }

    private fun scaleDown(source: Bitmap): Bitmap {
        val longest = maxOf(source.width, source.height)
        if (longest <= TASK_ICON_MAX_PX) return source
        val ratio = TASK_ICON_MAX_PX.toFloat() / longest
        val width = (source.width * ratio).toInt().coerceAtLeast(1)
        val height = (source.height * ratio).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(source, width, height, true)
    }

    private fun openMiniappWindow(appId: String, title: String, iconPath: String?): Boolean {
        if (appId.isBlank()) return false
        // 文档标识：同一个小程序 = 同一个 data = 同一张卡
        val documentUri = Uri.parse("lemonlite://miniapp/${Uri.encode(appId)}")

        if (focusExistingWindow(documentUri)) {
            // 已经有这张卡：提到前台即可。标题与图标不在这里重设 ——
            // 窗口自己的 Dart 侧会按当前主题与 metadata 再刷一次，
            // 宿主这边重设只会和它抢同一张卡的 TaskDescription。
            return true
        }

        return try {
            val intent =
                Intent(this, MiniappTaskActivity::class.java).apply {
                    data = documentUri
                    putExtra(MiniappTaskActivity.EXTRA_APP_ID, appId)
                    putExtra(MiniappTaskActivity.EXTRA_TITLE, title)
                    putExtra(MiniappTaskActivity.EXTRA_ICON, iconPath)
                    // MULTIPLE_TASK 保证新任务；NEW_TASK 是它的前提条件。
                    // 两个都是 API 1 就有的行为，不依赖任何厂商扩展。
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
                }
            startActivity(intent)
            true
        } catch (e: Throwable) {
            android.util.Log.w("LemonLite", "打开小程序窗口失败：$appId", e)
            false
        }
    }

    private fun focusExistingWindow(documentUri: Uri): Boolean {
        return try {
            val manager = getSystemService(ActivityManager::class.java) ?: return false
            val existing =
                manager.appTasks.firstOrNull { task ->
                    val base = task.taskInfo.baseIntent
                    base != null &&
                        base.component?.className == MiniappTaskActivity::class.java.name &&
                        base.data == documentUri
                } ?: return false
            existing.moveToFront()
            true
        } catch (e: Throwable) {
            android.util.Log.w("LemonLite", "复用已有小程序任务失败：$documentUri", e)
            false
        }
    }

    private fun openAppSettings(): Boolean {
        return try {
            val intent =
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", packageName, null)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun relaxPermissions(file: File): Int {
        file.setReadable(true, false)
        if (file.isDirectory) {
            file.setExecutable(true, false)
            var count = 1
            file.listFiles()?.forEach { count += relaxPermissions(it) }
            return count
        }
        return 1
    }

    /** 读媒体音量：level 是当前档位，max 是最大档位，percent 由两端都算得出来（这里算好给 Dart 直接用）。 */
    private fun readVolume(): Map<String, Any> {
        val audio = audioManager()
        val level = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        return mapOf(
            "level" to level,
            "max" to max,
            "percent" to if (max > 0) level.toDouble() / max else 0.0,
        )
    }

    private fun writeVolume(percent: Double): Map<String, Any> {
        val audio = audioManager()
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val target = (percent * max).roundToInt().coerceIn(0, max)
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
        // 回读一次真实结果：原生可能因音量策略（勿扰/固定音量设备）没按我们算的值生效，
        // 返回回读快照比返回入参更可信。
        return readVolume()
    }

    private fun audioManager(): AudioManager = getSystemService(AudioManager::class.java)

    /**
     * 读亮度。window 是当前窗口亮度，没设置过时系统给的就是 -1（跟随系统），原样返回，
     * 让 Dart 侧能区分「跟随系统」和「真的是 0（最暗）」。
     * system 是系统亮度，读 Settings.System 同样不需要任何权限（只有**写**才需要）。
     */
    private fun readBrightness(): Map<String, Any> {
        val windowBrightness = window.attributes.screenBrightness.toDouble()
        val systemBrightness =
            Settings.System.getInt(
                contentResolver,
                Settings.System.SCREEN_BRIGHTNESS,
                DEFAULT_SYSTEM_BRIGHTNESS,
            ) / 255.0
        return mapOf(
            "window" to windowBrightness,
            "system" to systemBrightness,
        )
    }

    /**
     * 只改**窗口亮度**，刻意不去写 Settings.System，理由有两条：
     *   1. 写系统亮度需要 WRITE_SETTINGS 特殊权限（要让用户去系统设置里手动授权），
     *      而窗口亮度只要 Activity 自己的 Window 就能改，零权限、零授权弹窗；
     *   2. 窗口亮度只影响本 App：用户退出小程序回到桌面时系统亮度原样不变，
     *      不会出现「调暗了小程序，桌面也跟着变暗」这种宿主改坏系统设置的体验。
     * value < 0（含 Dart 侧约定的 -1）表示恢复跟随系统。
     */
    private fun applyWindowBrightness(value: Double): Boolean {
        val attrs = window.attributes
        attrs.screenBrightness =
            if (value < 0) {
                WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            } else {
                value.coerceIn(0.0, 1.0).toFloat()
            }
        window.attributes = attrs
        return true
    }

    /**
     * FLAG_KEEP_SCREEN_ON 是窗口级标记，由 WindowManager 直接管，**不需要 WAKE_LOCK 权限**，
     * 也不会漏电：它只在当前窗口可见时生效，切到后台/锁屏后由系统自动失效。
     * clearFlags 用来恢复系统默认的熄屏行为。
     */
    private fun applyKeepScreenOn(enabled: Boolean): Boolean {
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        return true
    }

    /**
     * 直接改 Activity 的 requestedOrientation，交给系统去转屏。
     * auto → SCREEN_ORIENTATION_UNSPECIFIED，恢复「跟随系统设置/传感器」的默认行为。
     *
     * 不动 AndroidManifest 的 screenOrientation：那是静态默认值、装了包就定死，
     * 而小程序要的是运行期来回切，只有 requestedOrientation 能做到。
     * 清单里已声明 configChanges="orientation|screenSize"，所以转屏不会重建 Activity，
     * Flutter 侧的 WebView / 页面状态不会被重置。
     */
    private fun applyOrientation(value: String): Boolean {
        requestedOrientation =
            when (value) {
                "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                "landscape" -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                "portraitReverse" -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                "landscapeReverse" -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                // auto：恢复跟随系统（Dart 侧 MiniappOrientation.auto）
                ORIENTATION_AUTO -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                // 未知值同样回落到跟随系统：宁可跟随系统，也不要卡在某个奇怪的方向上
                else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            }
        return true
    }
}
