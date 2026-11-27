// 타임라인 조작 테스트(v0.1.6).
//
//  * 줌 배율과 가로 스크롤이 좌표 계산에 일관되게 반영되는가
//  * 클립 본체/좌우 핸들 히트 테스트와 드래그 커밋(이동·트림)
//  * 거터의 트랙 토글(음소거/숨김/잠금)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muud_edits/bridge_api.dart';
import 'package:muud_edits/editor/timeline_view.dart';
import 'package:muud_edits/media/media_platform_bridge.dart';
import 'package:muud_edits/models.dart';
import 'package:muud_edits/rust_core_loader.dart';
import 'package:muud_edits/theme.dart';

import 'support/fake_core_bridge.dart';

ClipView _clip({
  required String id,
  String path = '/a.mp4',
  int startMs = 0,
  int endMs = 4000,
  int offsetMs = 0,
  int? sourceDurationMs = 4000,
  String kind = 'video',
}) {
  return ClipView(
    id: id,
    kind: kind,
    sourcePath: path,
    startMs: startMs,
    endMs: endMs,
    offsetMs: offsetMs,
    speed: 1,
    volume: 1,
    opacity: 1,
    enabled: true,
    textContent: null,
    sourceDurationMs: sourceDurationMs,
  );
}

TrackView _track(
  String kind,
  List<ClipView> clips, {
  bool hidden = false,
  bool muted = false,
  bool locked = false,
}) {
  return TrackView(
    id: 'trk-$kind',
    name: kind,
    kind: kind,
    muted: muted,
    hidden: hidden,
    locked: locked,
    clips: clips,
  );
}

EditorState _state(List<TrackView> tracks) {
  return EditorState(
    raw: const <String, dynamic>{},
    summary: ProjectSummary.fromJson(<String, dynamic>{
      'id': 'prj',
      'name': '테스트',
      'resolution': <String, dynamic>{'width': 1080, 'height': 1920},
      'fps': 30,
      'duration_ms': 4000,
      'clip_count': 1,
    }),
    tracks: tracks,
    subtitles: const <SubtitleView>[],
  );
}

