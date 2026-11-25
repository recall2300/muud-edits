//
//  MuudMediaPlugin.swift
//  muud-edits — macOS / iOS 네이티브 미디어 채널
//
//  Flutter 쪽 계약: app/lib/media/media_platform_bridge.dart
//    MethodChannel  "muud_edits/media"            : probe / startExport / cancelExport / thumbnail / platformInfo
//    EventChannel   "muud_edits/export_progress"  : {event, state, completed_frames, total_frames, message, error}
//
//  이 파일은 macOS Runner와 iOS Runner **양쪽 타깃에 그대로 추가**한다.
//  (Xcode에서 대상 타깃을 체크하면 된다. 플랫폼 차이는 #if로 처리한다.)
//

#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif
import AVFoundation
import Foundation

public final class MuudMediaPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let engine = AVExportEngine()
    private var eventSink: FlutterEventSink?
    private let eventQueue = DispatchQueue(label: "app.muud.edits.events")

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = MuudMediaPlugin()

        #if os(macOS)
        let messenger = registrar.messenger
        #else
        let messenger = registrar.messenger()
        #endif

        let methods = FlutterMethodChannel(
            name: "muud_edits/media",
            binaryMessenger: messenger
        )
        registrar.addMethodCallDelegate(instance, channel: methods)

        let events = FlutterEventChannel(
            name: "muud_edits/export_progress",
            binaryMessenger: messenger
        )
        events.setStreamHandler(instance)
    }

    // MARK: - FlutterStreamHandler

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        engine.onEvent = { [weak self] payload in
            self?.send(payload)
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        engine.onEvent = nil
        return nil
    }

    private func send(_ payload: [String: Any]) {
        eventQueue.async { [weak self] in
            guard let self, let sink = self.eventSink else { return }
            DispatchQueue.main.async {
                sink(payload)
            }
        }
    }

    // MARK: - FlutterPlugin

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "probe":
            guard let path = args["path"] as? String, !path.isEmpty else {
                result(FlutterError(code: "bad_arguments", message: "path가 필요합니다", details: nil))
                return
            }
            Task {
                do {
                    let info = try await AVMediaProbe.probe(path: path)
                    await MainActor.run { result(info) }
                } catch {
                    await MainActor.run {
                        result(FlutterError(code: "probe_failed", message: error.localizedDescription, details: nil))
                    }
                }
            }

        case "startExport":
            guard
                let graphJson = args["graphJson"] as? String,
                let outputPath = args["outputPath"] as? String
            else {
                result(FlutterError(code: "bad_arguments", message: "graphJson/outputPath가 필요합니다", details: nil))
                return
            }
            engine.start(graphJson: graphJson, outputPath: outputPath) { error in
                result(FlutterError(code: "export_start_failed", message: error.localizedDescription, details: nil))
            }
            result(nil)

        case "cancelExport":
            result(engine.cancel())

        case "thumbnail":
            guard let path = args["path"] as? String else {
                result(FlutterError(code: "bad_arguments", message: "path가 필요합니다", details: nil))
                return
            }
            let atMs = (args["atMs"] as? NSNumber)?.int64Value ?? 0
            let maxWidth = (args["maxWidth"] as? NSNumber)?.intValue ?? 320
            Task {
                do {
                    let data = try await AVMediaProbe.thumbnail(path: path, atMs: atMs, maxWidth: maxWidth)
                    await MainActor.run { result(FlutterStandardTypedData(bytes: data)) }
                } catch {
                    await MainActor.run { result(nil) }
                }
            }

        case "platformInfo":
            #if os(macOS)
            let platformName = "macos"
            #else
            let platformName = "ios"
            #endif
            result([
                "api": "AVFoundation + VideoToolbox",
                "engine": "AVAssetExportSession",
                "supports_export": true,
                "supports_text_burn_in": true,
                "supports_image_clips": false,
                "platform": platformName,
            ])

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
