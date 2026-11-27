// Meta Edits 스타일 모바일 편집 화면(v0.1.8) 위젯 테스트.
//
//  * 상단 바: 프로젝트 이름(탭 → 이름 변경) + 해상도 배지 + 내보내기
//  * 컴팩트 트랜스포트: 되돌리기/다시 적용 · 재생 + 현재/전체 · 전체화면
//  * 슬림 타임라인: 좁은 아이콘 레일, 클립 끝 `+`
//  * 하단 가로 스크롤 메인/컨텍스트 툴바와 인라인 패널(프리뷰를 가리지 않음)
//  * 오디오 추출: 비디오 클립 → 오디오 트랙, 원본 무음, 한 번에 되돌리기
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muud_edits/bridge_api.dart';
import 'package:muud_edits/editor/editor_screen.dart';
import 'package:muud_edits/editor/mobile_toolbar.dart';
import 'package:muud_edits/editor/timeline_view.dart';
import 'package:muud_edits/editor/workspace.dart';
import 'package:muud_edits/media/media_platform_bridge.dart';
import 'package:muud_edits/models.dart';
import 'package:muud_edits/rust_core_loader.dart';
import 'package:muud_edits/theme.dart';

import 'support/fake_core_bridge.dart';

const Size _phone = Size(390, 844);

