package dev.pages.abts

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BydKeyReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "ABTS_BydKey"
        const val ACTION_TRIGGER_TOGGLE_PLAY = "dev.pages.abts.TRIGGER_TOGGLE_PLAY"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return
        val action = intent.action
        Log.i(TAG, "onReceive action=$action extras=${intent.extras}")

        if ("byd.intent.action.CUSTOM_KEY" == action) {
            // 发送本地广播通知MainActivity，由Activity通过MethodChannel调用Dart
            val notifyIntent = Intent(ACTION_TRIGGER_TOGGLE_PLAY)
            context.sendBroadcast(notifyIntent)
        }
    }
}
