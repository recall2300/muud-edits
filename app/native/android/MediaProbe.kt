package com.muud.edits.media

import android.content.Context
import android.media.MediaMetadataRetriever
import android.os.Build
import android.util.Size
import java.io.File
import kotlin.math.abs

/**
 * Android 미디어 메타데이터 프로브.
 *
 * 결과 키는 Rust `MediaProbeInfo`(rust_core/src/probe.rs)와 1:1이다.
 * - `duration_ms`는 정수 ms
 * - `width/height`는 **회전을 적용한 표시 크기** (코어가 그대로 클립에 쓴다)
 * - `fps`는 API 24+에서만 알 수 있다(없으면 생략하거나 0)
 * - 스트림이 하나도 없고 해상도만 있으면 코어가 정지 이미지로 판정한다
 */
object MediaProbe {

    fun probe(context: Context, path: String): Map<String, Any?> {
        val file = File(path)
        require(file.exists()) { "파일을 찾을 수 없습니다: $path" }
        require(file.canRead()) { "파일을 읽을 수 없습니다: $path" }

        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)

            val hasVideo = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
            val hasAudio = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
            val durationMs = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            var width = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 0
            var height = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 0
            val rotation = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0

            // 90/270도 회전이면 표시 크기는 가로/세로가 뒤집힌다.
            if (abs(rotation) % 180 == 90) {
                val swapped = width
                width = height
                height = swapped
            }

            val result = mutableMapOf<String, Any?>(
                "path" to path,
                "duration_ms" to durationMs,
                "width" to width,
                "height" to height,
                "has_video" to hasVideo,
                "has_audio" to hasAudio,
                "rotation_degrees" to rotation,
                "source" to "android-media",
                "probed_at_ms" to System.currentTimeMillis(),
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                retriever.metadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
                    ?.toDoubleOrNull()
                    ?.let { result["fps"] = it }
            }
            retriever.metadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)
                ?.toLongOrNull()
                ?.let { result["bitrate_kbps"] = (it / 1000).toInt() }
            retriever.metadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
                ?.let { result["video_codec"] = it }
            retriever.metadata(MediaMetadataRetriever.METADATA_KEY_AUDIO_CODEC)
                ?.let { result["audio_codec"] = it }

            if (!hasVideo && !hasAudio) {
                // 이미지 파일: BitmapFactory로 크기만 읽는다.
                val size = imageSize(path)
                if (size != null) {
                    result["width"] = size.width
                    result["height"] = size.height
                    result["duration_ms"] = 0
                }
            }

            return result
        } finally {
            runCatching { retriever.release() }
        }
    }

    /** 첫 프레임을 JPEG로. 실패하면 null. */
    fun thumbnail(path: String, atMs: Long, maxWidth: Int): ByteArray? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val timeUs = atMs.coerceAtLeast(0) * 1000
            val raw: android.graphics.Bitmap? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    retriever.getScaledFrameAtTime(
                        timeUs,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        maxWidth,
                        maxWidth * 4,
                    )
                } else {
                    retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                }
            val bitmap = raw ?: return null
            val out = java.io.ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 70, out)
            bitmap.recycle()
            out.toByteArray()
        } catch (_: Exception) {
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun imageSize(path: String): Size? {
        val options = android.graphics.BitmapFactory.Options().apply {
            inJustDecodeBounds = true
        }
        android.graphics.BitmapFactory.decodeFile(path, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) {
            return null
        }
        return Size(options.outWidth, options.outHeight)
    }

    private fun MediaMetadataRetriever.metadata(key: Int): String? =
        runCatching { extractMetadata(key) }.getOrNull()
}
