import 'package:flutter/material.dart';

import '../bridge_api.dart';
import '../models.dart';
import '../theme.dart';
import 'editor_section.dart';

/// 인스펙터의 빈 상태 키(테스트·레이아웃 계약 확인용).
const Key inspectorEmptyStateKey = ValueKey<String>('inspector-empty-state');

/// 클립 인스펙터(선택된 클립의 속성 편집).
///
/// Astryx 규칙으로 정리했다:
/// * 카드 안의 카드를 없애고 [EditorSection] + 1px 구분선만 쓴다.
/// * 영역 lead 는 "인스펙터" 하나, 클립 정보는 메타로 내린다.
/// * 모든 내용이 같은 좌우 기준선(content line)에 앉는다.
/// * 보조 설명은 크기를 줄이지 않고 weight/2·3차 색으로 구분한다.
///
/// 모든 조작은 커맨드로 나가므로 즉시 되돌릴 수 있다.
class InspectorPanel extends StatelessWidget {
  const InspectorPanel({
    super.key,
    required this.controller,
    this.onClose,
    this.closeTooltip = '선택 해제',
  });

  final EditorController controller;

  /// 선택 해제(사이드 패널) 또는 시트 닫기(모바일).
  final VoidCallback? onClose;

  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    final ({TrackView track, ClipView clip})? selected = controller.selected;
    final VoidCallback? close = onClose;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        EditorLead(
          title: '인스펙터',
          meta: selected == null
              ? '선택 없음'
              : '${selected.clip.kind} · ${selected.track.name}',
          trailing: close == null || selected == null
              ? null
              : IconButton(
                  tooltip: closeTooltip,
                  onPressed: close,
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close),
                ),
        ),
        const Divider(height: EditorStroke.hairline, thickness: 1),
        Expanded(
          child: selected == null
              ? const InspectorEmptyState(key: inspectorEmptyStateKey)
              : _ClipInspector(controller: controller, selected: selected),
        ),
      ],
    );
  }
}

