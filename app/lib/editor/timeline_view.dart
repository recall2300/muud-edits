import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../bridge_api.dart';
import '../models.dart';
import '../theme.dart';

const double _gutterWidth = 92;
const double _rowHeight = 44;
const double _rowGap = 6;
const double _rulerHeight = 26;
const double _subtitleLaneHeight = 30;
const double _rightPad = 28;

/// 타임라인 뷰.
///
/// 직접 그리기(CustomPainter)를 쓰는 이유: 클립이 수백 개가 되어도 위젯 트리를
/// 만들지 않아 스크롤/줌이 가볍다. 히트 테스트는 [TimelineMetrics]로 계산한다.
///
/// 재생 중 플레이헤드는 [playhead] 노티파이어만 따라 **선 하나만** 다시 그린다
/// (클립·눈금은 [RepaintBoundary]로 분리해 다시 래스터화하지 않는다).
class TimelineView extends StatelessWidget {
  const TimelineView({
    super.key,
    required this.controller,
    this.playhead,
    this.onScrubStart,
  });

  final EditorController controller;

  /// 재생 헤드 시각(없으면 [EditorController.playheadMs]를 한 번만 읽는다).
  final ValueListenable<int>? playhead;

  /// 사용자가 타임라인을 만지기 시작했을 때(재생 중이면 멈추게).
  final VoidCallback? onScrubStart;

  @override
  Widget build(BuildContext context) {
    final EditorState? state = controller.state;
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
        final TimelineMetrics metrics = TimelineMetrics(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          durationMs: state.durationMs,
          trackCount: state.tracks.length,
        );
        final ValueListenable<int> source =
            playhead ?? _StaticPlayhead(controller.playheadMs);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails details) {
            final ({TrackView track, ClipView clip})? hit = metrics.hitTest(
              state,
              details.localPosition,
            );
            controller.selectClip(hit?.clip.id);
            onScrubStart?.call();
            controller.setPlayhead(metrics.timeAt(details.localPosition.dx));
          },
          onHorizontalDragStart: (DragStartDetails details) {
            onScrubStart?.call();
            controller.setPlayhead(metrics.timeAt(details.localPosition.dx));
          },
          onHorizontalDragUpdate: (DragUpdateDetails details) {
            controller.setPlayhead(metrics.timeAt(details.localPosition.dx));
          },
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _TimelinePainter(
                      state: state,
                      metrics: metrics,
                      selectedClipId: controller.selectedClipId,
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
        );
      },
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
  }) {
    final double usable = math.max(width - _gutterWidth - _rightPad, 60);
    final int span = math.max(durationMs + 3000, 8000);
    pxPerMs = usable / span;
  }

  final double width;
  final double height;
  final int durationMs;
  final int trackCount;

  late final double pxPerMs;

  double get laneLeft => _gutterWidth;

  double get contentWidth => math.max(width - _gutterWidth - _rightPad, 60);

  double xForTime(int ms) => laneLeft + (ms < 0 ? 0 : ms) * pxPerMs;

  int timeAt(double dx) {
    final double raw = (dx - laneLeft) / pxPerMs;
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

  /// 좌표에 있는 클립(없으면 null).
  ({TrackView track, ClipView clip})? hitTest(
    EditorState state,
    Offset position,
  ) {
    for (int index = 0; index < state.tracks.length; index++) {
      final Rect lane = laneRect(index);
      if (position.dy < lane.top || position.dy > lane.bottom) {
        continue;
      }
      final TrackView track = state.tracks[index];
      for (final ClipView clip in track.clips) {
        final double left = xForTime(clip.offsetMs);
        final double right = xForTime(clip.endOffsetMs);
        if (position.dx >= left - 2 && position.dx <= right + 2) {
          return (track: track, clip: clip);
        }
      }
      return null;
    }
    return null;
  }

  /// 눈금 간격: 화면에서 70px 이상이 되는 최소 단위(초).
  int tickStepMs() {
    const List<int> candidates = <int>[
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
    ];
    for (final int step in candidates) {
      if (step * pxPerMs >= 70) {
        return step;
      }
    }
    return 300000;
  }
}

