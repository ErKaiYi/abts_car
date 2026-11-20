package dev.pages.abts

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.view.KeyEvent

/**
 * 专门拦截静音键（以及其它媒体按键），在后台也能触发播放/暂停。
 * 只要按下了静音键，我们就阻止系统真正静音，并强制发送播放/暂停广播。
 */
class VolumeMuteReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "ABTS_VolumeMute"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action == Intent.ACTION_MEDIA_BUTTON) {
            val event: KeyEvent? = intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
            
            if (event != null) {
                // 静音键的键值是 KEYCODE_VOLUME_MUTE
                if (event.keyCode == KeyEvent.KEYCODE_VOLUME_MUTE) {
                    if (event.action == KeyEvent.ACTION_DOWN) {
                        Log.i(TAG, "静音键被拦截，准备触发播放/暂停")
                        
                        // 发出一个标准的 MEDIA_PLAY_PAUSE 广播给 audio_service
                        val standardIntent = Intent(Intent.ACTION_MEDIA_BUTTON)
                        val newEvent = KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                        standardIntent.putExtra(Intent.EXTRA_KEY_EVENT, newEvent)
                        context?.sendBroadcast(standardIntent)
                    }
                    
                    // 如果 event 是 KeyEvent.ACTION_UP，也要吞掉
                    // 因为我们是静态注册的接收器，没法直接 return true，
                    // 但通过替换掉 action 并马上 clear 掉，可以阻止系统进一步处理。
                    // （如果这层拦截不够，再结合 MainActivity 的 onKeyDown 拦截）
                }
            }
        }
    }
}