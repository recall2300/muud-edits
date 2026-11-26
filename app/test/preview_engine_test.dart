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
  group('재생 시계(MediaPositionClock)', () {
    test('보고 간격이 길어져도 멈췄다가 점프하지 않는다', () {
      final MediaPositionClock clock = MediaPositionClock();
      expect(clock.advance(0, 0), 0);
      // 플랫폼 채널이 밀려 보고가 300ms 간격으로 도착하는 경우.
      expect(clock.advance(300, 300), 300);
      // 다음 보고 전까지 260ms 흘렀다: 기본 상한(160ms)에서 멈추면 안 된다.
      expect(clock.advance(300, 560), 560);
    });

    test('보고가 끊기면 기본 한도까지만 앞선다', () {
      final MediaPositionClock clock = MediaPositionClock();
      expect(clock.advance(0, 0), 0);
      // 간격 정보가 없으면 기본 상한(160ms)에서 멈춘다(플레이어가 정지한 경우).
      expect(clock.advance(0, 5000), 160);
    });

    test('보고 간격을 안 뒤에는 그 두 배까지만 허용하고 절대 한도를 넘지 않는다', () {
      final MediaPositionClock clock = MediaPositionClock();
      expect(clock.advance(0, 0), 0);
      expect(clock.advance(300, 300), 300);
      // 300ms 간격의 두 배(600)가 아니라 maxReportGapMs(400)에서 멈춘다.
      expect(clock.advance(300, 5000), 300 + 400);
    });
  });

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
    test('재생 중에는 플레이어 위치가 플레이헤드를 이끈다(이어 재생 시 시크 없음)', () {
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

        final FakePreviewMediaFactory factory = FakePreviewMediaFactory(
          clockMs: () => now,
        );
        final PreviewEngine engine = PreviewEngine(
          controller: controller,
          mediaFactory: factory,
          clockMs: () => now,
          tickInterval: const Duration(milliseconds: 20),
        );
        addTearDown(engine.dispose);
        addTearDown(controller.dispose);

        engine.play();
        async.flushMicrotasks();
        expect(engine.isPlaying, isTrue);
        expect(factory.opened, <String>['/a.mp4']);

        final FakePreviewMedia media = factory.media['/a.mp4']!;
        // 시작 위치가 이미 맞으면 시크하지 않는다.
        expect(media.seekCount, 0);

        now += 500;
        async.elapse(const Duration(milliseconds: 20));
        expect(engine.positionMs, 500);

        now += 500;
        async.elapse(const Duration(milliseconds: 20));
        expect(engine.positionMs, 1000);
        // 같은 클립을 이어 재생하는 동안에는 시크가 늘지 않는다(끊김 없음).
        expect(media.seekCount, 0);
        // 재생 중에는 컨트롤러를 매 프레임 건드리지 않는다(화면 전체 리빌드 방지).
        expect(controller.playheadMs, 0);

        engine.pause();
        async.flushMicrotasks();
        expect(engine.isPlaying, isFalse);
        expect(media.playing, isFalse);
        // 일시정지하면 그 위치가 컨트롤러에 반영된다.
        expect(controller.playheadMs, 1000);
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
        async.elapse(const Duration(milliseconds: 40));
        async.flushMicrotasks();

        final FakePreviewMedia media = factory.media['/a.mp4']!;
        expect(media.positionMs, closeTo(2400, 120));
        expect(engine.positionMs, 2400);
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

        final FakePreviewMediaFactory factory = FakePreviewMediaFactory(
          clockMs: () => now,
        );
        final PreviewEngine engine = PreviewEngine(
          controller: controller,
          mediaFactory: factory,
          clockMs: () => now,
          tickInterval: const Duration(milliseconds: 20),
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

    test('다음 클립은 경계 전에 미리 열어 두고, 경계에서 다시 열지 않는다', () {
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
          endMs: 3000,
          sourceDurationMs: 3000,
        );
        async.flushMicrotasks();
        controller.addMediaClip(
          sourcePath: '/second.mp4',
          kind: 'video',
          startMs: 0,
          endMs: 3000,
          sourceDurationMs: 3000,
        );
        async.flushMicrotasks();

        final FakePreviewMediaFactory factory = FakePreviewMediaFactory(
          clockMs: () => now,
        );
        final PreviewEngine engine = PreviewEngine(
          controller: controller,
          mediaFactory: factory,
          clockMs: () => now,
          tickInterval: const Duration(milliseconds: 20),
        );
        addTearDown(engine.dispose);
        addTearDown(controller.dispose);

        engine.play();
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(factory.opened, <String>['/first.mp4']);

        // 클립 끝까지 1400ms 남은 시점 → 다음 클립을 미리 연다.
        now += 1600;
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(factory.opened, <String>['/first.mp4', '/second.mp4']);

        // 경계를 넘어도 새로 열기(=전환 지연)가 없다.
        now += 1500;
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(
          factory.opened.where((String path) => path == '/second.mp4').length,
          1,
        );
        expect(engine.selection.visualPath, '/second.mp4');
      });
    });

    test('짧은 클립으로 넘어가도 미리 연 컨트롤러를 버리지 않는다', () {
      fakeAsync((FakeAsync async) {
        int now = 0;
        final EditorController controller = EditorController(
          bridge: FakeCoreBridge(),
          media: FakeMediaPlatformBridge(),
        );
        controller.bootstrap();
        async.flushMicrotasks();
        for (final (String path, int start, int end) in <(String, int, int)>[
          ('/a.mp4', 0, 3000),
          ('/b.mp4', 0, 1000),
          ('/c.mp4', 0, 3000),
        ]) {
          controller.addMediaClip(
            sourcePath: path,
            kind: 'video',
            startMs: start,
            endMs: end,
            sourceDurationMs: end - start,
          );
          async.flushMicrotasks();
        }

        final FakePreviewMediaFactory factory = FakePreviewMediaFactory(
          clockMs: () => now,
        );
        final PreviewEngine engine = PreviewEngine(
          controller: controller,
          mediaFactory: factory,
          clockMs: () => now,
          tickInterval: const Duration(milliseconds: 20),
        );
        addTearDown(engine.dispose);
        addTearDown(controller.dispose);

        engine.play();
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();

        now += 1600; // A 끝까지 1400ms → B 를 미리 연다
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(factory.opened, <String>['/a.mp4', '/b.mp4']);

        now += 1500; // B(1초) 안으로 들어간다
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(engine.selection.visualPath, '/b.mp4');
        // 미리 열어 둔 B 를 그대로 쓰고 버리지 않는다.
        expect(factory.media['/b.mp4']!.disposed, isFalse);
        expect(
          factory.opened.where((String path) => path == '/b.mp4').length,
          1,
        );
      });
    });

    test('같은 파일을 자른 두 클립은 클립이 바뀔 때만 시크한다', () {
      fakeAsync((FakeAsync async) {
        int now = 0;
        final EditorController controller = EditorController(
          bridge: FakeCoreBridge(),
          media: FakeMediaPlatformBridge(),
        );
        controller.bootstrap();
        async.flushMicrotasks();
        // 첫 클립: 소스 0~1000ms · 둘째 클립: 소스 2000~3000ms(같은 파일의 다른 대목).
        controller.addMediaClip(
          sourcePath: '/a.mp4',
          kind: 'video',
          startMs: 0,
          endMs: 1000,
          sourceDurationMs: 1000,
        );
        async.flushMicrotasks();
        controller.addMediaClip(
          sourcePath: '/a.mp4',
          kind: 'video',
          startMs: 2000,
          endMs: 3000,
          sourceDurationMs: 1000,
        );
        async.flushMicrotasks();
        expect(controller.durationMs, 2000);

        final FakePreviewMediaFactory factory = FakePreviewMediaFactory(
          clockMs: () => now,
        );
        final PreviewEngine engine = PreviewEngine(
          controller: controller,
          mediaFactory: factory,
          clockMs: () => now,
          tickInterval: const Duration(milliseconds: 20),
        );
        addTearDown(engine.dispose);
        addTearDown(controller.dispose);

        engine.play();
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        final FakePreviewMedia media = factory.media['/a.mp4']!;
        // 클립이 두 개여도 파일은 하나만 열린다.
        expect(factory.opened, <String>['/a.mp4']);

        // 첫 클립 안에서 이어 재생: 시크 없음.
        now += 600;
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(engine.positionMs, 600);
        expect(media.seekCount, 0);

        // 두 번째 클립으로 넘어가면 인점(소스 2000ms)으로 한 번 시크한다.
        now += 600;
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(engine.selection.visualClip?.id, isNotNull);
        expect(engine.positionMs, 1200);
        expect(media.seekCount, 1);
        expect(media.positionMs, greaterThanOrEqualTo(2000));
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

  group('단일 영상 이어 재생(끊김 회귀)', () {
    test('이어 재생 중에는 틱마다 플랫폼 호출이 없다', () {
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

        final FakePreviewMediaFactory factory = FakePreviewMediaFactory(
          clockMs: () => now,
        );
        final PreviewEngine engine = PreviewEngine(
          controller: controller,
          mediaFactory: factory,
          clockMs: () => now,
          tickInterval: const Duration(milliseconds: 20),
        );
        addTearDown(engine.dispose);
        addTearDown(controller.dispose);

        engine.play();
        async.flushMicrotasks();
        final FakePreviewMedia media = factory.media['/a.mp4']!;
        expect(media.playCount, 1);
        expect(media.seekCount, 0);
        final int volumeCallsAtStart = media.volumeCalls;
        final int speedCallsAtStart = media.speedCalls;
        final int readsAtStart = media.positionReads;

        // 10틱(200ms)을 그냥 흘려보낸다 — 플레이어를 건드리는 일이 없어야 한다.
        for (int i = 0; i < 10; i++) {
          now += 20;
          async.elapse(const Duration(milliseconds: 20));
        }

        expect(engine.positionMs, 200);
        expect(media.seekCount, 0, reason: '이어 재생 중 시크 금지');
        expect(media.playCount, 1, reason: '재생 시작은 한 번만');
        expect(media.pauseCount, 0);
        expect(media.volumeCalls, volumeCallsAtStart, reason: '볼륨은 바뀔 때만');
        expect(media.speedCalls, speedCallsAtStart, reason: '속도는 바뀔 때만');
        // 플레이헤드는 캐시된 위치만 읽는다(플랫폼 채널 왕복 없음).
        expect(media.positionReads, greaterThan(readsAtStart));
        // 재생 중 컨트롤러(화면 전체 리빌드)도 건드리지 않는다.
        expect(controller.playheadMs, 0);
      });
    });

    test('열기가 끝나기 전에 재생/일시정지를 반복해도 플레이어는 한 번만 열린다', () {
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

        final FakePreviewMediaFactory factory = FakePreviewMediaFactory(
          clockMs: () => now,
        );
        final PreviewEngine engine = PreviewEngine(
          controller: controller,
          mediaFactory: factory,
          clockMs: () => now,
          tickInterval: const Duration(milliseconds: 20),
        );
        addTearDown(engine.dispose);
        addTearDown(controller.dispose);

        // 열기·정렬이 끝나기 전에 상태가 여러 번 바뀐다.
        engine.play();
        engine.pause();
        engine.play();
        async.flushMicrotasks();

        final FakePreviewMedia media = factory.media['/a.mp4']!;
        expect(factory.opened, <String>['/a.mp4'], reason: '열기는 한 번');
        expect(media.seekCount, 0);
        // 마지막 상태(재생 중)로 정리된다.
        expect(engine.isPlaying, isTrue);
        expect(media.playing, isTrue);

        engine.pause();
        async.flushMicrotasks();
        expect(media.playing, isFalse);
      });
    });

    test('스크럽이 연달아 들어오면 마지막 위치로 한 번만 맞춘다', () {
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

        final FakePreviewMediaFactory factory = FakePreviewMediaFactory(
          clockMs: () => now,
        );
        final PreviewEngine engine = PreviewEngine(
          controller: controller,
          mediaFactory: factory,
          clockMs: () => now,
          tickInterval: const Duration(milliseconds: 20),
        );
        addTearDown(engine.dispose);
        addTearDown(controller.dispose);

        // 첫 정렬을 끝낸 뒤(일시정지 상태) 연달아 스크럽한다.
        engine.play();
        async.flushMicrotasks();
        engine.pause();
        async.flushMicrotasks();

        final FakePreviewMedia media = factory.media['/a.mp4']!;
        final int seeksBefore = media.seekCount;
        controller.setPlayhead(2000);
        controller.setPlayhead(2400);
        async.flushMicrotasks();

        expect(media.seekCount - seeksBefore, 1, reason: '마지막 요청만 반영');
        expect(media.positionMs, closeTo(2400, 60));
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

    testWidgets('영상 표면은 불투명할 때 Opacity·FittedBox 래퍼 없이 비율만 맞춘다', (
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

      final PreviewEngine engine = PreviewEngine(
        controller: controller,
        mediaFactory: FakePreviewMediaFactory(),
      );
      addTearDown(engine.dispose);

      // 일시정지 상태에서 위치를 옮기면 플레이어가 그 위치로 열리고 정렬된다.
      controller.setPlayhead(100);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEditorTheme(),
          home: Scaffold(
            body: PreviewPanel(controller: controller, engine: engine),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final Finder panel = find.byType(PreviewPanel);
      // 영상 텍스처는 표시 크기에 바로 맞춰 그린다(축소 변환 래퍼 없음).
      expect(
        find.descendant(of: panel, matching: find.byType(FittedBox)),
        findsNothing,
      );
      // 불투명 클립을 Opacity 로 감싸지 않는다(저장 레이어/복사 경로 방지).
      expect(
        find.descendant(of: panel, matching: find.byType(Opacity)),
        findsNothing,
      );
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
