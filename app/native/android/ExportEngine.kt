package com.muud.edits.media

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.SpeedChangeEffect
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.abs

/**
 * Android 렌더/인코딩 파이프라인 — Media3 `Transformer` 기반.
 *
 * Rust 코어의 `RenderGraph`를 그대로 받아:
 *  - 맨 아래 비디오 트랙의 영상·사진 세그먼트를 시간 순서대로 합성(concat)
 *  - 세그먼트 사이의 빈 구간은 Media3 `addGap`(검은 화면 + 무음)으로 채워
 *    영상·오디오·자막 싱크를 유지
 *  - 오디오 트랙은 레인(겹치지 않는 그룹)별 시퀀스로 만들어 **출력 시각 위치에**
 *    배치하고, 여러 레인이면 Media3가 믹싱
 *  - 자막·텍스트 클립은 `BitmapOverlay` + `OverlayEffect`로 프레임 위에 번인(burn-in)
 *  - H.264/AAC MP4로 하드웨어 인코딩
 *  - 진행률(프레임)과 취소를 Flutter 이벤트 채널로 전달
 *
 * 남은 한계(README/보고서에 명시):
 *  - 위쪽 레이어(오버레이 트랙)의 **영상/이미지** 클립은 아직 합성하지 않는다.
 *    텍스트 클립과 자막은 레이어와 무관하게 번인한다.
 */
@OptIn(UnstableApi::class)
class ExportEngine(private val context: Context) {

