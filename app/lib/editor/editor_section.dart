import 'package:flutter/material.dart';

import '../theme.dart';

/// 패널 안의 한 구획.
///
/// Astryx 의 "카드 대신 Section + Divider + 하나의 content line" 규칙을 그대로
/// 옮긴 위젯이다. 테두리 박스로 감싸지 않고, 제목 한 줄과 1px 구분선만으로
/// 위계를 만든다. 모든 내용은 같은 좌우 기준선([EditorSpacing.contentLine])에
/// 맞춘다.
class EditorSection extends StatelessWidget {
  const EditorSection({
    super.key,
    required this.title,
    required this.child,
    this.meta,
    this.trailing,
    this.showDivider = true,
    this.padding = const EdgeInsets.fromLTRB(
      EditorSpacing.contentLine,
      EditorSpacing.lg,
      EditorSpacing.contentLine,
      EditorSpacing.md,
    ),
  });

  final String title;

  /// 제목 옆 곁다리 정보(개수·단위 등). 크기를 줄이지 않고 3차 색으로 둔다.
  final String? meta;

  /// 제목 줄 오른쪽의 보조 행동(링크·아이콘).
  final Widget? trailing;

  final Widget child;
  final bool showDivider;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final String? metaText = meta;
    final Widget? trailingWidget = trailing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      title,
                      style: EditorText.section,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (metaText != null && metaText.isNotEmpty) ...<Widget>[
                    const SizedBox(width: EditorSpacing.sm),
                    Flexible(
                      child: Text(
                        metaText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: EditorText.caption,
                      ),
                    ),
                  ],
                  if (trailingWidget != null) ...<Widget>[
                    const SizedBox(width: EditorSpacing.xs),
                    trailingWidget,
                  ],
                ],
              ),
              const SizedBox(height: EditorSpacing.sm),
              child,
            ],
          ),
        ),
        if (showDivider)
          const Divider(height: EditorStroke.hairline, thickness: 1),
      ],
    );
  }
}

/// 패널·영역의 lead(제목 한 줄). 영역마다 하나만 둔다.
class EditorLead extends StatelessWidget {
  const EditorLead({
    super.key,
    required this.title,
    this.meta,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      EditorSpacing.contentLine,
      EditorSpacing.md,
      EditorSpacing.contentLine,
      EditorSpacing.sm,
    ),
  });

  final String title;
  final String? meta;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final String? metaText = meta;
    final Widget? trailingWidget = trailing;
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: EditorText.lead,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (metaText != null && metaText.isNotEmpty) ...<Widget>[
            const SizedBox(width: EditorSpacing.sm),
            Flexible(
              child: Text(
                metaText,
                style: EditorText.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
          ],
          if (trailingWidget != null) trailingWidget,
        ],
      ),
    );
  }
}
