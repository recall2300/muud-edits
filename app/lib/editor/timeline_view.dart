import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../bridge_api.dart';
import '../commands.dart';
import '../models.dart';
import '../theme.dart';

const double _gutterWidth = 112;
const double _compactRailWidth = 48;
const double _rowHeight = 44;
const double _rowGap = 6;
const double _rulerHeight = 26;
const double _subtitleLaneHeight = 30;
const double _rightPad = 28;
const double _handleWidth = 14;
const double _toolbarHeight = 30;

/// 클립의 어느 부분을 잡았는가.
enum ClipZone {
  /// 본체(좌우 이동).
  move,

  /// 왼쪽 끝(소스 인점 트림).
  trimStart,

  /// 오른쪽 끝(소스 아웃점 트림).
  trimEnd,
}

/// 트랙 헤더에서 누를 수 있는 토글.
enum TrackToggle { mute, hide, lock }

/// 타임라인 뷰.
///
/// 직접 그리기(CustomPainter)를 쓰는 이유: 클립이 수백 개가 되어도 위젯 트리를
/// 만들지 않아 스크롤/줌이 가볍다. 히트 테스트는 [TimelineMetrics]로 계산한다.
///
/// 조작:
/// * 핀치 줌 · 줌 버튼([_ZoomBar]) · 전체 맞춤
/// * 빈 영역/눈금 드래그 → 플레이헤드 스크럽
/// * 클립 본체 드래그 → 시간 이동([Commands.moveClip])
/// * 클립 좌/우 끝 핸들 드래그 → 트림([Commands.trimClip])
/// * 좌측 거터의 음소거/숨김/잠금 아이콘 탭 → 트랙 상태
///
/// 드래그 중에는 로컬 미리보기만 바꾸고, 손을 뗄 때 커맨드를 **한 번만** 보낸다.
///
/// 재생 중 플레이헤드는 [playhead] 노티파이어만 따라 **선 하나만** 다시 그린다
/// (클립·눈금은 [RepaintBoundary]로 분리해 다시 래스터화하지 않는다).
class TimelineView extends StatefulWidget {
  const TimelineView({
    super.key,
    required this.controller,
    this.playhead,
    this.onScrubStart,
    this.onAddClip,
  });

  final EditorController controller;

  /// 재생 헤드 시각(없으면 [EditorController.playheadMs]를 한 번만 읽는다).
  final ValueListenable<int>? playhead;

  /// 사용자가 타임라인을 만지기 시작했을 때(재생 중이면 멈추게).
  final VoidCallback? onScrubStart;

  /// 비디오 트랙 오른쪽 끝의 `+` 버튼을 누를 때(미디어 추가).
  final VoidCallback? onAddClip;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  /// 배율(1.0 = 전체 맞춤).
  double _zoom = 1.0;

  /// 화면 왼쪽 끝의 타임라인 시각(ms).
  double _scrollMs = 0;

  TimelineMetrics? _metrics;

  _DragMode _mode = _DragMode.none;
  ClipView? _dragClip;
  String? _dragTrackId;
  int _dragStartOffsetMs = 0;
  int _dragStartSourceMs = 0;
  int _dragDeltaMs = 0;

  /// 손을 대기 시작한 정확한 좌표.
  ///
  /// 제스처 인식기는 손가락이 슬롭(약 18px)을 넘은 뒤에야 시작되므로,
  /// `onScaleStart` 의 좌표는 누른 지점이 아니다. 핸들/본체 구분과 드래그
  /// 시작점은 pointer down 좌표를 써야 정확하다.
  Offset? _pointerDownLocal;

  /// 핀치 줌 시작 시 배율.

  /// 핀치 줌 시작 시 값.
  double _zoomAtScaleStart = 1;

  @override
  void initState() {
    super.initState();
    widget.playhead?.addListener(_followPlayhead);
  }

