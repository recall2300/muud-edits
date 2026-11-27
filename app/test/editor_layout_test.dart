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

  group('좁은 화면(<768)', () {
    testWidgets('사이드 패널 없이 하단 BottomSheet 로 인스펙터를 보여 준다', (
      WidgetTester tester,
    ) async {
      final EditorController controller = await _pumpEditor(
        tester,
        const Size(390, 844),
      );

      expect(find.byKey(inspectorSidePanelKey), findsNothing);
      expect(find.byKey(inspectorBottomSheetKey), findsNothing);

      controller.selectClip(_firstClip(controller).id);
      await tester.pumpAndSettle();

      expect(find.byKey(inspectorSidePanelKey), findsNothing);
      expect(find.byKey(inspectorBottomSheetKey), findsOneWidget);
      expect(find.byType(InspectorPanel), findsOneWidget);
      expect(find.text('자르기'), findsOneWidget);

      // 시트를 닫으면 선택이 풀리고 시트도 사라진다.
      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      expect(find.byKey(inspectorBottomSheetKey), findsNothing);
      expect(controller.selected, isNull);
    });

    testWidgets('시트 손잡이를 위로 끌면 시트가 커진다', (WidgetTester tester) async {
      final EditorController controller = await _pumpEditor(
        tester,
        const Size(390, 844),
      );
      controller.selectClip(_firstClip(controller).id);
      await tester.pumpAndSettle();

      final double before = tester
          .getSize(find.byKey(inspectorBottomSheetKey))
          .height;
      await tester.drag(
        find.byKey(inspectorSheetHandleKey),
        const Offset(0, -50),
      );
      await tester.pumpAndSettle();
      final double after = tester
          .getSize(find.byKey(inspectorBottomSheetKey))
          .height;
      expect(after, closeTo(before + 50, 2));
    });

    testWidgets('툴바 버튼은 48dp 타깃을 확보한다', (WidgetTester tester) async {
      await _pumpEditor(tester, const Size(390, 844));

      for (final String tooltip in <String>['재생', '한 프레임 뒤로', '추가 · 편집']) {
        final Size size = tester.getSize(find.byTooltip(tooltip));
        expect(size.width, greaterThanOrEqualTo(48), reason: '$tooltip 폭');
        expect(size.height, greaterThanOrEqualTo(48), reason: '$tooltip 높이');
      }
      // 타임라인 줌 버튼도 터치 타깃을 지킨다.
      final Size zoomOut = tester.getSize(find.byTooltip('축소'));
      expect(zoomOut.width, greaterThanOrEqualTo(48));
      expect(zoomOut.height, greaterThanOrEqualTo(48));
    });
  });

  testWidgets('데스크톱은 compact 밀도로 툴바를 조밀하게 쓴다', (WidgetTester tester) async {
    await _pumpEditor(tester, const Size(1280, 800));
    final Size play = tester.getSize(find.byTooltip('재생'));
    expect(play.width, EditorDensity.compact.minTarget);
    expect(play.width, lessThan(48));
  });
}
