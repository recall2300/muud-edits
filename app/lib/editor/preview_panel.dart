import 'package:flutter/material.dart';

import '../bridge_api.dart';
import '../models.dart';
import '../theme.dart';

/// 프리뷰 패널.
///
/// 1단계에서는 **레이어 정보만으로** 텍스트/자막을 미리 보여 준다.
/// 실제 프레임은 플랫폼 텍스처(2단계)가 이 자리에 그려진다.
class PreviewPanel extends StatelessWidget {
  const PreviewPanel({super.key, required this.controller});

  final EditorController controller;

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
                  const _TextureSlot(),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 컴포지터 출력이 들어갈 자리(플랫폼 텍스처).
class _TextureSlot extends StatelessWidget {
  const _TextureSlot();

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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.movie_creation_outlined,
              size: 34,
              color: EditorPalette.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 8),
            Text(
              '프리뷰 렌더러 미연결',
              style: TextStyle(
                color: EditorPalette.textMuted.withValues(alpha: 0.8),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '플랫폼 텍스처를 붙이면 여기에 프레임이 표시됩니다',
              style: TextStyle(
                color: EditorPalette.textMuted.withValues(alpha: 0.45),
                fontSize: 9,
              ),
            ),
          ],
        ),
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
