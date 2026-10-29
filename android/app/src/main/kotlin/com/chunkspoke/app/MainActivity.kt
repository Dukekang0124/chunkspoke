package com.chunkspoke.app

import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.media.audiofx.AutomaticGainControl
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.math.abs

class MainActivity : FlutterActivity() {
    private val UPDATE_CH = "chunkspoke/update"
    private val REC_CH = "chunkspoke/recorder"
    private val LEVEL_CH = "chunkspoke/recorder_level"
    private val POWER_CH = "chunkspoke/power"
    private val TTS_CH = "chunkspoke/tts"
    private val VOICE_CH = "chunkspoke/voice"
    private val SECURE_CH = "chunkspoke/secure_store"
    private val LLM_KEY_ALIAS = "chunkspoke_llm_key_v1"
    private val LISTEN_CH = "chunkspoke/listening_playback"
    private val LISTEN_EVENT_CH = "chunkspoke/listening_playback_events"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var recFile: File? = null
    private var recOut: FileOutputStream? = null
    private var levelSink: EventChannel.EventSink? = null
    private var player: MediaPlayer? = null
    private var voicePlayer: MediaPlayer? = null
    private var agc: AutomaticGainControl? = null

    // —— 采集时序（§30.3-1 / §30.3-2，1.5.8.2）——
    companion object {
        /** 采样率单一真源：AudioRecord、WAV 头、Dart 侧 kCaptureSampleRate 三处必须同值。
         *  改这里必须同步 lib/services/audio_format.dart（守门单测会红）。 */
        const val CAPTURE_RATE = 16000

        /** 句首预卷（毫秒）：按下即起采，最多把按下→start 之间的 400 ms 回灌进 WAV。
         *  区间 300–500，默认 400（§30.3-2）。 */
        const val PRE_ROLL_MS = 400

        /** armed 后迟迟不 start 的自动释放时间，避免麦克风被按下后一直占着。 */
        const val ARM_TIMEOUT_MS = 3000L

        /** AGC 开关（§30.3-8）：默认关。只有机型矩阵 A/B 证明「正常手持识别率提升
         *  且不削波」才置 true，否则保持关闭并记档（§30.3 验收列原文）。 */
        const val AGC_ENABLED = false
    }

