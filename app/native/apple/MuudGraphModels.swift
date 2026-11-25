//
//  MuudGraphModels.swift
//  muud-edits — Rust `RenderGraph` JSON 디코딩 모델
//
//  계약의 원본은 rust_core/src/render_plan.rs 다. 여기서는 렌더러가 쓰는
//  필드만 디코딩한다(모르는 키는 무시). 정수 시간은 모두 ms다.
//

import Foundation
import CoreMedia

struct MuudCurvePoint: Decodable {
    let atMs: Int64
    let value: Float

    enum CodingKeys: String, CodingKey {
        case atMs = "at_ms"
        case value
    }
}

struct MuudResolution: Decodable {
    let width: Int
    let height: Int
}

struct MuudAnchor: Decodable {
    let x: Float
    let y: Float
}

struct MuudTextOverlay: Decodable {
    let content: String
    let fontFamily: String
    let sizePx: Float
    let color: String
    let background: String?
    let strokePx: Float

    enum CodingKeys: String, CodingKey {
        case content
        case fontFamily = "font_family"
        case sizePx = "size_px"
        case color
        case background
        case strokePx = "stroke_px"
    }
}

struct MuudSegment: Decodable {
    let index: Int
    let layer: Int
    let trackId: String
    let clipId: String
    /// "video" | "image" | "text"
    let kind: String
    let sourcePath: String?
    let sourceInMs: Int64
    let sourceOutMs: Int64
    let timelineStartMs: Int64
    let timelineEndMs: Int64
    let renderStartMs: Int64
    let renderEndMs: Int64
    let frameStart: Int
    let frameEnd: Int
    let speed: Float
    let opacity: Float
    let opacityCurve: [MuudCurvePoint]
    let text: MuudTextOverlay?

    enum CodingKeys: String, CodingKey {
        case index
        case layer
        case trackId = "track_id"
        case clipId = "clip_id"
        case kind
        case sourcePath = "source_path"
        case sourceInMs = "source_in_ms"
        case sourceOutMs = "source_out_ms"
        case timelineStartMs = "timeline_start_ms"
        case timelineEndMs = "timeline_end_ms"
        case renderStartMs = "render_start_ms"
        case renderEndMs = "render_end_ms"
        case frameStart = "frame_start"
        case frameEnd = "frame_end"
        case speed
        case opacity
        case opacityCurve = "opacity_curve"
        case text
    }

    var isText: Bool { kind == "text" }
    var isStillImage: Bool { kind == "image" }
    var renderDurationMs: Int64 { max(1, renderEndMs - renderStartMs) }
}

struct MuudAudioSegment: Decodable {
    let index: Int
    let trackId: String
    let clipId: String
    let sourcePath: String
    let sourceInMs: Int64
    let sourceOutMs: Int64
    let renderStartMs: Int64
    let renderEndMs: Int64
    let speed: Float
    let gain: Float
    let gainCurve: [MuudCurvePoint]
    let muted: Bool
    let fromVideoTrack: Bool
    let hasAudioStream: Bool?

    enum CodingKeys: String, CodingKey {
        case index
        case trackId = "track_id"
        case clipId = "clip_id"
        case sourcePath = "source_path"
        case sourceInMs = "source_in_ms"
        case sourceOutMs = "source_out_ms"
        case renderStartMs = "render_start_ms"
        case renderEndMs = "render_end_ms"
        case speed
        case gain
        case gainCurve = "gain_curve"
        case muted
        case fromVideoTrack = "from_video_track"
        case hasAudioStream = "has_audio_stream"
    }
}

struct MuudSubtitleStyle: Decodable {
    let fontFamily: String
    let sizePx: Float
    let color: String
    let outlineColor: String
    let outlinePx: Float
    let anchor: MuudAnchor?

    enum CodingKeys: String, CodingKey {
        case fontFamily = "font_family"
        case sizePx = "size_px"
        case color
        case outlineColor = "outline_color"
        case outlinePx = "outline_px"
        case anchor
    }
}

