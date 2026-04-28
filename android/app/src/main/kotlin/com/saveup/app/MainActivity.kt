package com.saveup.app

import android.content.Intent
import android.content.pm.PackageManager
import androidx.browser.customtabs.CustomTabsService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var customTabsChannel: MethodChannel? = null
    private fun log(message: String) = android.util.Log.d(TAG, message)

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
                "getPartialCustomTabsSupport" -> result.success(getPartialCustomTabsSupport())
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        log("onActivityResult requestCode=$requestCode resultCode=$resultCode data=$data")

        if (requestCode == PARTIAL_CUSTOM_TABS_REQUEST_CODE) {
            log("partial custom tabs closed callback")
            customTabsChannel?.invokeMethod("partialCustomTabsClosed", null)
        }
    }

    private fun getPartialCustomTabsSupport(): Map<String, Any?> {
        log("preflight start")
        val chromeSupport = findSupportedChrome()
        if (chromeSupport != null) {
            log("preflight chrome result=$chromeSupport")
            return chromeSupport
        }

        val fallbackPackage = findAnyCustomTabsPackage()
        if (fallbackPackage != null) {
            log("preflight fallback package=$fallbackPackage")
            return mapOf(
                "supported" to true,
                "packageName" to fallbackPackage,
                "isChrome" to false,
                "reason" to "Chrome unavailable; using default Custom Tabs browser."
            )
        }

        log("preflight no custom tabs browser found")
        return mapOf(
            "supported" to false,
            "packageName" to null,
            "isChrome" to false,
            "reason" to "No Custom Tabs-capable browser found."
        )
    }

    private fun findSupportedChrome(): Map<String, Any?>? {
        for (packageName in CHROME_PACKAGES) {
            if (!supportsCustomTabs(packageName)) {
                log("chrome package lacks custom tabs service package=$packageName")
                continue
            }

            val majorVersion = browserMajorVersion(packageName)
            if (majorVersion == null) {
                log("chrome version unreadable package=$packageName")
                return mapOf(
                    "supported" to false,
                    "packageName" to packageName,
                    "isChrome" to true,
                    "reason" to "Chrome version could not be read."
                )
            }

            return if (majorVersion >= MIN_PARTIAL_CUSTOM_TABS_CHROME_VERSION) {
                log("chrome supported package=$packageName majorVersion=$majorVersion")
                mapOf(
                    "supported" to true,
                    "packageName" to packageName,
                    "isChrome" to true,
                    "reason" to "Chrome supports Partial Custom Tabs."
                )
            } else {
                log("chrome too old package=$packageName majorVersion=$majorVersion")
                mapOf(
                    "supported" to false,
                    "packageName" to packageName,
                    "isChrome" to true,
                    "reason" to "Chrome $majorVersion found; 107+ required."
                )
            }
        }

        return null
    }

    private fun findAnyCustomTabsPackage(): String? {
        val intent = Intent(CustomTabsService.ACTION_CUSTOM_TABS_CONNECTION)
        val services = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentServices(
                intent,
                PackageManager.ResolveInfoFlags.of(0)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentServices(intent, 0)
        }

        val packageName = services.firstOrNull()?.serviceInfo?.packageName
        log("findAnyCustomTabsPackage=$packageName")
        return packageName
    }

    private fun supportsCustomTabs(packageName: String): Boolean {
        val intent = Intent(CustomTabsService.ACTION_CUSTOM_TABS_CONNECTION)
            .setPackage(packageName)
        val service = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
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

    private fun browserMajorVersion(packageName: String): Int? {
        val packageInfo = try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(0)
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        }

        return packageInfo.versionName
            ?.substringBefore('.')
            ?.toIntOrNull()
    }

    private companion object {
        const val TAG = "SaveUpCustomTabs"
        const val CUSTOM_TABS_CHANNEL = "com.saveup.app/custom_tabs"
        const val PARTIAL_CUSTOM_TABS_REQUEST_CODE = 1001
        const val MIN_PARTIAL_CUSTOM_TABS_CHROME_VERSION = 107
        val CHROME_PACKAGES = listOf(
            "com.android.chrome",
            "com.chrome.beta",
            "com.chrome.dev",
            "com.chrome.canary"
        )
    }
}