Future<EditorController> _controllerWithClip(WidgetTester tester) async {
  rustCore = const RustCoreLoadResult(loadedFrom: 'test');
  final EditorController controller = EditorController(
    bridge: FakeCoreBridge(),
    media: FakeMediaPlatformBridge(),
  );
  addTearDown(controller.dispose);
  await controller.bootstrap();
  await controller.addMediaClip(
    sourcePath: '/a.mp4',
    kind: 'video',
    startMs: 0,
    endMs: 4000,
    sourceDurationMs: 4000,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEditorTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 260,
          child: TimelineView(controller: controller),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('TimelineMetrics(줌·스크롤)', () {
    test('줌 배율이 pxPerMs 에 비례한다', () {
      final TimelineMetrics fit = TimelineMetrics(
        width: 800,
        height: 240,
        durationMs: 4000,
        trackCount: 3,
      );
      final TimelineMetrics zoomed = TimelineMetrics(
        width: 800,
        height: 240,
        durationMs: 4000,
        trackCount: 3,
        zoom: 2,
      );
      expect(zoomed.pxPerMs, closeTo(fit.pxPerMs * 2, 1e-9));
      // 줌을 키우면 같은 시간이 더 오른쪽에 그려진다.
      expect(zoomed.xForTime(2000), greaterThan(fit.xForTime(2000)));
    });

    test('스크롤 오프셋이 화면 왼쪽 끝 시각이 된다', () {
      final TimelineMetrics metrics = TimelineMetrics(
        width: 800,
        height: 240,
        durationMs: 60000,
        trackCount: 3,
        zoom: 4,
        scrollMs: 5000,
      );
      expect(metrics.xForTime(5000), closeTo(metrics.laneLeft, 1e-6));
      expect(metrics.timeAt(metrics.laneLeft), 5000);
      // 왕복 변환이 일관된다.
      final double x = metrics.xForTime(12345);
      expect(metrics.timeAt(x), closeTo(12345, 2));
    });

    test('스크롤은 전체 범위를 넘지 않는다', () {
      final TimelineMetrics metrics = TimelineMetrics(
        width: 800,
        height: 240,
        durationMs: 4000,
        trackCount: 3,
        scrollMs: 999999,
      );
      expect(metrics.scrollMs, lessThanOrEqualTo(metrics.maxScrollMs));
    });

    test('클립 본체와 좌우 핸들을 구분하고, 거터는 클립이 아니다', () {
      final TimelineMetrics metrics = TimelineMetrics(
        width: 800,
        height: 240,
        durationMs: 4000,
        trackCount: 3,
      );
      final EditorState state = _state(<TrackView>[
        _track('video', <ClipView>[_clip(id: 'v1')]),
      ]);
      final double laneY = metrics.laneRect(0).center.dy;
      final double left = metrics.xForTime(0);
      final double right = metrics.xForTime(4000);

      expect(
        metrics.hitTestClip(state, Offset(left + 3, laneY))?.zone,
        ClipZone.trimStart,
      );
      expect(
        metrics.hitTestClip(state, Offset(right - 3, laneY))?.zone,
        ClipZone.trimEnd,
      );
      expect(
        metrics.hitTestClip(state, Offset((left + right) / 2, laneY))?.zone,
        ClipZone.move,
      );
      expect(
        metrics.hitTestClip(state, Offset(10, laneY)),
        isNull,
        reason: '거터는 클립 영역이 아니다',
      );
    });

    test('트랙 토글 사각형은 거터 안에 있다', () {
      final TimelineMetrics metrics = TimelineMetrics(
        width: 800,
        height: 240,
        durationMs: 4000,
        trackCount: 3,
      );
      for (final TrackToggle toggle in TrackToggle.values) {
        final Rect rect = metrics.toggleRect(0, toggle);
        expect(rect.right, lessThan(metrics.laneLeft));
        expect(rect.height, greaterThan(10));
      }
      // 세 토글이 서로 겹치지 않는다.
      final Rect mute = metrics.toggleRect(0, TrackToggle.mute);
      final Rect hide = metrics.toggleRect(0, TrackToggle.hide);
      expect(mute.overlaps(hide), isFalse);
    });
  });

  group('타임라인 드래그', () {
    testWidgets('클립 본체를 끌면 시간 이동 커맨드가 한 번 나간다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _controllerWithClip(tester);
      final Rect view = tester.getRect(find.byType(TimelineView));
      final double laneY = view.top + 30 + 26 + 22; // 툴바 + 눈금 + 행 중앙
      final double startX = view.left + 112 + 200;

      final TestGesture gesture = await tester.startGesture(
        Offset(startX, laneY),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(66, 0));
      await tester.pump();
      // 드래그 중에는 아직 커맨드가 나가지 않는다(로컬 미리보기만).
      expect(controller.state!.tracks.first.clips.first.offsetMs, 0);
      await gesture.up();
      await tester.pumpAndSettle();

      final ClipView clip = controller.state!.tracks.first.clips.first;
      // 800px 폭 · 8000ms 기준이라 66px ≈ 800ms.
      expect(clip.offsetMs, greaterThan(400));
      expect(clip.offsetMs, lessThan(1200));
    });

    testWidgets('오른쪽 끝을 끌면 트림 커맨드가 나간다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _controllerWithClip(tester);
      final Rect view = tester.getRect(find.byType(TimelineView));
      final double laneY = view.top + 30 + 26 + 22;
      // 자연 폭(800px)에서 4000ms 클립의 오른쪽 끝.
      final double rightX = view.left + 112 + (4000 * (660 / 8000));

      final TestGesture gesture = await tester.startGesture(
        Offset(rightX - 4, laneY),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final ClipView clip = controller.state!.tracks.first.clips.first;
      expect(clip.startMs, 0);
      expect(clip.endMs, lessThan(4000));
      expect(clip.endMs, greaterThan(2000));
    });
  });

  group('트랙 헤더 토글', () {
    testWidgets('거터의 음소거 아이콘을 누르면 트랙이 음소거된다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _controllerWithClip(tester);
      final Rect view = tester.getRect(find.byType(TimelineView));
      // toggleRect(0, mute) = (26, 26+44-20) ~ (46, 66)
      final Offset tap = Offset(view.left + 36, view.top + 30 + 58);
      await tester.tapAt(tap);
      await tester.pumpAndSettle();

      expect(controller.state!.tracks.first.muted, isTrue);
    });

    testWidgets('잠금 아이콘을 누르면 잠금이 켜진다', (WidgetTester tester) async {
      final EditorController controller = await _controllerWithClip(tester);
      final Rect view = tester.getRect(find.byType(TimelineView));
      // toggleRect(0, lock) = (26 + 2*24, 50) ~ (+20, 66)
      final Offset tap = Offset(view.left + 26 + 48 + 10, view.top + 30 + 58);
      await tester.tapAt(tap);
      await tester.pumpAndSettle();

      expect(controller.state!.tracks.first.locked, isTrue);
    });
  });
}
