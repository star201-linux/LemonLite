package xyz.star201.lemonlite

import android.content.Intent
import android.net.Uri
import android.os.Bundle

/** 小程序独立窗口：独占一条任务，卡片使用小程序自己的名字与图标。 */
class MiniappTaskActivity : MainActivity() {

    companion object {
        /** Intent 里带的三个参数；与 MainActivity.openMiniappWindow 逐字一致。 */
        const val EXTRA_APP_ID = "lemonlite.miniapp.appId"
        const val EXTRA_TITLE = "lemonlite.miniapp.title"
        const val EXTRA_ICON = "lemonlite.miniapp.iconPath"

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

        setTitle(extraTitle)
        applyTaskDescription(extraTitle, intent?.getStringExtra(EXTRA_ICON), force = true)

        android.util.Log.i(
            "LemonLite",
            "小程序窗口启动：appId=$extraAppId taskId=$taskId isTaskRoot=${isTaskRoot()} 标题=$extraTitle",
        )
    }

    override fun onPostResume() {
        super.onPostResume()
        if (cardRewrittenAfterVisible) return
        cardRewrittenAfterVisible = true
        setTitle(extraTitle)
        applyTaskDescription(extraTitle, intent?.getStringExtra(EXTRA_ICON), force = true)
    }

    /** [onPostResume] 的「只强写一次」标记。 */
    private var cardRewrittenAfterVisible = false

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
}
