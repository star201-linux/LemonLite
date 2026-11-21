package xyz.star201.lemonlite

import android.content.Intent
import android.net.Uri
import android.os.Bundle

/**
 * 小程序**独立窗口**：一个 Activity = 一张独立的任务卡。
 *
 * 为什么需要它：
 *   宿主的全部小程序原本都跑在 MainActivity 这一个任务里。那样在系统
 *   「最近任务」里永远只有一张卡 —— 要么叫「轻柠」（用户看不出是哪个
 *   小程序），要么被 TaskDescription 改名成小程序（宿主那张卡就消失了）。
 *   微信小程序不是这么做的：微信一张卡、小程序一张卡，两张卡在切换器里
 *   并存，各自切换。要做到这一点，只能再起一个 Activity —— 而且是
 *   **另一个任务**（`FLAG_ACTIVITY_NEW_DOCUMENT` + `documentLaunchMode`）。
 *
 * 「另一个任务」这件事在清单里还补了一道保险：本 Activity 显式声明了独立的
 *   `taskAffinity`（宿主那条是空字符串）。只靠 NEW_DOCUMENT 不够 —— 部分 ROM
 *   不认这个 flag，会把窗口塞进宿主任务栈，表现就是「打开小程序后主应用没了」。
 *   独立 affinity 让系统按 affinity 分任务，绕开对 flag 的实现差异。
 *
 * 为什么直接继承 MainActivity 而不是再写一个 FlutterActivity：
 *   `lemonlite/native` 那条通道（亮度 / 方向 / 常亮 / 运行时权限 / 下载 /
 *   蓝牙 / NFC / 任务卡片）全部注册在 MainActivity.configureFlutterEngine 里。
 *   继承之后，新窗口**自动**拿到同一套能力，两端只有 `getInitialRoute` 与
 *   `onCreate` 两处差异；将来通道加方法也不用改两遍（少一处漂移的机会）。
 *
 * 引擎：这里没有覆盖 provideFlutterEngine，走 FlutterActivity 的默认路径 ——
 *   每个窗口一个新引擎、Activity 销毁时一并销毁。之所以不复用宿主的引擎：
 *   Flutter 的一个引擎只能挂一个 FlutterView，两个窗口没法共享同一个引擎；
 *   而两个引擎（两个 isolate）意味着两边的 `MiniappHost` 互不可见 ——
 *   这正是「独立窗口」的语义：窗口里的小程序是一份独立运行的状态。
 *
 * 代价（如实写在 README 里）：一个窗口约多占 20~40MB（一个 Flutter 引擎 +
 *   一个 WebView），且从小程序窗口切回宿主时，宿主不会知道窗口里的页面在做什么。
 *   换来的是「像独立应用一样被系统管理」：可以从切换器直接回去、可以单独划掉。
 */
class MiniappTaskActivity : MainActivity() {

    companion object {
        /** Intent 里带的三个参数；与 MainActivity.openMiniappWindow 逐字一致。 */
        const val EXTRA_APP_ID = "lemonlite.miniapp.appId"
        const val EXTRA_TITLE = "lemonlite.miniapp.title"
        const val EXTRA_ICON = "lemonlite.miniapp.iconPath"

        /**
         * 初始路由前缀。
         *
         * 用路由而不是再开一条通道传参：Flutter 引擎在创建时就把
         * `initialRoute` 写进 `window.defaultRouteName`，Dart 侧在 `main()`
         * 第一行就能判断「我这次是被当成小程序窗口启动的」，不需要等
         * 通道就绪、也不会和宿主抢启动时序。
         */
        private const val ROUTE_PREFIX = "/miniapp-window"
    }

    private val extraAppId: String
        get() = intent?.getStringExtra(EXTRA_APP_ID)?.trim().orEmpty()

    private val extraTitle: String
        get() = intent?.getStringExtra(EXTRA_TITLE)?.trim().takeUnless { it.isNullOrEmpty() }
            ?: extraAppId

    /** 只对窗口为 true：`finishTask` 通道方法靠它决定要不要真的结束任务。 */
    override val isTaskWindow: Boolean
        get() = true

    /**
     * 让 Dart 侧知道「打开哪个小程序」。
     *
     * 参数放在 query 里而不是路径里：appId 允许带点、连字符之类，
     * 放进路径还要考虑转义与斜杠；`Uri.Builder` 负责编码，Dart 侧
     * `Uri.parse(...).queryParameters` 负责解码，两端都不用自己处理。
     */
    override fun getInitialRoute(): String? {
        val appId = extraAppId
        if (appId.isEmpty()) return null
        return Uri.parse(ROUTE_PREFIX)
            .buildUpon()
            .appendQueryParameter("appId", appId)
            .appendQueryParameter("title", extraTitle)
            .build()
            .toString()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 卡片在 Flutter 第一帧之前就要对：窗口一出现，最近任务里就该是
        // 小程序的名字和图标（Dart 起来之后还会再刷一次，值相同则跳过）。
        //
        // 标题同时写进 Activity（`setTitle`）：部分国产 ROM 的最近任务卡
        // 读的是窗口 / Activity 的 title，而不是 `TaskDescription.label`。
        // 两处都写，覆盖到的机型最多。
        setTitle(extraTitle)
        applyTaskDescription(extraTitle, intent?.getStringExtra(EXTRA_ICON), force = true)
    }

    /**
     * 窗口真正可见之后，再把卡片强写一次。
     *
     * 为什么不在 `onCreate` 里写完就算：vivo 的最近任务会在「窗口进入可见」
     * 那一刻用 `ActivityInfo`（也就是 application 的 label「轻柠」）
     * 重建一次卡片，把 `onCreate` 里写的 TaskDescription 覆盖掉。
     * 用户看到的就是「明明打开了柠檬天气，卡片上还是 Lemon Lite」。
     *
     * 只做一次：之后 Dart 侧的 `setTitle` 才是权威（小程序可以自己改标题），
     * 这里反复写会把用户的操作抢回去。
     */
    override fun onPostResume() {
        super.onPostResume()
        if (cardRewrittenAfterVisible) return
        cardRewrittenAfterVisible = true
        setTitle(extraTitle)
        applyTaskDescription(extraTitle, intent?.getStringExtra(EXTRA_ICON), force = true)
    }

    /** [onPostResume] 的「只强写一次」标记。 */
    private var cardRewrittenAfterVisible = false

    /**
     * 从宿主再点一次同一个小程序时，系统会把已有任务提到前台并走这里。
     *
     * 目前不需要做任何事（页面自己还在，不该被重置），但覆盖一下留下注释：
     * 将来若想「重开一次」或者「带上新参数」，入口就在这里。
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
}