  @override
  void didUpdateWidget(covariant TimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playhead != widget.playhead) {
      oldWidget.playhead?.removeListener(_followPlayhead);
      widget.playhead?.addListener(_followPlayhead);
    }
  }

  @override
  void dispose() {
    widget.playhead?.removeListener(_followPlayhead);
    super.dispose();
  }

  /// 재생 헤드가 화면 밖으로 나가면 따라간다(재생 중 타임라인이 멈춰 보이지 않게).
  void _followPlayhead() {
    final TimelineMetrics? metrics = _metrics;
    final ValueListenable<int>? playhead = widget.playhead;
    if (metrics == null || playhead == null || !mounted) {
      return;
    }
    final double visibleMs = metrics.visibleSpanMs;
    if (visibleMs <= 0) {
      return;
    }
    final double value = playhead.value.toDouble();
    final double left = _scrollMs;
    final double right = _scrollMs + visibleMs;
    if (value >= left + visibleMs * 0.2 && value <= right - visibleMs * 0.1) {
      return;
    }
    setState(() {
      _scrollMs = (value - visibleMs * 0.1).clamp(0.0, _maxScroll(_zoom, metrics));
    });
  }

  // ------------------------------------------------------------------ 줌/스크롤

  double _maxScroll(double zoom, TimelineMetrics metrics) {
    final double span = metrics.totalSpanMs.toDouble();
    final double visible = metrics.contentWidth / (metrics.basePxPerMs * zoom);
    return math.max(0, span - visible);
  }

  void _applyZoom(double nextZoom, {double? focusDx}) {
    final TimelineMetrics? metrics = _metrics;
    if (metrics == null) {
      return;
    }
    final double zoom =
        nextZoom.clamp(TimelineMetrics.minZoom, TimelineMetrics.maxZoom).toDouble();
    final double dx = focusDx ?? (metrics.laneLeft + metrics.contentWidth / 2);
    final int focusMs = metrics.timeAt(dx);
    setState(() {
      _zoom = zoom;
      final double pxPerMs = metrics.basePxPerMs * zoom;
      final double left = focusMs - (dx - metrics.laneLeft) / pxPerMs;
      _scrollMs = left.clamp(0.0, _maxScroll(zoom, metrics)).toDouble();
    });
  }

  void _fit() {
    final TimelineMetrics? metrics = _metrics;
    if (metrics == null) {
      return;
    }
    setState(() {
      _zoom = 1.0;
      _scrollMs = 0;
    });
  }

  // ------------------------------------------------------------------ 제스처

  void _onScaleStart(ScaleStartDetails details) {
    final TimelineMetrics? metrics = _metrics;
    final EditorState? state = widget.controller.state;
    if (metrics == null || state == null) {
      return;
    }
    _zoomAtScaleStart = _zoom;
    _dragDeltaMs = 0;
    _dragDeltaPx = 0;
    _dragClip = null;
    _dragTrackId = null;
    _mode = _DragMode.none;

    final Offset local = _pointerDownLocal ?? details.localFocalPoint;
    if (local.dx < metrics.laneLeft) {
      return; // 거터: 탭으로만 처리한다.
    }
    final ({TrackView track, ClipView clip, ClipZone zone})? hit =
        metrics.hitTestClip(state, local);
    if (hit == null) {
      _mode = _DragMode.scrub;
      widget.onScrubStart?.call();
      widget.controller.setPlayhead(metrics.timeAt(local.dx));
      return;
    }
    _dragClip = hit.clip;
    _dragTrackId = hit.track.id;
    _dragStartOffsetMs = hit.clip.offsetMs;
    _dragStartSourceMs = hit.clip.startMs;
    _mode = switch (hit.zone) {
      ClipZone.trimStart => _DragMode.trimStart,
      ClipZone.trimEnd => _DragMode.trimEnd,
      ClipZone.move => _DragMode.move,
    };
    widget.onScrubStart?.call();
    widget.controller.selectClip(hit.clip.id);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final TimelineMetrics? metrics = _metrics;
    if (metrics == null) {
      return;
    }
    // 두 손가락: 줌(+ 이동).
    if (details.pointerCount >= 2) {
      final double zoom = (_zoomAtScaleStart * details.scale)
          .clamp(TimelineMetrics.minZoom, TimelineMetrics.maxZoom)
          .toDouble();
      final double pxPerMs = metrics.basePxPerMs * zoom;
      final int focalMs = metrics.timeAt(details.localFocalPoint.dx);
      setState(() {
        _zoom = zoom;
        final double left =
            focalMs - (details.localFocalPoint.dx - metrics.laneLeft) / pxPerMs;
        _scrollMs = left.clamp(0.0, _maxScroll(zoom, metrics)).toDouble();
      });
      return;
    }
    switch (_mode) {
      case _DragMode.scrub:
        widget.controller.setPlayhead(metrics.timeAt(details.localFocalPoint.dx));
      case _DragMode.move:
      case _DragMode.trimStart:
      case _DragMode.trimEnd:
        final ClipView? clip = _dragClip;
        if (clip == null) {
          return;
        }
        _dragDeltaPx += details.focalPointDelta.dx;
        final int deltaMs = (_dragDeltaPx / metrics.pxPerMs).round();
        if (deltaMs != _dragDeltaMs) {
          setState(() => _dragDeltaMs = deltaMs);
        }
      case _DragMode.none:
        break;
    }
  }

  double _dragDeltaPx = 0;

  void _onScaleEnd(ScaleEndDetails details) {
    final ClipView? clip = _dragClip;
    final String? trackId = _dragTrackId;
    final _DragMode mode = _mode;
    final int delta = _dragDeltaMs;
    _mode = _DragMode.none;
    _dragClip = null;
    _dragTrackId = null;
    _dragDeltaMs = 0;
    if (clip == null || trackId == null || delta == 0) {
      return;
    }
    if (mode == _DragMode.move) {
      final int at = (_dragStartOffsetMs + delta).clamp(0, 24 * 60 * 60 * 1000);
      widget.controller.apply(
        Commands.moveClip(trackId: trackId, clipId: clip.id, atMs: at),
      );
      return;
    }
    // 트림: 타임라인 이동량을 소스 시각으로 환산한다(배속 반영).
    final double speed = clip.speed <= 0 ? 1 : clip.speed;
    final int sourceDelta = (delta * speed).round();
    const int minDurationMs = 34;
    if (mode == _DragMode.trimStart) {
      final int maxStart = clip.endMs - minDurationMs;
      final int next = (clip.startMs + sourceDelta).clamp(0, math.max(0, maxStart));
      widget.controller.apply(
        Commands.trimClip(
          trackId: trackId,
          clipId: clip.id,
          startMs: next,
          offsetMs: clip.offsetMs + ((next - clip.startMs) / speed).round(),
        ),
      );
      return;
    }
    final int sourceEnd = clip.sourceDurationMs ?? clip.endMs;
    final int minEnd = clip.startMs + minDurationMs;
    final int next = (clip.endMs + sourceDelta).clamp(
      minEnd,
      math.max(minEnd, sourceEnd),
    );
    widget.controller.apply(
      Commands.trimClip(trackId: trackId, clipId: clip.id, endMs: next),
    );
  }

  void _onTapUp(TapUpDetails details) {
    final TimelineMetrics? metrics = _metrics;
    final EditorState? state = widget.controller.state;
    if (metrics == null || state == null) {
      return;
    }
    final Offset local = details.localPosition;
    // 거터 탭: 트랙 토글(음소거/숨김/잠금).
    if (local.dx < metrics.laneLeft) {
      _handleGutterTap(metrics, state, local);
      return;
    }
    // 비디오 트랙 끝의 `+`(클립 추가).
    if (_addClipRect(state, metrics).inflate(4).contains(local)) {
      widget.onAddClip?.call();
      return;
    }
    final ({TrackView track, ClipView clip, ClipZone zone})? hit =
        metrics.hitTestClip(state, local);
    widget.controller.selectClip(hit?.clip.id);
    widget.onScrubStart?.call();
    widget.controller.setPlayhead(metrics.timeAt(local.dx));
  }

  /// 비디오 트랙 끝에 그리는 `+` 버튼 사각형(그리기와 히트 테스트 공용).
  Rect _addClipRect(EditorState state, TimelineMetrics metrics) =>
      timelineAddClipRect(state, metrics);

  void _handleGutterTap(
    TimelineMetrics metrics,
    EditorState state,
    Offset local,
  ) {
    for (int index = 0; index < state.tracks.length; index++) {
      final Rect lane = metrics.laneRect(index);
      if (local.dy < lane.top || local.dy > lane.bottom) {
        continue;
      }
      final TrackView track = state.tracks[index];
      for (final TrackToggle toggle in TrackToggle.values) {
        if (!metrics
            .toggleRect(index, toggle)
            .inflate(2)
            .contains(local)) {
          continue;
        }
        widget.controller.apply(
          Commands.setTrackState(
            trackId: track.id,
            muted: toggle == TrackToggle.mute ? !track.muted : null,
            hidden: toggle == TrackToggle.hide ? !track.hidden : null,
            locked: toggle == TrackToggle.lock ? !track.locked : null,
          ),
        );
        return;
      }
      return;
    }
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final EditorState? state = widget.controller.state;
    if (state == null) {
      return const Center(
        child: Text(
          '프로젝트가 없습니다',
          style: TextStyle(color: EditorPalette.textMuted),
        ),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 좁은(터치) 화면에서는 Edits 처럼 얇은 아이콘 레일 + 핀치 줌만 쓴다.
        final bool compact =
            constraints.maxWidth < EditorBreakpoints.compact;
        final bool touch = compact;
        final double toolbarHeight = compact
            ? 0
            : (touch ? EditorDensity.touch.minTarget : _toolbarHeight);
        final double contentHeight =
            _rulerHeight +
            state.tracks.length * (_rowHeight + _rowGap) +
            _subtitleLaneHeight +
            10;
        final double viewportHeight = math.max(
          constraints.maxHeight - toolbarHeight,
          60,
        );
        final double canvasHeight = math.max(contentHeight, viewportHeight);
        final TimelineMetrics metrics = TimelineMetrics(
          width: constraints.maxWidth,
          height: canvasHeight,
          durationMs: state.durationMs,
          trackCount: state.tracks.length,
          zoom: _zoom,
          scrollMs: _scrollMs,
          railWidth: compact ? _compactRailWidth : _gutterWidth,
          compact: compact,
        );
        _metrics = metrics;
        final ValueListenable<int> source =
            widget.playhead ?? _StaticPlayhead(widget.controller.playheadMs);

        final Widget canvas = Listener(
          onPointerDown: (PointerDownEvent event) {
            _pointerDownLocal = event.localPosition;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  RepaintBoundary(
                    child: CustomPaint(
                      painter: _TimelinePainter(
                        state: state,
                        metrics: metrics,
                        selectedClipId: widget.controller.selectedClipId,
                        drag: _dragPreview(state),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  CustomPaint(
                    painter: _PlayheadPainter(
                      metrics: metrics,
                      position: source,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ],
              ),
            ),
          ),
        );

        return Column(
          children: <Widget>[
            if (!compact)
              _ZoomBar(
                height: toolbarHeight,
                touch: touch,
                zoom: _zoom,
                onZoomIn: () => _applyZoom(_zoom * 1.5),
                onZoomOut: () => _applyZoom(_zoom / 1.5),
                onFit: _fit,
              ),
            Expanded(
              child: contentHeight > viewportHeight
                  ? SingleChildScrollView(
                      child: SizedBox(
                        height: canvasHeight,
                        width: constraints.maxWidth,
                        child: canvas,
                      ),
                    )
                  : canvas,
            ),
          ],
        );
      },
    );
  }

  /// 드래그 중인 클립의 임시 위치/구간(그리기용).
  TimelineDragPreview? _dragPreview(EditorState state) {
    final ClipView? clip = _dragClip;
    final _DragMode mode = _mode;
    if (clip == null || mode == _DragMode.none || _dragDeltaMs == 0) {
      return null;
    }
    final double speed = clip.speed <= 0 ? 1 : clip.speed;
    switch (mode) {
      case _DragMode.move:
        return TimelineDragPreview(
          clipId: clip.id,
          offsetMs: math.max(0, _dragStartOffsetMs + _dragDeltaMs),
        );
      case _DragMode.trimStart:
        final int sourceDelta = (_dragDeltaMs * speed).round();
        final int next = (_dragStartSourceMs + sourceDelta).clamp(
          0,
          math.max(0, clip.endMs - 34),
        );
        return TimelineDragPreview(
          clipId: clip.id,
          startMs: next,
          offsetMs: clip.offsetMs + ((next - clip.startMs) / speed).round(),
          endMs: clip.endMs,
        );
      case _DragMode.trimEnd:
        final int sourceDelta = (_dragDeltaMs * speed).round();
        final int minEnd = clip.startMs + 34;
        final int sourceEnd = clip.sourceDurationMs ?? clip.endMs;
        return TimelineDragPreview(
          clipId: clip.id,
          startMs: clip.startMs,
          endMs: (clip.endMs + sourceDelta).clamp(
            minEnd,
            math.max(minEnd, sourceEnd),
          ),
        );
      case _DragMode.none:
      case _DragMode.scrub:
        return null;
    }
  }
}

enum _DragMode { none, scrub, move, trimStart, trimEnd }

/// 드래그 중 미리보기(커밋 전 화면 표시용).
@immutable
class TimelineDragPreview {
  const TimelineDragPreview({
    required this.clipId,
    this.offsetMs,
    this.startMs,
    this.endMs,
  });

  final String clipId;
  final int? offsetMs;
  final int? startMs;
  final int? endMs;
}

/// 줌 버튼 막대(작게, 타임라인 위).
class _ZoomBar extends StatelessWidget {
  const _ZoomBar({
    required this.height,
    required this.touch,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
  });

  final double height;
  final bool touch;
  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        children: <Widget>[
          const SizedBox(width: EditorSpacing.xs),
          _MiniButton(
            icon: Icons.zoom_out,
            tooltip: '축소',
            onTap: onZoomOut,
            touch: touch,
          ),
          _MiniButton(
            icon: Icons.zoom_in,
            tooltip: '확대',
            onTap: onZoomIn,
            touch: touch,
          ),
          _MiniButton(
            icon: Icons.fit_screen_outlined,
            tooltip: '전체 맞춤',
            onTap: onFit,
            touch: touch,
          ),
          const SizedBox(width: EditorSpacing.sm),
          Text(
            '${zoom.toStringAsFixed(1)}x',
            style: EditorText.numeric.copyWith(fontSize: 10),
          ),
          const Spacer(),
          if (!touch)
            const Flexible(
              child: Text(
                '클립 드래그: 이동 · 끝 잡기: 자르기',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: EditorText.caption,
              ),
            ),
          const SizedBox(width: EditorSpacing.sm),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.touch,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final double target = touch
        ? EditorDensity.touch.minTarget
        : EditorDensity.compact.minTarget;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: EditorRadius.smAll,
        onTap: onTap,
        child: SizedBox(
          width: target,
          height: target,
          child: Icon(
            icon,
            size: touch ? 20 : 16,
            color: EditorText.secondary,
          ),
        ),
      ),
    );
  }
}

