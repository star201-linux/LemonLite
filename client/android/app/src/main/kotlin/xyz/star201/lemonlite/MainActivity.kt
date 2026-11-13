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

/**
 * 宿主 Activity：承载 Flutter 引擎，并暴露 `lemonlite/native` 通道。
 *
 * 为什么是 `open`：MiniappTaskActivity（小程序独立窗口）直接继承它，
 * 这样 `lemonlite/native` 通道的所有能力在两个 Activity 里是同一份实现，
 * 不会出现「宿主能用、窗口里用不了」的漂移。
 *
 * 为什么这些能力做在 MainActivity 而不是做成一个独立 Flutter Plugin：
 * 亮度、常亮、屏幕方向都是**窗口级**状态，必须拿到当前 Activity 的 Window 才能改。
 * 做成插件就得走 ActivityAware 生命周期、再让插件反向持有 Activity，凭空多出一层
 * 「attach/detach 时序」状态；而宿主只有这一个 Activity，直接放在这里最省事、最少状态。
 */
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

    /**
     * 下载桥。
     *
     * 单独一个类而不是继续堆在 MainActivity 里：下载与窗口级能力（亮度/方向）
     * 没有任何共享状态，分开之后 MainActivity 只负责「注册」，逻辑各归各的。
     * 这里持一下引用是为了让生命周期跟 Activity 对齐（通道本身也会持有它）。
     */
    private var downloadBridge: DownloadBridge? = null

    /** 蓝牙 / NFC 原生桥。与下载桥同理：各自一个通道，生命周期跟 Activity 对齐。 */
    private var bluetoothBridge: BluetoothBridge? = null
    private var nfcBridge: NfcBridge? = null

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

    /**
     * 「最近任务」卡片的默认样子（轻柠的图标 + 名字）。
     *
     * 懒计算：只有真的改过卡片（用户打开过小程序）才需要它来恢复，
     * 冷启动路径上不该为此多画一次图标。
     */
    private var defaultTaskDescription: ActivityManager.TaskDescription? = null

    /**
     * 上一次真正写给系统的 `label|icon` 组合。
     *
     * 小程序 setTitle 可能逐字改标题（比如做打字机效果），每次都跨 Binder 传
     * 一个 Bitmap 属于纯浪费；内容没变就直接返回。
     */
    private var appliedTaskKey: String? = null

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
        BluetoothBridge(this).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
            bluetoothBridge = it
        }
        NfcBridge(this).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
            nfcBridge = it
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

            // 小程序切到前台：把「最近任务」里的卡片换成**它的**图标和名字，
            // 而不是晃着一个「轻柠」让用户以为自己回到了宿主。
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

            // 只对窗口 Activity 生效：结束这张任务卡（宿主调它什么也不做，
            // 否则一次误调就把整个 App 关了）。
            "finishTask" -> {
                if (!isTaskWindow) {
                    result.success(false)
                } else {
                    result.success(true)
                    finishAndRemoveTask()
                }
            }

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

    /**
     * 把「最近任务」里的卡片改成 [label] + [iconPath] 指向的图标。
     *
     * 为什么需要这个：整个宿主只有一个 Activity、一个任务。用户打开小程序后
     * 按 Home 键，最近任务里原本只有一个写着「轻柠」的卡片 —— 他再点回来时
     * 根本分不清那是宿主还是刚才那个小程序，也和「小程序像独立应用」的预期不符。
     * TaskDescription 正好是系统给的、唯一的「这张卡叫什么、长什么样」的入口。
     *
     * @param iconPath 本地图片绝对路径（图标缓存里那张）；为空表示没有图标，
     *   此时用宿主自己的图标兜底，而不是留一个空白方块。
     */
    @Suppress("DEPRECATION")
    protected fun applyTaskDescription(label: String, iconPath: String?): Boolean {
        // 标题是给用户看的一行字：去掉首尾空白，并且限长。
        // 超长标题在最近任务里会被截断成一串省略号，不如我们自己收口。
        val title = label.trim().take(40).ifBlank { defaultLabel() }
        val path = iconPath?.takeIf { it.isNotBlank() }
        val key = "$title|${path ?: ""}"
        if (key == appliedTaskKey) return true

        val icon = path?.let { decodeTaskIcon(it) } ?: appIconBitmap()
        return try {
            setTaskDescription(ActivityManager.TaskDescription(title, icon))
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

    /**
     * 把小程序作为独立任务打开。
     *
     * 为什么不是「在宿主里再叠一层」：那样最近任务里只有一张卡，
     * 要么写着「轻柠」（用户看不出这是哪个小程序），要么被改名成小程序
     * （宿主那张卡就没了）。用户要的是「宿主一张卡、小程序一张卡」——
     * 也就是微信小程序的做法：两个任务在切换器里并存，各自独立切换。
     *
     * 实现上只有一条路：**另一个 Activity 实例**。Flutter 的一个引擎只能
     * 对应一个 View，所以新窗口会创建自己的引擎（独立 isolate），
     * 从已安装包重新加载那个小程序 —— 两边的运行状态互不干扰，
     * 这也正是「独立窗口」应有的语义。
     *
     * `data` 用 `lemonlite://miniapp/<appId>`，配 manifest 里的
     * `documentLaunchMode="intoExisting"`：同一个 appId 再次打开时
     * 系统会把**已有那张卡**提到前台，而不是越开越多。
     */
    private fun openMiniappWindow(appId: String, title: String, iconPath: String?): Boolean {
        if (appId.isBlank()) return false
        return try {
            val intent =
                Intent(this, MiniappTaskActivity::class.java).apply {
                    // 文档标识：同一个小程序 = 同一份文档 = 复用同一个任务
                    data = Uri.parse("lemonlite://miniapp/${Uri.encode(appId)}")
                    putExtra(MiniappTaskActivity.EXTRA_APP_ID, appId)
                    putExtra(MiniappTaskActivity.EXTRA_TITLE, title)
                    putExtra(MiniappTaskActivity.EXTRA_ICON, iconPath)
                    // NEW_DOCUMENT 才会新开任务；MULTIPLE_TASK 会绕过
                    // intoExisting（每次都新开），所以这里**不能**加。
                    addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
                }
            startActivity(intent)
            true
        } catch (e: Throwable) {
            android.util.Log.w("LemonLite", "打开小程序窗口失败：$appId", e)
            false
        }
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
