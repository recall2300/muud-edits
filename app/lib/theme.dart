import 'package:flutter/material.dart';

/// 편집기 팔레트. 다크 단일 테마로 시작한다(영상 편집은 색 판단이 중요하므로
/// UI의 채도/명도를 낮게 유지하고, 미리보기 캔버스만 중립 회색을 쓴다).
///
/// 이 클래스는 **원시 색상**만 담는다. 위젯은 아래의 시맨틱 토큰
/// ([EditorText], [EditorSurfaces], [EditorSpacing] …)을 읽고, 색을 직접
/// 만들지 않는다. Astryx 의 "토큰 → 컴포넌트" 2계층 규칙과 같다.
class EditorPalette {
  const EditorPalette._();

  static const Color background = Color(0xFF0E0F13);
  static const Color surface = Color(0xFF16181F);
  static const Color surfaceHigh = Color(0xFF1E2129);
  static const Color surfaceRaised = Color(0xFF242835);
  static const Color outline = Color(0xFF2C3040);
  static const Color outlineStrong = Color(0xFF3A4055);
  static const Color accent = Color(0xFF7C5CFF);
  static const Color accentSoft = Color(0xFF3A2E78);
  static const Color text = Color(0xFFF2F3F7);

  /// 본문 보조 텍스트. 예전 `textMuted` 를 그대로 두면 화면 전체가 흐린
  /// 회색이 되므로, 읽어야 하는 보조 정보는 [textSecondary] 를 쓴다.
  static const Color textSecondary = Color(0xFFC3C8D6);

  /// 정말 곁다리인 정보(타임코드·단위·개수)에만 쓰는 3차 텍스트.
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

// -----------------------------------------------------------------------------
// 시맨틱 토큰 (Astryx 이식)
// -----------------------------------------------------------------------------

/// 간격 스케일 — 4px 기반. 조밀한 곳([xs]·[sm])과 넉넉한 곳([xl]·[xxl])의
/// 대비를 일부러 크게 두어 "빽빽한 표"가 아니라 "정돈된 패널"로 읽히게 한다.
abstract final class EditorSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// 섹션 내용이 맞춰지는 단일 기준선(content line).
  /// 제목·본문·구분선이 모두 이 값에서 시작한다.
  static const double contentLine = lg;

  static const EdgeInsets panelPadding = EdgeInsets.fromLTRB(
    contentLine,
    md,
    contentLine,
    md,
  );

  static const EdgeInsets sectionPadding = EdgeInsets.fromLTRB(
    contentLine,
    lg,
    contentLine,
    0,
  );
}

/// 모서리 반경. 컨테이너 중첩을 줄였으므로 큰 반경은 시트/캔버스에만 쓴다.
abstract final class EditorRadius {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgTop = BorderRadius.vertical(
    top: Radius.circular(lg),
  );
}

/// 1px 경계. 카드 중첩 대신 이 선 하나로 영역을 나눈다.
abstract final class EditorStroke {
  static const double hairline = 1;
}

/// 텍스트 위계 — **크기를 줄이는 대신 무게와 농도로** 구분한다.
/// (Astryx: "흐린 작은 회색 글씨 남발 금지")
abstract final class EditorText {
  static const Color primary = EditorPalette.text;
  static const Color secondary = EditorPalette.textSecondary;
  static const Color tertiary = EditorPalette.textMuted;
  static const Color onAccent = Colors.white;

  /// 화면/시트의 대표 제목(프로젝트 이름, 계획 제목).
  static const TextStyle display = TextStyle(
    color: primary,
    fontSize: 17,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    height: 1.25,
  );

  /// 상단 바·영역의 lead.
  static const TextStyle lead = TextStyle(
    color: primary,
    fontSize: 15,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.1,
    height: 1.25,
  );

  /// 패널 안 섹션 제목.
  static const TextStyle section = TextStyle(
    color: primary,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.1,
    height: 1.3,
  );