/// 값이 변하지 않는 재생 헤드(엔진 없이 그릴 때).
class _StaticPlayhead implements ValueListenable<int> {
  const _StaticPlayhead(this.value);

  @override
  final int value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// 타임라인 좌표 계산(그리기와 히트 테스트가 같은 규칙을 쓰도록 한 곳에).
class TimelineMetrics {
  TimelineMetrics({
    required this.width,
    required this.height,
    required this.durationMs,
    required this.trackCount,
    double zoom = 1.0,
    double scrollMs = 0,
    this.railWidth = _gutterWidth,
    this.compact = false,
  }) : _zoom = zoom,
       contentScrollMs = scrollMs {
    final double usable = math.max(width - railWidth - _rightPad, 60);
    basePxPerMs = usable / totalSpanMs;
    pxPerMs = basePxPerMs * _zoom;
    _scrollMs = scrollMs.clamp(0.0, maxScrollMs);
  }

  static const double minZoom = 0.25;
  static const double maxZoom = 24.0;

  final double width;
  final double height;
  final int durationMs;
  final int trackCount;

  /// 왼쪽 트랙 레일 폭. Edits 스타일 좁은 화면은 48, 데스크톱은 112.
  final double railWidth;

  /// 좁은 화면 레이아웃인가(레일에 이름을 그리지 않고 토글만 둔다).
  final bool compact;

