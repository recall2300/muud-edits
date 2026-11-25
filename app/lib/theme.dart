import 'package:flutter/material.dart';

/// 편집기 팔레트. 다크 단일 테마로 시작한다(영상 편집은 색 판단이 중요하므로
/// UI의 채도/명도를 낮게 유지하고, 미리보기 캔버스만 중립 회색을 쓴다).
class EditorPalette {
  const EditorPalette._();

  static const Color background = Color(0xFF0E0F13);
  static const Color surface = Color(0xFF16181F);
  static const Color surfaceHigh = Color(0xFF1E2129);
  static const Color outline = Color(0xFF2C3040);
  static const Color accent = Color(0xFF7C5CFF);
  static const Color accentSoft = Color(0xFF3A2E78);
  static const Color text = Color(0xFFF2F3F7);
  static const Color textMuted = Color(0xFF9AA1B4);
  static const Color playhead = Color(0xFFFF4D6D);

  static const Color videoTrack = Color(0xFF2D6CDF);
  static const Color audioTrack = Color(0xFF1F9E77);
  static const Color overlayTrack = Color(0xFFB65CFF);
  static const Color subtitleTrack = Color(0xFFE0A100);

  /// 클립 종류별 블록 색.
  static Color forClipKind(String kind) {
    switch (kind) {
      case 'video':
        return videoTrack;
      case 'audio':
        return audioTrack;
      case 'image':
        return const Color(0xFF4B8BFF);
      case 'text':
        return overlayTrack;
      default:
        return surfaceHigh;
    }
  }

  /// 트랙 종류별 헤더 색.
  static Color forTrackKind(String kind) {
    switch (kind) {
      case 'video':
        return videoTrack;
      case 'audio':
        return audioTrack;
      case 'overlay':
        return overlayTrack;
      default:
        return outline;
    }
  }
}

ThemeData buildEditorTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: EditorPalette.accent,
    brightness: Brightness.dark,
  ).copyWith(
    surface: EditorPalette.surface,
    primary: EditorPalette.accent,
    outline: EditorPalette.outline,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: EditorPalette.background,
    splashFactory: InkSparkle.splashFactory,
    textTheme: const TextTheme(
      titleMedium: TextStyle(
        color: EditorPalette.text,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: TextStyle(color: EditorPalette.text, fontSize: 13),
      bodySmall: TextStyle(color: EditorPalette.textMuted, fontSize: 11),
      labelSmall: TextStyle(color: EditorPalette.textMuted, fontSize: 10),
    ),
    dividerColor: EditorPalette.outline,
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: EditorPalette.surfaceHigh,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: TextStyle(color: EditorPalette.text, fontSize: 11),
    ),
  );
}
