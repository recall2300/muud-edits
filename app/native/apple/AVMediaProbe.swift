//
//  AVMediaProbe.swift
//  muud-edits — AVFoundation 메타데이터 프로브 + 썸네일
//
//  결과 키는 Rust `MediaProbeInfo`(rust_core/src/probe.rs)가 그대로 받는다.
//  값이 없으면 키를 생략해도 된다(코어가 기본값으로 채운다).
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import CoreMedia
import Foundation
import ImageIO

enum AVMediaProbe {

    // MARK: - Probe

    static func probe(path: String) async throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw MuudExportError.unsupported("파일을 찾을 수 없습니다: \(path)")
        }

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        let duration = try await asset.load(.duration)
        let durationMs = max(0, Int64((CMTimeGetSeconds(duration) * 1000).rounded()))

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        var info: [String: Any] = [
            "path": path,
            "duration_ms": durationMs,
            "has_video": !videoTracks.isEmpty,
            "has_audio": !audioTracks.isEmpty,
            "source": "avfoundation",
            "probed_at_ms": Int64(Date().timeIntervalSince1970 * 1000),
        ]

        if let video = videoTracks.first {
            let naturalSize = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let nominalFrameRate = try await video.load(.nominalFrameRate)
            let formatDescriptions = try await video.load(.formatDescriptions)

            // preferredTransform을 적용한 "표시 크기". 회전 영상은 여기서 바로 선다.
            let transformed = naturalSize.applying(transform)
            let width = Int(abs(transformed.width).rounded())
            let height = Int(abs(transformed.height).rounded())

            info["width"] = width
            info["height"] = height
            info["fps"] = Double(nominalFrameRate)
            info["rotation_degrees"] = rotationDegrees(transform: transform)
            if let codec = formatDescriptions.first.map(fourCC) {
                info["video_codec"] = codec
            }
        }

        if let audio = audioTracks.first {
            let formatDescriptions = try await audio.load(.formatDescriptions)
            if let description = formatDescriptions.first {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    info["audio_sample_rate"] = Int(asbd.mSampleRate)
                    info["audio_channels"] = Int(asbd.mChannelsPerFrame)
                }
                info["audio_codec"] = fourCC(description)
            }
            info["has_audio"] = true
        }

        if let container = url.pathExtension.lowercased().isEmpty ? nil : url.pathExtension.lowercased() {
            info["container"] = container
        }

        // 비디오/오디오 스트림이 없으면 정지 이미지로 시도한다.
        if videoTracks.isEmpty && audioTracks.isEmpty {
            if let size = imagePixelSize(url: url) {
                info["width"] = Int(size.width)
                info["height"] = Int(size.height)
                info["duration_ms"] = 0
                info["has_video"] = false
                info["has_audio"] = false
            }
        }

        return info
    }

    // MARK: - Thumbnail

    /// `atMs` 위치의 프레임을 JPEG로. 실패하면 throw.
    static func thumbnail(path: String, atMs: Int64, maxWidth: Int) async throws -> Data {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: CGFloat(maxWidth),
            height: CGFloat(maxWidth) * 4
        )
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(value: CMTimeValue(max(0, atMs)), timescale: 1000)
        let (cgImage, _) = try await generator.image(at: time)
        return try jpegData(from: cgImage, quality: 0.7)
    }

    // MARK: - Helpers

    private static func fourCC(_ description: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }

    private static func rotationDegrees(transform: CGAffineTransform) -> Int {
        let angle = atan2(transform.b, transform.a) * 180 / .pi
        let rounded = Int(angle.rounded())
        let normalized = ((rounded % 360) + 360) % 360
        // 90도 단위로 스냅(코어가 90도 단위만 허용한다).
        return (normalized / 90) * 90
    }

    private static func imagePixelSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw MuudExportError.exportFailed("썸네일 인코더를 만들지 못했습니다")
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw MuudExportError.exportFailed("썸네일을 쓰지 못했습니다")
        }
        return data as Data
    }
}
