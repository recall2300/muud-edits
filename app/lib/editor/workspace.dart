import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../bridge_api.dart';
import '../theme.dart';

/// 작업 공간의 주요 영역 키. 위젯 테스트가 레이아웃 계약을 그대로 검증한다.
const Key previewPaneKey = ValueKey<String>('editor-preview-pane');
const Key timelinePaneKey = ValueKey<String>('editor-timeline-pane');
const Key inspectorSidePanelKey = ValueKey<String>(
  'editor-inspector-side-panel',
);
const Key inspectorBottomSheetKey = ValueKey<String>(
  'editor-inspector-bottom-sheet',
);
const Key inspectorResizeHandleKey = ValueKey<String>(
  'editor-resize-inspector',
);
const Key timelineResizeHandleKey = ValueKey<String>(
  'editor-resize-timeline',
);
const Key inspectorSheetHandleKey = ValueKey<String>(
  'editor-inspector-sheet-handle',
);

/// 편집 작업 공간(Outside-in 레이아웃).
///
/// 브레이크포인트 계약([EditorBreakpoints])을 실제 분기와 똑같이 구현한다:
///
/// * `>= 1024px` (wide) — [미리보기 | 인스펙터 사이드 패널] 위, 타임라인 아래.
///   두 경계 모두 드래그로 비율을 바꾼다(인스펙터 폭 · 타임라인 높이).
/// * `768 ~ 1023px` (medium) — 2영역. 클립을 선택했을 때만 축소 폭 패널이 붙는다.
/// * `< 768px` (compact) — 인스펙터는 하단 BottomSheet 로 스왑. 툴바는 48dp 타깃.
///
/// 리사이즈 값은 위젯 상태로만 두고(프로젝트와 무관), 드래그 중에는 매
/// 프레임 setState 로 경계만 다시 그린다.
class EditorWorkspace extends StatefulWidget {
  const EditorWorkspace({
    super.key,
    required this.controller,
    required this.preview,
    required this.transport,
    required this.timeline,
    required this.inspectorBuilder,
    this.initialTimelineHeight = 206,
    this.initialInspectorWidth = 320,
  });

  final EditorController controller;

  /// 미리보기 또는 시작 안내(빈 프로젝트).
  final Widget preview;

  /// 재생/편집 트랜스포트 바.
  final Widget transport;

  final Widget timeline;

  /// 인스펙터 내용. [onClose]를 넘기면 패널이 닫기 버튼을 보여 준다.
  final Widget Function(VoidCallback onClose) inspectorBuilder;

  final double initialTimelineHeight;
  final double initialInspectorWidth;

  @override
  State<EditorWorkspace> createState() => _EditorWorkspaceState();
}

class _EditorWorkspaceState extends State<EditorWorkspace> {
  static const double _transportHeight = 52;
  static const double _handleExtent = 10;
  static const double _minTimelineHeight = 150;
  static const double _minPreviewHeight = 160;

  late double _timelineHeight = widget.initialTimelineHeight;
  late double _inspectorWidth = widget.initialInspectorWidth;
  late double _sheetHeight = 280;

  bool get _hasSelection => widget.controller.selected != null;