    /** 采集模式：空闲 / 已按下（只进环形缓冲）/ 正式录音（落盘）。 */
    private val MODE_IDLE = 0
    private val MODE_ARM = 1
    private val MODE_LIVE = 2
    @Volatile private var recMode = MODE_IDLE
    private var armed = false
    private var armTimeout: Runnable? = null
    private val recLock = Any()
    private var ringBuf: ByteArray? = null
    private var ringFill = 0
    private var ringPos = 0
    /** 本次录音 AudioRecord 实际给出的采样率（写 WAV 头用，与请求值核对）。 */
    private var actualRate = CAPTURE_RATE

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // —— 更新安装通道 ——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstallPackages" -> {
                        val can = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else {
                            true
                        }
                        result.success(can)
                    }
                    "openInstallSettings" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent = Intent("android.settings.MANAGE_UNKNOWN_APPS").apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("SETTINGS", e.message, null)
                        }
                    }
                    "openUrl" -> {
                        // 交给系统浏览器/下载器接管：国内直连 GitHub 慢，
                        // 但浏览器可断点续传、可后台、可转给下载工具，比 App 内单线程稳。
                        val url = call.arguments as? String
                        if (url.isNullOrBlank()) {
                            result.error("NO_URL", "url is null", null)
                            return@setMethodCallHandler
                        }
                        val scheme = Uri.parse(url).scheme?.lowercase()
                        if (scheme != "http" && scheme != "https") {
                            result.error("BAD_URL", "only http(s) allowed: $url", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("OPEN_URL", e.message, null)
                        }
                    }
                    "installApk" -> {
                        val path = call.arguments as? String
                        if (path == null) {
                            result.error("NO_PATH", "path is null", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                result.error("NO_FILE", "apk not found: $path", null)
                                return@setMethodCallHandler
                            }
                            val uri = FileProvider.getUriForFile(
                                this, "$packageName.fileprovider", file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("INSTALL", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // —— 省电模式探测（B7：动效/触感自动降级） ——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, POWER_CH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isPowerSaveMode" -> {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        val save = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            pm.isPowerSaveMode
                        } else {
                            false
                        }
                        result.success(save)
                    }
                    else -> result.notImplemented()
                }
            }

        // —— TTS 修复引导：系统语音设置 / 应用商店 ——
        // 引导页与「无法播放语音」对话框共用；失败返回 false 由 Dart 侧给可见提示。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TTS_CH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openSettings" -> {
                        try {
                            // 标准 TTS 设置页（Android 11+ 也可直达首选引擎/语音数据）。
                            val intent = Intent("com.android.settings.TTS_SETTINGS").apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val fallback = Intent(Settings.ACTION_SETTINGS).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(fallback)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    "openStore" -> {
                        val q = (call.arguments as? String)?.takeIf { it.isNotBlank() }
                            ?: "text to speech engine"
                        // 先交给设备自带应用商店（国内机型为厂商商店），失败再走浏览器。
                        try {
                            val market = Intent(
                                Intent.ACTION_VIEW,
                                Uri.parse("market://search?q=" + Uri.encode(q))
                            ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                            startActivity(market)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val web = Intent(
                                    Intent.ACTION_VIEW,
                                    Uri.parse("https://play.google.com/store/search?q=" + Uri.encode(q))
                                ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                                startActivity(web)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // —— 录音通道（16k 单声道 PCM → WAV） ——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, REC_CH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "arm" -> {
                        try {
                            armRecording()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("REC", e.message, null)
                        }
                    }
                    "disarm" -> {
                        try {
                            disarmRecording()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("REC", e.message, null)
                        }
                    }
                    "start" -> {
                        val path = call.arguments as? String
                        try {
                            startRecording(path)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("REC", e.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            result.success(stopRecording())
                        } catch (e: Exception) {
                            result.error("REC", e.message, null)
                        }
                    }
                    "play" -> {
                        try {
                            playRecording(call.arguments as? String)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("PLAY", e.message, null)
                        }
                    }
                    "stopPlay" -> {
                        try {
                            stopPlayback()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("PLAY", e.message, null)
                        }
                    }
                    // §拾音-分享：只把指定 WAV 交给系统分享面板（不在 App 内自建
                    // 分享渠道）。文件必须先落在 FileProvider 声明的 cache/share 下，
                    // 否则 getUriForFile 会抛 IllegalArgumentException → 走错误回执。
                    "share" -> {
                        try {
                            val path = call.argument<String>("path")
                            val text = call.argument<String>("text")
                            shareFile(path, text)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SHARE", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // —— 高清发音包播放通道（VITS 合成 WAV → MediaPlayer） ——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOICE_CH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "playWav" -> {
                        try {
                            playVoice(call.argument<String>("path"))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("VOICE", e.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            stopVoice()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("VOICE", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // —— 本机密文通道：自定义模型 Key 用 Android Keystore（AES/GCM）加解密 ——
        // 明文只在 Dart 内存与本次调用参数里短暂存在，落库永远是 enc:v1: 密文。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURE_CH)
            .setMethodCallHandler { call, result ->
                val value = call.argument<String>("value")
                when (call.method) {
                    "encrypt" -> {
                        if (value.isNullOrEmpty()) {
                            result.error("ARGS", "value is null", null)
                        } else {
                            try {
                                result.success(encryptSecret(value))
                            } catch (e: Exception) {
                                result.error("ENC", e.message, null)
                            }
                        }
                    }
                    "decrypt" -> {
                        if (value.isNullOrEmpty()) {
                            result.error("ARGS", "value is null", null)
                        } else {
                            try {
                                result.success(decryptSecret(value))
                            } catch (e: Exception) {
                                result.error("DEC", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // —— 磨耳朵后台播放通道：前台服务 + 通知栏/锁屏动作 ——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LISTEN_CH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start", "update" -> {
                        val payload = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                        val ok = ListeningPlaybackService.send(
                            this,
                            payload,
                            call.method == "update",
                        )
                        result.success(ok)
                    }
                    "stop" -> {
                        ListeningPlaybackService.stop(this)
                        result.success(null)
                    }
                    "isRunning" -> result.success(ListeningPlaybackService.isRunning)
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LISTEN_EVENT_CH)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    events?.let { ListeningPlaybackBridge.attach(it) }
                }

                override fun onCancel(args: Any?) {
                    ListeningPlaybackBridge.detach()
                }
            })

        // —— 采集电平通道（录音期间实时 RMS/峰值 0..1，供 UI 电平反馈自检） ——
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LEVEL_CH)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    levelSink = events
                }

                override fun onCancel(args: Any?) {
                    levelSink = null
                }
            })
    }

    private fun emitLevel(level: Double) {
        mainHandler.post { levelSink?.success(level) }
    }

    private fun playVoice(path: String?) {
        if (path == null) throw IllegalArgumentException("path null")
        stopVoice()
        stopPlayback()
        voicePlayer = MediaPlayer().apply {
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            setDataSource(path)
            setOnCompletionListener { stopVoice() }
            prepare()
            start()
        }
    }

    private fun stopVoice() {
        try {
            voicePlayer?.stop()
        } catch (_: Exception) {
        }
        try {
            voicePlayer?.release()
        } catch (_: Exception) {
        }
        voicePlayer = null
    }

    private fun playRecording(path: String?) {
        if (path == null) throw IllegalArgumentException("path null")
        stopVoice()
        stopPlayback()
        player = MediaPlayer().apply {
            setDataSource(path)
            setOnCompletionListener { stopPlayback() }
            prepare()
            start()
        }
    }

    private fun stopPlayback() {
        try {
            player?.stop()
        } catch (_: Exception) {
        }
        try {
            player?.release()
        } catch (_: Exception) {
        }
        player = null
    }

    /**
     * 把一段录音交给系统分享面板。文件必须位于 FileProvider 声明的
     * cache/share 下（Dart 侧先复制过去），否则 getUriForFile 抛异常。
     */
    private fun shareFile(path: String?, text: String?) {
        if (path.isNullOrEmpty()) throw IllegalArgumentException("path null")
        val file = File(path)
        if (!file.exists()) throw IllegalStateException("file missing: $path")
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "audio/wav"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = android.content.ClipData.newRawUri("recording", uri)
            if (!text.isNullOrEmpty()) putExtra(Intent.EXTRA_TEXT, text)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(send, "分享录音"))
    }

    /// Activity 销毁时兜住 armed/录音中的采集器：预卷会提前占麦克风，
    /// 不在这里释放就会出现「退出了还占着麦」。
    override fun onDestroy() {
        try {
            disarmRecording()
        } catch (_: Exception) {
        }
        if (audioRecord != null) {
            try {
                releaseRecorder()
            } catch (_: Exception) {
            }
        }
        try {
            stopPlayback()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    /// 打开采集器：采集源固定 VOICE_RECOGNITION（§30.3-1：手机为语音设计的拾音链路，
    /// 自带增益/降噪；禁用 MIC/DEFAULT——裸麦克风在 25–35 cm 手持距离电平偏低）。
    private fun openRecorder(): AudioRecord {
        val minBuf = AudioRecord.getMinBufferSize(
            CAPTURE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val bufSize = if (minBuf > CAPTURE_RATE * 2) minBuf else CAPTURE_RATE * 2
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            CAPTURE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufSize,
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("AudioRecord 初始化失败（VOICE_RECOGNITION/${CAPTURE_RATE}Hz）")
        }
        actualRate = rec.sampleRate
        if (AGC_ENABLED) {
            try {
                agc = AutomaticGainControl.create(rec.audioSessionId)?.apply { enabled = true }
            } catch (_: Exception) {
                agc = null // 不支持 AGC 的机型：保持关闭即可，不影响采集
            }
        }
        return rec
    }

    /// 按下即起采（§30.3-2 预卷）：只往 400 ms 环形缓冲写，不落盘。
    private fun armRecording() {
        if (audioRecord != null) return
        val rec = openRecorder()
        audioRecord = rec
        rec.startRecording()
        synchronized(recLock) {
            ringBuf = ByteArray(CAPTURE_RATE * 2 * PRE_ROLL_MS / 1000)
            ringFill = 0
            ringPos = 0
        }
        recMode = MODE_ARM
        armed = true
        emitLevel(0.0)
        startCaptureThread()
        val t = Runnable { disarmRecording() }
        armTimeout = t
        mainHandler.postDelayed(t, ARM_TIMEOUT_MS)
    }

    /// 松手/取消：释放 armed 但没进入 start 的采集。幂等。
    private fun disarmRecording() {
        armTimeout?.let { mainHandler.removeCallbacks(it) }
        armTimeout = null
        if (!armed) return
        armed = false
        releaseRecorder()
    }

    private fun releaseRecorder() {
        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        try {
            audioRecord?.release()
        } catch (_: Exception) {
        }
        audioRecord = null
        recordingThread?.join(800)
        recordingThread = null
        synchronized(recLock) {
            ringBuf = null
            ringFill = 0
            ringPos = 0
        }
        try {
            agc?.enabled = false
            agc?.release()
        } catch (_: Exception) {
        }
        agc = null
        recMode = MODE_IDLE
    }

    private fun startRecording(path: String?) {
        if (path == null) throw IllegalArgumentException("path null")
        val dir = File(path).parentFile
        dir?.mkdirs()
        recFile = File(path)

        val fromArm = armed && audioRecord != null
        synchronized(recLock) {
            val out = FileOutputStream(recFile)
            if (fromArm) drainRingTo(out) // 预卷回灌：先写按下到此刻的音频
            recOut = out
        }
        if (fromArm) {
            armTimeout?.let { mainHandler.removeCallbacks(it) }
            armTimeout = null
            armed = false
            recMode = MODE_LIVE
            emitLevel(0.0)
            return
        }
        val rec = openRecorder()
        audioRecord = rec
        rec.startRecording()
        recMode = MODE_LIVE
        synchronized(recLock) {
            ringBuf = null
            ringFill = 0
            ringPos = 0
        }
        emitLevel(0.0)
        startCaptureThread()
    }

    private fun startCaptureThread() {
        val buffer = ByteArray(2048)
        recordingThread = Thread({
            var lastEmit = 0L
            while (audioRecord != null &&
                audioRecord!!.recordingState == AudioRecord.RECORDSTATE_RECORDING
            ) {
                val r = audioRecord!!.read(buffer, 0, buffer.size)
                if (r > 0) {
                    if (recMode == MODE_LIVE) {
                        synchronized(recLock) { recOut?.write(buffer, 0, r) }
                    } else {
                        pushRing(buffer, r) // armed：只进环形缓冲
                    }
                    // 峰值电平（16-bit PCM LE）→ 0..1，节流 ~12 次/秒
                    var peak = 0
                    var i = 0
                    while (i + 1 < r) {
                        val sample = ((buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xFF))
                            .toShort().toInt()
                        val a = abs(sample)
                        if (a > peak) peak = a
                        i += 2
                    }
                    val now = System.currentTimeMillis()
                    if (now - lastEmit >= 80L) {
                        lastEmit = now
                        emitLevel((peak / 32768.0).coerceIn(0.0, 1.0))
                    }
                }
            }
            emitLevel(0.0)
        }, "recorder")
        recordingThread!!.start()
    }

    /** 环形缓冲写入（保留最近 ring.size 字节，供预卷回灌）。 */
    private fun pushRing(buf: ByteArray, n: Int) {
        synchronized(recLock) {
            val ring = ringBuf ?: return
            if (n >= ring.size) {
                System.arraycopy(buf, n - ring.size, ring, 0, ring.size)
                ringFill = ring.size
                ringPos = 0
                return
            }
            var src = 0
            var left = n
            while (left > 0) {
                val take = minOf(left, ring.size - ringPos)
                System.arraycopy(buf, src, ring, ringPos, take)
                ringPos = (ringPos + take) % ring.size
                if (ringFill < ring.size) ringFill = minOf(ring.size, ringFill + take)
                src += take
                left -= take
            }
        }
    }

    /** 按时间顺序把环形缓冲倒进输出流，并清空。 */
    private fun drainRingTo(out: FileOutputStream) {
        synchronized(recLock) {
            val ring = ringBuf ?: return
            if (ringFill == 0) return
            val start = ((ringPos - ringFill) % ring.size + ring.size) % ring.size
            val first = minOf(ringFill, ring.size - start)
            out.write(ring, start, first)
            if (ringFill > first) out.write(ring, 0, ringFill - first)
            ringFill = 0
            ringPos = 0
        }
    }

    private fun stopRecording(): String? {
        try {
            audioRecord?.stop()
            audioRecord?.release()
            audioRecord = null
            recordingThread?.join(1500)
            recordingThread = null
            synchronized(recLock) {
                recOut?.close()
                recOut = null
                ringBuf = null
                ringFill = 0
                ringPos = 0
            }
            try {
                agc?.enabled = false
                agc?.release()
            } catch (_: Exception) {
            }
            agc = null
        } catch (_: Exception) {
            // ignore
        }
        recMode = MODE_IDLE
        armed = false
        val file = recFile ?: return null
        if (!file.exists()) return null
        val raw = file.readBytes()
        // 头里的采样率用**实际**采集率：请求值与实际不符时（个别机型）宁可在
        // Dart 侧解析出来报警，也不写一个自欺的 16000（§30.3-8 三处核对）。
        val header = wavHeader(raw.size, actualRate, 1, 16)
        val out = ByteArray(header.size + raw.size)
        System.arraycopy(header, 0, out, 0, header.size)
        System.arraycopy(raw, 0, out, header.size, raw.size)
        file.writeBytes(out)
        return file.absolutePath
    }

    private fun writeShortLE(dos: DataOutputStream, v: Int) {
        dos.writeByte(v and 0xFF)
        dos.writeByte((v shr 8) and 0xFF)
    }

    // Keystore 里的 AES-256-GCM 密钥永不出设备；这里只搬运 iv||ciphertext 的 Base64。
    private fun llmSecretKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(LLM_KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)
            ?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore"
        )
        gen.init(
            KeyGenParameterSpec.Builder(
                LLM_KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun encryptSecret(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, llmSecretKey())
        val iv = cipher.iv
        val ct = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val buf = ByteArray(iv.size + ct.size)
        System.arraycopy(iv, 0, buf, 0, iv.size)
        System.arraycopy(ct, 0, buf, iv.size, ct.size)
        return Base64.encodeToString(buf, Base64.NO_WRAP)
    }

    private fun decryptSecret(payload: String): String {
        val buf = Base64.decode(payload, Base64.NO_WRAP)
        if (buf.size <= 12) throw IllegalArgumentException("ciphertext too short")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE, llmSecretKey(),
            GCMParameterSpec(128, buf.copyOfRange(0, 12))
        )
        return String(cipher.doFinal(buf.copyOfRange(12, buf.size)), Charsets.UTF_8)
    }

    private fun wavHeader(dataLen: Int, sampleRate: Int, channels: Int, bits: Int): ByteArray {
        val byteRate = sampleRate * channels * bits / 8
        val total = dataLen + 36
        val baos = ByteArrayOutputStream(44)
        val dos = DataOutputStream(baos)
        dos.writeBytes("RIFF")
        dos.writeInt(Integer.reverseBytes(total))
        dos.writeBytes("WAVE")
        dos.writeBytes("fmt ")
        dos.writeInt(Integer.reverseBytes(16))
        writeShortLE(dos, 1)
        writeShortLE(dos, channels)
        dos.writeInt(Integer.reverseBytes(sampleRate))
        dos.writeInt(Integer.reverseBytes(byteRate))
        writeShortLE(dos, channels * bits / 8)
        writeShortLE(dos, bits)
        dos.writeBytes("data")
        dos.writeInt(Integer.reverseBytes(dataLen))
        dos.flush()
        return baos.toByteArray()
    }
}