/// 선택된 클립이 없을 때. 가운데 정렬된 안내 두 줄로, 패널이 좁아도
/// 레이아웃이 무너지지 않도록 스크롤 안에서 정렬한다.
class InspectorEmptyState extends StatelessWidget {
  const InspectorEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: EditorSpacing.contentLine,
          vertical: EditorSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.tune,
              size: 20,
              color: EditorText.tertiary,
            ),
            const SizedBox(height: EditorSpacing.sm),
            const Text(
              '선택한 클립이 없습니다',
              textAlign: TextAlign.center,
              style: EditorText.bodyStrong,
            ),
            const SizedBox(height: EditorSpacing.xs),
            Text(
              '타임라인에서 클립을 선택하면 소스 구간·속도·볼륨·불투명도를 '
              '여기에서 조정할 수 있습니다.',
              textAlign: TextAlign.center,
              style: EditorText.caption.copyWith(
                color: EditorText.tertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClipInspector extends StatelessWidget {
  const _ClipInspector({required this.controller, required this.selected});

  final EditorController controller;
  final ({TrackView track, ClipView clip}) selected;

  @override
  Widget build(BuildContext context) {
    final ClipView clip = selected.clip;
    final bool isText = clip.kind == 'text';
    final EditorDensity density = EditorDensity.forWidth(
      MediaQuery.sizeOf(context).width,
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: EditorSpacing.xl),
      children: <Widget>[
        // 편집 가능한 것(문구/자르기)을 먼저, 읽기용 정보(구간)를 마지막에 둔다.
        if (isText)
          EditorSection(
            title: '문구',
            meta: (clip.textContent ?? '').isEmpty ? '비어 있음' : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  (clip.textContent ?? '').isEmpty
                      ? '(빈 텍스트)'
                      : clip.textContent!,
                  style: EditorText.body,
                ),
                const SizedBox(height: EditorSpacing.sm),
                _TextContentEditor(
                  clip: clip,
                  onCommit: (String value) =>
                      controller.setTextClipContent(clip, value),
                ),
              ],
            ),
          )
        else
          EditorSection(
            title: '자르기',
            meta: '소스 인점 · 아웃점',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _TrimSlider(
                  label: '시작 자르기',
                  valueMs: clip.startMs,
                  minMs: 0,
                  maxMs: clip.endMs - 34 > 0 ? clip.endMs - 34 : 1,
                  onCommitMs: (int value) =>
                      controller.trimClip(startMs: value),
                ),
                _TrimSlider(
                  label: '끝 자르기',
                  valueMs: clip.endMs,
                  minMs: clip.startMs + 34,
                  maxMs: (clip.sourceDurationMs ?? clip.endMs) >
                          clip.startMs + 34
                      ? (clip.sourceDurationMs ?? clip.endMs)
                      : clip.startMs + 35,
                  onCommitMs: (int value) => controller.trimClip(endMs: value),
                ),
                const SizedBox(height: EditorSpacing.xs),
                Wrap(
                  spacing: EditorSpacing.sm,
                  runSpacing: EditorSpacing.sm,
                  children: <Widget>[
                    _ActionButton(
                      icon: Icons.first_page,
                      label: '앞 1프레임',
                      height: density.controlHeight,
                      onTap: () =>
                          controller.nudgeTrim(fromStart: true, frames: 1),
                    ),
                    _ActionButton(
                      icon: Icons.last_page,
                      label: '뒤 1프레임',
                      height: density.controlHeight,
                      onTap: () =>
                          controller.nudgeTrim(fromStart: false, frames: 1),
                    ),
                  ],
                ),
              ],
            ),
          ),
        EditorSection(
          title: '조정',
          meta: '배속 · 오디오 · 표시',
          child: Column(
            children: <Widget>[
              _ValueSlider(
                label: '속도',
                value: clip.speed,
                min: 0.25,
                max: 4.0,
                divisions: 15,
                display: '${clip.speed.toStringAsFixed(2)}x',
                onCommit: controller.setSpeed,
              ),
              _ValueSlider(
                label: '볼륨',
                value: clip.volume,
                min: 0,
                max: 2,
                divisions: 20,
                display: '${(clip.volume * 100).round()}%',
                onCommit: controller.setVolume,
              ),
              _ValueSlider(
                label: '불투명도',
                value: clip.opacity,
                min: 0,
                max: 1,
                divisions: 20,
                display: '${(clip.opacity * 100).round()}%',
                onCommit: controller.setOpacity,
              ),
            ],
          ),
        ),
        EditorSection(
          title: '구간',
          meta: '읽기 전용',
          showDivider: false,
          child: Column(
            children: <Widget>[
              _InfoRow(
                label: '소스',
                value: clip.sourcePath.isEmpty ? '(텍스트)' : clip.sourcePath,
              ),
              _InfoRow(
                label: '소스 구간',
                value:
                    '${formatTimecode(clip.startMs)} → ${formatTimecode(clip.endMs)}',
              ),
              _InfoRow(
                label: '타임라인',
                value:
                    '${formatTimecode(clip.offsetMs)} → ${formatTimecode(clip.endOffsetMs)}'
                    ' (${formatTimecode(clip.durationMs)})',
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: EditorSpacing.contentLine,
            vertical: EditorSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: controller.moveSelectedToPlayhead,
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size(0, density.controlHeight),
                  ),
                  icon: const Icon(Icons.content_cut, size: 15),
                  label: const Text('재생 헤드로 이동'),
                ),
              ),
              const SizedBox(width: EditorSpacing.sm),
              TextButton.icon(
                onPressed: controller.deleteSelected,
                style: TextButton.styleFrom(
                  foregroundColor: EditorSurfaces.danger,
                  minimumSize: Size(0, density.controlHeight),
                ),
                icon: const Icon(Icons.delete_outline, size: 15),
                label: const Text('삭제'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 소스 인점/아웃점 슬라이더(드래그 중 로컬 값, 손을 떼면 커맨드 한 번).
class _TrimSlider extends StatefulWidget {
  const _TrimSlider({
    required this.label,
    required this.valueMs,
    required this.minMs,
    required this.maxMs,
    required this.onCommitMs,
  });

  final String label;
  final int valueMs;
  final int minMs;
  final int maxMs;
  final Future<void> Function(int valueMs) onCommitMs;

  @override
  State<_TrimSlider> createState() => _TrimSliderState();
}

class _TrimSliderState extends State<_TrimSlider> {
  late double _draft = widget.valueMs.toDouble();

  @override
  void didUpdateWidget(covariant _TrimSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valueMs != widget.valueMs) {
      _draft = widget.valueMs.toDouble();
    }
  }

  @override
  Widget build(BuildContext context) {
    final double min = widget.minMs.toDouble();
    final double max = widget.maxMs.toDouble() <= min
        ? min + 1
        : widget.maxMs.toDouble();
    return Row(
      children: <Widget>[
        SizedBox(
          width: 64,
          child: Text(widget.label, style: EditorText.label),
        ),
        Expanded(
          child: Slider(
            value: _draft.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: (double value) => setState(() => _draft = value),
            onChangeEnd: (double value) => widget.onCommitMs(value.round()),
          ),
        ),
        SizedBox(
          width: 72,
          child: Text(
            formatTimecode(_draft.round()),
            textAlign: TextAlign.right,
            style: EditorText.numeric.copyWith(fontSize: 10),
          ),
        ),
      ],
    );
  }
}

/// 텍스트 클립의 문구를 바로 고치는 입력칸.
///
/// 입력 중에는 로컬 값만 바꾸고, "적용"을 누를 때 `set_clip_text` 커맨드를
/// 한 번 보낸다(타이핑마다 커맨드를 쌓지 않는다 — 되돌리기 한 단계로 유지).
class _TextContentEditor extends StatefulWidget {
  const _TextContentEditor({required this.clip, required this.onCommit});

  final ClipView clip;
  final Future<void> Function(String value) onCommit;

  @override
  State<_TextContentEditor> createState() => _TextContentEditorState();
}

class _TextContentEditorState extends State<_TextContentEditor> {
  late final TextEditingController _text = TextEditingController(
    text: widget.clip.textContent ?? '',
  );
  late String _clipId = widget.clip.id;

  @override
  void didUpdateWidget(covariant _TextContentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 다른 텍스트 클립을 골랐을 때만 입력칸을 그 클립의 문구로 바꾼다
    // (같은 클립이면 사용자가 타이핑 중인 내용을 건드리지 않는다).
    if (widget.clip.id != _clipId) {
      _clipId = widget.clip.id;
      _text.text = widget.clip.textContent ?? '';
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text('문구 수정', style: EditorText.label),
        const SizedBox(height: EditorSpacing.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _text,
                style: EditorText.body,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '화면에 표시할 문구',
                ),
                onSubmitted: (String value) => _commit(),
              ),
            ),
            const SizedBox(width: EditorSpacing.sm),
            FilledButton(
              onPressed: _commit,
              style: FilledButton.styleFrom(
                minimumSize: const Size(52, 38),
                padding: const EdgeInsets.symmetric(
                  horizontal: EditorSpacing.md,
                ),
              ),
              child: const Text('적용'),
            ),
          ],
        ),
      ],
    );
  }

  void _commit() {
    final String value = _text.text.trim();
    if (value.isEmpty) {
      return;
    }
    if (value == (widget.clip.textContent ?? '')) {
      return;
    }
    widget.onCommit(value);
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: EditorSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(label, style: EditorText.label),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: EditorText.body,
            ),
          ),
        ],
      ),
    );
  }
}

/// 드래그 중에는 로컬 값만 바꾸고, 손을 떼면 커맨드를 한 번만 보낸다.
class _ValueSlider extends StatefulWidget {
  const _ValueSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onCommit,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final int? divisions;
  final Future<void> Function(double value) onCommit;

  @override
  State<_ValueSlider> createState() => _ValueSliderState();
}

class _ValueSliderState extends State<_ValueSlider> {
  late double _draft = widget.value;

  @override
  void didUpdateWidget(covariant _ValueSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _draft = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 54,
          child: Text(widget.label, style: EditorText.label),
        ),
        Expanded(
          child: Slider(
            value: _draft.clamp(widget.min, widget.max).toDouble(),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            onChanged: (double value) => setState(() => _draft = value),
            onChangeEnd: (double value) => widget.onCommit(value),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            widget.display,
            textAlign: TextAlign.right,
            style: EditorText.numeric,
          ),
        ),
      ],
    );
  }
}

/// 패널 안의 보조 행동. 카드가 아니라 한 줄짜리 조용한 버튼이다.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.height,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(minimumSize: Size(0, height)),
      icon: Icon(icon, size: 14),
      label: Text(label),
    );
  }
}