    var onEvent: ((Map<String, Any?>) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private var transformer: Transformer? = null
    private var progressRunnable: Runnable? = null
    private var totalFrames: Int = 0
    private val textBitmaps = TextBitmapCache()

    @Volatile private var canceled = false

    fun start(graphJson: String, outputPath: String): Boolean {
        canceled = false
        return try {
            val graph = JSONObject(graphJson)
            totalFrames = graph.optInt("frame_count", 0)
            validate(graph)
            emit(mapOf("event" to "stage", "state" to "preparing"))

            val composition = buildComposition(graph)
            if (composition == null) {
                emit(
                    mapOf(
                        "event" to "failed",
                        "state" to "failed",
                        "error" to "렌더할 영상 세그먼트가 없습니다",
                    )
                )
                return false
            }

            executor.execute {
                try {
                    runTransformer(composition, outputPath)
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

    // ------------------------------------------------------------------ 검증

    private fun validate(graph: JSONObject) {
        require(!graph.optBoolean("watermark", false)) { "워터마크가 있는 그래프는 렌더하지 않습니다" }
        val container = graph.optString("container", "mp4")
        require(container == "mp4") { "Android는 MP4만 출력합니다(요청: $container)" }

        val segments = graph.optJSONArray("segments").toObjectList()
        val baseLayer = baseVisualLayer(segments)
        val droppedLayers = segments
            .filter {
                val kind = it.optString("kind", "")
                (kind == "video" || kind == "image") && it.optInt("layer", 0) != baseLayer
            }
        if (droppedLayers.isNotEmpty()) {
            emit(
                mapOf(
                    "event" to "progress",
                    "state" to "preparing",
                    "completed_frames" to 0,
                    "total_frames" to totalFrames,
                    "message" to "위 레이어의 영상 ${droppedLayers.size}개는 이번 Android 내보내기에서 합성하지 않습니다",
                )
            )
        }
        val images = segments.count { it.optString("kind", "") == "image" }
        if (images > 0) {
            emit(
                mapOf(
                    "event" to "progress",
                    "state" to "preparing",
                    "completed_frames" to 0,
                    "total_frames" to totalFrames,
                    "message" to "사진 클립 ${images}개를 포함해 내보냅니다",
                )
            )
        }
    }

    // ------------------------------------------------------------- composition

    private fun buildComposition(graph: JSONObject): Composition? {
        val fps = graph.optInt("fps", 30).coerceAtLeast(1)
        val durationMs = graph.optLong("duration_ms", 0L).coerceAtLeast(0L)
        val resolution = graph.optJSONObject("resolution")
        val frameWidth = resolution?.optInt("width", 1080)?.takeIf { it > 0 } ?: 1080
        val frameHeight = resolution?.optInt("height", 1920)?.takeIf { it > 0 } ?: 1920

        val segments = graph.optJSONArray("segments").toObjectList()
        val baseLayer = baseVisualLayer(segments)
        val visualSegments = segments
            .filter {
                val kind = it.optString("kind", "")
                (kind == "video" || kind == "image") && it.optInt("layer", 0) == baseLayer
            }
            .sortedBy { it.optLong("render_start_ms", 0L) }
        if (visualSegments.isEmpty()) {
            return null
        }

        val overlays = collectOverlays(graph, segments)

        // ---- 영상 시퀀스: 세그먼트 + 빈 구간(검은 화면) ----
        val videoSequence = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO))
        var cursor = 0L
        for (segment in visualSegments) {
            val start = segment.optLong("render_start_ms", 0L).coerceAtLeast(0L)
            if (start > cursor) {
                videoSequence.addGap(msToUs(start - cursor))
                cursor = start
            }
            videoSequence.addItem(
                buildVisualItem(segment, overlays, fps, frameWidth, frameHeight)
            )
            cursor = maxOf(cursor, segment.optLong("render_end_ms", cursor))
        }
        if (durationMs > cursor) {
            videoSequence.addGap(msToUs(durationMs - cursor))
        }

        val sequences = mutableListOf(videoSequence.build())
        sequences.addAll(buildAudioSequences(graph, durationMs))
        return Composition.Builder(sequences).build()
    }

    /** 렌더 기준이 되는 레이어: 영상/이미지가 있는 가장 아래 레이어. */
    private fun baseVisualLayer(segments: List<JSONObject>): Int {
        var layer = -1
        for (segment in segments) {
            val kind = segment.optString("kind", "")
            if (kind != "video" && kind != "image") continue
            val value = segment.optInt("layer", 0)
            if (layer < 0 || value < layer) layer = value
        }
        return if (layer < 0) 0 else layer
    }

    private fun buildVisualItem(
        segment: JSONObject,
        overlays: List<OverlayWindow>,
        fps: Int,
        frameWidth: Int,
        frameHeight: Int,
    ): EditedMediaItem {
        val kind = segment.optString("kind", "video")
        val path = segment.optString("source_path", "")
        if (path.isEmpty() || !File(path).exists()) {
            throw IllegalArgumentException("소스 파일이 없습니다: $path")
        }
        val start = segment.optLong("render_start_ms", 0L).coerceAtLeast(0L)
        val end = segment.optLong("render_end_ms", start).coerceAtLeast(start + 1)
        val durationMs = end - start
        val speed = segment.optDouble("speed", 1.0).toFloat().let { if (it <= 0f) 1f else it }

        val mediaItemBuilder = MediaItem.Builder()
            .setUri(File(path).toURI().toString())
        val audioProcessors = mutableListOf<AudioProcessor>()
        val videoEffects = mutableListOf<Effect>()
        val itemBuilder: EditedMediaItem.Builder

        if (kind == "image") {
            // 사진: 길이를 직접 주고 프레임률을 지정해야 Transformer가 프레임을 만든다.
            mediaItemBuilder.setImageDurationMs(durationMs)
            itemBuilder = EditedMediaItem.Builder(mediaItemBuilder.build()).setFrameRate(fps)
        } else {
            val inMs = segment.optLong("source_in_ms", 0L).coerceAtLeast(0L)
            val outMs = segment.optLong("source_out_ms", inMs + durationMs)
                .coerceAtLeast(inMs + 1)
            mediaItemBuilder.setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(inMs)
                    .setEndPositionMs(outMs)
                    .build()
            )
            // 영상 트랙의 소리는 오디오 시퀀스가 따로 맡는다(중복 재생 방지).
            itemBuilder = EditedMediaItem.Builder(mediaItemBuilder.build()).setRemoveAudio(true)
            if (abs(speed - 1f) > 0.01f) {
                videoEffects.add(SpeedChangeEffect(speed))
            }
        }

        // 이 세그먼트 구간에 걸치는 자막·텍스트를 프레임 위에 굽는다.
        val active = overlays.filter { it.endMs > start && it.startMs < end }
        if (active.isNotEmpty()) {
            val textureOverlays = mutableListOf<TextureOverlay>()
            for (overlay in active) {
                textureOverlays.add(
                    TimedTextOverlay(
                        spec = overlay.spec,
                        localStartMs = overlay.startMs - start,
                        localEndMs = overlay.endMs - start,
                        frameWidth = frameWidth,
                        frameHeight = frameHeight,
                        cache = textBitmaps,
                    )
                )
            }
            // 배속(SpeedChangeEffect)이 타임스탬프를 먼저 바꾸므로, 오버레이는
            // 출력 타임라인 기준으로 그 뒤에 둔다.
            videoEffects.add(OverlayEffect(textureOverlays))
        }

        if (audioProcessors.isNotEmpty() || videoEffects.isNotEmpty()) {
            itemBuilder.setEffects(Effects(audioProcessors, videoEffects))
        }
        return itemBuilder.build()
    }

    /**
     * 오디오 시퀀스 묶음.
     *
     * 시퀀스 하나는 **순차** 재생이므로, 겹치는 오디오 클립은 레인을 나눠 각각의
     * 시퀀스로 만들고 Media3가 믹싱하게 한다. 각 레인은 시작 전/사이/끝의 빈 구간을
     * `addGap`(무음)으로 채워 출력 시각 위치를 정확히 맞춘다.
     */
    private fun buildAudioSequences(
        graph: JSONObject,
        durationMs: Long,
    ): List<EditedMediaItemSequence> {
        val specs = graph.optJSONArray("audio_segments").toObjectList()
            .filter { !it.optBoolean("muted", false) }
            .filter {
                val path = it.optString("source_path", "")
                path.isNotEmpty() && File(path).exists()
            }
            .sortedBy { it.optLong("render_start_ms", 0L) }
        if (specs.isEmpty()) {
            return emptyList()
        }

        val lanes = mutableListOf<MutableList<JSONObject>>()
        val laneEnds = mutableListOf<Long>()
        for (spec in specs) {
            val start = spec.optLong("render_start_ms", 0L).coerceAtLeast(0L)
            val end = spec.optLong("render_end_ms", start)
            var placed = false
            for (index in lanes.indices) {
                if (laneEnds[index] <= start) {
                    lanes[index].add(spec)
                    laneEnds[index] = end
                    placed = true
                    break
                }
            }
            if (!placed) {
                lanes.add(mutableListOf(spec))
                laneEnds.add(end)
            }
        }

        return lanes.map { lane ->
            val builder = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
            var cursor = 0L
            for (spec in lane) {
                val start = spec.optLong("render_start_ms", 0L).coerceAtLeast(0L)
                if (start > cursor) {
                    builder.addGap(msToUs(start - cursor))
                    cursor = start
                }
                builder.addItem(buildAudioItem(spec))
                cursor = maxOf(cursor, spec.optLong("render_end_ms", cursor))
            }
            if (durationMs > cursor) {
                builder.addGap(msToUs(durationMs - cursor))
            }
            builder.build()
        }
    }

    private fun buildAudioItem(segment: JSONObject): EditedMediaItem {
        val path = segment.optString("source_path", "")
        val inMs = segment.optLong("source_in_ms", 0L).coerceAtLeast(0L)
        val outMs = segment.optLong("source_out_ms", inMs + 1).coerceAtLeast(inMs + 1)
        val speed = segment.optDouble("speed", 1.0).toFloat().let { if (it <= 0f) 1f else it }
        val gain = segment.optDouble("gain", 1.0).toFloat().let { it.coerceIn(0f, 4f) }

        val mediaItem = MediaItem.Builder()
            .setUri(File(path).toURI().toString())
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(inMs)
                    .setEndPositionMs(outMs)
                    .build()
            )
            .build()

        // 소리만 쓰는 시퀀스다. 영상을 남기면 컴포지션에 비디오 시퀀스가 둘이 되어
        // Transformer가 거부한다.
        val builder = EditedMediaItem.Builder(mediaItem).setRemoveVideo(true)

        val audioProcessors = mutableListOf<AudioProcessor>()
        // 배속: 음성 피치와 길이를 함께 맞춘다.
        if (abs(speed - 1f) > 0.01f) {
            audioProcessors.add(SonicAudioProcessor().apply { setSpeed(speed) })
        }
        // 게인(0.0 ~ 2.0): muted 만이 아니라 실제 볼륨 값을 반영한다.
        if (abs(gain - 1f) > 0.01f) {
            audioProcessors.add(GainAudioProcessor(gain))
        }
        if (audioProcessors.isNotEmpty()) {
            builder.setEffects(Effects(audioProcessors, emptyList()))
        }
        return builder.build()
    }

    // --------------------------------------------------------------- 오버레이

    /** 자막·텍스트 클립을 시간 창과 스타일로 모은다(레이어 무관). */
    private fun collectOverlays(
        graph: JSONObject,
        segments: List<JSONObject>,
    ): List<OverlayWindow> {
        val overlays = mutableListOf<OverlayWindow>()

        val subtitles = graph.optJSONObject("subtitles")
        if (subtitles != null && subtitles.optBoolean("enabled", false)) {
            val trackStyle = subtitles.optJSONObject("style")
            for (item in subtitles.optJSONArray("items").toObjectList()) {
                val text = item.optString("display_text", "").ifEmpty {
                    item.optString("text", "")
                }
                if (text.trim().isEmpty()) continue
                val style = item.optJSONObject("style") ?: trackStyle
                val start = item.optLong("render_start_ms", 0L)
                val end = item.optLong("render_end_ms", start)
                if (end <= start) continue
                overlays.add(
                    OverlayWindow(
                        spec = textSpec(
                            text = text,
                            style = style,
                            defaultSizePx = 56f,
                        ),
                        startMs = start,
                        endMs = end,
                    )
                )
            }
        }

        for (segment in segments) {
            if (segment.optString("kind", "") != "text") continue
            val text = segment.optJSONObject("text") ?: continue
            val content = text.optString("content", "")
            if (content.trim().isEmpty()) continue
            val start = segment.optLong("render_start_ms", 0L)
            val end = segment.optLong("render_end_ms", start)
            if (end <= start) continue
            overlays.add(
                OverlayWindow(
                    spec = textSpec(
                        text = content,
                        style = text,
                        defaultSizePx = 64f,
                    ),
                    startMs = start,
                    endMs = end,
                )
            )
        }
        return overlays
    }

    private fun textSpec(
        text: String,
        style: JSONObject?,
        defaultSizePx: Float,
    ): TextSpec {
        val sizePx = style?.optDouble("size_px", defaultSizePx.toDouble())?.toFloat()
            ?.takeIf { it > 1f } ?: defaultSizePx
        val color = parseColor(style?.optString("color", "")) ?: Color.WHITE
        val anchor = style?.optJSONObject("anchor")
        val anchorX = anchor?.optDouble("x", 0.5)?.toFloat() ?: 0.5f
        val anchorY = anchor?.optDouble("y", 0.82)?.toFloat() ?: 0.82f
        return TextSpec(
            text = text,
            sizePx = sizePx,
            color = color,
            anchorX = anchorX.coerceIn(0f, 1f),
            anchorY = anchorY.coerceIn(0f, 1f),
        )
    }

    // ------------------------------------------------------------------ run

    private fun runTransformer(composition: Composition, outputPath: String) {
        val outputFile = File(outputPath)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) {
            outputFile.delete()
        }

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
                // Transformer.getProgress()는 @ProgressState int를 돌려준다.
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

// -----------------------------------------------------------------------------
// 헬퍼 (composable 아님 — 순수 함수/클래스)
// -----------------------------------------------------------------------------

private fun JSONArray?.toObjectList(): List<JSONObject> {
    if (this == null) return emptyList()
    val result = ArrayList<JSONObject>(length())
    for (index in 0 until length()) {
        optJSONObject(index)?.let { result.add(it) }
    }
    return result
}

private fun msToUs(ms: Long): Long = if (ms < 0) 0L else ms * 1000L

private fun parseColor(value: String?): Int? {
    if (value.isNullOrBlank()) return null
    return try {
        Color.parseColor(value)
    } catch (_: IllegalArgumentException) {
        null
    }
}

/** 시간 창이 있는 텍스트 한 줄(자막/텍스트 클립). */
private data class OverlayWindow(
    val spec: TextSpec,
    val startMs: Long,
    val endMs: Long,
)

/** 그릴 텍스트와 스타일(정규화 좌표 0~1). */
private data class TextSpec(
    val text: String,
    val sizePx: Float,
    val color: Int,
    val anchorX: Float,
    val anchorY: Float,
) {
    fun key(width: Int, height: Int): String =
        "$text|$sizePx|$color|$anchorX|$anchorY|${width}x$height"
}

/**
 * 시간 창 안에서만 보이는 텍스트 오버레이.
 *
 * Media3의 `OverlayEffect`는 아이템 전체에 걸리므로, 창 밖에서는 1×1 투명
 * 비트맵을 돌려주어 아무것도 그리지 않는다(투명 프레임).
 */
@OptIn(UnstableApi::class)
private class TimedTextOverlay(
    private val spec: TextSpec,
    private val localStartMs: Long,
    private val localEndMs: Long,
    private val frameWidth: Int,
    private val frameHeight: Int,
    private val cache: TextBitmapCache,
) : BitmapOverlay() {

    private val blank: Bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)

    override fun getBitmap(presentationTimeUs: Long): Bitmap {
        val ms = presentationTimeUs / 1000L
        if (ms < localStartMs || ms >= localEndMs) {
            return blank
        }
        return cache.bitmap(spec, frameWidth, frameHeight)
    }
}

/** 그린 텍스트 비트맵을 문구/스타일별로 재사용한다(아이템이 여러 개여도 한 번만 그린다). */
private class TextBitmapCache {

