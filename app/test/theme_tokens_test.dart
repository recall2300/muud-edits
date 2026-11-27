// Astryx 시맨틱 토큰 테스트(v0.1.7).
//
//  * 간격·반경 스케일이 한 규칙(4px 기반)을 따르는가
//  * 텍스트 위계가 "작은 흐린 회색"이 아니라 무게·농도로 구분되는가
//  * 본문 텍스트가 배경 대비 WCAG AA(4.5:1)를 넘는가
//  * 브레이크포인트/밀도 계약(좁은 화면 48dp 타깃)이 지켜지는가
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muud_edits/theme.dart';

double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double lighter = la > lb ? la : lb;
  final double darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  group('간격·반경 스케일', () {
    test('간격은 4px 기반으로 커지고 tight/generous 대비를 만든다', () {
      const List<double> scale = <double>[
        EditorSpacing.xs,
        EditorSpacing.sm,
        EditorSpacing.md,
        EditorSpacing.lg,
        EditorSpacing.xl,
        EditorSpacing.xxl,
      ];
      for (int index = 1; index < scale.length; index++) {
        expect(
          scale[index],
          greaterThan(scale[index - 1]),
          reason: '스케일은 단조 증가해야 한다',
        );
      }
      expect(EditorSpacing.xs, 4);
      expect(EditorSpacing.sm, 8);
      expect(EditorSpacing.md, 12);
      expect(EditorSpacing.lg, 16);
      // generous 대비: xxl 은 xs 의 8배.
      expect(EditorSpacing.xxl, EditorSpacing.xs * 8);
    });

    test('섹션 내용은 하나의 content line 에 맞춘다', () {
      expect(EditorSpacing.contentLine, EditorSpacing.lg);
      expect(EditorSpacing.panelPadding.left, EditorSpacing.contentLine);
      expect(EditorSpacing.sectionPadding.left, EditorSpacing.contentLine);
    });

    test('반경은 작은 것부터 커지고, 경계선은 1px 이다', () {
      expect(EditorRadius.sm, lessThan(EditorRadius.md));
      expect(EditorRadius.md, lessThan(EditorRadius.lg));
      expect(EditorStroke.hairline, 1);
    });
  });

  group('텍스트 위계', () {
    test('크기를 줄이지 않고 무게·농도로 구분한다', () {
      // lead/section 은 굵게, body 는 보통.
      expect(EditorText.lead.fontWeight, FontWeight.w700);
      expect(EditorText.section.fontWeight, FontWeight.w700);
      expect(EditorText.body.fontWeight, FontWeight.w400);
      expect(EditorText.bodyStrong.fontWeight, FontWeight.w600);

      // 본문 계열은 11px 미만으로 내려가지 않는다.
      const List<TextStyle> bodyStyles = <TextStyle>[
        EditorText.display,
        EditorText.lead,
        EditorText.section,
        EditorText.body,
        EditorText.bodyStrong,
        EditorText.label,
        EditorText.caption,
        EditorText.numeric,
        EditorText.mono,
      ];
      for (final TextStyle style in bodyStyles) {
        expect(
          style.fontSize,
          greaterThanOrEqualTo(11),
          reason: '본문/라벨은 11px 이상이어야 읽힌다',
        );
      }
    });

    test('1차 > 2차 > 3차 텍스트의 명도 순서가 유지된다', () {
      final double primary = EditorText.primary.computeLuminance();
      final double secondary = EditorText.secondary.computeLuminance();
      final double tertiary = EditorText.tertiary.computeLuminance();
      expect(primary, greaterThan(secondary));
      expect(secondary, greaterThan(tertiary));
    });

    test('본문 텍스트는 배경 대비 WCAG AA(4.5:1)를 넘는다', () {
      expect(
        _contrast(EditorText.primary, EditorSurfaces.canvas),
        greaterThanOrEqualTo(7),
      );
      expect(
        _contrast(EditorText.secondary, EditorSurfaces.panel),
        greaterThanOrEqualTo(7),
      );
      // 곁다리 정보도 4.5:1 이상(읽을 수 있어야 한다).
      expect(
        _contrast(EditorText.tertiary, EditorSurfaces.panel),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('반응형 계약', () {
    test('브레이크포인트: <768 compact, 768~1023 medium, >=1024 wide', () {
      expect(EditorBreakpoints.layoutModeFor(390), EditorLayoutMode.compact);
      expect(
        EditorBreakpoints.layoutModeFor(EditorBreakpoints.compact - 0.1),
        EditorLayoutMode.compact,
      );
      expect(
        EditorBreakpoints.layoutModeFor(EditorBreakpoints.compact),
        EditorLayoutMode.medium,
      );
      expect(
        EditorBreakpoints.layoutModeFor(EditorBreakpoints.wide - 0.1),
        EditorLayoutMode.medium,
      );
      expect(
        EditorBreakpoints.layoutModeFor(EditorBreakpoints.wide),
        EditorLayoutMode.wide,
      );
    });

    test('좁은(터치) 화면은 48dp 최소 타깃, 데스크톱은 compact 밀도', () {
      final EditorDensity touch = EditorDensity.forWidth(390);
      final EditorDensity desktop = EditorDensity.forWidth(1280);

      expect(touch.minTarget, greaterThanOrEqualTo(48));
      expect(touch.isTouch, isTrue);
      expect(touch.iconSize, greaterThan(desktop.iconSize));

      expect(desktop.minTarget, lessThan(48));
      expect(desktop.name, 'compact');
    });
  });

  test('테마는 다크 단일 테마이고 1px 구분선을 쓴다', () {
    final ThemeData theme = buildEditorTheme();
    expect(theme.colorScheme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, EditorSurfaces.canvas);
    expect(theme.dividerTheme.thickness, EditorStroke.hairline);
    expect(theme.colorScheme.primary, EditorSurfaces.accent);
  });
}
