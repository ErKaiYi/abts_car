package dev.pages.abts

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.util.Log
import android.view.KeyEvent

/**
 * 监听系统 MEDIA_BUTTON 广播：把方向盘 / 耳机线控的静音键
 * （KEYCODE_VOLUME_MUTE）转成标准播放 / 暂停键，交给当前活跃媒体会话处理。
 *
 * 标准 MEDIA_PLAY_PAUSE / PLAY / PAUSE 由 audio_service 会话直接回调，
 * 这里只兜底处理系统会话未识别的静音键。
 */
class VolumeMuteReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "ABTS_VolumeMute"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent?.action != Intent.ACTION_MEDIA_BUTTON) return

        val event: KeyEvent? = intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
        if (event == null) return

        Log.i(TAG, "onReceive keyCode=${event.keyCode} action=${event.action}")

        if (event.keyCode == KeyEvent.KEYCODE_VOLUME_MUTE &&
            event.action == KeyEvent.ACTION_DOWN
        ) {
            Log.i(TAG, "静音键拦截 → 派发播放/暂停")
            val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            val code = KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            try {
                am?.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
                am?.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
            } catch (e: Exception) {
                Log.e(TAG, "dispatchMediaKeyEvent failed", e)
            }
        }
    }
}
