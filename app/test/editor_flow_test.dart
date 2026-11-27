// 편집 화면 UI 흐름 테스트.
//
// 가짜 코어 브리지(FakeCoreBridge)를 끼워서, 앱을 처음 켠 사용자가
// "새 프로젝트 → 미디어 추가 → 편집 → 되돌리기 → 내보내기"를 막힘없이
// 지나갈 수 있는지 화면 단위로 확인한다.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muud_edits/bridge_api.dart';
import 'package:muud_edits/editor/editor_screen.dart';
import 'package:muud_edits/editor/preview_engine.dart';
import 'package:muud_edits/media/media_platform_bridge.dart';
import 'package:muud_edits/models.dart';
import 'package:muud_edits/rust_core_loader.dart';
import 'package:muud_edits/theme.dart';

import 'support/fake_core_bridge.dart';

Future<EditorController> _pumpEditor(
  WidgetTester tester, {
  FakeCoreBridge? bridge,
  FakeMediaPlatformBridge? media,
}) async {
  // 테스트 환경에는 실제 코어 라이브러리가 없으므로 "로드됨"으로 표시한다
  // (FrbCoreBridge 대신 FakeCoreBridge를 쓰기 때문).
  rustCore = const RustCoreLoadResult(loadedFrom: 'test');
  final EditorController controller = EditorController(
    bridge: bridge ?? FakeCoreBridge(),
    media: media ?? FakeMediaPlatformBridge(),
  );
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEditorTheme(),
      home: EditorScreen(controller: controller),
    ),
  );
  // bootstrap()은 첫 프레임 뒤에 돈다.
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  // 내보내기 경로는 path_provider 플러그인에서 온다. 테스트에는 플러그인이 없으므로
  // 문서 디렉터리를 흉내 내 준다(이게 없으면 내보내기가 시작되지 않는다).
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => '/tmp/muud-edits-test',
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });

  testWidgets('첫 화면에서 새 프로젝트가 자동으로 준비되고 시작 안내가 보인다', (
    WidgetTester tester,
  ) async {
    final EditorController controller = await _pumpEditor(tester);

    expect(controller.ready, isTrue);
    expect(find.text('새 프로젝트'), findsWidgets); // 앱바 제목
    expect(find.text('새 프로젝트가 준비됐어요'), findsOneWidget);
    expect(find.text('영상 · 사진 추가'), findsOneWidget);
    // 초기화 안내(개발자용 오류)가 아니라 정상 연결 안내가 보여야 한다.
    expect(find.textContaining('flutter_rust_bridge_codegen'), findsNothing);
    expect(controller.error, isNull);
  });

  testWidgets('미디어 추가 → 타임라인 반영 → 되돌리기', (WidgetTester tester) async {
    final EditorController controller = await _pumpEditor(tester);

    await controller.addMediaFile('/media/first.mp4');
    await tester.pumpAndSettle();

    expect(controller.state!.summary.clipCount, 1);
    expect(controller.durationMs, 4000); // FakeMediaPlatformBridge 프로브: 4000ms
    expect(find.text('영상 · 사진 추가'), findsNothing); // 빈 상태 안내는 사라진다

    await controller.undo();
    await tester.pumpAndSettle();
    expect(controller.state!.summary.clipCount, 0);
    expect(find.text('영상 · 사진 추가'), findsOneWidget);
  });

  testWidgets('텍스트·자막을 추가하면 프리뷰와 요약에 반영된다', (WidgetTester tester) async {
    final EditorController controller = await _pumpEditor(tester);

    await controller.addTextOverlay('안녕하세요');
    await controller.addSubtitleHere('첫 자막');
    await tester.pumpAndSettle();

    expect(controller.state!.summary.clipCount, 1);
    expect(controller.state!.summary.subtitleCount, 1);
    expect(find.text('안녕하세요'), findsOneWidget);
    expect(find.text('첫 자막'), findsWidgets);
  });

  testWidgets('새 프로젝트 버튼은 편집 내용을 버리기 전에 확인한다', (WidgetTester tester) async {
    final EditorController controller = await _pumpEditor(tester);
    await controller.addMediaFile('/media/first.mp4');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('새 프로젝트'));
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않은 편집이 있습니다. 버리고 새로 시작할까요?'), findsOneWidget);

    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(controller.state!.summary.clipCount, 1);

    await tester.tap(find.byTooltip('새 프로젝트'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('새로 시작'));
    await tester.pumpAndSettle();
    expect(controller.state!.summary.clipCount, 0);
  });

  testWidgets('내보내기 시트가 렌더 그래프와 계획을 보여 준다', (WidgetTester tester) async {
    final FakeMediaPlatformBridge media = FakeMediaPlatformBridge();
    final EditorController controller = await _pumpEditor(tester, media: media);
    await controller.addMediaFile('/media/first.mp4');
    await tester.pumpAndSettle();

    await tester.tap(find.text('내보내기'));
    // 시트에는 진행률 위젯(계속 도는 애니메이션)이 있어 pumpAndSettle 대신 고정 pump.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('내보내기 계획'), findsOneWidget);
    expect(controller.lastPlan, isNotNull);
    expect(controller.lastRenderPlan, isNotNull);

    await tester.tap(find.text('내보내기 시작'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.error, isNull);
    expect(media.exportStarted, isTrue);
    expect(media.lastOutputPath, contains('muud-edits-export-'));
  });

  testWidgets('자막 목록에서 문구를 고치고 지울 수 있다', (WidgetTester tester) async {
    final EditorController controller = await _pumpEditor(tester);
    await controller.addSubtitleHere('처음 자막');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('자막 목록 · 편집'));
    await tester.pumpAndSettle();
    expect(find.text('자막 1개'), findsOneWidget);

    await tester.tap(find.byTooltip('수정'));
    await tester.pumpAndSettle();
    expect(find.text('자막 수정'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '처음 자막'), '고친 자막');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(controller.error, isNull);
    expect(controller.state!.subtitles.first.text, '고친 자막');

    await tester.tap(find.byTooltip('삭제'));
    await tester.pumpAndSettle();
    expect(controller.state!.subtitles, isEmpty);
  });

  testWidgets('저장 버튼은 프로젝트를 저장하고 위치를 안내한다', (WidgetTester tester) async {
    final EditorController controller = await _pumpEditor(tester);
    await controller.addMediaFile('/media/first.mp4');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('저장'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(controller.error, isNull);
    expect(controller.lastSavedProjectPath, contains('muudproj'));
    expect(find.textContaining('프로젝트를 저장했습니다'), findsOneWidget);
  });

  testWidgets('내보내기가 끝나면 공유·열기 버튼과 저장 위치를 보여 준다', (
    WidgetTester tester,
  ) async {
    final FakeMediaPlatformBridge media = FakeMediaPlatformBridge();
    final EditorController controller = await _pumpEditor(tester, media: media);
    await controller.addMediaFile('/media/first.mp4');
    await tester.pumpAndSettle();

    await tester.tap(find.text('내보내기'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('내보내기 시작'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    media.emit(
      const MediaExportEvent(
        event: 'completed',
        state: 'completed',
        completedFrames: 120,
        totalFrames: 120,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(controller.exportProgress?.state, 'completed');
    expect(find.text('공유'), findsOneWidget);
    expect(find.text('열기'), findsOneWidget);
    expect(find.textContaining('저장 위치'), findsOneWidget);
  });

  testWidgets('트림 슬라이더가 소스 구간을 자르고 프리뷰 매핑에 반영된다', (
    WidgetTester tester,
  ) async {
    final EditorController controller = await _pumpEditor(tester);
    await controller.addMediaFile('/media/first.mp4');
    await tester.pumpAndSettle();

    final ClipView clip = controller.state!.tracks.first.clips.first;
    controller.selectClip(clip.id);
    await tester.pumpAndSettle();
    expect(find.text('시작 자르기'), findsOneWidget);

    await controller.trimClip(startMs: 1000);
    await tester.pumpAndSettle();

    final ClipView trimmed = controller.state!.tracks.first.clips.first;
    expect(controller.error, isNull);
    expect(trimmed.startMs, 1000);
    expect(trimmed.durationMs, 3000);
    // 재생 헤드 0의 프레임은 이제 소스 1000ms다.
    expect(sourceTimeFor(trimmed, 0), 1000);
  });

  testWidgets('재생 중에는 컨트롤러를 매 프레임 건드리지 않고 재생 헤드만 갱신한다', (
    WidgetTester tester,
  ) async {
    rustCore = const RustCoreLoadResult(loadedFrom: 'test');
    final EditorController controller = EditorController(
      bridge: FakeCoreBridge(),
      media: FakeMediaPlatformBridge(),
    );
    addTearDown(controller.dispose);

    int now = 0;
    final PreviewEngine engine = PreviewEngine(
      controller: controller,
      mediaFactory: FakePreviewMediaFactory(clockMs: () => now),
      clockMs: () => now,
    );
    addTearDown(engine.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildEditorTheme(),
        home: EditorScreen(controller: controller, previewEngine: engine),
      ),
    );
    await tester.pumpAndSettle();
    await controller.addMediaFile('/media/first.mp4');
    await tester.pumpAndSettle();

    expect(find.text('00:00:00.000'), findsOneWidget);

    int notifications = 0;
    void countNotices() => notifications++;
    controller.addListener(countNotices);
    addTearDown(() => controller.removeListener(countNotices));

    await tester.tap(find.byTooltip('재생'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byTooltip('일시정지'), findsOneWidget);

    final int afterStart = notifications;
    now += 600;
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));

    // 타임코드는 엔진이 이끄는 재생 헤드를 따라간다.
    expect(find.text('00:00:00.600'), findsOneWidget);
    // 재생 중에는 컨트롤러 알림(=화면 전체 리빌드)이 일어나지 않는다.
    expect(notifications, afterStart);

    await tester.tap(find.byTooltip('일시정지'));
    await tester.pump();
    // 일시정지하면 그 위치가 편집 기준으로 커밋된다.
    expect(controller.playheadMs, 600);
  });

  testWidgets('코어가 없으면 안내와 다시 시도 버튼이 뜬다', (WidgetTester tester) async {    // 실제 FrbCoreBridge + 미로딩 상태 그대로(라이브러리 없는 환경과 같은 조건).
    rustCore = const RustCoreLoadResult(error: '코어 라이브러리를 찾지 못했습니다');
    final EditorController controller = EditorController(
      media: FakeMediaPlatformBridge(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildEditorTheme(),
        home: EditorScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.ready, isFalse);
    expect(find.textContaining('코어 라이브러리를 찾지 못했습니다'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
    // 예전에 사용자가 본 개발자용 안내가 다시 나오면 안 된다.
    expect(find.textContaining('UnimplementedError'), findsNothing);
  });

  testWidgets('인스펙터에서 텍스트 클립 문구를 바로 고칠 수 있다', (
    WidgetTester tester,
  ) async {
    final EditorController controller = await _pumpEditor(tester);
    await controller.addTextOverlay('처음 문구');
    await tester.pumpAndSettle();

    // 텍스트 클립은 오버레이 트랙에 놓인다.
    final ClipView textClip = controller.state!.tracks
        .firstWhere((TrackView track) => track.kind == 'overlay')
        .clips
        .first;
    controller.selectClip(textClip.id);
    await tester.pumpAndSettle();

    expect(find.text('문구 수정'), findsOneWidget);
    final Finder field = find.widgetWithText(TextField, '처음 문구');
    expect(field, findsOneWidget);

    await tester.enterText(field, '고친 문구');
    await tester.tap(find.widgetWithText(FilledButton, '적용'));
    await tester.pumpAndSettle();

    final ClipView updated = controller.state!.tracks
        .firstWhere((TrackView track) => track.kind == 'overlay')
        .clips
        .first;
    expect(updated.textContent, '고친 문구');
  });
}
