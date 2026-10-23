package com.chunkspoke.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

/** 磨耳朵通知/锁屏事件 → Flutter EventChannel。 */
object ListeningPlaybackBridge {
    private var sink: io.flutter.plugin.common.EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    fun attach(s: io.flutter.plugin.common.EventChannel.EventSink) {
        sink = s
    }

    fun detach() {
        sink = null
    }

    fun send(event: String) {
        main.post { sink?.success(event) }
    }
}

/**
 * 前台播放服务：只负责「让 Flutter 播放器在后台活着」+ 通知栏/锁屏控制。
 *
 * 音频焦点一律交给 just_audio 的 audio_session（它已申请 GAIN，并在
 * LOSS/TRANSIENT/拔出耳机时暂停）——本服务再申请一次会把焦点从
 * audio_session 手里抢走，反而立刻触发暂停，故此处不碰焦点。
 * 本服务补的是：常驻通知 + MediaSession（锁屏/耳机键）+ 耳机拔出兜底
 * （实时 TTS 链路不经过 just_audio）+ 播放期 partial wake lock。
 * 任何失败都静默降级，不影响播放主链路。
 */
class ListeningPlaybackService : Service() {
    companion object {
        private const val CHANNEL_ID = "listening_playback"
        private const val NOTIFICATION_ID = 1201

        const val ACTION_START = "com.chunkspoke.app.LISTEN_START"
        const val ACTION_UPDATE = "com.chunkspoke.app.LISTEN_UPDATE"
        const val ACTION_STOP = "com.chunkspoke.app.LISTEN_STOP"
        const val ACTION_PLAY = "com.chunkspoke.app.LISTEN_PLAY"
        const val ACTION_PAUSE = "com.chunkspoke.app.LISTEN_PAUSE"
        const val ACTION_TOGGLE = "com.chunkspoke.app.LISTEN_TOGGLE"
        const val ACTION_PREV = "com.chunkspoke.app.LISTEN_PREV"
        const val ACTION_NEXT = "com.chunkspoke.app.LISTEN_NEXT"
        const val ACTION_CLOSE = "com.chunkspoke.app.LISTEN_CLOSE"

        const val EXTRA_TITLE = "title"
        const val EXTRA_SCENE = "scene"
        const val EXTRA_PLAYING = "playing"
        const val EXTRA_PRECISE = "precise"
        const val EXTRA_INDEX = "index"
        const val EXTRA_TOTAL = "total"
        const val EXTRA_POSITION = "positionMs"
        const val EXTRA_SPEED = "speed"

        @Volatile
        var isRunning = false
            private set

        fun send(context: Context, payload: Map<*, *>, update: Boolean): Boolean {
            val intent = Intent(context, ListeningPlaybackService::class.java)
                .setAction(if (update) ACTION_UPDATE else ACTION_START)
                .putExtra(EXTRA_TITLE, payload[EXTRA_TITLE] as? String ?: "")
                .putExtra(EXTRA_SCENE, payload[EXTRA_SCENE] as? String ?: "")
                .putExtra(EXTRA_PLAYING, payload[EXTRA_PLAYING] as? Boolean ?: false)
                .putExtra(EXTRA_PRECISE, payload[EXTRA_PRECISE] as? Boolean ?: false)
                .putExtra(EXTRA_INDEX, (payload[EXTRA_INDEX] as? Number)?.toInt() ?: 0)
                .putExtra(EXTRA_TOTAL, (payload[EXTRA_TOTAL] as? Number)?.toInt() ?: 0)
                .putExtra(
                    EXTRA_POSITION,
                    (payload[EXTRA_POSITION] as? Number)?.toLong() ?: 0L,
                )
                .putExtra(EXTRA_SPEED, (payload[EXTRA_SPEED] as? Number)?.toFloat() ?: 1.0f)
            return try {
                if (isRunning) {
                    context.startService(intent)
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (_: Exception) {
                false
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(
                    Intent(context, ListeningPlaybackService::class.java)
                )
            } catch (_: Exception) {
            }
        }
    }

    private var title = "磨耳朵"
    private var scene = ""
    private var playing = false
    private var index = 0
    private var total = 0
    private var positionMs = 0L
    private var speed = 1.0f

    private lateinit var mediaSession: MediaSession
    private var wakeLock: PowerManager.WakeLock? = null
    private var noisyRegistered = false

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                pauseFromSystem()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createChannel()
        mediaSession = MediaSession(this, "ChunkSpokeListening").apply {
            setFlags(
                MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
            )
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() {
                    playing = true
                    publish()
                    ListeningPlaybackBridge.send("play")
                }

                override fun onPause() {
                    playing = false
                    publish()
                    ListeningPlaybackBridge.send("pause")
                }

                override fun onSkipToNext() {
                    ListeningPlaybackBridge.send("next")
                }

                override fun onSkipToPrevious() {
                    ListeningPlaybackBridge.send("prev")
                }

                override fun onStop() {
                    ListeningPlaybackBridge.send("stop")
                    finish()
                }
            }, Handler(Looper.getMainLooper()))
            setSessionActivity(openAppIntent())
            isActive = true
        }
        registerNoisy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP, ACTION_CLOSE -> {
                ListeningPlaybackBridge.send("stop")
                finish()
                return START_NOT_STICKY
            }
            ACTION_PLAY -> {
                playing = true
                publish()
                ListeningPlaybackBridge.send("play")
                return START_NOT_STICKY
            }
            ACTION_PAUSE -> {
                playing = false
                publish()
                ListeningPlaybackBridge.send("pause")
                return START_NOT_STICKY
            }
            ACTION_TOGGLE -> {
                playing = !playing
                publish()
                ListeningPlaybackBridge.send(if (playing) "play" else "pause")
                return START_NOT_STICKY
            }
            ACTION_PREV -> {
                ListeningPlaybackBridge.send("prev")
                return START_NOT_STICKY
            }
            ACTION_NEXT -> {
                ListeningPlaybackBridge.send("next")
                return START_NOT_STICKY
            }
            ACTION_START, ACTION_UPDATE, null -> {
                readPayload(intent)
            }
            else -> readPayload(intent)
        }

        updateWakeLock()
        updateSession()
        startForegroundCompat(buildNotification())
        return START_NOT_STICKY
    }

    private fun readPayload(intent: Intent?) {
        if (intent == null) return
        title = intent.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotEmpty() } ?: title
        scene = intent.getStringExtra(EXTRA_SCENE) ?: scene
        playing = intent.getBooleanExtra(EXTRA_PLAYING, playing)
        index = intent.getIntExtra(EXTRA_INDEX, index)
        total = intent.getIntExtra(EXTRA_TOTAL, total)
        positionMs = intent.getLongExtra(EXTRA_POSITION, positionMs)
        speed = intent.getFloatExtra(EXTRA_SPEED, speed)
    }

    private fun publish() {
        updateWakeLock()
        updateSession()
        startForegroundCompat(buildNotification())
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "磨耳朵播放",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "后台播放与锁屏控制"
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val open = openAppIntent()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val where = if (scene.isNotEmpty()) {
            "$scene · 第 ${index + 1}/$total 句"
        } else {
            "第 ${index + 1}/$total 句"
        }
        val toggleIcon = if (playing) android.R.drawable.ic_media_pause
        else android.R.drawable.ic_media_play
        val toggleTitle = if (playing) "暂停" else "播放"
        val actionFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val style = Notification.MediaStyle()
            .setMediaSession(mediaSession.sessionToken)
            .setShowActionsInCompactView(0, 1, 2)
        return builder
            .setContentTitle(title)
            .setContentText(where)
            .setSubText(if (playing) "正在播放" else "已暂停")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(open)
            .setStyle(style)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_media_previous,
                    "上一句",
                    actionIntent(ACTION_PREV, 11, actionFlags),
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    toggleIcon,
                    toggleTitle,
                    actionIntent(ACTION_TOGGLE, 12, actionFlags),
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_media_next,
                    "下一句",
                    actionIntent(ACTION_NEXT, 13, actionFlags),
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "关闭",
                    actionIntent(ACTION_CLOSE, 14, actionFlags),
                ).build()
            )
            .build()
    }

    private fun actionIntent(action: String, code: Int, flags: Int): PendingIntent {
        val intent = Intent(this, ListeningPlaybackService::class.java).setAction(action)
        return PendingIntent.getService(this, code, intent, flags)
    }

    private fun openAppIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return PendingIntent.getActivity(
            this,
            10,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun updateSession() {
        val state = PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackState.ACTION_STOP
            )
            .setState(
                if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                positionMs,
                if (playing) speed else 0f,
            )
            .build()
        mediaSession.setPlaybackState(state)
        mediaSession.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, scene)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, "磨耳朵")
                .build()
        )
    }

    private fun startForegroundCompat(notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            // 通知权限/前台服务受限时静默；音频本身不受影响。
        }
    }

    private fun pauseFromSystem() {
        if (!playing) return
        playing = false
        publish()
        ListeningPlaybackBridge.send("pause")
    }

    private fun updateWakeLock() {
        try {
            if (playing) {
                if (wakeLock == null) {
                    wakeLock = getSystemService(PowerManager::class.java)
                        .newWakeLock(
                            PowerManager.PARTIAL_WAKE_LOCK,
                            "ChunkSpoke:ListeningPlayback",
                        )
                        .apply { setReferenceCounted(false) }
                }
                if (wakeLock?.isHeld == false) wakeLock?.acquire()
            } else {
                if (wakeLock?.isHeld == true) wakeLock?.release()
            }
        } catch (_: Exception) {
        }
    }

    private fun registerNoisy() {
        try {
            val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(noisyReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(noisyReceiver, filter)
            }
            noisyRegistered = true
        } catch (_: Exception) {
        }
    }

    private fun finish() {
        playing = false
        updateWakeLock()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Exception) {
        }
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        ListeningPlaybackBridge.send("stop")
        finish()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        isRunning = false
        updateWakeLock()
        if (noisyRegistered) {
            try {
                unregisterReceiver(noisyReceiver)
            } catch (_: Exception) {
            }
            noisyRegistered = false
        }
        try {
            mediaSession.isActive = false
            mediaSession.release()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
