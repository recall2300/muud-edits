import 'dart:convert';

import 'src/rust/api.dart' as rust;

/// Rust 코어 호출 경계.
///
/// 이 인터페이스가 있는 이유:
/// * 화면 코드는 브리지 구현을 모른다(테스트에서 가짜 구현으로 바꿀 수 있다).
/// * `flutter_rust_bridge_codegen`이 생성하는 함수 이름/시그니처가 바뀌어도
///   고칠 곳이 [FrbCoreBridge] 한 곳뿐이다.
///
/// 모든 함수는 Rust가 돌려준 JSON 문자열을 그대로 전달한다.
/// 해석은 `EditorState.fromEnvelope`가 담당한다.
abstract class CoreBridge {
  Future<String> coreVersion();

  Future<String> createProject({
    required String name,
    required int width,
    required int height,
    required int fps,
  });

  Future<String> applyCommand(String stateJson, Map<String, dynamic> command);

  Future<String> addMediaClip({
    required String stateJson,
    required String trackId,
    required String kind,
    required String sourcePath,
    required int startMs,
    required int endMs,
    int? atMs,
    int? sourceDurationMs,
  });

  Future<String> addTextClip({
    required String stateJson,
    required String trackId,
    required String content,
    required int durationMs,
    required int atMs,
  });

  Future<String> addSubtitle({
    required String stateJson,
    required String text,
    int? startMs,
    int? endMs,
  });

  Future<String> splitClip({
    required String stateJson,
    required String trackId,
    required String clipId,
    required int atTimelineMs,
  });

  Future<String> undo(String stateJson);

  Future<String> redo(String stateJson);

  Future<String> exportPlan({
    required String stateJson,
    required String settingsJson,
    required String platformId,
  });

  /// 타임라인 → 결정적 렌더 그래프(네이티브 엔진에 그대로 넘긴다).
  Future<String> renderGraph({
    required String stateJson,
    required String settingsJson,
    required String platformId,
  });

  /// 플랫폼 프로브 결과(JSON)를 코어에서 검증/정규화한다.
  Future<String> probeMediaInfo(String probeJson);

  /// 내보내기 진행률 상태 생성.
  Future<String> exportJobCreate({
    required String jobId,
    required int totalFrames,
    int? atMs,
  });

  /// 진행률/단계/취소 이벤트 적용.
  Future<String> exportJobEvent({
    required String jobJson,
    required String eventJson,
  });

  /// 취소 요청(편의).
  Future<String> exportJobCancel({
    required String jobJson,
    int? atMs,
  });

  Future<String> saveProject({
    required String stateJson,
    required String path,
  });

  Future<String> loadProject(String path);

  Future<String> saveSubtitlesSrt({
    required String stateJson,
    required String path,
  });
}

/// flutter_rust_bridge 생성 바인딩을 사용하는 실제 구현.
///
/// 코드 생성 후 시그니처가 다르면 **이 클래스의 메서드 본문만** 고치면 된다.
class FrbCoreBridge implements CoreBridge {
  const FrbCoreBridge();

  @override
  Future<String> coreVersion() => rust.coreVersion();

  @override
  Future<String> createProject({
    required String name,
    required int width,
    required int height,
    required int fps,
  }) {
    return rust.createProject(name: name, width: width, height: height, fps: fps);
  }

  @override
  Future<String> applyCommand(String stateJson, Map<String, dynamic> command) {
    return rust.applyCommand(
      stateJson: stateJson,
      commandJson: encodeCommand(command),
    );
  }

  @override
  Future<String> addMediaClip({
    required String stateJson,
    required String trackId,
    required String kind,
    required String sourcePath,
    required int startMs,
    required int endMs,
    int? atMs,
    int? sourceDurationMs,
  }) {
    return rust.addMediaClip(
      stateJson: stateJson,
      trackId: trackId,
      kind: kind,
      sourcePath: sourcePath,
      startMs: startMs,
      endMs: endMs,
      atMs: atMs,
      sourceDurationMs: sourceDurationMs,
    );
  }

  @override
  Future<String> addTextClip({
    required String stateJson,
    required String trackId,
    required String content,
    required int durationMs,
    required int atMs,
  }) {
    return rust.addTextClip(
      stateJson: stateJson,
      trackId: trackId,
      content: content,
      durationMs: durationMs,
      atMs: atMs,
    );
  }

  @override
  Future<String> addSubtitle({
    required String stateJson,
    required String text,
    int? startMs,
    int? endMs,
  }) {
    return rust.addSubtitle(
      stateJson: stateJson,
      startMs: startMs,
      endMs: endMs,
      text: text,
    );
  }

  @override
  Future<String> splitClip({
    required String stateJson,
    required String trackId,
    required String clipId,
    required int atTimelineMs,
  }) {
    return rust.splitClip(
      stateJson: stateJson,
      trackId: trackId,
      clipId: clipId,
      atTimelineMs: atTimelineMs,
    );
  }

  @override
  Future<String> undo(String stateJson) => rust.undo(stateJson: stateJson);

  @override
  Future<String> redo(String stateJson) => rust.redo(stateJson: stateJson);

  @override
  Future<String> exportPlan({
    required String stateJson,
    required String settingsJson,
    required String platformId,
  }) {
    return rust.exportPlan(
      stateJson: stateJson,
      settingsJson: settingsJson,
      platformId: platformId,
    );
  }

  @override
  Future<String> renderGraph({
    required String stateJson,
    required String settingsJson,
    required String platformId,
  }) {
    return rust.renderGraph(
      stateJson: stateJson,
      settingsJson: settingsJson,
      platformId: platformId,
    );
  }

  @override
  Future<String> probeMediaInfo(String probeJson) {
    return rust.probeMediaInfo(probeJson: probeJson);
  }

  @override
  Future<String> exportJobCreate({
    required String jobId,
    required int totalFrames,
    int? atMs,
  }) {
    return rust.exportJobCreate(
      jobId: jobId,
      totalFrames: totalFrames,
      atMs: atMs,
    );
  }

  @override
  Future<String> exportJobEvent({
    required String jobJson,
    required String eventJson,
  }) {
    return rust.exportJobEvent(
      jobJson: jobJson,
      eventJson: eventJson,
    );
  }

  @override
  Future<String> exportJobCancel({
    required String jobJson,
    int? atMs,
  }) {
    return rust.exportJobCancel(jobJson: jobJson, atMs: atMs);
  }

  @override
  Future<String> saveProject({
    required String stateJson,
    required String path,
  }) {
    return rust.saveProject(stateJson: stateJson, path: path);
  }

  @override
  Future<String> loadProject(String path) => rust.loadProject(path: path);

  @override
  Future<String> saveSubtitlesSrt({
    required String stateJson,
    required String path,
  }) {
    return rust.saveSubtitlesSrt(stateJson: stateJson, path: path);
  }
}

/// 커맨드 Map을 브리지용 JSON 문자열로.
String encodeCommand(Map<String, dynamic> command) => jsonEncode(command);