Future<EditorController> _pumpPhone(
  WidgetTester tester, {
  bool withClip = true,
  FakeMediaPlatformBridge? media,
}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  rustCore = const RustCoreLoadResult(loadedFrom: 'test');
  final EditorController controller = EditorController(
    bridge: FakeCoreBridge(),
    media: media ?? FakeMediaPlatformBridge(),
  );
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEditorTheme(),
      home: EditorScreen(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
  if (withClip) {
    await controller.addMediaFile('/media/first.mp4');
    await tester.pumpAndSettle();
  }
  return controller;
}

Future<void> _tapTool(WidgetTester tester, String label) async {
  final Finder target = find.byKey(ValueKey<String>('mobile-tool-$label'));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

({TrackView track, ClipView clip}) _firstClip(EditorController controller) =>
    (track: controller.state!.tracks.first, clip: controller.state!.tracks.first.clips.first);

void main() {
  group('상단 바', () {
    testWidgets('프로젝트 이름·해상도 배지·내보내기가 한 줄에 있다', (WidgetTester tester) async {
      await _pumpPhone(tester);

      expect(find.byKey(projectNameKey), findsOneWidget);
      expect(find.byKey(qualityBadgeKey), findsOneWidget);
      expect(find.text('1080p'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '내보내기'), findsOneWidget);
    });

    testWidgets('이름을 탭하면 이름을 바꿀 수 있다', (WidgetTester tester) async {
      final EditorController controller = await _pumpPhone(tester);

      await tester.tap(find.byKey(projectNameKey));
      await tester.pumpAndSettle();
      expect(find.text('프로젝트 이름'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '상하이 마라톤');
      await tester.tap(find.widgetWithText(FilledButton, '저장'));
      await tester.pumpAndSettle();

      expect(controller.error, isNull);
      expect(controller.state!.summary.name, '상하이 마라톤');
      expect(find.text('상하이 마라톤'), findsOneWidget);
    });
  });

  group('컴팩트 트랜스포트', () {
    testWidgets('줌 바 없이 되돌리기·재생·시간·전체화면이 한 줄에 있다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _pumpPhone(tester);

      expect(find.byTooltip('되돌리기'), findsOneWidget);
      expect(find.byTooltip('다시 적용'), findsOneWidget);
      expect(find.byTooltip('재생'), findsOneWidget);
      expect(find.text('00:00:00.000 / 00:00:04.000'), findsOneWidget);
      expect(find.byTooltip('전체화면'), findsOneWidget);
      expect(find.byTooltip('축소'), findsNothing);

      await tester.tap(find.byTooltip('전체화면'));
      await tester.pumpAndSettle();
      expect(find.byKey(previewFullscreenKey), findsOneWidget);
      // 전체화면에서는 타임라인·툴바를 숨긴다.
      expect(find.byKey(timelinePaneKey), findsNothing);
      expect(find.byKey(mobileToolbarKey), findsNothing);

      await tester.tap(find.byTooltip('전체화면 닫기'));
      await tester.pumpAndSettle();
      expect(find.byKey(previewFullscreenKey), findsNothing);
      expect(controller.durationMs, 4000);
    });
  });

  group('하단 툴바', () {
    testWidgets('선택이 없으면 메인 툴바, 선택하면 컨텍스트 툴바', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _pumpPhone(tester);

      for (final String label in <String>['미디어 추가', '오디오', '텍스트', '오버레이', '자막', '필터·조정']) {
        expect(find.text(label), findsOneWidget, reason: '메인 툴바: $label');
      }

      controller.selectClip(_firstClip(controller).clip.id);
      await tester.pumpAndSettle();

      for (final String label in <String>['분할', '속도', '볼륨', '오디오 추출', '트림', '복제', '삭제']) {
        expect(find.text(label), findsOneWidget, reason: '비디오 컨텍스트: $label');
      }
      expect(find.text('미디어 추가'), findsNothing);
    });

    testWidgets('볼륨을 열면 인라인 패널이 뜨고 프리뷰는 계속 보인다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _pumpPhone(tester);
      controller.selectClip(_firstClip(controller).clip.id);
      await tester.pumpAndSettle();

      await _tapTool(tester, '볼륨');

      expect(find.byKey(mobilePanelKey), findsOneWidget);
      expect(find.byKey(previewPaneKey), findsOneWidget);
      expect(find.text('페이드 인'), findsOneWidget);

      // 다시 누르면 패널이 닫힌다.
      await _tapTool(tester, '볼륨');
      expect(find.byKey(mobilePanelKey), findsNothing);
    });

    testWidgets('속도 프리셋을 누르면 클립 배속이 바뀐다', (WidgetTester tester) async {
      final EditorController controller = await _pumpPhone(tester);
      controller.selectClip(_firstClip(controller).clip.id);
      await tester.pumpAndSettle();

      await _tapTool(tester, '속도');
      await tester.tap(find.text('2.0x'));
      await tester.pumpAndSettle();

      expect(controller.error, isNull);
      expect(controller.state!.tracks.first.clips.first.speed, 2.0);
    });

    testWidgets('트림 패널에서 소스 구간을 자를 수 있다', (WidgetTester tester) async {
      final EditorController controller = await _pumpPhone(tester);
      controller.selectClip(_firstClip(controller).clip.id);
      await tester.pumpAndSettle();

      await _tapTool(tester, '트림');
      expect(find.text('시작'), findsOneWidget);
      expect(find.text('끝'), findsOneWidget);

      await tester.tap(find.text('앞 1f'));
      await tester.pumpAndSettle();
      expect(controller.error, isNull);
      expect(controller.state!.tracks.first.clips.first.startMs, 33);
    });

    testWidgets('텍스트 클립은 수정·스타일을 제공하고 문구를 고칠 수 있다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _pumpPhone(tester, withClip: false);
      await controller.addTextOverlay('처음 문구');
      await tester.pumpAndSettle();
      final ClipView textClip = controller.state!.tracks
          .firstWhere((TrackView track) => track.kind == 'overlay')
          .clips
          .first;
      controller.selectClip(textClip.id);
      await tester.pumpAndSettle();

      expect(find.text('수정'), findsOneWidget);
      expect(find.text('스타일'), findsOneWidget);

      await _tapTool(tester, '수정');
      await tester.enterText(find.byType(TextField).last, '고친 문구');
      await tester.tap(find.widgetWithText(FilledButton, '적용'));
      await tester.pumpAndSettle();

      final ClipView updated = controller.state!.tracks
          .firstWhere((TrackView track) => track.kind == 'overlay')
          .clips
          .first;
      expect(controller.error, isNull);
      expect(updated.textContent, '고친 문구');
    });
  });

  group('오디오 추출', () {
    testWidgets('비디오 클립의 소리를 오디오 트랙으로 분리하고 원본을 무음으로 만든다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _pumpPhone(tester);
      final ({TrackView track, ClipView clip}) before = _firstClip(controller);
      controller.selectClip(before.clip.id);
      await tester.pumpAndSettle();

      await _tapTool(tester, '오디오 추출');

      expect(controller.error, isNull);
      final TrackView video = controller.state!.tracks.first;
      final TrackView audio = controller.state!.tracks
          .firstWhere((TrackView track) => track.kind == 'audio');
      expect(video.clips.single.volume, 0.0);
      expect(audio.clips.length, 1);
      final ClipView extracted = audio.clips.single;
      expect(extracted.kind, 'audio');
      expect(extracted.sourcePath, '/media/first.mp4');
      expect(extracted.startMs, before.clip.startMs);
      expect(extracted.endMs, before.clip.endMs);
      expect(extracted.offsetMs, before.clip.offsetMs);
      expect(extracted.volume, 1.0);
      // 결과 오디오 클립이 선택되어 바로 볼륨을 조절할 수 있다.
      expect(controller.selectedClipId, extracted.id);

      // 되돌리기 한 번이면 원본 볼륨 복구 + 오디오 클립 제거.
      await controller.undo();
      await tester.pumpAndSettle();
      expect(controller.state!.tracks.first.clips.single.volume, 1.0);
      expect(
        controller.state!.tracks
            .firstWhere((TrackView track) => track.kind == 'audio')
            .clips,
        isEmpty,
      );
    });

    testWidgets('오디오 스트림이 없는 영상은 안내만 하고 아무것도 바꾸지 않는다', (
      WidgetTester tester,
    ) async {
      final FakeMediaPlatformBridge media = FakeMediaPlatformBridge(
        probeResult: <String, dynamic>{
          'path': '/media/first.mp4',
          'duration_ms': 4000,
          'width': 1080,
          'height': 1920,
          'fps': 30.0,
          'has_video': true,
          'has_audio': false,
          'source': 'fake',
        },
      );
      final EditorController controller = await _pumpPhone(tester, media: media);
      controller.selectClip(_firstClip(controller).clip.id);
      await tester.pumpAndSettle();

      await _tapTool(tester, '오디오 추출');

      expect(find.textContaining('오디오 스트림이 없습니다'), findsOneWidget);
      expect(controller.state!.tracks.first.clips.single.volume, 1.0);
      expect(
        controller.state!.tracks
            .firstWhere((TrackView track) => track.kind == 'audio')
            .clips,
        isEmpty,
      );
    });

    testWidgets('오디오 클립을 선택하면 추출 대신 볼륨·속도·복제·삭제를 보여 준다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _pumpPhone(tester);
      controller.selectClip(_firstClip(controller).clip.id);
      await tester.pumpAndSettle();
      await _tapTool(tester, '오디오 추출');

      expect(find.text('오디오 추출'), findsNothing);
      expect(find.text('볼륨'), findsOneWidget);
      expect(find.text('속도'), findsOneWidget);
      expect(find.text('복제'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
    });
  });

  group('슬림 타임라인', () {
    test('좁은 레일은 48px이고 토글이 레일 안에 있다', () {
      final TimelineMetrics metrics = TimelineMetrics(
        width: 390,
        height: 220,
        durationMs: 4000,
        trackCount: 3,
        railWidth: 48,
        compact: true,
      );
      expect(metrics.laneLeft, 48);
      for (final TrackToggle toggle in TrackToggle.values) {
        final Rect rect = metrics.toggleRect(0, toggle);
        expect(rect.right, lessThanOrEqualTo(metrics.laneLeft));
      }
      // 클립이 차지하는 가로 폭이 넓어졌다(112 → 48 레일).
      final TimelineMetrics wide = TimelineMetrics(
        width: 390,
        height: 220,
        durationMs: 4000,
        trackCount: 3,
      );
      expect(metrics.contentWidth, greaterThan(wide.contentWidth));
    });

    testWidgets('비디오 트랙 끝의 + 를 누르면 클립 추가 콜백이 불린다', (
      WidgetTester tester,
    ) async {
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

      bool tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEditorTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 200,
              child: TimelineView(
                controller: controller,
                onAddClip: () => tapped = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final EditorState state = controller.state!;
      final TimelineMetrics metrics = TimelineMetrics(
        width: 390,
        height: 200,
        durationMs: state.durationMs,
        trackCount: state.tracks.length,
        railWidth: 48,
        compact: true,
      );
      final Rect rect = timelineAddClipRect(state, metrics);
      expect(rect.isEmpty, isFalse);

      final Rect view = tester.getRect(find.byType(TimelineView));
      await tester.tapAt(view.topLeft + rect.center);
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });
  });

  testWidgets('좁은 화면에서도 모든 편집이 예외 없이 동작한다', (WidgetTester tester) async {
    final EditorController controller = await _pumpPhone(tester);
    controller.selectClip(_firstClip(controller).clip.id);
    await tester.pumpAndSettle();

    await _tapTool(tester, '복제');
    expect(controller.state!.summary.clipCount, 2);

    await _tapTool(tester, '삭제');
    expect(controller.state!.summary.clipCount, 1);
    expect(tester.takeException(), isNull);
  });
}
