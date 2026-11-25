package com.muud.edits.media

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Android 렌더/인코딩 파이프라인 — Media3 `Transformer` 기반.
 *
 * Rust 코어의 `RenderGraph`를 그대로 받아:
 *  - 영상 세그먼트를 순서대로 concat (trim + speed)
 *  - 오디오 세그먼트를 별도 sequence로 합성 (trim + speed)
 *  - H.264/AAC MP4로 하드웨어 인코딩
 *  - 진행률(프레임)과 취소를 Flutter 이벤트 채널로 전달
 *
 * Media3 Transformer를 쓰는 이유:
 *  - MediaCodec/MediaMuxer를 직접 다루면 timestamp 재매핑, 오디오 리샘플링,
 *    surface 수명 관리가 전부 애플리케이션 몫이 된다. Transformer는 이 경로를
 *    이미 하드웨어 가속으로 구현해 두었다.
 *  - 다중 레이어 합성은 `OverlayEffect`로 확장할 수 있다(v1에서는 미구현, 아래 참고).
 *
 * v1 한계(README/보고서에 명시):
 *  - 텍스트 클립·자막 번인은 아직 그리지 않는다(그래프에 있으면 경고 이벤트를 보낸다).
 *  - 정지 이미지 클립은 거부한다.
 *  - 레이어 2개 이상의 동시 합성은 지원하지 않는다(첫 레이어만 렌더).
 */
@OptIn(UnstableApi::class)
class ExportEngine(private val context: Context) {

    var onEvent: ((Map<String, Any?>) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private var transformer: Transformer? = null
    private var progressRunnable: Runnable? = null
    private var totalFrames: Int = 0
    @Volatile private var canceled = false

    fun start(graphJson: String, outputPath: String): Boolean {
        canceled = false
        return try {
            val graph = JSONObject(graphJson)
            validate(graph)
            totalFrames = graph.optInt("frame_count", 0)
            emit(mapOf("event" to "stage", "state" to "preparing"))

            val videoItems = buildVideoItems(graph)
            if (videoItems.isEmpty()) {
                emit(
                    mapOf(
                        "event" to "failed",
                        "state" to "failed",
                        "error" to "렌더할 영상 세그먼트가 없습니다",
                    )
                )
                return false
            }
            val audioItems = buildAudioItems(graph)

            executor.execute {
                try {
                    runTransformer(videoItems, audioItems, outputPath)
                } catch (error: Exception) {
                    emit(
                        mapOf(
                            "event" to "failed",
                            "state" to "failed",
                            "message" to (error.message ?: "내보내기 실패"),
                            "error" to (error.message ?: error.toString()),
                        )
                    )
                }
            }
            true
        } catch (error: Exception) {
            emit(
                mapOf(
                    "event" to "failed",
                    "state" to "failed",
                    "message" to (error.message ?: "렌더 그래프 오류"),
                    "error" to (error.message ?: error.toString()),
                )
            )
            false
        }
    }

    /** 취소 요청. 실제 정리는 `canceled` 이벤트로 확인된다. */
    fun cancel(): Boolean {
        val active = transformer ?: return false
        canceled = true
        mainHandler.post { active.cancel() }
        return true
    }

    fun release() {
        stopProgressLoop()
        transformer?.cancel()
        transformer = null
        executor.shutdown()
    }

    // ------------------------------------------------------------------ build

    private fun validate(graph: JSONObject) {
        require(!graph.optBoolean("watermark", false)) { "워터마크가 있는 그래프는 렌더하지 않습니다" }
        val container = graph.optString("container", "mp4")
        require(container == "mp4") { "Android는 MP4만 출력합니다(요청: $container)" }
        val segments = graph.optJSONArray("segments") ?: return
        for (index in 0 until segments.length()) {
            val segment = segments.getJSONObject(index)
            if (segment.optString("kind") == "image") {
                throw UnsupportedOperationException("정지 이미지 클립은 Android v1에서 지원하지 않습니다")
            }
        }
        if (graph.optJSONObject("subtitles")?.optBoolean("enabled", false) == true) {
            val items = graph.optJSONObject("subtitles")?.optJSONArray("items")
            if (items != null && items.length() > 0) {
                emit(
                    mapOf(
                        "event" to "progress",
                        "state" to "rendering",
                        "message" to "자막 번인은 Android v1에서 지원하지 않아 자막 없이 내보냅니다",
                        "completed_frames" to 0,
                    )
                )
            }
        }
    }

    private fun buildVideoItems(graph: JSONObject): List<EditedMediaItem> {
        val result = mutableListOf<EditedMediaItem>()
        val segments = graph.optJSONArray("segments") ?: return result
        val layers = mutableSetOf<Int>()
        for (index in 0 until segments.length()) {
            val segment = segments.getJSONObject(index)
            val kind = segment.optString("kind")
            if (kind != "video") {
                continue
            }
            val layer = segment.optInt("layer", 0)
            if (layers.isNotEmpty() && !layers.contains(layer)) {
                // v1: 여러 레이어의 동시 합성은 미지원. 첫 레이어만 렌더한다.
                continue
            }
            layers.add(layer)
            val path = segment.optString("source_path", "")
            if (path.isEmpty() || !File(path).exists()) {
                throw IllegalArgumentException("소스 파일이 없습니다: $path")
            }
            result.add(
                buildItem(
                    path = path,
                    startMs = segment.optLong("source_in_ms", 0),
                    endMs = segment.optLong("source_out_ms", 0),
                    speed = segment.optDouble("speed", 1.0).toFloat(),
                    removeAudio = true,
                    removeVideo = false,
                )
            )
        }
        return result
    }

    private fun buildAudioItems(graph: JSONObject): List<EditedMediaItem> {
        val result = mutableListOf<EditedMediaItem>()
        val segments = graph.optJSONArray("audio_segments") ?: return result
        for (index in 0 until segments.length()) {
            val segment = segments.getJSONObject(index)
            if (segment.optBoolean("muted", false)) {
                continue
            }
            val path = segment.optString("source_path", "")
            if (path.isEmpty() || !File(path).exists()) {
                continue
            }
            result.add(
                buildItem(
                    path = path,
                    startMs = segment.optLong("source_in_ms", 0),
                    endMs = segment.optLong("source_out_ms", 0),
                    speed = segment.optDouble("speed", 1.0).toFloat(),
                    removeAudio = false,
                    // 소리만 쓰는 시퀀스다. 영상을 남기면 컴포지션에 비디오
                    // 시퀀스가 둘이 되어 Transformer가 거부한다.
                    removeVideo = true,
                )
            )
        }
        return result
    }

    private fun buildItem(
        path: String,
        startMs: Long,
        endMs: Long,
        speed: Float,
        removeAudio: Boolean,
        removeVideo: Boolean,
    ): EditedMediaItem {
        val mediaItem = MediaItem.Builder()
            .setUri(File(path).toURI().toString())
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(startMs.coerceAtLeast(0))
                    .setEndPositionMs(endMs.coerceAtLeast(startMs + 1))
                    .build()
            )
            .build()

        val builder = EditedMediaItem.Builder(mediaItem)
        if (removeAudio) {
            builder.setRemoveAudio(true)
        }
        if (removeVideo) {
            builder.setRemoveVideo(true)
        }
        // 배속: 영상은 SpeedChangeEffect, 소리는 SonicAudioProcessor로 같은 배속을
        // 적용해야 음성 피치와 길이가 함께 맞는다(둘 중 하나만 적용하면 싱크가 어긋난다).
        if (speed > 0f && kotlin.math.abs(speed - 1f) > 0.01f) {
            val audioProcessors = if (removeAudio) {
                emptyList<androidx.media3.common.audio.AudioProcessor>()
            } else {
                listOf<androidx.media3.common.audio.AudioProcessor>(
                    androidx.media3.common.audio.SonicAudioProcessor().apply { setSpeed(speed) }
                )
            }
            val videoEffects = if (removeVideo) {
                emptyList<androidx.media3.common.Effect>()
            } else {
                listOf<androidx.media3.common.Effect>(
                    androidx.media3.effect.SpeedChangeEffect(speed)
                )
            }
            builder.setEffects(androidx.media3.transformer.Effects(audioProcessors, videoEffects))
        }
        return builder.build()
    }