  final double _zoom;

  /// 생성 시 요청한 스크롤(클램프 전 값 보관용).
  final double contentScrollMs;

  late final double basePxPerMs;
  late final double pxPerMs;
  late double _scrollMs;

  /// 화면 왼쪽 끝의 타임라인 시각(ms).
  double get scrollMs => _scrollMs;

  /// 줌 배율.
  double get zoom => _zoom;

  /// 프로젝트 길이 + 여유분(스크롤 가능한 전체 범위).
  int get totalSpanMs => math.max(durationMs + 3000, 8000);

  double get maxScrollMs {
    final double visible = contentWidth / pxPerMs;
    return math.max(0, totalSpanMs - visible);
  }

  /// 화면에 보이는 시간 폭(ms).
  double get visibleSpanMs => contentWidth / pxPerMs;

  double get laneLeft => railWidth;

  double get contentWidth => math.max(width - railWidth - _rightPad, 60);

  double xForTime(int ms) => laneLeft + (ms - _scrollMs) * pxPerMs;

  int timeAt(double dx) {
    final double raw = _scrollMs + (dx - laneLeft) / pxPerMs;
    if (raw.isNaN || raw.isInfinite) {
      return 0;
    }
    final int limit = 24 * 60 * 60 * 1000;
    final int clamped = raw.round();
    if (clamped < 0) {
      return 0;
    }
    return clamped > limit ? limit : clamped;
  }