/// 클립·눈금·자막 — 플레이헤드와 무관한 정적인 층.
class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.state,
    required this.metrics,
    required this.selectedClipId,
  });

  final EditorState state;
  final TimelineMetrics metrics;
  final String? selectedClipId;

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
    canvas.drawRect(Rect.fromLTWH(0, 0, _gutterWidth, metrics.height), gutter);

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
      canvas.drawCircle(Offset(14, lane.center.dy), 4, dot);

      _drawText(
        canvas,
        track.name,
        Offset(26, lane.top + 8),
        _gutterWidth - 32,
        TextStyle(
          color: track.hidden ? EditorPalette.textMuted : EditorPalette.text,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      );
      _drawText(
        canvas,
        '${track.clips.length}개 · ${formatTimecode(track.durationMs)}',
        Offset(26, lane.top + 24),
        _gutterWidth - 32,
        const TextStyle(color: EditorPalette.textMuted, fontSize: 9),
      );

      if (track.locked) {
        _drawText(
          canvas,
          '🔒',
          Offset(_gutterWidth - 24, lane.top + 4),
          16,
          const TextStyle(fontSize: 10),
        );
      }
    }
  }

  void _paintClips(Canvas canvas) {
    for (int index = 0; index < state.tracks.length; index++) {
      final TrackView track = state.tracks[index];
      final Rect lane = metrics.laneRect(index);
      for (final ClipView clip in track.clips) {
        final double left = metrics.xForTime(clip.offsetMs);
        final double right = metrics.xForTime(clip.endOffsetMs);
        if (right - left < 2) {
          continue;
        }
        final Rect rect = Rect.fromLTRB(
          left,
          lane.top + 4,
          math.max(right, left + 2),
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
              ..strokeWidth = 1.6
              ..color = EditorPalette.text,
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
              '${formatTimecode(clip.durationMs)}${clip.speed == 1 ? '' : ' · ${clip.speed}x'}',
              Offset(rect.left + 6, rect.top + 20),
              rect.width - 12,
              TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 9,
              ),
            );
          }
        }

        // 페이드 핸들은 2단계(트랜지션/페이드 UI)에서 그린다.
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
      Offset(26, top + 8),
      _gutterWidth - 32,
      const TextStyle(color: EditorPalette.textMuted, fontSize: 10),
    );

    final Paint itemPaint = Paint()
      ..color = EditorPalette.subtitleTrack.withValues(alpha: 0.8);
    for (final SubtitleView item in state.subtitles) {
      final double left = metrics.xForTime(item.startMs);
      final double right = metrics.xForTime(item.endMs);
      if (right - left < 2) {
        continue;
      }
      final Rect rect = Rect.fromLTRB(
        left,
        top + 5,
        right,
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
        _gutterWidth,
        0,
        metrics.width - _gutterWidth,
        _rulerHeight,
      ),
      rulerBg,
    );

    final int step = metrics.tickStepMs();
    final int total = (metrics.timeAt(metrics.width) + step) > 86400000
        ? 86400000
        : metrics.timeAt(metrics.width) + step;
    final Paint tick = Paint()
      ..color = EditorPalette.outline
      ..strokeWidth = 1;

    for (int ms = 0; ms <= total; ms += step) {
      final double x = metrics.xForTime(ms);
      if (x > metrics.width) {
        break;
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
      Offset(_gutterWidth + 16, _rulerHeight + 8),
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
        oldDelegate.metrics.pxPerMs != metrics.pxPerMs ||
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
    if (x < _gutterWidth - 1 || x > metrics.width) {
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
        oldDelegate.metrics.width != metrics.width ||
        oldDelegate.metrics.height != metrics.height;
  }
}
