package com.chunkspoke.app

import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs

class MainActivity : FlutterActivity() {
    private val UPDATE_CH = "chunkspoke/update"
    private val REC_CH = "chunkspoke/recorder"
    private val LEVEL_CH = "chunkspoke/recorder_level"
    private val POWER_CH = "chunkspoke/power"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var recFile: File? = null
    private var recOut: FileOutputStream? = null
    private var levelSink: EventChannel.EventSink? = null
    private var player: MediaPlayer? = null

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

        // —— 录音通道（16k 单声道 PCM → WAV） ——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, REC_CH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
                    else -> result.notImplemented()
                }
            }

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

    private fun playRecording(path: String?) {
        if (path == null) throw IllegalArgumentException("path null")
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

    private fun startRecording(path: String?) {
        if (path == null) throw IllegalArgumentException("path null")
        val dir = File(path).parentFile
        dir?.mkdirs()
        recFile = File(path)
        recOut = FileOutputStream(recFile)
        val sr = 16000
        val minBuf = AudioRecord.getMinBufferSize(
            sr, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val bufSize = if (minBuf > sr * 2) minBuf else sr * 2
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sr,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufSize,
        )
        audioRecord!!.startRecording()
        emitLevel(0.0)
        val buffer = ByteArray(2048)
        recordingThread = Thread({
            var lastEmit = 0L
            while (audioRecord != null &&
                audioRecord!!.recordingState == AudioRecord.RECORDSTATE_RECORDING
            ) {
                val r = audioRecord!!.read(buffer, 0, buffer.size)
                if (r > 0) {
                    recOut!!.write(buffer, 0, r)
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

    private fun stopRecording(): String {
        try {
            audioRecord?.stop()
            audioRecord?.release()
            audioRecord = null
            recordingThread?.join(1500)
            recOut?.close()
            recOut = null
        } catch (_: Exception) {
            // ignore
        }
        val raw = recFile!!.readBytes()
        val header = wavHeader(raw.size, 16000, 1, 16)
        val out = ByteArray(header.size + raw.size)
        System.arraycopy(header, 0, out, 0, header.size)
        System.arraycopy(raw, 0, out, header.size, raw.size)
        recFile!!.writeBytes(out)
        return recFile!!.absolutePath
    }

    private fun writeShortLE(dos: DataOutputStream, v: Int) {
        dos.writeByte(v and 0xFF)
        dos.writeByte((v shr 8) and 0xFF)
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