  double topForTrack(int index) =>
      _rulerHeight + index * (_rowHeight + _rowGap);

  double get subtitleLaneTop => topForTrack(trackCount) + _rowHeight + _rowGap;

  Rect laneRect(int index) =>
      Rect.fromLTWH(laneLeft, topForTrack(index), contentWidth, _rowHeight);

  /// 거터의 트랙 토글 아이콘 위치(그리기와 히트 테스트가 같은 값을 쓴다).
  Rect toggleRect(int index, TrackToggle toggle) {
    if (compact) {
      // 좁은 레일: 3개 토글을 15px 간격으로 한 줄에 둔다.
      final double top = topForTrack(index) + _rowHeight - 17;
      final double left = 2 + toggle.index * 15;
      return Rect.fromLTWH(left, top, 14, 16);
    }
    final double top = topForTrack(index) + _rowHeight - 20;
    final double left = 26 + toggle.index * 24;
    return Rect.fromLTWH(left, top, 20, 16);
  }

  /// 좌표에 있는 클립과 잡은 지점(없으면 null).
  ({TrackView track, ClipView clip, ClipZone zone})? hitTestClip(
    EditorState state,
    Offset position,
  ) {
    if (position.dx < laneLeft - 1) {
      return null;
    }
    for (int index = 0; index < state.tracks.length; index++) {
      final Rect lane = laneRect(index);
      if (position.dy < lane.top || position.dy > lane.bottom) {
        continue;
      }
      final TrackView track = state.tracks[index];
      for (final ClipView clip in track.clips) {
        final double left = xForTime(clip.offsetMs);
        final double right = xForTime(clip.endOffsetMs);
        if (position.dx >= left - 6 && position.dx <= right + 6) {
          final ClipZone zone;
          if (right - left < _handleWidth * 2.4) {
            zone = ClipZone.move;
          } else if (position.dx <= left + _handleWidth) {
            zone = ClipZone.trimStart;
          } else if (position.dx >= right - _handleWidth) {
            zone = ClipZone.trimEnd;
          } else {
            zone = ClipZone.move;
          }
          return (track: track, clip: clip, zone: zone);
        }
      }
      return null;
    }
    return null;
  }

