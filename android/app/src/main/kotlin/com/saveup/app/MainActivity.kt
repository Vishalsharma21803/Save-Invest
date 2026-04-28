package com.saveup.app

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.widget.RemoteViews
import androidx.browser.customtabs.CustomTabsIntent
import androidx.browser.customtabs.CustomTabsService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private fun log(message: String) = android.util.Log.d(TAG, message)
    private var toolbarDecisionAction: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        log("configureFlutterEngine")

        customTabsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CUSTOM_TABS_CHANNEL
        )

        customTabsChannel?.setMethodCallHandler { call, result ->
            log("methodChannel call=${call.method}")
            when (call.method) {
                "getCustomTabsSupport" -> result.success(getCustomTabsSupport())
                "launchCustomTabWithToolbar" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("INVALID_URL", "Missing URL", null)
                    } else {
                        launchCustomTabWithToolbar(url)
                        result.success(null)
                    }
                }
                "closeCustomTabSession" -> {
                    closeCustomTabSession()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        handleToolbarActionIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleToolbarActionIntent(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        log("onActivityResult requestCode=$requestCode resultCode=$resultCode")
        if (requestCode == CUSTOM_TABS_REQUEST_CODE) {
            if (toolbarDecisionAction != null) {
                log("custom tabs close ignored due toolbar action=$toolbarDecisionAction")
                toolbarDecisionAction = null
                return
            }
            log("custom tabs closed callback")
            customTabsChannel?.invokeMethod("customTabsClosed", null)
        }
    }

    private fun handleToolbarActionIntent(intent: Intent?) {
        val action = intent?.getStringExtra(EXTRA_TOOLBAR_ACTION) ?: return
        log("toolbar action intent action=$action")
        if (action == "save" || action == "invest") {
            toolbarDecisionAction = action
        }
        customTabsChannel?.invokeMethod(
            "secondaryToolbarAction",
            mapOf("action" to action)
        )
        intent.removeExtra(EXTRA_TOOLBAR_ACTION)
    }

    private fun launchCustomTabWithToolbar(url: String) {
        val actionIntent = Intent(this, CustomTabsToolbarReceiver::class.java).apply {
            action = ACTION_TOOLBAR_CLICK
            `package` = packageName
        }
        val pendingIntentFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
        val toolbarPendingIntent = PendingIntent.getBroadcast(
            this,
            7,
            actionIntent,
            pendingIntentFlags
        )

        val remoteViews = RemoteViews(packageName, R.layout.custom_tabs_secondary_toolbar)
        val clickableIds = intArrayOf(
            R.id.btn_pay,
            R.id.btn_save,
            R.id.btn_invest,
        )

        val support = getCustomTabsSupport()
        val builder = CustomTabsIntent.Builder()
            .setShowTitle(true)
            .setSecondaryToolbarViews(remoteViews, clickableIds, toolbarPendingIntent)
        val customTabsIntent = builder.build()

        val packageName = support["packageName"] as String?
        if (!packageName.isNullOrBlank()) {
            customTabsIntent.intent.setPackage(packageName)
        }

        customTabsIntent.intent.data = android.net.Uri.parse(url)
        startActivityForResult(customTabsIntent.intent, CUSTOM_TABS_REQUEST_CODE)
    }

    private fun closeCustomTabSession() {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        startActivity(intent)
    }

    private fun getCustomTabsSupport(): Map<String, Any?> {
        val chromePackage = findSupportedChromePackage()
        if (chromePackage != null) {
            return mapOf(
                "supported" to true,
                "packageName" to chromePackage,
                "reason" to "Chrome supports Custom Tabs."
            )
        }

        val fallbackPackage = findAnyCustomTabsPackage()
        if (fallbackPackage != null) {
            return mapOf(
                "supported" to true,
                "packageName" to fallbackPackage,
                "reason" to "Fallback browser supports Custom Tabs."
            )
        }

        return mapOf(
            "supported" to false,
            "packageName" to null,
            "reason" to "No Custom Tabs-capable browser found."
        )
    }

    private fun findSupportedChromePackage(): String? {
        for (packageName in CHROME_PACKAGES) {
            if (supportsCustomTabs(packageName)) {
                return packageName
            }
        }
        return null
    }

    private fun findAnyCustomTabsPackage(): String? {
        val intent = Intent(CustomTabsService.ACTION_CUSTOM_TABS_CONNECTION)
        val services = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentServices(
                intent,
                PackageManager.ResolveInfoFlags.of(0)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentServices(intent, 0)
        }
        return services.firstOrNull()?.serviceInfo?.packageName
    }

    private fun supportsCustomTabs(packageName: String): Boolean {
        val intent = Intent(CustomTabsService.ACTION_CUSTOM_TABS_CONNECTION)
            .setPackage(packageName)
        val service = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.resolveService(
                intent,
                PackageManager.ResolveInfoFlags.of(0)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.resolveService(intent, 0)
        }
        return service != null
    }

    companion object {
        const val TAG = "SaveUpCustomTabs"
        const val CUSTOM_TABS_CHANNEL = "com.saveup.app/custom_tabs"
        const val ACTION_TOOLBAR_CLICK = "com.saveup.app.TOOLBAR_CLICK"
        const val EXTRA_TOOLBAR_ACTION = "toolbar_action"
        const val CUSTOM_TABS_REQUEST_CODE = 1001
        val CHROME_PACKAGES = listOf(
            "com.android.chrome",
            "com.chrome.beta",
            "com.chrome.dev",
            "com.chrome.canary"
        )

        var customTabsChannel: MethodChannel? = null
    }
}
