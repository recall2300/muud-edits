// 타임라인 ↔ 프리뷰 동기화 테스트.
//
// 재생 플러그인 없이(가짜 미디어 팩토리) 검증하는 것:
//  * 재생 헤드 시각이 어떤 클립의 어느 소스 시각으로 매핑되는가(트림·배속·빈 구간)
//  * 재생/일시정지, 스크럽 시 시크
//  * 클립 경계를 넘을 때 다음 클립으로 전환
//  * 자막/텍스트 오버레이가 프리뷰에 시각에 맞춰 보이는가
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muud_edits/bridge_api.dart';
import 'package:muud_edits/editor/preview_engine.dart';
import 'package:muud_edits/editor/preview_panel.dart';
import 'package:muud_edits/media/media_platform_bridge.dart';
import 'package:muud_edits/models.dart';
import 'package:muud_edits/rust_core_loader.dart';
import 'package:muud_edits/theme.dart';

import 'support/fake_core_bridge.dart';

Future<EditorController> _controller() async {
  rustCore = const RustCoreLoadResult(loadedFrom: 'test');
  final EditorController controller = EditorController(
    bridge: FakeCoreBridge(),
    media: FakeMediaPlatformBridge(),
  );
  await controller.bootstrap();
  return controller;
}

ClipView _clip({
  required String id,
  required String path,
  int startMs = 0,
  int endMs = 4000,
  int offsetMs = 0,
  double speed = 1,
  double volume = 1,
  double opacity = 1,
  String kind = 'video',
  bool enabled = true,
}) {
  return ClipView(
    id: id,
    kind: kind,
    sourcePath: path,
    startMs: startMs,
    endMs: endMs,
    offsetMs: offsetMs,
    speed: speed,
    volume: volume,
    opacity: opacity,
    enabled: enabled,
    textContent: null,
  );
}

EditorState _state(List<TrackView> tracks, {List<SubtitleView>? subtitles}) {
  return EditorState(
    raw: const <String, dynamic>{},
    summary: ProjectSummary.fromJson(<String, dynamic>{
      'id': 'prj',
      'name': '테스트',
      'resolution': <String, dynamic>{'width': 1080, 'height': 1920},
      'fps': 30,
      'duration_ms': 8000,
      'clip_count': 1,
    }),
    tracks: tracks,
    subtitles: subtitles ?? const <SubtitleView>[],
  );
}

TrackView _track(
  String kind,
  List<ClipView> clips, {
  bool hidden = false,
  bool muted = false,
}) {
  return TrackView(
    id: 'trk-$kind',
    name: kind,
    kind: kind,
    muted: muted,
    hidden: hidden,
    locked: false,
    clips: clips,
  );
}

