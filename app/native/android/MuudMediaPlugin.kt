package com.muud.edits.media

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
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
                        // 자막·텍스트는 OverlayEffect 번인으로, 사진은 MediaItem
                        // 이미지 입력으로 내보낸다.
                        "supports_text_burn_in" to true,
                        "supports_image_clips" to true,
                        "supports_multi_layer" to false,
                        "sdk_int" to version,
                        "hardware_video_encoders" to codecs,
                        "platform" to "android",
                    )
                )
            }

            // 결과 파일을 갤러리/다운로드에 노출한다(사용자가 폰에서 바로 찾을 수 있게).
            "publishFile" -> {
                val path = call.argument<String>("path")
                val displayName = call.argument<String>("displayName")
                val isVideo = call.argument<Boolean>("isVideo") ?: true
                if (path.isNullOrEmpty()) {
                    result.error("bad_arguments", "path가 필요합니다", null)
                    return
                }
                io.execute {
                    val info = runCatching {
                        publishFile(path, displayName ?: File(path).name, isVideo)
                    }
                    mainHandler.post {
                        info.fold(
                            onSuccess = { result.success(it) },
                            onFailure = {
                                result.success(
                                    mapOf(
                                        "path" to path,
                                        "display_path" to path,
                                        "error" to (it.message ?: "공개 폴더로 복사하지 못했습니다"),
                                    )
                                )
                            },
                        )
                    }
                }
            }

            "shareFile" -> result.success(shareFile(call.argument<String>("path")))

            "openFile" -> result.success(openFile(call.argument<String>("path")))

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

    // ------------------------------------------------------------ 파일 공개

    /**
     * 앱 내부(문서 폴더)에 쓴 결과물을 **사용자가 찾을 수 있는 곳**으로 복사한다.
     *
     * Android 10(API 29)+: MediaStore에 넣어 갤러리/다운로드에 바로 보인다(권한 불필요).
     * Android 8~9(API 26~28): 앱 전용 외부 폴더(Android/data/...)에 둔다.
     *  → 두 경우 모두 content URI(또는 경로)를 돌려주고, UI가 공유/열기 버튼을 띄운다.
     */
    private fun publishFile(
        path: String,
        displayName: String,
        isVideo: Boolean,
    ): Map<String, Any?> {
        val source = File(path)
        require(source.exists()) { "결과 파일이 없습니다: $path" }
        val safeName = displayName.replace('/', '_').replace('\\', '_')

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val relative = if (isVideo) {
                "${Environment.DIRECTORY_MOVIES}/muud-edits"
            } else {
                "${Environment.DIRECTORY_DOWNLOADS}/muud-edits"
            }
            val collection = if (isVideo) {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            }
            val mime = if (isVideo) "video/mp4" else "application/octet-stream"
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("MediaStore에 항목을 만들지 못했습니다")
            try {
                resolver.openOutputStream(uri)?.use { output ->
                    source.inputStream().use { input -> input.copyTo(output) }
                } ?: throw IllegalStateException("출력 스트림을 열지 못했습니다")
                val done = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                resolver.update(uri, done, null, null)
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
            return mapOf(
                "path" to path,
                "uri" to uri.toString(),
                "display_path" to "$relative/$safeName",
                "location" to relative,
            )
        }

        val base = context.getExternalFilesDir(
            if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_DOWNLOADS,
        ) ?: context.filesDir
        val directory = File(base, "muud-edits").apply { mkdirs() }
        val destination = File(directory, safeName)
        source.copyTo(destination, overwrite = true)
        return mapOf(
            "path" to path,
            "display_path" to destination.absolutePath,
            "location" to directory.absolutePath,
        )
    }

    /** 공유 시트. content:// URI만 안전하게 공유한다(API 24+ file:// 금지). */
    private fun shareFile(target: String?): Boolean {
        if (target.isNullOrEmpty()) {
            return false
        }
        return try {
            val uri = toUri(target) ?: return false
            val type = mimeOf(target)
            val intent = Intent(Intent.ACTION_SEND).apply {
                this.type = type
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(intent, "공유")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(chooser)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** 기본 앱으로 열기(플레이어/갤러리). */
    private fun openFile(target: String?): Boolean {
        if (target.isNullOrEmpty()) {
            return false
        }
        return try {
            val uri = toUri(target) ?: return false
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeOf(target))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun toUri(target: String): Uri? {
        if (target.startsWith("content://")) {
            return Uri.parse(target)
        }
        val file = File(target)
        if (!file.exists()) {
            return null
        }
        // 앱 전용 외부 폴더는 FileProvider 없이도 MediaStore URI로 바꿀 수 없으므로
        // 공유는 MediaStore에 들어간 경우(content://)만 지원한다.
        return null
    }

    private fun mimeOf(target: String): String {
        val lower = target.lowercase()
        return when {
            lower.endsWith(".mp4") || lower.endsWith(".m4v") -> "video/mp4"
            lower.endsWith(".mov") -> "video/quicktime"
            lower.endsWith(".mkv") -> "video/x-matroska"
            lower.endsWith(".webm") -> "video/webm"
            else -> "application/octet-stream"
        }
    }
}