  /// 클립 본체만(존 구분 없이) — 기존 호출 호환용.
  ({TrackView track, ClipView clip})? hitTest(
    EditorState state,
    Offset position,
  ) {
    final ({TrackView track, ClipView clip, ClipZone zone})? hit =
        hitTestClip(state, position);
    if (hit == null) {
      return null;
    }
    return (track: hit.track, clip: hit.clip);
  }

  /// 눈금 간격: 화면에서 70px 이상이 되는 최소 단위(초).
  int tickStepMs() {
    const List<int> candidates = <int>[
      100,
      250,
      500,
      1000,
      2000,
      5000,
      10000,
      15000,
      30000,
      60000,
      120000,
      300000,
    ];
    for (final int step in candidates) {
      if (step * pxPerMs >= 70) {
        return step;
      }
    }
    return 600000;
  }
}

/// 비디오 트랙 끝에 그리는 `+`(클립 추가) 버튼 자리. 그리기와 히트 테스트 공용.
Rect timelineAddClipRect(EditorState state, TimelineMetrics metrics) {
  final int index = state.tracks.indexWhere(
    (TrackView track) => track.kind == 'video' || track.kind == 'image',
  );
  if (index < 0) {
    return Rect.zero;
  }
  final Rect lane = metrics.laneRect(index);
  final int endMs = state.tracks[index].durationMs;
  final double desired = endMs > 0
      ? metrics.xForTime(endMs) + 10
      : metrics.laneLeft + 10;
  final double x = desired.clamp(metrics.laneLeft + 2, metrics.width - 30);
  return Rect.fromLTWH(x, lane.center.dy - 13, 26, 26);
}

/// 클립·눈금·자막 — 플레이헤드와 무관한 정적인 층.
class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.state,
    required this.metrics,
    required this.selectedClipId,
    this.drag,
  });

  final EditorState state;
  final TimelineMetrics metrics;
  final String? selectedClipId;
  final TimelineDragPreview? drag;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint background = Paint()..color = EditorPalette.background;
    canvas.drawRect(Offset.zero & size, background);

    _paintTrackLanes(canvas);
    _paintClips(canvas);
    _paintSubtitleLane(canvas);
    _paintRuler(canvas);

    if (state.summary.clipCount == 0) {
      _paintEmptyHint(canvas);
    }
  }

  void _paintTrackLanes(Canvas canvas) {
    final Paint gutter = Paint()..color = EditorPalette.surface;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, metrics.railWidth, metrics.height),
      gutter,
    );

    for (int index = 0; index < state.tracks.length; index++) {
      final TrackView track = state.tracks[index];
      final Rect lane = metrics.laneRect(index);
      final Paint lanePaint = Paint()..color = EditorPalette.surfaceHigh;
      canvas.drawRRect(
        RRect.fromRectAndRadius(lane, const Radius.circular(6)),
        lanePaint,
      );

      if (track.kind == 'video') {
        final Paint stripe = Paint()..color = EditorPalette.videoTrack;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(lane.left, lane.top, 3, lane.height),
            const Radius.circular(2),
          ),
          stripe,
        );
      }

      final Color accent = EditorPalette.forTrackKind(track.kind);
      final Paint dot = Paint()..color = accent;
      if (metrics.compact) {
        // Edits 스타일: 긴 이름 대신 색 점만 남긴다(레이블은 클립이 말한다).
        canvas.drawCircle(Offset(14, lane.top + 14), 4.5, dot);
      } else {
        canvas.drawCircle(Offset(14, lane.top + 12), 4, dot);
        _drawText(
          canvas,
          track.name,
          Offset(26, lane.top + 5),
          metrics.railWidth - 34,
          TextStyle(
            color: track.hidden ? EditorPalette.textMuted : EditorPalette.text,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        );
      }

      // 트랙 상토글: 음소거 · 숨김 · 잠금
      _paintToggle(
        canvas,
        metrics.toggleRect(index, TrackToggle.mute),
        track.muted ? '🔇' : '🔊',
        active: track.muted,
      );
      _paintToggle(
        canvas,
        metrics.toggleRect(index, TrackToggle.hide),
        track.hidden ? '🙈' : '👁',
        active: track.hidden,
      );
      _paintToggle(
        canvas,
        metrics.toggleRect(index, TrackToggle.lock),
        track.locked ? '🔒' : '🔓',
        active: track.locked,
      );
    }

    _paintAddClipButton(canvas);
  }

  /// 비디오 트랙 끝의 `+` — 바로 미디어를 더할 수 있다.
  void _paintAddClipButton(Canvas canvas) {
    final Rect rect = timelineAddClipRect(state, metrics);
    if (rect.isEmpty || rect.left > metrics.width) {
      return;
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      Paint()..color = EditorPalette.surfaceRaised,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), const Radius.circular(6)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = EditorPalette.outlineStrong,
    );
    final Paint plus = Paint()
      ..color = EditorPalette.textSecondary
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final Offset center = rect.center;
    canvas.drawLine(
      Offset(center.dx - 5, center.dy),
      Offset(center.dx + 5, center.dy),
      plus,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 5),
      Offset(center.dx, center.dy + 5),
      plus,
    );
  }

  void _paintToggle(
    Canvas canvas,
    Rect rect,
    String glyph, {
    required bool active,
  }) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()
        ..color = active
            ? EditorPalette.accent.withValues(alpha: 0.22)
            : EditorPalette.background.withValues(alpha: 0.35),
    );
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: glyph,
        style: TextStyle(
          fontSize: 9,
          color: active ? EditorPalette.text : EditorPalette.textMuted,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(
        rect.center.dx - painter.width / 2,
        rect.center.dy - painter.height / 2,
      ),
    );
  }

  void _paintClips(Canvas canvas) {
    for (int index = 0; index < state.tracks.length; index++) {
      final TrackView track = state.tracks[index];
      final Rect lane = metrics.laneRect(index);
      for (final ClipView clip in track.clips) {
        final TimelineDragPreview? preview = drag;
        final bool dragging = preview != null && preview.clipId == clip.id;
        final int offsetMs = dragging ? (preview.offsetMs ?? clip.offsetMs) : clip.offsetMs;
        final int startMs = dragging ? (preview.startMs ?? clip.startMs) : clip.startMs;
        final int endMs = dragging ? (preview.endMs ?? clip.endMs) : clip.endMs;
        final double speed = clip.speed <= 0 ? 1 : clip.speed;
        final int durationMs = ((endMs - startMs) / speed).round();

        final double left = metrics.xForTime(offsetMs);
        final double right = metrics.xForTime(offsetMs + durationMs);
        if (right < metrics.laneLeft || left > metrics.width) {
          continue; // 화면 밖
        }
        final double visibleLeft = math.max(left, metrics.laneLeft);
        final double visibleRight = math.min(right, metrics.width);
        if (visibleRight - visibleLeft < 2) {
          continue;
        }
        final Rect rect = Rect.fromLTRB(
          visibleLeft,
          lane.top + 4,
          math.max(visibleRight, visibleLeft + 2),
          lane.bottom - 4,
        );

        final Color base = EditorPalette.forClipKind(clip.kind);
        final Paint fill = Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              base.withValues(alpha: clip.enabled ? 0.95 : 0.35),
              base.withValues(alpha: clip.enabled ? 0.65 : 0.2),
            ],
          ).createShader(rect);

        final RRect rounded = RRect.fromRectAndRadius(
          rect,
          const Radius.circular(5),
        );
        canvas.drawRRect(rounded, fill);

        final bool selected = clip.id == selectedClipId;
        if (selected) {
          canvas.drawRRect(
            rounded.deflate(0.5),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.2
              ..color = EditorPalette.accent,
          );
          // 양쪽 트림 핸들(잡기 쉬운 사각 손잡이)
          final Paint handle = Paint()..color = Colors.white;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(rect.left + 1.5, rect.center.dy - 10, 4, 20),
              const Radius.circular(2),
            ),
            handle,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(rect.right - 5.5, rect.center.dy - 10, 4, 20),
              const Radius.circular(2),
            ),
            handle,
          );
        }
        if (dragging) {
          canvas.drawRRect(
            rounded.deflate(0.5),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4
              ..color = EditorPalette.accent,
          );
        }

        // 클립 이름 + 길이
        if (rect.width > 28) {
          _drawText(
            canvas,
            clip.label,
            Offset(rect.left + 6, rect.top + 5),
            rect.width - 12,
            const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          );
          if (rect.height > 26 && rect.width > 70) {
            _drawText(
              canvas,
              '${formatTimecode(durationMs)}${(speed - 1).abs() < 0.01 ? '' : ' · ${speed.toStringAsFixed(2)}x'}',
              Offset(rect.left + 6, rect.top + 20),
              rect.width - 12,
              TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 9,
              ),
            );
          }
        }
      }
    }
  }

  void _paintSubtitleLane(Canvas canvas) {
    final double top = metrics.subtitleLaneTop;
    if (top + _subtitleLaneHeight > metrics.height) {
      return;
    }
    final Rect lane = Rect.fromLTWH(
      metrics.laneLeft,
      top,
      metrics.contentWidth,
      _subtitleLaneHeight,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(lane, const Radius.circular(6)),
      Paint()..color = EditorPalette.surfaceHigh.withValues(alpha: 0.6),
    );
    _drawText(
      canvas,
      '자막',
      Offset(metrics.compact ? 4 : 26, top + 8),
      metrics.railWidth - 32,
      const TextStyle(color: EditorPalette.textMuted, fontSize: 10),
    );

    final Paint itemPaint = Paint()
      ..color = EditorPalette.subtitleTrack.withValues(alpha: 0.8);
    for (final SubtitleView item in state.subtitles) {
      final double left = metrics.xForTime(item.startMs);
      final double right = metrics.xForTime(item.endMs);
      if (right - left < 2 || right < metrics.laneLeft || left > metrics.width) {
        continue;
      }
      final Rect rect = Rect.fromLTRB(
        math.max(left, metrics.laneLeft),
        top + 5,
        math.min(right, metrics.width),
        top + _subtitleLaneHeight - 5,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        itemPaint,
      );
      if (rect.width > 40) {
        _drawText(
          canvas,
          item.text,
          Offset(rect.left + 4, rect.top + 3),
          rect.width - 8,
          const TextStyle(color: Colors.black87, fontSize: 9),
        );
      }
    }
  }

  void _paintRuler(Canvas canvas) {
    final Paint rulerBg = Paint()..color = EditorPalette.surface;
    canvas.drawRect(
      Rect.fromLTWH(
        metrics.railWidth,
        0,
        metrics.width - metrics.railWidth,
        _rulerHeight,
      ),
      rulerBg,
    );

    final int step = metrics.tickStepMs();
    final int first = (metrics.scrollMs / step).floor() * step;
    final int last = (metrics.scrollMs + metrics.visibleSpanMs).ceil() + step;
    final Paint tick = Paint()
      ..color = EditorPalette.outline
      ..strokeWidth = 1;

    for (int ms = math.max(0, first); ms <= last; ms += step) {
      final double x = metrics.xForTime(ms);
      if (x < metrics.railWidth || x > metrics.width) {
        continue;
      }
      canvas.drawLine(
        Offset(x, _rulerHeight - 8),
        Offset(x, _rulerHeight),
        tick,
      );
      _drawText(
        canvas,
        _shortTime(ms),
        Offset(x + 3, 5),
        60,
        const TextStyle(color: EditorPalette.textMuted, fontSize: 9),
      );
    }
  }

  void _paintEmptyHint(Canvas canvas) {
    _drawText(
      canvas,
      '미디어를 추가하면 여기에 클립이 표시됩니다',
      Offset(metrics.laneLeft + 44, _rulerHeight + 8),
      metrics.contentWidth - 32,
      const TextStyle(color: EditorPalette.textMuted, fontSize: 11),
    );
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    double maxWidth,
    TextStyle style,
  ) {
    if (maxWidth <= 0) {
      return;
    }
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    );
    painter.layout(maxWidth: maxWidth);
    painter.paint(canvas, offset);
  }

  String _shortTime(int ms) {
    final int totalSeconds = ms ~/ 1000;
    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;
    final String mm = minutes.toString().padLeft(2, '0');
    final String ss = seconds.toString().padLeft(2, '0');
    if (ms % 1000 != 0) {
      final String msPart = (ms % 1000).toString().padLeft(3, '0');
      return '$mm:$ss.$msPart';
    }
    return '$mm:$ss';
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter oldDelegate) {
    return !identical(oldDelegate.state, state) ||
        oldDelegate.selectedClipId != selectedClipId ||
        oldDelegate.drag != drag ||
        oldDelegate.metrics.pxPerMs != metrics.pxPerMs ||
        oldDelegate.metrics.railWidth != metrics.railWidth ||
        oldDelegate.metrics.compact != metrics.compact ||
        oldDelegate.metrics.scrollMs != metrics.scrollMs ||
        oldDelegate.metrics.width != metrics.width ||
        oldDelegate.metrics.height != metrics.height;
  }
}

