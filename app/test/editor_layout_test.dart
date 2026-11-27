// 반응형 작업 공간(Astryx outside-in) 위젯 테스트(v0.1.7).
//
//  * 넓은 화면: [미리보기 | 인스펙터 사이드 패널] + 하단 타임라인
//  * 중간 화면: 선택이 있을 때만 축소 폭 패널(2영역 유지)
//  * 좁은 화면: 사이드 패널 대신 하단 BottomSheet, 툴바 48dp 타깃
//  * 경계 드래그로 인스펙터 폭·타임라인 높이를 조절
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muud_edits/bridge_api.dart';
import 'package:muud_edits/editor/editor_screen.dart';
import 'package:muud_edits/editor/inspector_panel.dart';
import 'package:muud_edits/editor/mobile_toolbar.dart';
import 'package:muud_edits/editor/workspace.dart';
import 'package:muud_edits/media/media_platform_bridge.dart';
import 'package:muud_edits/models.dart';
import 'package:muud_edits/rust_core_loader.dart';
import 'package:muud_edits/theme.dart';

import 'support/fake_core_bridge.dart';

Future<EditorController> _pumpEditor(
  WidgetTester tester,
  Size size, {
  bool withClip = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  rustCore = const RustCoreLoadResult(loadedFrom: 'test');
  final EditorController controller = EditorController(
    bridge: FakeCoreBridge(),
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
  if (withClip) {
    await controller.addMediaFile('/media/first.mp4');
    await tester.pumpAndSettle();
  }
  return controller;
}

ClipView _firstClip(EditorController controller) =>
    controller.state!.tracks.first.clips.first;

void main() {
  group('넓은 화면(>=1024)', () {
    testWidgets('인스펙터가 사이드 패널로 상시 보이고 하단 시트는 없다', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, const Size(1280, 800));

      expect(find.byKey(inspectorSidePanelKey), findsOneWidget);
      expect(find.byKey(inspectorBottomSheetKey), findsNothing);
      expect(find.byKey(timelinePaneKey), findsOneWidget);
      // 선택이 없어도 패널은 EmptyState 로 자리를 지킨다.
      expect(find.byKey(inspectorEmptyStateKey), findsOneWidget);
      expect(find.text('선택한 클립이 없습니다'), findsOneWidget);
      // 상단 바의 primary action 은 내보내기 하나.
      expect(find.widgetWithText(FilledButton, '내보내기'), findsOneWidget);
    });

    testWidgets('인스펙터 경계를 끌면 패널 폭이 바뀐다', (WidgetTester tester) async {
      await _pumpEditor(tester, const Size(1280, 800));

      final double before = tester
          .getSize(find.byKey(inspectorSidePanelKey))
          .width;
      await tester.drag(
        find.byKey(inspectorResizeHandleKey),
        const Offset(-80, 0),
      );
      await tester.pumpAndSettle();

      final double after = tester
          .getSize(find.byKey(inspectorSidePanelKey))
          .width;
      expect(after, greaterThan(before));
      expect(after, closeTo(before + 80, 2));
    });

    testWidgets('타임라인 경계를 끌면 타임라인 높이가 바뀐다', (WidgetTester tester) async {
      await _pumpEditor(tester, const Size(1280, 800));

      final double before = tester.getSize(find.byKey(timelinePaneKey)).height;
      // 위로 끌면 타임라인이 커진다.
      await tester.drag(
        find.byKey(timelineResizeHandleKey),
        const Offset(0, -60),
      );
      await tester.pumpAndSettle();

      final double after = tester.getSize(find.byKey(timelinePaneKey)).height;
      expect(after, closeTo(before + 60, 2));
    });
  });

  group('중간 화면(768~1023)', () {
    testWidgets('선택이 없으면 2영역, 선택하면 축소 폭 패널이 붙는다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _pumpEditor(
        tester,
        const Size(900, 700),
      );

      expect(find.byKey(inspectorSidePanelKey), findsNothing);
      expect(find.byKey(inspectorBottomSheetKey), findsNothing);

      controller.selectClip(_firstClip(controller).id);
      await tester.pumpAndSettle();

      expect(find.byKey(inspectorSidePanelKey), findsOneWidget);
      final double panelWidth = tester
          .getSize(find.byKey(inspectorSidePanelKey))
          .width;
      expect(panelWidth, greaterThanOrEqualTo(240));
      expect(panelWidth, lessThanOrEqualTo(340));
      expect(find.text('시작 자르기'), findsOneWidget);
    });
  });

  group('좁은 화면(<768) — Edits 스타일', () {
    testWidgets('인스펙터 시트 대신 하단 툴바가 붙고, 선택하면 컨텍스트 툴바가 된다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _pumpEditor(
        tester,
        const Size(390, 844),
      );

      expect(find.byKey(inspectorSidePanelKey), findsNothing);
      expect(find.byKey(inspectorBottomSheetKey), findsNothing);
      expect(find.byKey(previewPaneKey), findsOneWidget);
      expect(find.byKey(timelinePaneKey), findsOneWidget);
      expect(find.byKey(mobileToolbarKey), findsOneWidget);
      // 줌 바는 모바일에서 사라졌다(핀치 줌).
      expect(find.byTooltip('축소'), findsNothing);

      controller.selectClip(_firstClip(controller).id);
      await tester.pumpAndSettle();

      // 선택해도 시트가 아니라 툴바가 컨텍스트로 바뀐다.
      expect(find.byKey(inspectorBottomSheetKey), findsNothing);
      expect(find.text('오디오 추출'), findsOneWidget);
      expect(find.text('볼륨'), findsOneWidget);

      await tester.tap(find.byTooltip('선택 해제'));
      await tester.pumpAndSettle();
      expect(controller.selected, isNull);
      expect(find.text('미디어 추가'), findsOneWidget);
    });

    testWidgets('툴바 버튼은 48dp 타깃을 확보한다', (WidgetTester tester) async {
      await _pumpEditor(tester, const Size(390, 844));

      for (final String tooltip in <String>['재생', '되돌리기', '다시 적용', '전체화면']) {
        final Size size = tester.getSize(find.byTooltip(tooltip));
        expect(size.width, greaterThanOrEqualTo(44), reason: '$tooltip 폭');
        expect(size.height, greaterThanOrEqualTo(44), reason: '$tooltip 높이');
      }
      // 하단 툴바는 아이콘+라벨로 가로 스크롤된다.
      expect(find.byKey(mobileToolbarScrollerKey), findsOneWidget);
    });
  });

  testWidgets('데스크톱은 compact 밀도로 툴바를 조밀하게 쓴다', (WidgetTester tester) async {
    await _pumpEditor(tester, const Size(1280, 800));
    final Size play = tester.getSize(find.byTooltip('재생'));
    expect(play.width, EditorDensity.compact.minTarget);
    expect(play.width, lessThan(48));
  });

  testWidgets('좁은 화면의 시작 화면과 내보내기 시트가 넘치지 않는다', (
    WidgetTester tester,
  ) async {
    await _pumpEditor(tester, const Size(390, 844), withClip: false);

    expect(tester.takeException(), isNull);
    expect(find.text('영상 · 사진 추가'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '내보내기'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('내보내기 계획'), findsOneWidget);
    // 시트는 스크롤되므로 하단의 실행 버튼도 트리에 존재한다.
    expect(find.text('내보내기 시작'), findsOneWidget);
  });
}
