import 'dart:async';

import 'package:flutter/services.dart';

/// 네이티브 미디어 엔진 호출 경계.
///
/// ## 왜 추상화하는가
/// * 이 앱은 4개 플랫폼에서 **같은 렌더 그래프**를 네이티브 인코더에 넘긴다.
///   Dart 쪽에서 봐야 하는 것은 "프로브 / 내보내기 시작 / 진행 이벤트 / 취소" 네 가지뿐이다.
/// * 테스트에서는 [FakeMediaPlatformBridge]로 바꿔 네이티브 없이 UI 흐름을 검증한다.
/// * 네이티브 파일을 `flutter create` 뒤에 붙이지 않은 상태에서는
///   `MissingPluginException`이 나고, UI는 수동 입력 경로로 폴백한다.
///
/// ## 채널 계약
/// | 채널 | 종류 | 이름 |
/// |---|---|---|
/// | 메서드 | MethodChannel | `muud_edits/media` |
/// | 이벤트 | EventChannel | `muud_edits/export_progress` |
///
/// 메서드:
/// * `probe({path})` → `Map` (아래 프로브 키)
/// * `startExport({graphJson, outputPath})` → `null` (완료/실패는 이벤트로)
/// * `cancelExport()` → `bool` (취소 요청 접수 여부)
/// * `thumbnail({path, atMs, maxWidth})` → `Uint8List`
/// * `platformInfo()` → `{api, engine, supports_export}` (설정 화면/로그)
///
/// 프로브 결과 키(코어 `MediaProbeInfo`가 그대로 받는다):
/// `path, duration_ms, width, height, fps, has_video, has_audio, audio_channels,
///  audio_sample_rate, video_codec, audio_codec, rotation_degrees, bitrate_kbps,
///  container, source, probed_at_ms`
///
/// 진행 이벤트 키:
/// `{state?: "preparing"|"rendering"|"finalizing", completed_frames?: int,
///   total_frames?: int, message?: string, error?: string,
///   event: "progress"|"completed"|"failed"|"canceled"}`
abstract class MediaPlatformBridge {
  /// 파일 메타데이터(길이·해상도·fps·오디오 유무). 네이티브 엔진이 없으면 예외.
  Future<Map<String, dynamic>> probe(String path);

  /// 렌더 그래프(JSON 문자열)를 그대로 넘겨 인코딩을 시작한다.
  Future<void> startExport({
    required String graphJson,
    required String outputPath,
  });

  /// 취소 요청. 실제 정리는 `canceled` 이벤트로 확인한다.
  Future<bool> cancelExport();

  /// 썸네일(JPEG/PNG 바이트). 실패하면 null.
  Future<Uint8List?> thumbnail(
    String path, {
    int atMs = 0,
    int maxWidth = 320,
  });

  /// 플랫폼 미디어 엔진 정보(없으면 빈 맵).
  Future<Map<String, dynamic>> platformInfo();

  /// 내보내기 진행 이벤트.
  Stream<MediaExportEvent> get progressStream;
}

/// 네이티브에서 올라온 원시 진행 이벤트.
///
/// 상태 정규화(프레임→퍼센트, ETA, 취소 확정)는 **Rust 코어**(`ExportJob`)가 한다.
/// 여기서는 값만 옮긴다.
class MediaExportEvent {
  const MediaExportEvent({
    required this.event,
    this.state,
    this.completedFrames,
    this.totalFrames,
    this.message,
    this.error,
  });

  /// `progress` | `completed` | `failed` | `canceled` | `stage`
  final String event;
  final String? state;
  final int? completedFrames;
  final int? totalFrames;
  final String? message;
  final String? error;

  bool get isFailure => event == 'failed';

  bool get isFinished => event == 'completed' || event == 'failed';

  static MediaExportEvent fromMap(Object? value) {
    final Map<Object?, Object?> raw =
        value is Map ? value : const <Object?, Object?>{};
    final Map<String, dynamic> map = raw.map(
      (Object? key, Object? val) => MapEntry(key.toString(), val),
    );
    int? asInt(Object? v) => v is num ? v.round() : null;
    return MediaExportEvent(
      event: (map['event'] as String?) ?? 'progress',
      state: map['state'] as String?,
      completedFrames: asInt(map['completed_frames']),
      totalFrames: asInt(map['total_frames']),
      message: map['message'] as String?,
      error: map['error'] as String?,
    );
  }

  @override
  String toString() =>
      'MediaExportEvent($event, state=$state, '
      '$completedFrames/$totalFrames)';
}

/// MethodChannel/EventChannel 기반 실제 구현.
///
/// 네이티브 쪽 구현 위치:
/// * macOS: `native/macos/MuudMediaPlugin.swift`
/// * iOS: `native/ios/MuudMediaPlugin.swift`
/// * Android: `native/android/MuudMediaPlugin.kt`
/// * Windows: `native/windows/muud_media_plugin.cpp`
class MethodChannelMediaBridge implements MediaPlatformBridge {
  MethodChannelMediaBridge({MethodChannel? methods, EventChannel? events})
      : _methods = methods ?? const MethodChannel('muud_edits/media'),
        _events = events ?? const EventChannel('muud_edits/export_progress');