struct MuudSubtitleItem: Decodable {
    let id: String
    let text: String
    let renderStartMs: Int64
    let renderEndMs: Int64
    let frameStart: Int
    let frameEnd: Int
    let style: MuudSubtitleStyle?
    /// 코어가 줄바꿈까지 끝낸 표시 문자열.
    let displayText: String

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case renderStartMs = "render_start_ms"
        case renderEndMs = "render_end_ms"
        case frameStart = "frame_start"
        case frameEnd = "frame_end"
        case style
        case displayText = "display_text"
    }
}

struct MuudSubtitles: Decodable {
    let enabled: Bool
    let style: MuudSubtitleStyle
    let items: [MuudSubtitleItem]
}

struct MuudEncoder: Decodable {
    let name: String
    let hardware: Bool
}

struct MuudRenderGraph: Decodable {
    let projectId: String
    let projectName: String
    let platform: String
    let container: String
    let videoCodec: String
    let audioCodec: String
    let encoder: MuudEncoder
    let resolution: MuudResolution
    let fps: Int
    let gopFrames: Int
    let videoBitrateKbps: Int
    let sampleRate: Int
    let durationMs: Int64
    let frameCount: Int
    let segments: [MuudSegment]
    let audioSegments: [MuudAudioSegment]
    let subtitles: MuudSubtitles
    let watermark: Bool
    let graphDigest: String

    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case projectName = "project_name"
        case platform
        case container
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case encoder
        case resolution
        case fps
        case gopFrames = "gop_frames"
        case videoBitrateKbps = "video_bitrate_kbps"
        case sampleRate = "sample_rate"
        case durationMs = "duration_ms"
        case frameCount = "frame_count"
        case segments
        case audioSegments = "audio_segments"
        case subtitles
        case watermark
        case graphDigest = "graph_digest"
    }

    static func decode(json: String) throws -> MuudRenderGraph {
        guard let data = json.data(using: .utf8) else {
            throw MuudExportError.invalidGraph("그래프 문자열을 UTF-8로 읽지 못했습니다")
        }
        do {
            return try JSONDecoder().decode(MuudRenderGraph.self, from: data)
        } catch {
            throw MuudExportError.invalidGraph("렌더 그래프 JSON: \(error)")
        }
    }

    var visibleSegments: [MuudSegment] {
        segments.filter { !$0.isText }
    }

    var fullDuration: CMTime {
        CMTime(value: CMTimeValue(durationMs), timescale: 1000)
    }
}

/// 커브 보간. 코어(`render_plan::curve_value_at`)와 같은 규칙(양 끝 고정, 선형).
enum MuudCurve {
    static func value(_ curve: [MuudCurvePoint], atMs: Int64) -> Float {
        guard let first = curve.first else { return 1 }
        if atMs <= first.atMs { return first.value }
        guard let last = curve.last else { return first.value }
        if atMs >= last.atMs { return last.value }
        for index in 0..<(curve.count - 1) {
            let a = curve[index]
            let b = curve[index + 1]
            if atMs >= a.atMs && atMs <= b.atMs {
                let span = Float(max(1, b.atMs - a.atMs))
                let t = Float(atMs - a.atMs) / span
                return a.value + (b.value - a.value) * t
            }
        }
        return last.value
    }
}

extension MuudSegment {
    func opacity(atRenderMs renderMs: Int64) -> Float {
        MuudCurve.value(opacityCurve, atMs: renderMs - renderStartMs)
    }
}

extension MuudAudioSegment {
    func gain(atRenderMs renderMs: Int64) -> Float {
        muted ? 0 : MuudCurve.value(gainCurve, atMs: renderMs - renderStartMs)
    }
}

enum MuudExportError: LocalizedError {
    case invalidGraph(String)
    case unsupported(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidGraph(let detail):
            return "렌더 그래프가 올바르지 않습니다: \(detail)"
        case .unsupported(let detail):
            return "이 플랫폼에서 아직 지원하지 않는 기능입니다: \(detail)"
        case .exportFailed(let detail):
            return "내보내기에 실패했습니다: \(detail)"
        }
    }
}
