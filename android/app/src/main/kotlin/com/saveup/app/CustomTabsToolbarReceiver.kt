package com.saveup.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.browser.customtabs.CustomTabsIntent

class CustomTabsToolbarReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != MainActivity.ACTION_TOOLBAR_CLICK) {
            return
        }

        val clickedId = intent.getIntExtra(
            CustomTabsIntent.EXTRA_REMOTEVIEWS_CLICKED_ID,
            -1
        )

        when (clickedId) {
            R.id.btn_pay -> {
                Toast.makeText(
                    context,
                    "Continue shopping - Pay active",
                    Toast.LENGTH_SHORT
                ).show()
            }
            R.id.btn_save -> {
                bringAppToFront(context, "save")
            }
            R.id.btn_invest -> {
                bringAppToFront(context, "invest")
            }
        }
    }

    private fun bringAppToFront(context: Context, action: String) {
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_TOOLBAR_ACTION, action)
        }
        context.startActivity(launchIntent)
    }
}