    private val entries = object : LinkedHashMap<String, Bitmap>(8, 0.75f, true) {
        override fun removeEldestEntry(
            eldest: MutableMap.MutableEntry<String, Bitmap>?,
        ): Boolean = size > maxEntries
    }

    fun bitmap(spec: TextSpec, width: Int, height: Int): Bitmap {
        val key = spec.key(width, height)
        entries[key]?.let { return it }
        val drawn = drawTextBitmap(spec, width, height)
        entries[key] = drawn
        return drawn
    }

    private companion object {
        const val maxEntries = 6
    }
}

/** 프레임 크기의 투명 비트맵에 문구를 그린다(번인용). */
private fun drawTextBitmap(spec: TextSpec, width: Int, height: Int): Bitmap {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    // 1080×1920 기준으로 저장된 px 값을 현재 프레임 높이에 맞춰 환산한다.
    val scale = height / 1920f
    val textSize = (spec.sizePx * scale).coerceAtLeast(8f)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG)
    paint.color = spec.color
    paint.textSize = textSize
    paint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    paint.textAlign = Paint.Align.CENTER
    paint.setShadowLayer(textSize * 0.12f, 0f, textSize * 0.06f, Color.BLACK)

    val lines = wrapLines(spec.text, paint, width * 0.86f)
    val lineHeight = textSize * 1.25f
    val blockHeight = lineHeight * lines.size
    var baseline = height * spec.anchorY - blockHeight / 2f + textSize
    for (line in lines) {
        canvas.drawText(line, width * spec.anchorX, baseline, paint)
        baseline += lineHeight
    }
    return bitmap
}