  final MethodChannel _methods;
  final EventChannel _events;
  Stream<MediaExportEvent>? _progress;

  @override
  Stream<MediaExportEvent> get progressStream =>
      _progress ??= _events
          .receiveBroadcastStream()
          .map(MediaExportEvent.fromMap)
          .handleError((Object error) {
        // 네이티브 쪽 프로세스가 죽어도 앱은 살아 있어야 한다.
        throw MediaPlatformException('stream_error', '$error');
      });

  @override
  Future<Map<String, dynamic>> probe(String path) async {
    try {
      final Map<Object?, Object?>? result =
          await _methods.invokeMapMethod<Object?, Object?>('probe', <String, dynamic>{
        'path': path,
      });
      if (result == null) {
        throw MediaPlatformException('probe_empty', '프로브 결과가 비어 있습니다');
      }
      return result.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
    } on PlatformException catch (error) {
      throw MediaPlatformException(
        error.code,
        error.message ?? '미디어 정보를 읽지 못했습니다',
      );
    } on MissingPluginException {
      throw const MediaPlatformException(
        'engine_missing',
        '네이티브 미디어 엔진이 연결되지 않았습니다',
      );
    }
  }

  @override
  Future<void> startExport({
    required String graphJson,
    required String outputPath,
  }) async {
    try {
      await _methods.invokeMethod<void>('startExport', <String, dynamic>{
        'graphJson': graphJson,
        'outputPath': outputPath,
      });
    } on PlatformException catch (error) {
      throw MediaPlatformException(
        error.code,
        error.message ?? '내보내기를 시작하지 못했습니다',
      );
    } on MissingPluginException {
      throw const MediaPlatformException(
        'engine_missing',
        '네이티브 미디어 엔진이 연결되지 않았습니다',
      );
    }
  }

  @override
  Future<bool> cancelExport() async {
    try {
      final bool? accepted =
          await _methods.invokeMethod<bool>('cancelExport');
      return accepted ?? false;
    } on PlatformException catch (error) {
      throw MediaPlatformException(
        error.code,
        error.message ?? '취소하지 못했습니다',
      );
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<Uint8List?> thumbnail(
    String path, {
    int atMs = 0,
    int maxWidth = 320,
  }) async {
    try {
      return await _methods.invokeMethod<Uint8List>('thumbnail', <String, dynamic>{
        'path': path,
        'atMs': atMs,
        'maxWidth': maxWidth,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>> platformInfo() async {
    try {
      final Map<Object?, Object?>? result = await _methods
          .invokeMapMethod<Object?, Object?>('platformInfo');
      if (result == null) {
        return const <String, dynamic>{};
      }
      return result.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
    } on PlatformException {
      return const <String, dynamic>{};
    } on MissingPluginException {
      return const <String, dynamic>{};
    }
  }
}

/// 네이티브 미디어 엔진 오류.
class MediaPlatformException implements Exception {
  const MediaPlatformException(this.code, this.message);

  final String code;
  final String message;

  bool get isEngineMissing => code == 'engine_missing';

  @override
  String toString() => message;
}

/// 테스트/데모용 가짜 구현.
///
/// 시나리오를 직접 주입해 UI(진행률·취소·오류 배너)를 네이티브 없이 검증한다.
class FakeMediaPlatformBridge implements MediaPlatformBridge {
  FakeMediaPlatformBridge({
    Map<String, dynamic>? probeResult,
    this.throwOnProbe = false,
  }) : _probeResult = probeResult;

  final Map<String, dynamic>? _probeResult;
  final bool throwOnProbe;
  final StreamController<MediaExportEvent> _events =
      StreamController<MediaExportEvent>.broadcast();
  bool exportStarted = false;
  bool cancelRequested = false;
  String? lastGraphJson;
  String? lastOutputPath;

  @override
  Stream<MediaExportEvent> get progressStream => _events.stream;

  void emit(MediaExportEvent event) => _events.add(event);

  void close() => _events.close();

  @override
  Future<Map<String, dynamic>> probe(String path) async {
    if (throwOnProbe) {
      throw const MediaPlatformException(
        'engine_missing',
        '네이티브 미디어 엔진이 연결되지 않았습니다',
      );
    }
    return _probeResult ??
        <String, dynamic>{
          'path': path,
          'duration_ms': 4000,
          'width': 1080,
          'height': 1920,
          'fps': 30.0,
          'has_video': true,
          'has_audio': true,
          'source': 'fake',
        };
  }

  @override
  Future<void> startExport({
    required String graphJson,
    required String outputPath,
  }) async {
    exportStarted = true;
    lastGraphJson = graphJson;
    lastOutputPath = outputPath;
  }

  @override
  Future<bool> cancelExport() async {
    cancelRequested = true;
    return true;
  }

  @override
  Future<Uint8List?> thumbnail(
    String path, {
    int atMs = 0,
    int maxWidth = 320,
  }) async =>
      null;

  @override
  Future<Map<String, dynamic>> platformInfo() async =>
      <String, dynamic>{'api': 'fake', 'supports_export': true};
}
