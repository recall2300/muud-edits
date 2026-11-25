//
//  AVExportEngine.swift
//  muud-edits — AVFoundation 기반 렌더/인코딩 파이프라인 (macOS / iOS)
//
//  입력: Rust 코어가 만든 **결정적 렌더 그래프**(JSON).
//  출력: MP4/MOV(H.264/HEVC/ProRes), AAC 오디오, 자막/텍스트 번인.
//
//  구조
//   1) AVMutableComposition      : 세그먼트를 타임라인 위치에 삽입(trim/speed)
//   2) AVMutableVideoComposition : 레이어 합성·불투명도 커브·화면 맞춤
//   3) AVMutableAudioMix         : 세그먼트별 볼륨/페이드 커브
//   4) Core Animation overlay    : 텍스트 클립 + 자막 번인
//   5) AVAssetExportSession      : VideoToolbox 하드웨어 인코딩 + 진행률/취소
//
//  한계(v1, README에 명시):
//   * 정지 이미지 클립은 아직 렌더하지 않는다(코어 모델에는 있음).
//   * WebM 출력은 AVFoundation이 지원하지 않아 거부한다.
//   * 여러 비디오 레이어는 프레임 단위 합성 대신 AVMutableVideoComposition
//     레이어 지시문으로 처리한다(불투명도/변환 지원, 블렌드 모드는 후속).
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import CoreMedia
import CoreText
import QuartzCore
import Foundation

final class AVExportEngine {

    /// 진행/완료 이벤트. Flutter 이벤트 채널로 그대로 전달된다.
    var onEvent: (([String: Any]) -> Void)?

    private var session: AVAssetExportSession?
    private var progressTimer: Timer?
    private var cancelRequested = false
    private let buildQueue = DispatchQueue(label: "app.muud.edits.export.build")

    // MARK: - Public

