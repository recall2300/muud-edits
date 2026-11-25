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
class PreviewPanel extends StatelessWidget {
  const PreviewPanel({super.key, required this.controller, this.engine});

  final EditorController controller;

  /// 재생 엔진. 없으면 화면(EditorScreen)이 만든 것을 쓴다.
  final PreviewEngine? engine;

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
    final PreviewEngine? player = engine;

    final int playhead = controller.playheadMs;
    final List<ClipView> textClips = state.textClipsAt(playhead);
    final String? subtitle = state.subtitleAt(playhead);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Center(
        child: AspectRatio(
          aspectRatio: state.aspectRatio,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF07070A),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: EditorPalette.outline),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (player == null)
                    const _NoPlayerSlot()
                  else
                    _PreviewSurface(engine: player, state: state),
                  for (int index = 0; index < textClips.length; index++)
                    Align(
                      alignment: Alignment(0, 0.55 - index * 0.14),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          textClips[index].label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            shadows: const <Shadow>[
                              Shadow(color: Colors.black, blurRadius: 6),
                            ],
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(6),
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
                  Positioned(
                    left: 10,
                    top: 8,
                    child: _Badge(text: formatTimecode(playhead)),
                  ),
                  Positioned(
                    right: 10,
                    top: 8,
                    child: _Badge(
                      text: '${state.width}x${state.height} · ${state.fps}fps',
                    ),
                  ),
                  if (player != null && player.error != null)
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 8,
                      child: _Notice(
                        icon: Icons.error_outline,
                        color: EditorPalette.playhead,
                        text: player.error!,
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
          content = FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: 1000,
              height: 1000 / ratio,
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
        final double opacity = selection.visualClip?.opacity ?? 1;
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: content,
        );
      },
    );
  }
}

/// 재생 엔진이 없을 때(설정 오류)의 안내.
class _NoPlayerSlot extends StatelessWidget {
  const _NoPlayerSlot();

  @override
  Widget build(BuildContext context) {
    return const _GapSlot(
      icon: Icons.movie_creation_outlined,
      title: '프리뷰를 준비하는 중…',
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
                size: 30,
                color: EditorPalette.textMuted.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: EditorPalette.textMuted.withValues(alpha: 0.8),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
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
        borderRadius: BorderRadius.circular(6),
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
              style: TextStyle(color: color, fontSize: 9.5, height: 1.3),
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
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: EditorPalette.text,
          fontSize: 9,
          fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