void main() {
  group('소스 시각 매핑', () {
    test('트림과 배속을 반영한다', () {
      final ClipView clip = _clip(
        id: 'c1',
        path: '/a.mp4',
        startMs: 2000,
        endMs: 6000,
        offsetMs: 1000,
        speed: 2,
      );
      // 타임라인 1000 → 소스 2000
      expect(sourceTimeFor(clip, 1000), 2000);
      // 타임라인 +500 → 소스 +1000 (2배속)
      expect(sourceTimeFor(clip, 1500), 3000);
      // 소스 아웃점을 넘지 않는다.
      expect(sourceTimeFor(clip, 99999), 5999);
      // 타임라인 시작 전은 소스 인점.
      expect(sourceTimeFor(clip, 0), 2000);
    });

    test('소스 → 타임라인 역변환', () {
      final ClipView clip = _clip(
        id: 'c1',
        path: '/a.mp4',
        startMs: 0,
        endMs: 4000,
        offsetMs: 2000,
        speed: 2,
      );
      expect(timelineTimeFor(clip, 1000), 2500);
    });
  });

  group('재생 헤드 → 클립 선택', () {
    test('가장 위 트랙의 영상 클립을 고른다', () {
      final ClipView lower = _clip(id: 'v1', path: '/lower.mp4');
      final ClipView upper = _clip(
        id: 'v2',
        path: '/upper.mp4',
        offsetMs: 1000,
        startMs: 0,
        endMs: 2000,
      );
      final EditorState state = _state(<TrackView>[
        _track('video', <ClipView>[lower]),
        _track('video', <ClipView>[upper]),
      ]);
      expect(resolvePreviewSelection(state, 500).visualPath, '/lower.mp4');
      expect(resolvePreviewSelection(state, 1500).visualPath, '/upper.mp4');
      expect(resolvePreviewSelection(state, 3500).visualPath, '/lower.mp4');
    });

    test('숨긴 트랙·빈 구간·비활성 클립은 제외한다', () {
      final EditorState state = _state(<TrackView>[
        _track('video', <ClipView>[
          _clip(id: 'v1', path: '/hidden.mp4'),
        ], hidden: true),
        _track('video', <ClipView>[
          _clip(id: 'v2', path: '/off.mp4', enabled: false),
        ]),
      ]);
      final PreviewSelection selection = resolvePreviewSelection(state, 1000);
      expect(selection.visualClip, isNull);
      expect(selection.isGap, isTrue);
    });

    test('별도 오디오 클립을 함께 고르고 볼륨을 반영한다', () {
      final EditorState state = _state(<TrackView>[
        _track('video', <ClipView>[
          _clip(id: 'v1', path: '/a.mp4', volume: 0.4),
        ]),
        _track('audio', <ClipView>[
          _clip(id: 'a1', path: '/music.m4a', endMs: 8000, volume: 1.5),
        ]),
      ]);
      final PreviewSelection selection = resolvePreviewSelection(state, 1000);
      expect(selection.visualPath, '/a.mp4');
      expect(selection.audioPath, '/music.m4a');
      // 플레이어 볼륨은 0~1로 제한된다.
      expect(selection.volume, 0.4);
      expect(selection.audioVolume, 1.0);
    });

    test('음소거 트랙은 볼륨 0', () {
      final EditorState state = _state(<TrackView>[
        _track('video', <ClipView>[_clip(id: 'v1', path: '/a.mp4')], muted: true),
      ]);
      expect(resolvePreviewSelection(state, 100).volume, 0);
    });
  });

  group('재생 엔진', () {
    test('재생하면 플레이헤드가 흐르고 플레이어가 재생된다', () {
      fakeAsync((FakeAsync async) {
        int now = 0;
        late EditorController controller;
        late PreviewEngine engine;
        late FakePreviewMediaFactory factory;

        controller = EditorController(
          bridge: FakeCoreBridge(),
          media: FakeMediaPlatformBridge(),
        );
        controller.bootstrap();
        async.flushMicrotasks();
        controller.addMediaClip(
          sourcePath: '/a.mp4',
          kind: 'video',
          startMs: 0,
          endMs: 4000,
          sourceDurationMs: 4000,
        );
        async.flushMicrotasks();

        factory = FakePreviewMediaFactory();
        engine = PreviewEngine(
          controller: controller,
          mediaFactory: factory,
          clockMs: () => now,
        );
        addTearDown(engine.dispose);
        addTearDown(controller.dispose);

        engine.play();
        async.flushMicrotasks();
        expect(engine.isPlaying, isTrue);
        expect(factory.opened, <String>['/a.mp4']);

        now += 500;
        async.elapse(const Duration(milliseconds: 20));
        expect(controller.playheadMs, 500);

        now += 500;
        async.elapse(const Duration(milliseconds: 20));
        expect(controller.playheadMs, 1000);

        engine.pause();
        async.flushMicrotasks();
        expect(engine.isPlaying, isFalse);
        expect(factory.media['/a.mp4']!.playing, isFalse);
      });
    });

    test('스크럽하면 해당 클립의 소스 시각으로 시크한다', () {
      fakeAsync((FakeAsync async) {
        int now = 0;
        final EditorController controller = EditorController(
          bridge: FakeCoreBridge(),
          media: FakeMediaPlatformBridge(),
        );
        controller.bootstrap();
        async.flushMicrotasks();
        controller.addMediaClip(
          sourcePath: '/a.mp4',
          kind: 'video',
          startMs: 0,
          endMs: 4000,
          sourceDurationMs: 4000,
        );
        async.flushMicrotasks();

        final FakePreviewMediaFactory factory = FakePreviewMediaFactory();
        final PreviewEngine engine = PreviewEngine(
          controller: controller,
          mediaFactory: factory,
          clockMs: () => now,
        );
        addTearDown(engine.dispose);
        addTearDown(controller.dispose);

        controller.setPlayhead(2400);
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();

        final FakePreviewMedia media = factory.media['/a.mp4']!;
        expect(media.position, closeTo(2400, 120));
      });
    });

    test('클립 경계를 넘으면 다음 클립으로 전환한다', () {
      fakeAsync((FakeAsync async) {
        int now = 0;
        final EditorController controller = EditorController(
          bridge: FakeCoreBridge(),
          media: FakeMediaPlatformBridge(),
        );
        controller.bootstrap();
        async.flushMicrotasks();
        controller.addMediaClip(
          sourcePath: '/first.mp4',
          kind: 'video',
          startMs: 0,
          endMs: 1000,
          sourceDurationMs: 1000,
        );
        async.flushMicrotasks();
        controller.addMediaClip(
          sourcePath: '/second.mp4',
          kind: 'video',
          startMs: 0,
          endMs: 1000,
          sourceDurationMs: 1000,
        );
        async.flushMicrotasks();
        expect(controller.durationMs, 2000);

        final FakePreviewMediaFactory factory = FakePreviewMediaFactory();
        final PreviewEngine engine = PreviewEngine(
          controller: controller,
          mediaFactory: factory,
          clockMs: () => now,
        );
        addTearDown(engine.dispose);
        addTearDown(controller.dispose);

        engine.play();
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(factory.opened.first, '/first.mp4');

        now += 1200;
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();

        expect(factory.opened, contains('/second.mp4'));
        expect(engine.selection.visualPath, '/second.mp4');
      });
    });

    test('재생할 수 없는 파일이면 오류를 알린다', () {
      fakeAsync((FakeAsync async) {
        final EditorController controller = EditorController(
          bridge: FakeCoreBridge(),
          media: FakeMediaPlatformBridge(),
        );
        controller.bootstrap();
        async.flushMicrotasks();
        controller.addMediaClip(
          sourcePath: '/broken.mp4',
          kind: 'video',
          startMs: 0,
          endMs: 1000,
          sourceDurationMs: 1000,
        );
        async.flushMicrotasks();

        final PreviewEngine engine = PreviewEngine(
          controller: controller,
          mediaFactory: FakePreviewMediaFactory(fail: true),
          clockMs: () => 0,
        );
        addTearDown(engine.dispose);
        addTearDown(controller.dispose);

        engine.play();
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(engine.error, contains('재생할 수 없음'));
      });
    });
  });

  group('프리뷰 오버레이', () {
    testWidgets('자막과 텍스트가 재생 헤드 시각에 맞춰 보인다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _controller();
      addTearDown(controller.dispose);
      await controller.addMediaClip(
        sourcePath: '/a.mp4',
        kind: 'video',
        startMs: 0,
        endMs: 4000,
        sourceDurationMs: 4000,
      );
      await controller.addTextOverlay('상하이 여행', durationMs: 3000);
      await controller.addSubtitleHere('첫날 아침');

      final PreviewEngine engine = PreviewEngine(
        controller: controller,
        mediaFactory: FakePreviewMediaFactory(),
      );
      addTearDown(engine.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildEditorTheme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (BuildContext context, Widget? child) =>
                  PreviewPanel(controller: controller, engine: engine),
            ),
          ),
        ),
      );
      await tester.pump();

      controller.setPlayhead(500);
      await tester.pump();
      expect(find.text('상하이 여행'), findsOneWidget);
      expect(find.text('첫날 아침'), findsOneWidget);

      // 자막 구간(2초)이 지나면 자막만 사라진다.
      controller.setPlayhead(2600);
      await tester.pump();
      expect(find.text('상하이 여행'), findsOneWidget);
      expect(find.text('첫날 아침'), findsNothing);
    });

    testWidgets('영상이 없는 구간은 안내 문구를 보여 준다', (WidgetTester tester) async {
      final EditorController controller = await _controller();
      addTearDown(controller.dispose);
      await controller.addMediaClip(
        sourcePath: '/a.mp4',
        kind: 'video',
        startMs: 0,
        endMs: 1000,
        sourceDurationMs: 1000,
      );
      final PreviewEngine engine = PreviewEngine(
        controller: controller,
        mediaFactory: FakePreviewMediaFactory(),
      );
      addTearDown(engine.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildEditorTheme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (BuildContext context, Widget? child) =>
                  PreviewPanel(controller: controller, engine: engine),
            ),
          ),
        ),
      );
      await tester.pump();
      controller.setPlayhead(3000);
      await tester.pump();
      expect(find.text('이 구간에는 영상이 없습니다'), findsOneWidget);
    });
  });
}