    func start(
        graphJson: String,
        outputPath: String,
        onStartError: @escaping (Error) -> Void
    ) {
        cancelRequested = false
        emit(event: "stage", state: "preparing", message: "렌더 그래프 준비 중")

        buildQueue.async { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let graph = try MuudRenderGraph.decode(json: graphJson)
                    let built = try await self.build(graph: graph)
                    try await self.run(
                        graph: graph,
                        built: built,
                        outputPath: outputPath
                    )
                } catch {
                    self.emit(
                        event: "failed",
                        state: nil,
                        message: error.localizedDescription,
                        error: error.localizedDescription
                    )
                    DispatchQueue.main.async { onStartError(error) }
                }
            }
        }
    }

    /// 취소 요청. 실제 정리는 `canceled` 이벤트로 확인된다.
    func cancel() -> Bool {
        guard let session, session.status == .exporting || session.status == .waiting else {
            return false
        }
        cancelRequested = true
        session.cancelExport()
        return true
    }

    // MARK: - Build

    private struct VideoEntry {
        let segment: MuudSegment
        let track: AVMutableCompositionTrack
        let transform: CGAffineTransform
    }

    private struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition?
        let audioMix: AVAudioMix?
        let duration: CMTime
    }

    private func build(graph: MuudRenderGraph) async throws -> Built {
        guard !graph.watermark else {
            throw MuudExportError.invalidGraph("워터마크가 있는 그래프는 렌더하지 않습니다")
        }
        guard graph.container == "mp4" || graph.container == "mov" else {
            throw MuudExportError.unsupported("컨테이너 \(graph.container)")
        }
        if graph.segments.contains(where: { $0.isStillImage }) {
            throw MuudExportError.unsupported("정지 이미지 클립(후속 단계)")
        }

        let composition = AVMutableComposition()
        let renderSize = CGSize(
            width: CGFloat(graph.resolution.width),
            height: CGFloat(graph.resolution.height)
        )
        var entries: [VideoEntry] = []

        for segment in graph.visibleSegments {
            guard let path = segment.sourcePath, !path.isEmpty else { continue }
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw MuudExportError.invalidGraph("\(segment.clipId): 비디오 트랙이 없습니다")
            }
            let naturalSize = try await sourceTrack.load(.naturalSize)
            let preferredTransform = try await sourceTrack.load(.preferredTransform)

            guard
                let track = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            else {
                throw MuudExportError.exportFailed("비디오 트랙을 만들지 못했습니다")
            }

            let sourceRange = CMTimeRange(
                start: ms(segment.sourceInMs),
                duration: ms(max(1, segment.sourceOutMs - segment.sourceInMs))
            )
            let insertAt = ms(segment.renderStartMs)
            try track.insertTimeRange(sourceRange, of: sourceTrack, at: insertAt)

            if abs(segment.speed - 1.0) > 0.0001 {
                let inserted = CMTimeRange(start: insertAt, duration: sourceRange.duration)
                track.scaleTimeRange(inserted, toDuration: ms(segment.renderDurationMs))
            }

            entries.append(
                VideoEntry(
                    segment: segment,
                    track: track,
                    transform: fitTransform(
                        naturalSize: naturalSize,
                        preferredTransform: preferredTransform,
                        renderSize: renderSize
                    )
                )
            )
        }

        let videoComposition = entries.isEmpty
            ? nil
            : makeVideoComposition(graph: graph, entries: entries, renderSize: renderSize)

        let (audioMix, hasAudio) = try await addAudio(
            composition: composition,
            segments: graph.audioSegments
        )

        let videoDuration = entries
            .map { ms($0.segment.renderEndMs) }
            .max() ?? .zero
        let audioDuration = hasAudio
            ? composition.duration
            : .zero
        let duration = CMTimeMaximum(videoDuration, audioDuration)
        let finalDuration = duration.seconds > 0 ? duration : ms(graph.durationMs)

        // 텍스트/자막은 비디오 합성 위에 Core Animation으로 얹는다.
        if let videoComposition, !graph.subtitles.items.isEmpty || graph.segments.contains(where: \.isText) {
            attachOverlay(to: videoComposition, graph: graph, renderSize: renderSize)
        }

        return Built(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: finalDuration
        )
    }

    /// 소스를 렌더 프레임 안에 비율 유지로 맞추고 가운데 정렬.
    private func fitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let oriented = naturalSize.applying(preferredTransform)
        let displayWidth = abs(oriented.width)
        let displayHeight = abs(oriented.height)
        guard displayWidth > 0, displayHeight > 0 else { return preferredTransform }
        let scale = min(renderSize.width / displayWidth, renderSize.height / displayHeight)
        let scaled = preferredTransform.concatenating(
            CGAffineTransform(scaleX: scale, y: scale)
        )
        let finalSize = CGSize(
            width: displayWidth * scale,
            height: displayHeight * scale
        )
        let tx = (renderSize.width - finalSize.width) / 2
        let ty = (renderSize.height - finalSize.height) / 2
        return scaled.concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// 겹치는 레이어를 시간 슬라이스별 지시문으로 바꾼다.
    private func makeVideoComposition(
        graph: MuudRenderGraph,
        entries: [VideoEntry],
        renderSize: CGSize
    ) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, graph.fps))
        )

        var boundaries: Set<Int64> = [0, max(1, graph.durationMs)]
        for entry in entries {
            boundaries.insert(entry.segment.renderStartMs)
            boundaries.insert(entry.segment.renderEndMs)
        }
        let sorted = boundaries.sorted()
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for index in 0..<(sorted.count - 1) {
            let start = sorted[index]
            let end = sorted[index + 1]
            guard end > start else { continue }
            let range = CMTimeRange(start: ms(start), duration: ms(end - start))
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range
            instruction.backgroundColor = CGColor(
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                components: [0, 0, 0, 1]
            )

            var layers: [AVMutableVideoCompositionLayerInstruction] = []
            for entry in entries
            where entry.segment.renderStartMs < end && entry.segment.renderEndMs > start {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
                layer.setTransform(entry.transform, at: ms(start))
                let from = entry.segment.opacity(atRenderMs: start)
                let to = entry.segment.opacity(atRenderMs: max(start, end - 1))
                if abs(from - to) < 0.001 {
                    layer.setOpacity(from, at: ms(start))
                } else {
                    layer.setOpacityRamp(
                        fromStartOpacity: from,
                        toEndOpacity: to,
                        timeRange: range
                    )
                }
                layers.append(layer)
            }
            instruction.layerInstructions = layers
            instructions.append(instruction)
        }
        composition.instructions = instructions
        return composition
    }

    private func addAudio(
        composition: AVMutableComposition,
        segments: [MuudAudioSegment]
    ) async throws -> (AVAudioMix?, Bool) {
        let audioMix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        var added = false

        for segment in segments where !segment.muted && !segment.sourcePath.isEmpty {
            let asset = AVURLAsset(url: URL(fileURLWithPath: segment.sourcePath))
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                continue
            }
            guard
                let track = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            else {
                continue
            }
            let range = CMTimeRange(
                start: ms(segment.sourceInMs),
                duration: ms(max(1, segment.sourceOutMs - segment.sourceInMs))
            )
            let insertAt = ms(segment.renderStartMs)
            try track.insertTimeRange(range, of: sourceTrack, at: insertAt)
            if abs(segment.speed - 1.0) > 0.0001 {
                let inserted = CMTimeRange(start: insertAt, duration: range.duration)
                track.scaleTimeRange(
                    inserted,
                    toDuration: ms(max(1, segment.renderEndMs - segment.renderStartMs))
                )
            }

            let params = AVMutableAudioMixInputParameters(track: track)
            applyVolumeCurve(params: params, segment: segment)
            parameters.append(params)
            added = true
        }

        guard added else { return (nil, false) }
        audioMix.inputParameters = parameters
        return (audioMix, true)
    }

    private func applyVolumeCurve(
        params: AVMutableAudioMixInputParameters,
        segment: MuudAudioSegment
    ) {
        let points = segment.gainCurve
        guard points.count >= 2 else {
            params.setVolume(segment.gain, at: ms(segment.renderStartMs))
            return
        }
        for index in 0..<(points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            guard b.atMs > a.atMs else { continue }
            params.setVolumeRamp(
                fromStartVolume: a.value,
                toEndVolume: b.value,
                timeRange: CMTimeRange(
                    start: ms(segment.renderStartMs + a.atMs),
                    duration: ms(b.atMs - a.atMs)
                )
            )
        }
    }

    // MARK: - Overlay (text + subtitles)

    private func attachOverlay(
        to videoComposition: AVMutableVideoComposition,
        graph: MuudRenderGraph,
        renderSize: CGSize
    ) {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.masksToBounds = true

        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        let overlay = CALayer()
        overlay.frame = parent.frame
        parent.addSublayer(overlay)

        for segment in graph.segments where segment.isText {
            guard let text = segment.text else { continue }
            let layer = makeTextLayer(
                text: text.content,
                fontFamily: text.fontFamily,
                sizePx: text.sizePx,
                color: text.color,
                background: text.background,
                strokePx: text.strokePx,
                anchor: CGPoint(x: 0.5, y: 0.82),
                renderSize: renderSize
            )
            let frames = opacityKeyframes(
                segment: segment,
                totalMs: graph.durationMs
            )
            layer.add(frames, forKey: "muud.fade")
            overlay.addSublayer(layer)
        }

        if graph.subtitles.enabled {
            for item in graph.subtitles.items {
                let style = item.style ?? graph.subtitles.style
                let layer = makeTextLayer(
                    text: item.displayText,
                    fontFamily: style.fontFamily,
                    sizePx: style.sizePx,
                    color: style.color,
                    background: nil,
                    strokePx: style.outlinePx,
                    outlineColor: style.outlineColor,
                    anchor: CGPoint(
                        x: CGFloat(style.anchor?.x ?? 0.5),
                        y: CGFloat(style.anchor?.y ?? 0.82)
                    ),
                    renderSize: renderSize
                )
                let animation = CAKeyframeAnimation(keyPath: "opacity")
                let total = max(1.0, Double(graph.durationMs))
                let start = min(1, max(0, Double(item.renderStartMs) / total))
                let end = min(1, max(start + 0.000002, Double(item.renderEndMs) / total))
                animation.values = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0]
                animation.keyTimes = [
                    NSNumber(value: 0),
                    NSNumber(value: start),
                    NSNumber(value: min(1, start + 0.000001)),
                    NSNumber(value: end),
                    NSNumber(value: min(1, end + 0.000001)),
                    NSNumber(value: 1),
                ]
                animation.duration = total / 1000
                animation.beginTime = AVCoreAnimationBeginTimeAtZero
                animation.isRemovedOnCompletion = false
                animation.fillMode = .both
                layer.add(animation, forKey: "muud.subtitle")
                overlay.addSublayer(layer)
            }
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parent
        )
    }

    /// 클립 불투명도 커브를 전체 길이 키프레임으로 변환.
    private func opacityKeyframes(segment: MuudSegment, totalMs: Int64) -> CAKeyframeAnimation {
        let total = max(1.0, Double(totalMs))
        var times: [NSNumber] = [0]
        var values: [NSNumber] = [0]
        for point in segment.opacityCurve {
            let global = Double(segment.renderStartMs + point.atMs) / total
            times.append(NSNumber(value: min(1, max(0, global))))
            values.append(NSNumber(value: point.value))
        }
        times.append(1)
        values.append(0)
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = times
        animation.duration = total / 1000
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        return animation
    }

    private func makeTextLayer(
        text: String,
        fontFamily: String,
        sizePx: Float,
        color: String,
        background: String?,
        strokePx: Float,
        outlineColor: String = "#000000FF",
        anchor: CGPoint,
        renderSize: CGSize
    ) -> CATextLayer {
        let layer = CATextLayer()
        let width = renderSize.width * 0.9
        let height = max(renderSize.height * 0.3, CGFloat(sizePx) * 3)
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // CA 좌표는 좌하단 원점 → 정규화 y를 뒤집는다.
        layer.position = CGPoint(
            x: anchor.x * renderSize.width,
            y: (1 - anchor.y) * renderSize.height
        )
        layer.alignmentMode = .center
        layer.isWrapped = true
        layer.contentsScale = 2.0

        let fontSize = CGFloat(sizePx)
        let font = resolvedFont(family: fontFamily, size: fontSize)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: muudColor(color),
        ]
        if strokePx > 0 {
            attributes[.strokeColor] = muudColor(outlineColor)
            // 음수 strokeWidth = 채우기 + 외곽선
            attributes[.strokeWidth] = NSNumber(value: -Double(strokePx) / Double(fontSize) * 100)
        }
        layer.string = NSAttributedString(string: text, attributes: attributes)
        if let background, let cg = muudCGColor(background) {
            layer.backgroundColor = cg
        }
        return layer
    }

    private func resolvedFont(family: String, size: CGFloat) -> Any {
        #if os(macOS)
        if let font = NSFont(name: family, size: size) {
            return font
        }
        return NSFont.boldSystemFont(ofSize: size)
        #else
        if let font = UIFont(name: family, size: size) {
            return font
        }
        return UIFont.boldSystemFont(ofSize: size)
        #endif
    }

    // MARK: - Run

    private func run(
        graph: MuudRenderGraph,
        built: Built,
        outputPath: String
    ) async throws {
        let outputURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputPath) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard
            let session = AVAssetExportSession(
                asset: built.composition,
                presetName: AVAssetExportPresetHighestQuality
            )
        else {
            throw MuudExportError.exportFailed("AVAssetExportSession을 만들지 못했습니다")
        }

        let fileType: AVFileType = graph.container == "mov" ? .mov : .mp4
        guard session.supportedFileTypes.contains(fileType) else {
            throw MuudExportError.unsupported("출력 형식 \(graph.container)")
        }
        session.outputURL = outputURL
        session.outputFileType = fileType
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = graph.container == "mp4"
        if built.duration.seconds > 0 {
            session.timeRange = CMTimeRange(start: .zero, duration: built.duration)
        }

        await MainActor.run {
            self.session = session
            self.emit(
                event: "stage",
                state: "rendering",
                message: "인코딩 중 (\(graph.frameCount) 프레임)"
            )
            self.startProgressTimer(frameCount: graph.frameCount)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        await MainActor.run {
            self.stopProgressTimer()
            switch session.status {
            case .completed:
                self.emit(
                    event: "completed",
                    state: "completed",
                    completedFrames: graph.frameCount,
                    totalFrames: graph.frameCount,
                    message: outputPath
                )
            case .cancelled:
                self.emit(event: "canceled", state: "canceled", message: "취소됨")
            default:
                let message = session.error?.localizedDescription ?? "알 수 없는 인코딩 오류"
                self.emit(event: "failed", state: "failed", message: message, error: message)
            }
            self.session = nil
        }
    }

    // MARK: - Progress

    @MainActor
    private func startProgressTimer(frameCount: Int) {
        stopProgressTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let session = self.session else { return }
            let total = max(1, frameCount)
            let completed = Int((Double(session.progress) * Double(total)).rounded())
            self.emit(
                event: "progress",
                state: "rendering",
                completedFrames: min(completed, total),
                totalFrames: total
            )
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Events

    private func emit(
        event: String,
        state: String?,
        completedFrames: Int? = nil,
        totalFrames: Int? = nil,
        message: String? = nil,
        error: String? = nil
    ) {
        var payload: [String: Any] = ["event": event]
        if let state { payload["state"] = state }
        if let completedFrames { payload["completed_frames"] = completedFrames }
        if let totalFrames { payload["total_frames"] = totalFrames }
        if let message { payload["message"] = message }
        if let error { payload["error"] = error }
        onEvent?(payload)
    }

    // MARK: - Helpers

    private func ms(_ value: Int64) -> CMTime {
        CMTime(value: CMTimeValue(max(0, value)), timescale: 1000)
    }
}

// MARK: - Color parsing

func muudCGColor(_ hex: String) -> CGColor? {
    var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6 || text.count == 8 else { return nil }
    guard let value = UInt64(text, radix: 16) else { return nil }
    let r, g, b, a: CGFloat
    if text.count == 8 {
        r = CGFloat((value >> 24) & 0xFF) / 255
        g = CGFloat((value >> 16) & 0xFF) / 255
        b = CGFloat((value >> 8) & 0xFF) / 255
        a = CGFloat(value & 0xFF) / 255
    } else {
        r = CGFloat((value >> 16) & 0xFF) / 255
        g = CGFloat((value >> 8) & 0xFF) / 255
        b = CGFloat(value & 0xFF) / 255
        a = 1
    }
    return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])
}

func muudColor(_ hex: String) -> Any {
    guard let cg = muudCGColor(hex) else {
        #if os(macOS)
        return NSColor.white
        #else
        return UIColor.white
        #endif
    }
    #if os(macOS)
    return NSColor(cgColor: cg) ?? NSColor.white
    #else
    return UIColor(cgColor: cg)
    #endif
}