/** 공백 단위 줄바꿈(폭 초과 시). 빈 줄은 건너뛴다. */
private fun wrapLines(text: String, paint: Paint, maxWidth: Float): List<String> {
    val lines = mutableListOf<String>()
    for (paragraph in text.replace("\r", "").split('\n')) {
        val words = paragraph.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) continue
        var current = ""
        for (word in words) {
            val candidate = if (current.isEmpty()) word else "$current $word"
            if (current.isNotEmpty() && paint.measureText(candidate) > maxWidth) {
                lines.add(current)
                current = word
            } else {
                current = candidate
            }
        }
        if (current.isNotEmpty()) lines.add(current)
    }
    return if (lines.isEmpty()) listOf(text) else lines
}

/**
 * 고정 게인(0.0 ~ 4.0) 오디오 프로세서.
 *
 * Media3의 `GainProcessor`는 게인을 0~1로 다루지만, 이 앱의 클립 볼륨은 2.0까지
 * 올릴 수 있어 1을 넘는 값을 그대로 반영하려면 직접 곱해야 한다(PCM16 포화).
 */
@OptIn(UnstableApi::class)
private class GainAudioProcessor(private val gain: Float) : BaseAudioProcessor() {

    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        // 16비트 PCM만 처리한다. 다른 포맷이면 비활성(NOT_SET)으로 두고 통과시킨다.
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            return AudioFormat.NOT_SET
        }
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val position = inputBuffer.position()
        val limit = inputBuffer.limit()
        val output = replaceOutputBuffer(limit - position)
        val factor = gain.coerceAtLeast(0f)
        inputBuffer.order(java.nio.ByteOrder.nativeOrder())
        while (inputBuffer.position() + 1 < inputBuffer.limit()) {
            val sample = inputBuffer.short.toInt()
            val scaled = Math.round(sample * factor).coerceIn(-32768, 32767)
            output.putShort(scaled.toShort())
        }
        inputBuffer.position(limit)
        output.flip()
    }
}
