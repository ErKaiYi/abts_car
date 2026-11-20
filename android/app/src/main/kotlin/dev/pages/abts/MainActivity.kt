package dev.pages.abts

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.app.NotificationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    companion object {
        private const val TAG = "ABTS_Focus"
        private const val CACHE_CHANNEL_ID = "dev.pages.abts.channel.cache"
        private const val CACHE_NOTIFY_ID = 4201
    }

    private var audioManager: AudioManager? = null
    private var focusCallback: EventChannel.EventSink? = null
    private var focusRequest: AudioFocusRequest? = null
    private var hasAudioFocus = false

    private var cacheNotifyManager: NotificationManager? = null
    private var fullscreen = false
    private var deviceChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        disableSystemFocusHighlight(window.decorView)

        // 熄屏/亮屏广播
        try {
            val screenFilter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(
                    screenReceiver,
                    screenFilter,
                    Context.RECEIVER_NOT_EXPORTED
                )
            } else {
                registerReceiver(screenReceiver, screenFilter)
            }
        } catch (e: Exception) {
            Log.e(TAG, "register screen receiver failed", e)
        }
    }

    // 拦截硬件按键（前台生效，后台靠静态广播接收器）
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        // 1. 拦截静音键：直接将静音键转换为播放/暂停
        if (keyCode == KeyEvent.KEYCODE_VOLUME_MUTE) {
            if (event?.action == KeyEvent.ACTION_DOWN) {
                try {
                    val intent = Intent(Intent.ACTION_MEDIA_BUTTON)
                    // 伪造一个按下的播放/暂停事件，让 audio_service 接收
                    val newEvent = KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                    intent.putExtra(Intent.EXTRA_KEY_EVENT, newEvent)
                    sendBroadcast(intent)
                    Log.i(TAG, "静音键被拦截，触发播放/暂停")
                } catch (_: Exception) {}
            }
            // 返回 true 吃掉该按键，防止系统真正静音
            return true
        }

        // 2. 保留原有对标准媒体按键的处理
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                try {
                    val intent = Intent(Intent.ACTION_MEDIA_BUTTON)
                    val newEvent = KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                    intent.putExtra(Intent.EXTRA_KEY_EVENT, newEvent)
                    sendBroadcast(intent)
                } catch (_: Exception) {}
                return true
            }
        }

        return super.onKeyDown(keyCode, event)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)

        if (hasFocus && fullscreen) {
            applyFullscreen(true)
        }
    }

    override fun onPostResume() {
        super.onPostResume()

        disableSystemFocusHighlight(window.decorView)

        if (fullscreen) {
            applyFullscreen(true)
        }
    }

    private fun applyFullscreen(on: Boolean) {
        val w = window ?: return

        if (on) {
            w.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val attrs = w.attributes
                attrs.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                w.attributes = attrs
            }

            @Suppress("DEPRECATION")
            w.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN

        } else {
            w.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val attrs = w.attributes
                attrs.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT
                w.attributes = attrs
            }

            @Suppress("DEPRECATION")
            w.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_VISIBLE
        }
    }

    private fun disableSystemFocusHighlight(view: View) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        view.defaultFocusHighlightEnabled = false

        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                disableSystemFocusHighlight(view.getChildAt(i))
            }
        }
    }

    // 耳机拔出广播
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                notifyFocusEvent("noisy")
            }
        }
    }

    // 熄屏/亮屏广播
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> notifyDart("screenOff")
                Intent.ACTION_SCREEN_ON -> notifyDart("screenOn")
            }
        }
    }

    private fun notifyDart(method: String) {
        runOnUiThread {
            try {
                deviceChannel?.invokeMethod(method, null)
            } catch (e: Exception) {
                Log.e(TAG, "notify dart failed: $method", e)
            }
        }
    }

    private fun notifyFocusEvent(event: String) {
        runOnUiThread {
            try {
                focusCallback?.success(event)
            } catch (e: Exception) {
                Log.e(TAG, "focus event failed: $event", e)
            }
        }
    }

    // 系统音频焦点变化
    private val focusListener =
        AudioManager.OnAudioFocusChangeListener { focusChange ->

            Log.i(TAG, "audio focus changed: $focusChange")

            when (focusChange) {
                AudioManager.AUDIOFOCUS_GAIN -> {
                    hasAudioFocus = true
                    notifyFocusEvent("gained")
                }

                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                    hasAudioFocus = false
                    notifyFocusEvent("interrupted")
                }

                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    notifyFocusEvent("ducked")
                }

                AudioManager.AUDIOFOCUS_LOSS -> {
                    hasAudioFocus = false
                    notifyFocusEvent("lost")
                }
            }
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioManager =
            getSystemService(Context.AUDIO_SERVICE) as AudioManager

        Log.i(TAG, "AudioManager initialized")

        // 耳机拔出监听
        try {
            val noisyFilter =
                IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(
                    noisyReceiver,
                    noisyFilter,
                    Context.RECEIVER_NOT_EXPORTED
                )
            } else {
                registerReceiver(noisyReceiver, noisyFilter)
            }
        } catch (e: Exception) {
            Log.e(TAG, "register noisy receiver failed", e)
        }

        // 音频焦点 MethodChannel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/audio_focus"
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "request" -> {
                    result.success(requestFocus())
                }

                "abandon" -> {
                    abandonFocus()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        // 音频焦点 EventChannel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/audio_focus_events"
        ).setStreamHandler(object : EventChannel.StreamHandler {

            override fun onListen(
                arguments: Any?,
                events: EventChannel.EventSink?
            ) {
                focusCallback = events
                Log.i(TAG, "focus event listener attached")
            }

            override fun onCancel(arguments: Any?) {
                focusCallback = null
                Log.i(TAG, "focus event listener detached")
            }
        })

        // 相册
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/gallery"
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "sdkInt" -> {
                    result.success(Build.VERSION.SDK_INT)
                }

                "saveImage" -> {
                    val base64 = call.argument<String>("base64")
                    val name = call.argument<String>("name") ?: "image"

                    if (base64 == null) {
                        result.success(null)
                    } else {
                        result.success(saveImageToGallery(base64, name))
                    }
                }

                else -> result.notImplemented()
            }
        }

        // 浏览器
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/browser"
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "open" -> {
                    val url = call.argument<String>("url")

                    if (url.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        result.success(openExternal(url))
                    }
                }

                else -> result.notImplemented()
            }
        }

        // 缓存通知
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/cache_notify"
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "update" -> {
                    val title =
                        call.argument<String>("title") ?: "正在缓存"

                    val text =
                        call.argument<String>("text") ?: ""

                    val progress =
                        call.argument<Int>("progress") ?: -1

                    updateCacheNotification(title, text, progress)
                    result.success(true)
                }

                "cancel" -> {
                    cacheNotifyManager?.cancel(CACHE_NOTIFY_ID)
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        // 存储空间
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/storage"
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "freeBytes" -> {
                    try {
                        val path = call.argument<String>("path")

                        val stat = if (path.isNullOrBlank()) {
                            StatFs(filesDir.absolutePath)
                        } else {
                            StatFs(path)
                        }

                        result.success(stat.availableBytes)

                    } catch (e: Exception) {
                        Log.e(TAG, "get free bytes failed", e)
                        result.success(-1L)
                    }
                }

                else -> result.notImplemented()
            }
        }

        // 设备控制
        val device = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/device"
        )

        deviceChannel = device

        device.setMethodCallHandler { call, result ->

            when (call.method) {

                "isLeanback" -> {
                    try {
                        val pm = packageManager

                        val leanback =
                            pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
                            pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK_ONLY)

                        val touch =
                            pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)

                        val dpad =
                            resources.configuration.navigation ==
                            android.content.res.Configuration.NAVIGATION_DPAD

                        result.success(
                            (leanback && !touch) || (!touch && dpad)
                        )

                    } catch (e: Exception) {
                        Log.e(TAG, "isLeanback failed", e)
                        result.success(false)
                    }
                }

                "restart" -> {
                    result.success(true)

                    try {
                        val intent =
                            packageManager.getLaunchIntentForPackage(packageName)

                        intent?.addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP
                        )

                        if (intent != null) {
                            startActivity(intent)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "restart failed", e)
                    }

                    android.os.Handler(mainLooper).postDelayed({
                        android.os.Process.killProcess(
                            android.os.Process.myPid()
                        )
                    }, 400)
                }

                "setFullscreen" -> {
                    val on =
                        call.argument<Boolean>("on") ?: false

                    fullscreen = on
                    applyFullscreen(on)
                    result.success(true)
                }

                "statusBarInset" -> {
                    val inset = try {
                        val insets = window.decorView.rootWindowInsets

                        when {
                            insets == null -> 0

                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                                insets.getInsets(
                                    WindowInsets.Type.statusBars()
                                ).top

                            else -> {
                                @Suppress("DEPRECATION")
                                insets.systemWindowInsetTop
                            }
                        }

                    } catch (e: Exception) {
                        Log.e(TAG, "statusBarInset failed", e)
                        0
                    }

                    result.success(inset)
                }

                "exit" -> {
                    result.success(true)

                    try {
                        stopService(
                            Intent(
                                this,
                                com.ryanheise.audioservice.AudioService::class.java
                            )
                        )
                    } catch (e: Exception) {
                        Log.e(TAG, "stop audio service failed", e)
                    }

                    try {
                        finishAndRemoveTask()
                    } catch (e: Exception) {
                        Log.e(TAG, "finish task failed", e)
                    }

                    android.os.Handler(mainLooper).postDelayed({
                        android.os.Process.killProcess(
                            android.os.Process.myPid()
                        )
                    }, 300)
                }

                else -> result.notImplemented()
            }
        }

        // 电池优化
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/battery"
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "isIgnoring" -> {
                    val pm =
                        getSystemService(Context.POWER_SERVICE) as PowerManager

                    result.success(
                        pm.isIgnoringBatteryOptimizations(packageName)
                    )
                }

                "requestIgnore" -> {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            )
                        )
                    } catch (e: Exception) {
                        Log.e(TAG, "request battery optimization failed", e)

                        try {
                            startActivity(
                                Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
                            )
                        } catch (e2: Exception) {
                            Log.e(TAG, "open battery settings failed", e2)
                        }
                    }

                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    // 申请系统音频焦点
    private fun requestFocus(): Boolean {
        val am = audioManager ?: run {
            Log.e(TAG, "AudioManager is null")
            return false
        }

        return try {
            val result: Int

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {

                var request = focusRequest

                if (request == null) {
                    request = AudioFocusRequest.Builder(
                        AudioManager.AUDIOFOCUS_GAIN
                    )
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                                .build()
                        )
                        .setOnAudioFocusChangeListener(focusListener)
                        .setAcceptsDelayedFocusGain(false)
                        .build()

                    focusRequest = request
                }

                result = am.requestAudioFocus(request)

            } else {

                result = am.requestAudioFocus(
                    focusListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN
                )
            }

            val granted =
                result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED

            hasAudioFocus = granted

            Log.i(
                TAG,
                "requestAudioFocus result=$result granted=$granted"
            )

            granted

        } catch (e: Exception) {
            hasAudioFocus = false
            Log.e(TAG, "requestAudioFocus exception", e)
            false
        }
    }

    // 释放系统音频焦点
    private fun abandonFocus() {
        val am = audioManager ?: return

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {

                val request = focusRequest ?: return

                val result =
                    am.abandonAudioFocusRequest(request)

                Log.i(
                    TAG,
                    "abandonAudioFocus result=$result"
                )

            } else {

                val result =
                    am.abandonAudioFocus(focusListener)

                Log.i(
                    TAG,
                    "abandonAudioFocus result=$result"
                )
            }

            hasAudioFocus = false

        } catch (e: Exception) {
            Log.e(TAG, "abandonAudioFocus exception", e)
        }
    }

    // 打开外部链接
    private fun openExternal(url: String): Boolean {
        return try {
            val intent = Intent(
                Intent.ACTION_VIEW,
                Uri.parse(url)
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            startActivity(intent)
            true

        } catch (e: Exception) {
            Log.e(TAG, "open external failed", e)
            false
        }
    }

    // 更新缓存通知
    private fun updateCacheNotification(
        title: String,
        text: String,
        progress: Int
    ) {
        try {
            val nm = cacheNotifyManager ?: run {
                val n =
                    getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

                createCacheChannel(n)
                cacheNotifyManager = n
                n
            }

            val builder =
                android.app.Notification.Builder(this, CACHE_CHANNEL_ID)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setSmallIcon(android.R.drawable.stat_sys_download)
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)

            if (progress >= 0) {
                builder.setProgress(100, progress, false)
            }

            nm.notify(CACHE_NOTIFY_ID, builder.build())

        } catch (e: Exception) {
            Log.e(TAG, "update cache notification failed", e)
        }
    }

    private fun createCacheChannel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {

            val channel = android.app.NotificationChannel(
                CACHE_CHANNEL_ID,
                "离线缓存",
                NotificationManager.IMPORTANCE_LOW
            )

            channel.setShowBadge(false)
            channel.enableVibration(false)
            channel.setSound(null, null)

            nm.createNotificationChannel(channel)
        }
    }

    // 保存图片到相册
    private fun saveImageToGallery(
        base64: String,
        name: String
    ): String? {
        return try {
            val bytes = android.util.Base64.decode(
                base64,
                android.util.Base64.DEFAULT
            )

            val bitmap =
                android.graphics.BitmapFactory.decodeByteArray(
                    bytes,
                    0,
                    bytes.size
                ) ?: return null

            val fileName =
                if (name.endsWith(".png")) name else "$name.png"

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {

                val values =
                    android.content.ContentValues().apply {

                        put(
                            android.provider.MediaStore.Images.Media.DISPLAY_NAME,
                            fileName
                        )

                        put(
                            android.provider.MediaStore.Images.Media.MIME_TYPE,
                            "image/png"
                        )

                        put(
                            android.provider.MediaStore.Images.Media.RELATIVE_PATH,
                            "Pictures/阿B听书"
                        )

                        put(
                            android.provider.MediaStore.Images.Media.IS_PENDING,
                            1
                        )
                    }

                val uri = contentResolver.insert(
                    android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    values
                ) ?: return null

                contentResolver.openOutputStream(uri)?.use { output ->
                    bitmap.compress(
                        android.graphics.Bitmap.CompressFormat.PNG,
                        100,
                        output
                    )
                }

                values.clear()

                values.put(
                    android.provider.MediaStore.Images.Media.IS_PENDING,
                    0
                )

                contentResolver.update(uri, values, null, null)

                uri.toString()

            } else {

                @Suppress("DEPRECATION")
                val dir = java.io.File(
                    android.os.Environment.getExternalStoragePublicDirectory(
                        android.os.Environment.DIRECTORY_PICTURES
                    ),
                    "阿B听书"
                )

                if (!dir.exists() && !dir.mkdirs()) {
                    return null
                }

                val file = java.io.File(dir, fileName)

                java.io.FileOutputStream(file).use { output ->
                    bitmap.compress(
                        android.graphics.Bitmap.CompressFormat.PNG,
                        100,
                        output
                    )
                }

                android.media.MediaScannerConnection.scanFile(
                    this,
                    arrayOf(file.absolutePath),
                    arrayOf("image/png"),
                    null
                )

                file.absolutePath
            }

        } catch (e: Exception) {
            Log.e(TAG, "save image failed", e)
            null
        }
    }

    override fun onDestroy() {

        try {
            unregisterReceiver(noisyReceiver)
        } catch (_: Exception) {}

        try {
            unregisterReceiver(screenReceiver)
        } catch (_: Exception) {}

        abandonFocus()

        focusCallback = null
        deviceChannel = null

        super.onDestroy()
    }
}