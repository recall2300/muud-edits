// 인스펙터 패널 테스트(v0.1.7).
//
//  * 선택이 없을 때 EmptyState 가 레이아웃을 무너뜨리지 않는다(좁고 낮은 패널)
//  * Section + Divider 로 구획되고, 편집 항목(자르기/조정)과 읽기 항목(구간)이
//    한 content line 에 정렬된다
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muud_edits/bridge_api.dart';
import 'package:muud_edits/editor/inspector_panel.dart';
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
  addTearDown(controller.dispose);
  await controller.bootstrap();
  return controller;
}

Future<void> _pumpPanel(
  WidgetTester tester,
  EditorController controller,
  Size size,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEditorTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: InspectorPanel(
              controller: controller,
              onClose: () => controller.selectClip(null),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('선택이 없으면 정돈된 EmptyState 를 보여 주고 넘치지 않는다', (
    WidgetTester tester,
  ) async {
    final EditorController controller = await _controller();
    // 좁고 낮은 패널에서도 레이아웃이 무너지지 않아야 한다.
    await _pumpPanel(tester, controller, const Size(240, 140));

    expect(tester.takeException(), isNull);
    expect(find.byKey(inspectorEmptyStateKey), findsOneWidget);
    expect(find.text('선택한 클립이 없습니다'), findsOneWidget);
    expect(find.text('인스펙터'), findsOneWidget);
    // 선택이 없으면 닫기(선택 해제) 버튼도 없다.
    expect(find.byTooltip('선택 해제'), findsNothing);
  });

  testWidgets('영상 클립: 자르기·조정·구간 섹션이 1px 구분선으로 나뉜다', (
    WidgetTester tester,
  ) async {
    final EditorController controller = await _controller();
    await controller.addMediaClip(
      sourcePath: '/a.mp4',
      kind: 'video',
      startMs: 0,
      endMs: 4000,
      sourceDurationMs: 4000,
    );
    final ClipView clip = controller.state!.tracks.first.clips.first;
    controller.selectClip(clip.id);
    await _pumpPanel(tester, controller, const Size(240, 600));

    expect(tester.takeException(), isNull);
    for (final String label in <String>[
      '인스펙터',
      '자르기',
      '시작 자르기',
      '끝 자르기',
      '조정',
      '속도',
      '볼륨',
      '불투명도',
      '구간',
      '소스 구간',
    ]) {
      expect(find.text(label), findsWidgets, reason: '$label 이 보여야 한다');
    }
    // 패널 안의 구획은 카드가 아니라 구분선으로 나눈다.
    expect(find.byType(Divider), findsWidgets);
    expect(find.byTooltip('선택 해제'), findsOneWidget);
  });

  testWidgets('텍스트 클립: 문구 섹션이 먼저 나오고 자르기 섹션은 없다', (
    WidgetTester tester,
  ) async {
    final EditorController controller = await _controller();
    await controller.addTextOverlay('처음 문구');
    final ClipView clip = controller.state!.tracks
        .firstWhere((TrackView track) => track.kind == 'overlay')
        .clips
        .first;
    controller.selectClip(clip.id);
    await _pumpPanel(tester, controller, const Size(240, 600));

    expect(tester.takeException(), isNull);
    expect(find.text('문구'), findsOneWidget);
    expect(find.text('문구 수정'), findsOneWidget);
    expect(find.text('자르기'), findsNothing);
    // 문구 섹션이 읽기용 구간 섹션보다 위에 온다.
    final double textSectionY = tester.getTopLeft(find.text('문구')).dy;
    final double rangeSectionY = tester.getTopLeft(find.text('구간')).dy;
    expect(textSectionY, lessThan(rangeSectionY));
  });
}
