package xyz.star201.lemonlite

import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
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

/**
 * 宿主 Activity：承载 Flutter 引擎，并暴露 `lemonlite/native` 通道。
 *
 * 为什么这些能力做在 MainActivity 而不是做成一个独立 Flutter Plugin：
 * 亮度、常亮、屏幕方向都是**窗口级**状态，必须拿到当前 Activity 的 Window 才能改。
 * 做成插件就得走 ActivityAware 生命周期、再让插件反向持有 Activity，凭空多出一层
 * 「attach/detach 时序」状态；而宿主只有这一个 Activity，直接放在这里最省事、最少状态。
 */
class MainActivity : FlutterActivity() {

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
    }

    /** 是否因为数据目录锁冲突而启用了独立的 WebView 数据目录（Dart 侧启动时会查询并写日志）。 */
    private var webviewSuffixApplied = false

    /**
     * 下载桥。
     *
     * 单独一个类而不是继续堆在 MainActivity 里：下载与窗口级能力（亮度/方向）
     * 没有任何共享状态，分开之后 MainActivity 只负责「注册」，逻辑各归各的。
     * 这里持一下引用是为了让生命周期跟 Activity 对齐（通道本身也会持有它）。
     */
    private var downloadBridge: DownloadBridge? = null

    /** 预检用的探针 WebView，[preflightWebView] 的 finally 里销毁。 */
    private var webviewProbe: android.webkit.WebView? = null

    /**
     * 正在等待系统授权框返回的 Dart 回调。
     *
     * 为什么要有这个字段：Android 的运行时授权是**异步 + 回调**模型
     *（ActivityCompat.requestPermissions 只负责弹框，结果从 onRequestPermissionsResult 回来），
     * 而 MethodChannel 的 result 必须恰好被回一次。于是先把 result 存下来，
     * 等系统回调到达时再回 —— 这样 Dart 侧看到的仍是一个普通的 await。
     *
     * 同时只能有一个：用户不可能同时看到两个系统授权框，
     * 若真的并发来了第二次请求，直接把旧的按「拒绝」结掉，避免泄漏。
     */
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // 必须放在 super.onCreate 之前：configureFlutterEngine 会触发插件初始化，
        // 任何 WebView 的创建都必须等预检做完。
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
        // 插件注册：交回给 super。
        //
        // FlutterActivity.configureFlutterEngine() 的实现就是调用
        // GeneratedPluginRegister.registerGeneratedPlugins()（已用 javap 核对 Flutter 3.47.7
        // 的 android-arm64-release/flutter.jar），所以 super 已经完成了注册。
        // 这里**不要**再自己调一次 GeneratedPluginRegistrant.registerWith()：
        // 那是同一个入口，写两遍等于把所有插件注册两遍 —— in_appwebview 的
        // platform view factory 重复注册会直接抛异常。用 super 的另一个好处是
        // 将来 Flutter 改默认注册方式时不用跟着改这里。
        super.configureFlutterEngine(flutterEngine)

        val nativeChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        // 下载通道：目标目录是公共「下载」目录，落盘交给系统 DownloadManager。
        DownloadBridge(this).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
            downloadBridge = it
        }

        nativeChannel.setMethodCallHandler { call, result ->
            // 通道回调不保证在主线程，而 screenBrightness / FLAG_KEEP_SCREEN_ON /
            // requestedOrientation 都只能在主线程改；MethodChannel.Result 也要求回到主线程回调。
            // 所以整个处理逻辑统一切到 UI 线程，只切一次，不做「按 method 判断要不要切」的分支。
            runOnUiThread {
                try {
                    handleNativeCall(call, result)
                } catch (e: Exception) {
                    // 任何原生异常都转成错误码回给 Dart，绝不让 Activity 崩掉：
                    // 小程序里一次亮度设置失败不该把整个宿主一起带走。
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

            // 启动预检的结果：Dart 侧启动时会查询并写进日志，
            // 这样导出的日志里能看出「这次是走了独立数据目录启动的」。
            "getWebviewPreflight" -> result.success(webviewSuffixApplied)

            // 自检专用（只在传了 --dart-define=LEMONLITE_AUTOTEST 的包里会被调用）。
            //
            // 为什么需要它：开发机上的 Android 容器（Waydroid）没有 root，
            // adb / logcat / screencap 全部不可用，而应用私有目录是 0700 + 应用 uid，
            // 宿主机读不到 —— 于是"自检到底跑成什么样"这件事没有任何出口。
            // 这个方法把本应用自己的数据目录改成「其它用户可读可进入」，
            // 让宿主机能取走自检日志、权限决定与对话框截图。
            //
            // 作用范围被硬限制在 applicationInfo.dataDir 之内：即便被恶意调用，
            // 也只能放开这个 App 自己的数据；而 Android 的 SELinux 本来就阻止
            // 其它 App 读它，所以在真机上这不会额外泄露给任何第三方应用。
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

    /**
     * 申请 Android 运行时权限，结果通过 [pendingPermissionResult] 异步回给 Dart。
     *
     * 为什么必须由宿主来做：WebView 的 onPermissionRequest 只告诉宿主
     * 「网页想要摄像头」，它**不会**替宿主申请系统权限。Chromium 真正开设备时
     * Android 还会再拦一道，所以顺序必须是「先拿到系统权限，再回 ALLOW」。
     *
     * 已经全部授予时不弹框、立刻回 true（常见于用户之前同意过）。
     */
    private fun requestRuntimePermissions(
        permissions: Array<String>,
        result: MethodChannel.Result,
    ) {
        if (permissions.isEmpty()) {
            result.success(true)
            return
        }

        // 只保留本应用在清单里声明过的权限：没声明的申请一定会被系统立刻拒绝，
        // 提前过滤掉可以让「是否已授予」的判断更准确。
        val declared =
            permissions.filter {
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

    /**
     * 跳到本应用在系统设置里的详情页。
     *
     * 用于「拒绝且不再询问」之后的兜底：那时应用再也弹不出系统框，
     * 只能让用户自己去设置里打开。个别 ROM 没有这个 Activity，此时返回 false。
     */
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

    /**
     * 递归把权限放开到「其它用户可读 + 可进入」。
     * 目录必须同时给 x，否则宿主机连列目录都做不到。
     * 返回处理过的条目数（自检日志里会打出来，便于确认真的生效了）。
     */
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

    /**
     * 设置媒体音量。
     *
     * flags 传 0 而不是 FLAG_SHOW_UI：后者会弹出系统音量条，那是「系统 UI 抢焦点」，
     * 会把小程序自己画的音量面板盖住 —— 我们只需要改数值，不需要系统提示。
     *
     * STREAM_MUSIC 的读写不需要任何运行时权限（新版本 Android 上受限的只是铃声/系统音量流）。
     */
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
