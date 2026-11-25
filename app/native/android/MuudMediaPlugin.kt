package com.muud.edits.media

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Flutter ↔ Android 미디어 채널.
 *
 * 계약(양쪽 동일):
 *  - MethodChannel  "muud_edits/media"           : probe / startExport / cancelExport / thumbnail / platformInfo
 *  - EventChannel   "muud_edits/export_progress" : {event, state, completed_frames, total_frames, message, error}
 *
 * 연결 방법(MainActivity.kt):
 * ```kotlin
 * override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
 *     super.configureFlutterEngine(flutterEngine)
 *     MuudMediaPlugin.registerWith(this, flutterEngine)   // this: Activity(Context)
 * }
 * ```
 */
class MuudMediaPlugin private constructor(
    private val context: Context,
    private val messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "muud_edits/media"
        const val EVENT_CHANNEL = "muud_edits/export_progress"

        // Flutter 3.50의 FlutterEngine 에는 Context getter가 없어 Activity를 함께 받는다.
        @JvmStatic
        fun registerWith(context: Context, engine: FlutterEngine) {
            val messenger = engine.dartExecutor.binaryMessenger
            MuudMediaPlugin(context, messenger).attach(messenger)
        }
    }

    private val io = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val engine = ExportEngine(context)
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private fun attach(messenger: BinaryMessenger) {
        methods = MethodChannel(messenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        events = EventChannel(messenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
        engine.onEvent = { payload ->
            eventSink?.success(payload)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("bad_arguments", "path가 필요합니다", null)
                    return
                }
                io.execute {
                    val info = runCatching { MediaProbe.probe(context, path) }
                    mainHandler.post {
                        info.fold(
                            onSuccess = { result.success(it) },
                            onFailure = { result.error("probe_failed", it.message, null) },
                        )
                    }
                }
            }

            "startExport" -> {
                val graphJson = call.argument<String>("graphJson")
                val outputPath = call.argument<String>("outputPath")
                if (graphJson.isNullOrEmpty() || outputPath.isNullOrEmpty()) {
                    result.error("bad_arguments", "graphJson/outputPath가 필요합니다", null)
                    return
                }
                val started = engine.start(graphJson, outputPath)
                if (started) {
                    result.success(null)
                } else {
                    result.error("export_start_failed", "내보내기를 시작하지 못했습니다", null)
                }
            }

            "cancelExport" -> result.success(engine.cancel())

            "thumbnail" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("bad_arguments", "path가 필요합니다", null)
                    return
                }
                val atMs = (call.argument<Number>("atMs") ?: 0).toLong()
                val maxWidth = (call.argument<Number>("maxWidth") ?: 320).toInt()
                io.execute {
                    val bytes = MediaProbe.thumbnail(path, atMs, maxWidth)
                    mainHandler.post { result.success(bytes) }
                }
            }

            "platformInfo" -> {
                val version = android.os.Build.VERSION.SDK_INT
                val codecs = android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS)
                    .codecInfos
                    .count { it.isEncoder && it.supportedTypes.any { type -> type.startsWith("video/") } }
                result.success(
                    mapOf(
                        "api" to "MediaCodec + MediaMuxer (Media3 Transformer)",
                        "engine" to "androidx.media3.transformer",
                        "supports_export" to true,
                        "supports_text_burn_in" to false,
                        "supports_image_clips" to false,
                        "sdk_int" to version,
                        "hardware_video_encoders" to codecs,
                        "platform" to "android",
                    )
                )
            }

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        events?.setStreamHandler(null)
        methods?.setMethodCallHandler(null)
        engine.release()
        io.shutdown()
    }
}