  /// 본문.
  static const TextStyle body = TextStyle(
    color: secondary,
    fontSize: 12.5,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  /// 강조가 필요한 본문(값·이름).
  static const TextStyle bodyStrong = TextStyle(
    color: primary,
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  /// 필드 라벨.
  static const TextStyle label = TextStyle(
    color: secondary,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  /// 곁다리 메타데이터(단위·개수·경로).
  static const TextStyle caption = TextStyle(
    color: tertiary,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  /// 타임코드·숫자(자리 고정).
  static const TextStyle numeric = TextStyle(
    color: secondary,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    height: 1.3,
  );

  /// 내보내기 명령 같은 고정폭 텍스트.
  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    color: secondary,
    fontSize: 11,
    height: 1.45,
  );
}

/// 표면 계층 — 위로 갈수록 밝다. 3단계를 넘기지 않는다.
abstract final class EditorSurfaces {
  /// 타임라인 캔버스·미리보기 바탕.
  static const Color canvas = EditorPalette.background;

  /// 패널·상단 바.
  static const Color panel = EditorPalette.surface;

  /// 입력칸·호버 등 패널 안에서 한 단계 올라간 면.
  static const Color raised = EditorPalette.surfaceHigh;

  /// 시트·메뉴(가장 위).
  static const Color overlay = EditorPalette.surfaceRaised;

  /// 1px 경계선.
  static const Color divider = EditorPalette.outline;

  static const Color accent = EditorPalette.accent;
  static const Color accentSoft = EditorPalette.accentSoft;
  static const Color danger = EditorPalette.playhead;
  static const Color success = EditorPalette.audioTrack;
}

/// 반응형 계약. 코드의 분기와 주석이 같은 값을 쓰도록 여기 한 곳에 둔다.
///
/// * `>= 1024px` — wide: 상단 바 / [미리보기 | 리사이즈 가능 인스펙터] / 타임라인
/// * `768 ~ 1023px` — medium: 2영역. 클립을 선택했을 때만 좁은(축소 폭) 인스펙터
/// * `< 768px` — compact: 인스펙터 사이드 패널 없음 → 하단 BottomSheet 로 스왑
abstract final class EditorBreakpoints {
  static const double compact = 768;
  static const double wide = 1024;

  static EditorLayoutMode layoutModeFor(double width) {
    if (width >= wide) {
      return EditorLayoutMode.wide;
    }
    if (width >= compact) {
      return EditorLayoutMode.medium;
    }
    return EditorLayoutMode.compact;
  }
}

enum EditorLayoutMode {
  /// < 768px — 터치 48dp 타깃, 하단 시트 인스펙터.
  compact,

  /// 768~1023px — 축소 폭 사이드 패널(선택 시).
  medium,

  /// >= 1024px — 고정 사이드 패널 + 리사이즈 핸들.
  wide,
}

/// 터치/포인터 밀도. 좁은 화면(터치)은 48dp 최소 타깃을 반드시 확보하고,
/// 데스크톱은 compact 밀도로 정보를 더 담는다.
class EditorDensity {
  const EditorDensity({
    required this.name,
    required this.minTarget,
    required this.controlHeight,
    required this.iconSize,
    required this.panelGap,
  });

  final String name;

  /// 눌러야 하는 요소의 최소 한 변(dp).
  final double minTarget;

  /// 슬라이더·입력칸이 앉는 행 높이.
  final double controlHeight;

  final double iconSize;

  /// 패널 요소 사이 세로 간격.
  final double panelGap;

  static const EditorDensity touch = EditorDensity(
    name: 'touch',
    minTarget: 48,
    controlHeight: 44,
    iconSize: 22,
    panelGap: 10,
  );

  static const EditorDensity compact = EditorDensity(
    name: 'compact',
    minTarget: 32,
    controlHeight: 32,
    iconSize: 18,
    panelGap: 6,
  );

  /// 좁은 화면(터치)에서 48dp 타깃을 보장한다.
  static EditorDensity forWidth(double width) =>
      width < EditorBreakpoints.compact ? touch : compact;

  bool get isTouch => minTarget >= 48;
}

// -----------------------------------------------------------------------------
// 테마
// -----------------------------------------------------------------------------

ThemeData buildEditorTheme() {
  final ColorScheme scheme =
      ColorScheme.fromSeed(
        seedColor: EditorPalette.accent,
        brightness: Brightness.dark,
      ).copyWith(
        surface: EditorSurfaces.panel,
        onSurface: EditorText.primary,
        surfaceContainerHighest: EditorSurfaces.raised,
        primary: EditorSurfaces.accent,
        onPrimary: EditorText.onAccent,
        outline: EditorSurfaces.divider,
        error: EditorSurfaces.danger,
      );

  const RoundedRectangleBorder panelShape = RoundedRectangleBorder(
    borderRadius: EditorRadius.mdAll,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: EditorSurfaces.canvas,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.compact,
    textTheme: const TextTheme(
      titleMedium: EditorText.lead,
      titleSmall: EditorText.section,
      bodyMedium: EditorText.body,
      bodySmall: EditorText.caption,
      labelLarge: EditorText.label,
      labelSmall: EditorText.caption,
    ),
    dividerColor: EditorSurfaces.divider,
    dividerTheme: const DividerThemeData(
      color: EditorSurfaces.divider,
      thickness: EditorStroke.hairline,
      space: EditorStroke.hairline,
    ),
    iconTheme: const IconThemeData(
      color: EditorText.secondary,
      size: 20,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: EditorSurfaces.accent,
        foregroundColor: EditorText.onAccent,
        disabledBackgroundColor: EditorPalette.surfaceHigh,
        disabledForegroundColor: EditorText.tertiary,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: EditorSpacing.md),
        shape: panelShape,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: EditorText.primary,
        side: const BorderSide(
          color: EditorSurfaces.divider,
          width: EditorStroke.hairline,
        ),
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: EditorSpacing.md),
        shape: panelShape,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: EditorText.secondary,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: EditorSpacing.sm),
        shape: panelShape,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: EditorText.secondary,
        disabledForegroundColor: EditorText.tertiary.withValues(alpha: 0.4),
        shape: const RoundedRectangleBorder(borderRadius: EditorRadius.smAll),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: EditorPalette.background,
      hintStyle: EditorText.caption,
      labelStyle: EditorText.caption,
      floatingLabelStyle: EditorText.caption,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: EditorSpacing.md,
        vertical: 10,
      ),
      border: const OutlineInputBorder(
        borderRadius: EditorRadius.smAll,
        borderSide: BorderSide(
          color: EditorSurfaces.divider,
          width: EditorStroke.hairline,
        ),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: EditorRadius.smAll,
        borderSide: BorderSide(
          color: EditorSurfaces.divider,
          width: EditorStroke.hairline,
        ),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: EditorRadius.smAll,
        borderSide: BorderSide(
          color: EditorSurfaces.accent,
          width: EditorStroke.hairline,
        ),
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 2,
      activeTrackColor: EditorSurfaces.accent,
      inactiveTrackColor: EditorPalette.surfaceRaised,
      thumbColor: EditorText.primary,
      overlayColor: EditorSurfaces.accent.withValues(alpha: 0.14),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      valueIndicatorTextStyle: EditorText.caption,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: EditorSurfaces.panel,
      surfaceTintColor: Colors.transparent,
      shape: panelShape,
      titleTextStyle: EditorText.lead,
      contentTextStyle: EditorText.body,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: EditorSurfaces.overlay,
      surfaceTintColor: Colors.transparent,
      shape: panelShape,
      textStyle: EditorText.body,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: EditorSurfaces.overlay,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: EditorSurfaces.overlay,
      shape: RoundedRectangleBorder(borderRadius: EditorRadius.lgTop),
      showDragHandle: false,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: EditorSurfaces.overlay,
      contentTextStyle: EditorText.body,
      actionTextColor: EditorPalette.accent,
      shape: panelShape,
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: EditorSurfaces.accent,
      linearTrackColor: EditorPalette.surfaceRaised,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: EditorSurfaces.raised,
      selectedColor: EditorSurfaces.accentSoft,
      side: const BorderSide(
        color: EditorSurfaces.divider,
        width: EditorStroke.hairline,
      ),
      shape: const RoundedRectangleBorder(borderRadius: EditorRadius.smAll),
      labelStyle: EditorText.label,
      showCheckmark: false,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: EditorSurfaces.overlay,
        borderRadius: EditorRadius.smAll,
        border: Border.fromBorderSide(
          BorderSide(
            color: EditorSurfaces.divider,
            width: EditorStroke.hairline,
          ),
        ),
      ),
      textStyle: EditorText.caption,
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}