    // ------------------------------------------------------------------ run

    private fun runTransformer(
        videoItems: List<EditedMediaItem>,
        audioItems: List<EditedMediaItem>,
        outputPath: String,
    ) {
        val outputFile = File(outputPath)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) {
            outputFile.delete()
        }

        val sequences = mutableListOf(
            EditedMediaItemSequence.Builder(videoItems).build()
        )
        if (audioItems.isNotEmpty()) {
            sequences.add(EditedMediaItemSequence.Builder(audioItems).build())
        }
        val composition = Composition.Builder(sequences).build()

        val listener = object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                stopProgressLoop()
                emit(
                    mapOf(
                        "event" to "completed",
                        "state" to "completed",
                        "completed_frames" to totalFrames,
                        "total_frames" to totalFrames,
                        "message" to outputPath,
                    )
                )
                transformer = null
            }

            override fun onError(
                composition: Composition,
                exportResult: ExportResult,
                exportException: ExportException,
            ) {
                stopProgressLoop()
                if (canceled) {
                    emit(mapOf("event" to "canceled", "state" to "canceled"))
                } else {
                    val detail = buildString {
                        append(exportException.message ?: "내보내기에 실패했습니다")
                        append(" (")
                        append(ExportException.getErrorCodeName(exportException.errorCode))
                        append(")")
                    }
                    emit(
                        mapOf(
                            "event" to "failed",
                            "state" to "failed",
                            "message" to detail,
                            "error" to detail,
                        )
                    )
                }
                transformer = null
            }
        }

        val active = Transformer.Builder(context)
            .addListener(listener)
            .build()
        transformer = active
        mainHandler.post {
            emit(mapOf("event" to "stage", "state" to "rendering"))
            startProgressLoop(active)
        }
        active.start(composition, outputPath)
    }

    // ------------------------------------------------------------------ progress

    private fun startProgressLoop(active: Transformer) {
        stopProgressLoop()
        val holder = ProgressHolder()
        val runnable = object : Runnable {
            override fun run() {
                // Transformer.getProgress()는 @ProgressState int를 돌려준다(1.5.x).
                val progressState = active.getProgress(holder)
                val percent = if (progressState == Transformer.PROGRESS_STATE_AVAILABLE) {
                    holder.progress
                } else {
                    -1
                }
                if (percent >= 0) {
                    val completed = (totalFrames * percent / 100f).toInt()
                    emit(
                        mapOf(
                            "event" to "progress",
                            "state" to "rendering",
                            "completed_frames" to completed.coerceIn(0, totalFrames),
                            "total_frames" to totalFrames,
                        )
                    )
                }
                if (transformer === active) {
                    mainHandler.postDelayed(this, 200)
                }
            }
        }
        progressRunnable = runnable
        mainHandler.postDelayed(runnable, 200)
    }

    private fun stopProgressLoop() {
        progressRunnable?.let { mainHandler.removeCallbacks(it) }
        progressRunnable = null
    }

    private fun emit(payload: Map<String, Any?>) {
        mainHandler.post { onEvent?.invoke(payload) }
    }
}
