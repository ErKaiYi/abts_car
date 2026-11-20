package dev.pages.abts

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.util.Log
import android.view.KeyEvent

/**
 * 比亚迪 DiLink 方向盘私有按键监听（Manifest 静态注册，后台 / 服务存活时也能收到）。
 *
 * 比亚迪部分车型把方向盘「播放 / 暂停」以私有广播形式下发，而不是标准媒体键：
 *  - [ACTION_CUSTOM_KEY] ：携带 type / value 两个 int extra，档位含义由车机定义
 *  - [ACTION_MEDIA_BUTTON] ：携带标准 [Intent.EXTRA_KEY_EVENT]
 *
 * 收到后统一转成标准 MEDIA_PLAY_PAUSE，通过系统派发给当前活跃的媒体会话
 * （即本 app 的 audio_service 会话），由 BiliAudioHandler 切换播放 / 暂停。
 *
 * 注意：切歌 / 快进快退等键不在这里拦截，交给系统媒体会话处理，避免重复触发。
 */
class BydKeyReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "ABTS_BydKey"
        const val ACTION_CUSTOM_KEY = "byd.intent.action.CUSTOM_KEY"
        const val ACTION_MEDIA_BUTTON = "byd.intent.action.MEDIA_BUTTON"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        val action = intent?.action ?: return
        if (context == null) return

        // 打印全部 extras，便于在日志里核对比亚迪按键的 type / value 档位
        val extras = buildString {
            intent.extras?.let { bundle ->
                for (key in bundle.keySet()) {
                    append(key).append('=').append(bundle.get(key)).append("  ")
                }
            }
        }
        Log.i(TAG, "onReceive action=$action extras=[$extras]")

        when (action) {
            ACTION_CUSTOM_KEY -> {
                val type = intent.getIntExtra("type", -1)
                val value = intent.getIntExtra("value", -1)
                Log.i(TAG, "CUSTOM_KEY type=$type value=$value → 派发播放/暂停")
                dispatchPlayPause(context)
            }

            ACTION_MEDIA_BUTTON -> {
                val event: KeyEvent? =
                    intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                if (event == null) {
                    Log.w(TAG, "MEDIA_BUTTON 广播缺少 EXTRA_KEY_EVENT")
                    return
                }
                Log.i(TAG, "MEDIA_BUTTON keyCode=${event.keyCode} action=${event.action}")
                when (event.keyCode) {
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                    KeyEvent.KEYCODE_HEADSETHOOK,
                    KeyEvent.KEYCODE_MEDIA_PLAY,
                    KeyEvent.KEYCODE_MEDIA_PAUSE -> dispatchPlayPause(context)
                    // 切歌 / 快进快退交给系统会话，这里不拦截
                }
            }
        }
    }

    private fun dispatchPlayPause(context: Context) {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val code = KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
        try {
            am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
            am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
            Log.i(TAG, "dispatchMediaKeyEvent PLAY_PAUSE 已派发")
        } catch (e: Exception) {
            Log.e(TAG, "dispatchMediaKeyEvent failed", e)
        }
    }
}