  void _closeInspector() => widget.controller.selectClip(null);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final EditorLayoutMode mode = EditorBreakpoints.layoutModeFor(
          constraints.maxWidth,
        );
        switch (mode) {
          case EditorLayoutMode.compact:
            return _buildCompact(constraints);
          case EditorLayoutMode.medium:
          case EditorLayoutMode.wide:
            return _buildDocked(mode, constraints);
        }
      },
    );
  }

  // --------------------------------------------------------------- 데스크톱/태블릿

  Widget _buildDocked(EditorLayoutMode mode, BoxConstraints constraints) {
    final double maxTimelineHeight = math.max(
      _minTimelineHeight,
      constraints.maxHeight -
          _transportHeight -
          _handleExtent -
          _minPreviewHeight,
    );
    final double timelineHeight = _timelineHeight.clamp(
      _minTimelineHeight,
      maxTimelineHeight,
    );

    // medium 은 선택이 있을 때만 좁은 패널을 붙인다(2영역 유지).
    final bool showInspector =
        mode == EditorLayoutMode.wide || _hasSelection;
    final double minPanelWidth = mode == EditorLayoutMode.medium ? 240 : 280;
    final double maxPanelWidth = math.min(
      mode == EditorLayoutMode.medium ? 340 : 480,
      constraints.maxWidth * 0.48,
    );
    final double panelWidth = _inspectorWidth.clamp(
      minPanelWidth,
      math.max(minPanelWidth, maxPanelWidth),
    );

    return Column(
      children: <Widget>[
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: Container(
                  key: previewPaneKey,
                  color: EditorSurfaces.canvas,
                  child: widget.preview,
                ),
              ),
              if (showInspector) ...<Widget>[
                EditorResizeHandle(
                  key: inspectorResizeHandleKey,
                  axis: Axis.horizontal,
                  semanticsLabel: '인스펙터 폭 조절',
                  onDrag: (double deltaX) {
                    setState(() {
                      _inspectorWidth = (_inspectorWidth - deltaX).clamp(
                        minPanelWidth,
                        math.max(minPanelWidth, maxPanelWidth),
                      );
                    });
                  },
                ),
                Container(
                  key: inspectorSidePanelKey,
                  width: panelWidth,
                  decoration: const BoxDecoration(
                    color: EditorSurfaces.panel,
                    border: Border(
                      left: BorderSide(
                        color: EditorSurfaces.divider,
                        width: EditorStroke.hairline,
                      ),
                    ),
                  ),
                  child: widget.inspectorBuilder(_closeInspector),
                ),
              ],
            ],
          ),
        ),
        widget.transport,
        EditorResizeHandle(
          key: timelineResizeHandleKey,
          axis: Axis.vertical,
          semanticsLabel: '타임라인 높이 조절',
          onDrag: (double deltaY) {
            setState(() {
              _timelineHeight = (_timelineHeight - deltaY).clamp(
                _minTimelineHeight,
                maxTimelineHeight,
              );
            });
          },
        ),
        SizedBox(
          key: timelinePaneKey,
          height: timelineHeight,
          child: widget.timeline,
        ),
      ],
    );
  }

  // -------------------------------------------------------------------- 모바일

  Widget _buildCompact(BoxConstraints constraints) {
    final double maxTimelineHeight = math.max(
      120,
      constraints.maxHeight - _transportHeight - 200,
    );
    final double timelineHeight = math.min(
      _timelineHeight,
      maxTimelineHeight,
    );
    // 시트는 화면 맨 아래(타임라인 아래)에 붙는다. 타임라인은 항상 보이므로
    // 자르는 동안에도 클립 위치를 확인할 수 있다.
    final double maxSheetHeight = math.max(
      200,
      constraints.maxHeight - _transportHeight - timelineHeight - 120,
    );
    final double sheetHeight = _sheetHeight.clamp(200, maxSheetHeight);

    return Column(
      children: <Widget>[
        Expanded(
          child: Container(
            key: previewPaneKey,
            color: EditorSurfaces.canvas,
            child: widget.preview,
          ),
        ),
        widget.transport,
        SizedBox(
          key: timelinePaneKey,
          height: timelineHeight,
          child: widget.timeline,
        ),
        if (_hasSelection)
          SizedBox(
            key: inspectorBottomSheetKey,
            height: sheetHeight,
            child: _InspectorSheet(
              onResize: (double deltaY) {
                setState(() {
                  _sheetHeight = (_sheetHeight - deltaY).clamp(
                    200,
                    maxSheetHeight,
                  );
                });
              },
              child: widget.inspectorBuilder(_closeInspector),
            ),
          ),
      ],
    );
  }
}

/// 폭/높이를 끄는 경계 핸들(Astryx `ResizeHandle` 개념).
///
/// 시각은 1px 선이지만 잡는 영역은 10dp 로 넓히고, 포인터 커서도 바꾼다.
class EditorResizeHandle extends StatefulWidget {
  const EditorResizeHandle({
    super.key,
    required this.axis,
    required this.onDrag,
    required this.semanticsLabel,
  });

  /// [Axis.horizontal] = 세로 막대를 좌우로 끈다(폭 조절).
  /// [Axis.vertical] = 가로 막대를 위아래로 끈다(높이 조절).
  final Axis axis;

  /// 끈 거리(px)를 그대로 넘긴다. 부호 처리는 사용하는 쪽이 정한다.
  final ValueChanged<double> onDrag;

  final String semanticsLabel;

  @override
  State<EditorResizeHandle> createState() => _EditorResizeHandleState();
}

class _EditorResizeHandleState extends State<EditorResizeHandle> {
  bool _hot = false;

  @override
  Widget build(BuildContext context) {
    final bool horizontal = widget.axis == Axis.horizontal;
    return Semantics(
      label: widget.semanticsLabel,
      container: true,
      child: MouseRegion(
        cursor: horizontal
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow,
        onEnter: (_) => setState(() => _hot = true),
        onExit: (_) => setState(() => _hot = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: horizontal
              ? (DragUpdateDetails details) => widget.onDrag(details.delta.dx)
              : null,
          onVerticalDragUpdate: horizontal
              ? null
              : (DragUpdateDetails details) => widget.onDrag(details.delta.dy),
          child: SizedBox(
            width: horizontal ? _EditorWorkspaceState._handleExtent : null,
            height: horizontal ? null : _EditorWorkspaceState._handleExtent,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: horizontal ? EditorStroke.hairline : double.infinity,
                height: horizontal ? double.infinity : EditorStroke.hairline,
                color: _hot
                    ? EditorSurfaces.accent
                    : EditorSurfaces.divider,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 좁은 화면의 인스펙터. 화면 아래에서 올라오는 시트로 스왑한다.
class _InspectorSheet extends StatelessWidget {
  const _InspectorSheet({required this.child, required this.onResize});

  final Widget child;
  final ValueChanged<double> onResize;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: EditorSurfaces.overlay,
      elevation: 18,
      shadowColor: Colors.black,
      borderRadius: EditorRadius.lgTop,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          GestureDetector(
            key: inspectorSheetHandleKey,
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (DragUpdateDetails details) =>
                onResize(details.delta.dy),
            child: SizedBox(
              height: EditorDensity.touch.minTarget * 0.6,
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: const BoxDecoration(
                    color: EditorPalette.outlineStrong,
                    borderRadius: BorderRadius.all(Radius.circular(2)),
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
