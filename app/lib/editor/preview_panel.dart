import 'dart:io';

import 'package:flutter/material.dart';

import '../bridge_api.dart';
import '../models.dart';
import '../theme.dart';
import 'preview_engine.dart';

/// 프리뷰 패널.
///
/// 실제 재생은 [PreviewEngine]이 맡는다(영상 프레임 + 소리). 이 위젯은
/// 재생 표면 위에 **텍스트 오버레이·자막·배지**를 재생 헤드 시각에 맞춰 그린다.
///
/// 재생 중에는 [PreviewEngine.position]만 구독해 오버레이와 타임코드만 다시
/// 그린다(영상 표면은 [PreviewEngine.repaint] 때만 바뀐다).
class PreviewPanel extends StatelessWidget {
  const PreviewPanel({
    super.key,
    required this.controller,
    required this.engine,
  });

  final EditorController controller;
  final PreviewEngine engine;

  @override
  Widget build(BuildContext context) {
    final EditorState? state = controller.state;
    if (state == null) {
      return Center(
        child: Text('프로젝트가 없습니다', style: EditorText.body),
      );
    }

    // 캔버스는 카드가 아니라 작업면이다. 1px 테두리와 낮은 반경만 남기고
    // 주변은 content line 에 맞춘 여백으로 비운다(영상 색 판단을 방해하지 않게).
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        EditorSpacing.contentLine,
        EditorSpacing.md,
        EditorSpacing.contentLine,
        EditorSpacing.sm,
      ),
      child: Center(
        child: AspectRatio(
          aspectRatio: state.aspectRatio,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF07070A),
              borderRadius: EditorRadius.mdAll,
              border: Border.all(
                color: EditorSurfaces.divider,
                width: EditorStroke.hairline,
              ),
            ),
            child: ClipRRect(
              borderRadius: EditorRadius.mdAll,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _PreviewSurface(engine: engine, state: state),
                  ValueListenableBuilder<int>(
                    valueListenable: engine.position,
                    builder: (BuildContext context, int playhead, Widget? _) =>
                        _OverlayLayer(state: state, playheadMs: playhead),
                  ),
                  Positioned(
                    right: EditorSpacing.sm,
                    top: EditorSpacing.sm,
                    child: _Badge(
                      text: '${state.width}x${state.height} · ${state.fps}fps',
                    ),
                  ),
                  if (engine.error != null)
                    Positioned(
                      left: EditorSpacing.sm,
                      right: EditorSpacing.sm,
                      bottom: EditorSpacing.sm,
                      child: _Notice(
                        icon: Icons.error_outline,
                        color: EditorSurfaces.danger,
                        text: engine.error!,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 재생 헤드 시각에 맞춰 그리는 텍스트·자막·배지.
///
/// 재생 중 매 프레임 다시 그려지는 부분을 여기로 모아 둔다.
class _OverlayLayer extends StatelessWidget {
  const _OverlayLayer({required this.state, required this.playheadMs});

  final EditorState state;
  final int playheadMs;

  @override
  Widget build(BuildContext context) {
    final List<ClipView> textClips = state.textClipsAt(playheadMs);
    final String? subtitle = state.subtitleAt(playheadMs);
    if (textClips.isEmpty && subtitle == null) {
      return const SizedBox.shrink();
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (int index = 0; index < textClips.length; index++)
          Align(
            alignment: Alignment(0, 0.55 - index * 0.14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                textClips[index].label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  shadows: <Shadow>[Shadow(color: Colors.black, blurRadius: 6)],
                  height: 1.25,
                ),
              ),
            ),
          ),
        if (subtitle != null)
          Align(
            alignment: const Alignment(0, 0.86),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 14),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: EditorRadius.smAll,
              ),
              child: Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 재생 표면(영상/이미지)과 그 위의 상태 표시.
class _PreviewSurface extends StatelessWidget {
  const _PreviewSurface({required this.engine, required this.state});

  final PreviewEngine engine;
  final EditorState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: engine.repaint,
      builder: (BuildContext context, int _, Widget? child) {
        final PreviewSelection selection = engine.selection;
        final Widget? surface = engine.surface;
        final String? imagePath = engine.imagePath;

        Widget content;
        if (surface != null) {
          final double ratio = engine.surfaceAspectRatio > 0
              ? engine.surfaceAspectRatio
              : state.aspectRatio;
          // 영상 텍스처는 **표시 크기에 바로** 맞춰 그린다.
          //
          // 이전에는 FittedBox + 고정 크기(1000px) 자식으로 텍스처를 매 프레임
          // 축소 변환해 그렸다. Android 에서는 이 변환·리샘플 단계에 텍스처 레이어가
          // 한 번 더 복사되는 경로가 생기고(특히 Impeller), 1000px 레이아웃을
          // 매번 다시 계산하게 된다. AspectRatio 로 맞추면 텍스처가 자기 비율
          // 그대로 한 번에 합성된다.
          content = Center(
            child: AspectRatio(
              aspectRatio: ratio,
              child: surface,
            ),
          );
        } else if (imagePath != null) {
          content = Image.file(
            File(imagePath),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (BuildContext context, Object error, _) =>
                const _GapSlot(
                  icon: Icons.broken_image_outlined,
                  title: '이미지를 표시할 수 없습니다',
                ),
          );
        } else if (engine.isLoading) {
          content = const _GapSlot(
            icon: Icons.hourglass_bottom,
            title: '프레임을 준비하는 중…',
          );
        } else {
          content = const _GapSlot(
            icon: Icons.movie_outlined,
            title: '이 구간에는 영상이 없습니다',
          );
        }

        // 영상 클립 불투명도 반영(텍스트/자막은 위에서 별도로 그린다).
        //
        // 불투명(1.0)일 때 Opacity 로 감싸면 저장 레이어(saveLayer)가 하나
        // 생길 수 있는 경로를 만든다(영상 텍스처를 오프스크린에 한 번 더 그린다).
        // 실제로 투명도가 줄었을 때만 감싼다.
        final double opacity = (selection.visualClip?.opacity ?? 1).clamp(
          0.0,
          1.0,
        );
        if (opacity >= 0.999) {
          return content;
        }
        return Opacity(opacity: opacity, child: content);
      },
    );
  }
}

/// 영상이 없는 자리.
class _GapSlot extends StatelessWidget {
  const _GapSlot({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF15161C), Color(0xFF0A0A0E)],
        ),
      ),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                size: 28,
                color: EditorText.tertiary.withValues(alpha: 0.6),
              ),
              const SizedBox(height: EditorSpacing.sm),
              Text(
                title,
                textAlign: TextAlign.center,
                style: EditorText.body.copyWith(color: EditorText.secondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: EditorRadius.smAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 11, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: EditorRadius.smAll,
      ),
      child: Text(
        text,
        style: EditorText.numeric.copyWith(fontSize: 10, color: EditorText.secondary),
      ),
    );
  }
}
