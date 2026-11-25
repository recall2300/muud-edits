// Rust ↔ Dart FFI 실연결 테스트.
//
// 이 테스트는 **실제 `libmuud_core` 동적 라이브러리**를 dlopen 해서 코어를 호출한다.
// (위젯 테스트가 쓰는 가짜 브리지와 달리, flutter_rust_bridge 코드젠 결과·심볼·
//  라이브러리 배치까지 한 번에 검증한다.)
//
// 라이브러리가 없는 환경(예: Rust를 빌드하지 않는 CI 분석 잡)에서는 자동으로 skip 된다.
// 로컬에서 돌리는 법:
//
//     cd rust_core && cargo build --release
//     cd ../app && flutter test test/rust_ffi_test.dart
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muud_edits/core_bridge.dart';
import 'package:muud_edits/models.dart';
import 'package:muud_edits/rust_core_loader.dart';

/// 코어 라이브러리 후보 경로(앱 디렉터리 기준).
String? _findCoreLibrary() {
  final String stem = kCoreLibraryStem;
  final List<String> candidates = <String>[
    if (Platform.isMacOS) ...<String>[
      '../rust_core/target/release/lib$stem.dylib',
      '../rust_core/target/debug/lib$stem.dylib',
    ] else if (Platform.isWindows) ...<String>[
      '..\\rust_core\\target\\release\\$stem.dll',
      '..\\rust_core\\target\\debug\\$stem.dll',
    ] else ...<String>[
      '../rust_core/target/release/lib$stem.so',
      '../rust_core/target/debug/lib$stem.so',
    ],
  ];
  for (final String path in candidates) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  return null;
}

void main() {
  final String? library = _findCoreLibrary();
  final Object skipReason = library == null
      ? 'Rust 코어 라이브러리가 없습니다 (rust_core에서 cargo build --release 후 실행)'
      : false;

  group('Rust 코어 FFI', () {
    const CoreBridge bridge = FrbCoreBridge();

    test('라이브러리를 로드하고 버전을 읽는다', () async {
      final RustCoreLoadResult result = await loadRustCore();
      expect(result.ok, isTrue, reason: result.error);
      expect(await bridge.coreVersion(), isNotEmpty);
    });

    test('새 프로젝트 생성 → 미디어 추가 → 되돌리기', () async {
      await loadRustCore();
      final String createdAt = await bridge.createProject(
        name: 'FFI 테스트',
        width: 1080,
        height: 1920,
        fps: 30,
      );
      final EditorState created = EditorState.fromEnvelope(createdAt);
      expect(created.name, 'FFI 테스트');
      expect(created.tracks, hasLength(3));
      expect(created.durationMs, 0);

      final String stateJson = jsonEncode(created.raw);
      final String videoTrack = created.tracks
          .firstWhere((TrackView track) => track.kind == 'video')
          .id;

      final String withClipAt = await bridge.addMediaClip(
        stateJson: stateJson,
        trackId: videoTrack,
        kind: 'video',
        sourcePath: '/media/sample.mp4',
        startMs: 0,
        endMs: 3000,
        sourceDurationMs: 3000,
      );
      final Map<String, dynamic> withClip =
          jsonDecode(withClipAt) as Map<String, dynamic>;
      expect(withClip['ok'], isTrue);
      expect((withClip['created_id'] as String).startsWith('clp-'), isTrue);
      final EditorState afterAdd = EditorState.fromEnvelope(withClipAt);
      expect(afterAdd.summary.clipCount, 1);
      expect(afterAdd.durationMs, 3000);

      final String undoneAt = await bridge.undo(jsonEncode(afterAdd.raw));
      expect(EditorState.fromEnvelope(undoneAt).summary.clipCount, 0);
    });

    test('자막 추가와 SRT 직렬화', () async {
      await loadRustCore();
      final String createdAt = await bridge.createProject(
        name: '자막 테스트',
        width: 1080,
        height: 1920,
        fps: 30,
      );
      final EditorState created = EditorState.fromEnvelope(createdAt);
      final String withSubtitle = await bridge.addSubtitle(
        stateJson: jsonEncode(created.raw),
        text: '첫 자막',
        startMs: 0,
        endMs: 1500,
      );
      final EditorState state = EditorState.fromEnvelope(withSubtitle);
      expect(state.summary.subtitleCount, 1);
    });

    test('잘못된 커맨드는 BridgeException(JSON 오류)으로 돌아온다', () async {
      await loadRustCore();
      final String createdAt = await bridge.createProject(
        name: '오류 테스트',
        width: 1080,
        height: 1920,
        fps: 30,
      );
      final EditorState created = EditorState.fromEnvelope(createdAt);
      await expectLater(
        bridge.applyCommand(jsonEncode(created.raw), <String, dynamic>{
          'type': 'nope',
        }),
        throwsA(
          isA<BridgeException>().having(
            (BridgeException error) => error.code,
            'code',
            'bad_command',
          ),
        ),
      );
    });

    test('내보내기 계획과 렌더 그래프', () async {
      await loadRustCore();
      final String createdAt = await bridge.createProject(
        name: '내보내기 테스트',
        width: 1080,
        height: 1920,
        fps: 30,
      );
      final EditorState created = EditorState.fromEnvelope(createdAt);
      final String stateJson = jsonEncode(created.raw);
      final String planAt = await bridge.exportPlan(
        stateJson: stateJson,
        settingsJson: '',
        platformId: 'android',
      );
      final Map<String, dynamic> plan =
          jsonDecode(planAt) as Map<String, dynamic>;
      expect(plan['ok'], isTrue);
      expect((plan['plan'] as Map<String, dynamic>)['watermark'], isFalse);

      final String graphAt = await bridge.renderGraph(
        stateJson: stateJson,
        settingsJson: '',
        platformId: 'android',
      );
      final Map<String, dynamic> graph =
          jsonDecode(graphAt) as Map<String, dynamic>;
      expect(graph['ok'], isTrue);
      expect((graph['graph'] as Map<String, dynamic>)['frame_count'], 0);
    });
  }, skip: skipReason);
}