/// 재생 헤드 선만 그리는 층. [position]이 바뀔 때 이 층만 다시 칠한다.
class _PlayheadPainter extends CustomPainter {
  _PlayheadPainter({required this.metrics, required this.position})
    : super(repaint: position);

  final TimelineMetrics metrics;
  final ValueListenable<int> position;

  @override
  void paint(Canvas canvas, Size size) {
    final double x = metrics.xForTime(position.value);
    if (x < metrics.railWidth - 1 || x > metrics.width) {
      return;
    }
    final Paint line = Paint()
      ..color = EditorPalette.playhead
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(x, 0), Offset(x, metrics.height), line);

    final Path knob = Path()
      ..moveTo(x - 5, 0)
      ..lineTo(x + 5, 0)
      ..lineTo(x, 8)
      ..close();
    canvas.drawPath(knob, Paint()..color = EditorPalette.playhead);
  }

  @override
  bool shouldRepaint(covariant _PlayheadPainter oldDelegate) {
    return oldDelegate.position != position ||
        oldDelegate.metrics.pxPerMs != metrics.pxPerMs ||
        oldDelegate.metrics.railWidth != metrics.railWidth ||
        oldDelegate.metrics.compact != metrics.compact ||
        oldDelegate.metrics.scrollMs != metrics.scrollMs ||
        oldDelegate.metrics.width != metrics.width ||
        oldDelegate.metrics.height != metrics.height;
  }
}
